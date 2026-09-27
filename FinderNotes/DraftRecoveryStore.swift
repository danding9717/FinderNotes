import Darwin
import Foundation

/// A recovery record is an unsaved draft and the exact baseline against which it was edited.
/// It is never a second source of saved notes and never grants permission to write to its path.
struct DraftRecoveryRecord: Codable, Sendable, Equatable {
    let version: Int
    let id: UUID
    let draft: String
    let revision: UInt64
    let updatedAt: Date
    private let baseline: NoteSnapshot

    var snapshot: NoteSnapshot { baseline }

    init(id: UUID, baseline: NoteSnapshot, draft: String, revision: UInt64) {
        self.version = 1
        self.id = id
        // Foundation may retain the system /var alias even after resolvingSymlinksInPath.
        // Match NoteReader's canonical path both in memory and in the on-disk representation.
        if baseline.url.isFileURL,
           baseline.url.host == nil || baseline.url.host == "" || baseline.url.host == "localhost",
           baseline.url.query == nil, baseline.url.fragment == nil,
           let path = try? NoteReader.localPath(baseline.url.path) {
            self.baseline = NoteSnapshot(url: URL(fileURLWithPath: path),
                                         identity: baseline.identity, content: baseline.content)
        } else {
            self.baseline = baseline
        }
        self.draft = draft
        self.revision = revision
        self.updatedAt = Date()
    }

    private enum Keys: String, CodingKey { case version, id, baseline, draft, revision, updatedAt }
    private enum BaselineKeys: String, CodingKey { case path, identity, content }
    private enum IdentityKeys: String, CodingKey { case device, inode, birthSeconds, birthNanoseconds }
    private enum ContentKeys: String, CodingKey { case kind, bytes }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == 1 else { throw DraftRecoveryError.unsupportedVersion }
        id = try values.decode(UUID.self, forKey: .id)
        draft = try values.decode(String.self, forKey: .draft)
        revision = try values.decode(UInt64.self, forKey: .revision)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        let baselineValues = try values.nestedContainer(keyedBy: BaselineKeys.self, forKey: .baseline)
        let path = try baselineValues.decode(String.self, forKey: .path)
        guard try NoteReader.localPath(path) == path else { throw DraftRecoveryError.invalidRecord }
        let identityValues = try baselineValues.nestedContainer(keyedBy: IdentityKeys.self, forKey: .identity)
        let identity = FileIdentity(device: try identityValues.decode(UInt64.self, forKey: .device),
                                    inode: try identityValues.decode(UInt64.self, forKey: .inode),
                                    birthSeconds: try identityValues.decode(Int64.self, forKey: .birthSeconds),
                                    birthNanoseconds: try identityValues.decode(Int64.self, forKey: .birthNanoseconds))
        let contentValues = try baselineValues.nestedContainer(keyedBy: ContentKeys.self, forKey: .content)
        let content: NoteContent
        switch try contentValues.decode(String.self, forKey: .kind) {
        case "missing":
            guard !contentValues.contains(.bytes) else { throw DraftRecoveryError.invalidRecord }
            content = .missing
        case "present":
            let bytes = try contentValues.decode(Data.self, forKey: .bytes)
            guard String(data: bytes, encoding: .utf8) != nil else { throw DraftRecoveryError.invalidUTF8 }
            content = .present(bytes)
        default:
            throw DraftRecoveryError.invalidRecord
        }
        baseline = NoteSnapshot(url: URL(fileURLWithPath: path), identity: identity, content: content)
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(version, forKey: .version)
        try values.encode(id, forKey: .id)
        try values.encode(draft, forKey: .draft)
        try values.encode(revision, forKey: .revision)
        try values.encode(updatedAt, forKey: .updatedAt)
        var baselineValues = values.nestedContainer(keyedBy: BaselineKeys.self, forKey: .baseline)
        try baselineValues.encode(try NoteReader.localPath(baseline.url.path), forKey: .path)
        var identityValues = baselineValues.nestedContainer(keyedBy: IdentityKeys.self, forKey: .identity)
        try identityValues.encode(baseline.identity.device, forKey: .device)
        try identityValues.encode(baseline.identity.inode, forKey: .inode)
        try identityValues.encode(baseline.identity.birthSeconds, forKey: .birthSeconds)
        try identityValues.encode(baseline.identity.birthNanoseconds, forKey: .birthNanoseconds)
        var contentValues = baselineValues.nestedContainer(keyedBy: ContentKeys.self, forKey: .content)
        switch baseline.content {
        case .missing:
            try contentValues.encode("missing", forKey: .kind)
        case .present(let bytes):
            try contentValues.encode("present", forKey: .kind)
            try contentValues.encode(bytes, forKey: .bytes)
        }
    }

    fileprivate func validate() throws {
        guard version == 1 else { throw DraftRecoveryError.unsupportedVersion }
        guard baseline.url.isFileURL,
              baseline.url.host == nil || baseline.url.host == "" || baseline.url.host == "localhost",
              baseline.url.query == nil, baseline.url.fragment == nil,
              updatedAt.timeIntervalSinceReferenceDate.isFinite else { throw DraftRecoveryError.invalidRecord }
        _ = try NoteReader.localPath(baseline.url.path)
        if case .present(let bytes) = baseline.content,
           String(data: bytes, encoding: .utf8) == nil { throw DraftRecoveryError.invalidUTF8 }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.id == rhs.id && Data(lhs.draft.utf8) == Data(rhs.draft.utf8) &&
            lhs.revision == rhs.revision && lhs.updatedAt == rhs.updatedAt &&
            lhs.baseline.url == rhs.baseline.url && lhs.baseline.identity == rhs.baseline.identity &&
            lhs.baseline.content == rhs.baseline.content
    }
}

enum DraftRecoveryError: Error, LocalizedError, Equatable {
    case invalidDirectory, insecureDirectory, insecureFile, storeBusy, directoryChanged
    case invalidRecord, unsupportedVersion, invalidUTF8, staleRevision
    case readbackMismatch, temporaryFileChanged, publicationUnconfirmed
    case system(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidDirectory: return "草稿恢复目录无效；不支持符号链接路径。"
        case .insecureDirectory: return "草稿恢复目录必须由当前用户拥有，权限为 0700。"
        case .insecureFile: return "草稿恢复文件的类型、所有者或权限不安全，已保留原文件。"
        case .storeBusy: return "另一个 FinderNotes 实例正在使用草稿恢复目录。"
        case .directoryChanged: return "草稿恢复目录或锁文件发生变化，已暂停恢复文件操作。"
        case .invalidRecord: return "恢复文件损坏或内容不一致，已保留原文件。"
        case .unsupportedVersion: return "恢复文件版本不受支持，已保留原文件。"
        case .invalidUTF8: return "恢复文件的原始笔记不是有效 UTF-8，已保留原文件。"
        case .staleRevision: return "已存在更新的恢复草稿，未覆盖它。"
        case .readbackMismatch: return "恢复临时文件回读不一致，未替换上次草稿。"
        case .temporaryFileChanged: return "恢复临时文件发生变化，未替换上次草稿。"
        case .publicationUnconfirmed: return "恢复文件操作已提交，但无法确认最终落盘结果；请保留当前草稿。"
        case .system(let operation, let code): return "草稿恢复失败（\(operation)，\(code)）。"
        }
    }
}

/// All calls are serialized by the actor. The directory lock lives until this store is released;
/// another cooperating process cannot read, replace or delete records while this store owns it.
/// Crash recovery covers successfully published files, not keystrokes still awaiting a put call.
actor DraftRecoveryStore {
    private let directory: URL
    private var directoryFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var directoryIdentity: FileIdentity?
    private var lockIdentity: FileIdentity?

    init(directory: URL) { self.directory = directory }

    deinit {
        if lockFD >= 0 { close(lockFD) }
        if directoryFD >= 0 { close(directoryFD) }
    }

    static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.findernotes.FinderNotes", isDirectory: true)
            .appendingPathComponent("DraftRecovery/v1", isDirectory: true)
    }

    func put(_ record: DraftRecoveryRecord) throws {
        try record.validate()
        let fd = try openedDirectory()
        let name = record.id.uuidString + ".json"
        if let previous = try readRecord(named: name, directory: fd), previous.revision > record.revision {
            throw DraftRecoveryError.staleRevision
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes: Data
        do { bytes = try encoder.encode(record) }
        catch let error as DraftRecoveryError { throw error }
        catch { throw DraftRecoveryError.invalidRecord }

        let temporaryName = ".draft-\(UUID().uuidString).tmp"
        let temporaryFD = openat(fd, temporaryName,
                                 O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard temporaryFD >= 0 else { throw Self.systemError("创建恢复临时文件") }
        var temporaryIdentity: FileIdentity?
        var published = false
        defer {
            close(temporaryFD)
            if !published, let temporaryIdentity,
               let current = try? Self.entryStatus(fd, name: temporaryName),
               FileIdentity(current) == temporaryIdentity { _ = unlinkat(fd, temporaryName, 0) }
        }
        let temporaryStatus = try Self.secureFileStatus(temporaryFD)
        temporaryIdentity = FileIdentity(temporaryStatus)
        try Self.writeAll(bytes, to: temporaryFD)
        try Self.sync(temporaryFD)
        guard try Self.readAll(temporaryFD) == bytes else { throw DraftRecoveryError.readbackMismatch }
        try validateHeldDirectory()
        guard let current = try Self.entryStatus(fd, name: temporaryName),
              FileIdentity(current) == temporaryIdentity else { throw DraftRecoveryError.temporaryFileChanged }
        _ = try Self.secureFileStatus(temporaryFD)
        // Re-read the destination under our process lock. A corrupt or unsafe existing record
        // must never be silently overwritten, even though rename itself would not follow a link.
        if let previous = try readRecord(named: name, directory: fd), previous.revision > record.revision {
            throw DraftRecoveryError.staleRevision
        }
        guard renameat(fd, temporaryName, fd, name) == 0 else { throw Self.systemError("替换恢复文件") }
        published = true
        do {
            try Self.sync(fd)
            try validateHeldDirectory()
            guard let final = try Self.entryStatus(fd, name: name),
                  FileIdentity(final) == temporaryIdentity,
                  try readRecord(named: name, directory: fd) == record else {
                throw DraftRecoveryError.publicationUnconfirmed
            }
        } catch { throw DraftRecoveryError.publicationUnconfirmed }
    }

    /// Call only after a confirmed save or explicit discard. Missing files make cleanup idempotent.
    func remove(id: UUID) throws {
        let fd = try openedDirectory()
        let name = id.uuidString + ".json"
        guard try readRecord(named: name, directory: fd) != nil else { return }
        try validateHeldDirectory()
        guard unlinkat(fd, name, 0) == 0 else { throw Self.systemError("清理恢复文件") }
        do { try Self.sync(fd); try validateHeldDirectory() }
        catch { throw DraftRecoveryError.publicationUnconfirmed }
    }

    /// A bad record fails closed and stays on disk. Temporary crash remnants stay untouched.
    func records() throws -> [DraftRecoveryRecord] {
        let fd = try openedDirectory()
        // dup would share a directory offset; a fresh openat gives each enumeration its own offset.
        let enumerationFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard enumerationFD >= 0 else { throw Self.systemError("枚举恢复文件") }
        guard let stream = fdopendir(enumerationFD) else {
            close(enumerationFD)
            throw Self.systemError("枚举恢复文件")
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Self.systemError("枚举恢复文件") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name.hasSuffix(".json") { names.append(name) }
        }
        var records: [DraftRecoveryRecord] = []
        for name in names.sorted() {
            guard let record = try readRecord(named: name, directory: fd) else {
                throw DraftRecoveryError.directoryChanged
            }
            records.append(record)
        }
        try validateHeldDirectory()
        return records.sorted { $0.updatedAt < $1.updatedAt }
    }

    private func openedDirectory() throws -> Int32 {
        if directoryFD >= 0 {
            try validateHeldDirectory()
            return directoryFD
        }
        guard directory.isFileURL, directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.query == nil, directory.fragment == nil else { throw DraftRecoveryError.invalidDirectory }
        let path: String
        do { path = try NoteReader.localPath(directory.path) }
        catch { throw DraftRecoveryError.invalidDirectory }
        let fd = try Self.openDirectory(path, create: true)
        var acquiredLock: Int32 = -1
        do {
            let status = try Self.secureDirectoryStatus(fd)
            acquiredLock = openat(fd, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard acquiredLock >= 0 else { throw Self.systemError("打开恢复目录锁") }
            let lockStatus = try Self.secureFileStatus(acquiredLock)
            guard flock(acquiredLock, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw DraftRecoveryError.storeBusy }
                throw Self.systemError("锁定恢复目录")
            }
            directoryFD = fd
            lockFD = acquiredLock
            directoryIdentity = FileIdentity(status)
            lockIdentity = FileIdentity(lockStatus)
            try validateHeldDirectory()
            return fd
        } catch {
            if acquiredLock >= 0 { close(acquiredLock) }
            close(fd)
            directoryFD = -1
            lockFD = -1
            directoryIdentity = nil
            lockIdentity = nil
            throw error
        }
    }

    private func validateHeldDirectory() throws {
        guard directoryFD >= 0, lockFD >= 0 else { throw DraftRecoveryError.directoryChanged }
        let currentFD: Int32
        do { currentFD = try Self.openDirectory(try NoteReader.localPath(directory.path), create: false) }
        catch { throw DraftRecoveryError.directoryChanged }
        defer { close(currentFD) }
        let current = try Self.secureDirectoryStatus(currentFD)
        let held = try Self.secureDirectoryStatus(directoryFD)
        let lock = try Self.secureFileStatus(lockFD)
        guard FileIdentity(current) == directoryIdentity, FileIdentity(held) == directoryIdentity,
              FileIdentity(lock) == lockIdentity,
              let entry = try Self.entryStatus(directoryFD, name: ".lock"),
              FileIdentity(entry) == lockIdentity else { throw DraftRecoveryError.directoryChanged }
    }

    private func readRecord(named name: String, directory fd: Int32) throws -> DraftRecoveryRecord? {
        guard name.hasSuffix(".json"), let expectedID = UUID(uuidString: String(name.dropLast(5))),
              name == expectedID.uuidString + ".json" else { throw DraftRecoveryError.invalidRecord }
        guard let entry = try Self.entryStatus(fd, name: name) else { return nil }
        try Self.validateFile(entry)
        let recordFD = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard recordFD >= 0 else { throw Self.systemError("打开恢复文件") }
        defer { close(recordFD) }
        let before = try Self.secureFileStatus(recordFD)
        guard FileIdentity(before) == FileIdentity(entry) else { throw DraftRecoveryError.directoryChanged }
        let bytes = try Self.readAll(recordFD)
        let after = try Self.secureFileStatus(recordFD)
        guard before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              let current = try Self.entryStatus(fd, name: name),
              FileIdentity(current) == FileIdentity(before) else { throw DraftRecoveryError.directoryChanged }
        do {
            let record = try JSONDecoder().decode(DraftRecoveryRecord.self, from: bytes)
            guard record.id == expectedID else { throw DraftRecoveryError.invalidRecord }
            return record
        } catch let error as DraftRecoveryError { throw error }
        catch { throw DraftRecoveryError.invalidRecord }
    }

    private static func openDirectory(_ path: String, create: Bool) throws -> Int32 {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw DraftRecoveryError.invalidDirectory }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw systemError("打开根目录") }
        do {
            for component in components {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                        throw systemError("创建恢复目录")
                    }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw systemError("打开恢复目录") }
                close(fd)
                fd = next
            }
            _ = try secureDirectoryStatus(fd)
            return fd
        } catch { close(fd); throw error }
    }

    private static func secureDirectoryStatus(_ fd: Int32) throws -> stat {
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw systemError("检查恢复目录") }
        guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(),
              status.st_mode & 0o7777 == 0o700 else { throw DraftRecoveryError.insecureDirectory }
        return status
    }

    private static func secureFileStatus(_ fd: Int32) throws -> stat {
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw systemError("检查恢复文件") }
        try validateFile(status)
        return status
    }

    private static func validateFile(_ status: stat) throws {
        guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
              status.st_uid == geteuid(), status.st_mode & 0o7777 == 0o600 else {
            throw DraftRecoveryError.insecureFile
        }
    }

    private static func entryStatus(_ fd: Int32, name: String) throws -> stat? {
        var status = stat()
        if fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return status }
        if errno == ENOENT { return nil }
        throw systemError("检查恢复目录项")
    }

    private static func writeAll(_ bytes: Data, to fd: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, base.advanced(by: offset), min(buffer.count - offset, Int(Int32.max)))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw systemError("写入恢复临时文件", fallback: EIO) }
                offset += count
            }
        }
    }

    private static func readAll(_ fd: Int32) throws -> Data {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw systemError("回读恢复文件") }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw systemError("回读恢复文件") }
            if count == 0 { return bytes }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func sync(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw systemError("同步恢复文件")
        }
    }

    private static func systemError(_ operation: String, fallback: Int32? = nil) -> DraftRecoveryError {
        .system(operation: operation, code: errno == 0 ? (fallback ?? EIO) : errno)
    }
}
