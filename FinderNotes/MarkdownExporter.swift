import Darwin
import Foundation

/// The caller freezes the editor text as UTF-8 before presenting the destination panel.
struct MarkdownExportRequest: Sendable {
    let source: URL
    let destination: URL
    let bytes: Data

    init(source: URL, destination: URL, bytes: Data) {
        self.source = source
        self.destination = destination
        self.bytes = bytes
    }
}

enum MarkdownExportError: Error, LocalizedError, Equatable {
    case invalidSource
    case invalidDestination
    case invalidUTF8
    case sourceDestinationSame
    case destinationExists
    case readbackMismatch
    case temporaryFileChanged
    case publicationUnconfirmed
    case exclusivePublishUnavailable
    case system(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "素材路径无效，无法导出。"
        case .invalidDestination:
            return "导出路径无效；请选择无符号链接的本机目录。"
        case .invalidUTF8:
            return "导出内容不是有效的 UTF-8 文本。"
        case .sourceDestinationSame:
            return "导出位置不能是素材文件。"
        case .destinationExists:
            return "目标文件已存在，请更改名称或目录；原文件未被覆盖。"
        case .readbackMismatch:
            return "导出文件回读与草稿快照不一致，未发布目标文件。"
        case .temporaryFileChanged:
            return "导出临时文件发生变化，未发布目标文件。"
        case .publicationUnconfirmed:
            return "导出已提交，但无法确认目标文件仍是本次内容；请检查目标位置。"
        case .exclusivePublishUnavailable:
            return "目标文件系统不支持安全的新文件发布，未覆盖已有文件。"
        case .system(let operation, let code):
            return "导出失败（\(operation)，\(code)：\(String(cString: strerror(code)))）。"
        }
    }
}

struct MarkdownExporter: Sendable {
    #if DEBUG
    /// Called after verifying the temporary file, for a deterministic destination race test.
    private let beforePublish: (@Sendable () throws -> Void)?

    init(beforePublish: (@Sendable () throws -> Void)? = nil) {
        self.beforePublish = beforePublish
    }
    #else
    init() {}
    #endif

    static func defaultFileName(for source: URL) -> String {
        source.lastPathComponent + ".note.md"
    }

    func export(_ request: MarkdownExportRequest) throws {
        guard String(data: request.bytes, encoding: .utf8) != nil else {
            throw MarkdownExportError.invalidUTF8
        }
        let sourcePath = try Self.localPath(request.source, error: .invalidSource)
        let destinationPath = try Self.localPath(request.destination, error: .invalidDestination)
        guard sourcePath != destinationPath else { throw MarkdownExportError.sourceDestinationSame }

        let components = destinationPath.split(separator: "/").map(String.init)
        guard let name = components.last, name != ".", name != ".." else {
            throw MarkdownExportError.invalidDestination
        }
        let directory = try Self.openParent(of: components)
        defer { close(directory) }

        // An existing entry, including a symlink, is never a valid export destination.
        try Self.requireUnused(directory: directory, name: name, sourcePath: sourcePath)
        let (temporaryName, temporaryFD) = try Self.createTemporaryFile(in: directory)
        var temporaryIdentity: stat? = nil
        var published = false
        defer {
            close(temporaryFD)
            if !published, let temporaryIdentity {
                Self.unlinkIfSameFile(directory: directory, name: temporaryName,
                                      expected: temporaryIdentity)
            }
        }
        temporaryIdentity = try Self.status(of: temporaryFD, operation: "检查临时文件")

        try Self.writeAll(request.bytes, to: temporaryFD)
        try Self.sync(temporaryFD)
        try Self.verify(request.bytes, in: temporaryFD)
        #if DEBUG
        try beforePublish?()
        #endif
        guard let temporaryIdentity,
              let current = try Self.entryStatus(directory: directory, name: temporaryName),
              Self.sameFile(current, temporaryIdentity) else {
            throw MarkdownExportError.temporaryFileChanged
        }

        guard renameatx_np(directory, temporaryName, directory, name, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw MarkdownExportError.destinationExists }
            if code == ENOTSUP || code == EOPNOTSUPP || code == ENOSYS {
                throw MarkdownExportError.exclusivePublishUnavailable
            }
            throw MarkdownExportError.system(operation: "发布新文件", code: code)
        }
        published = true

        guard let final = try Self.entryStatus(directory: directory, name: name),
              Self.sameFile(final, temporaryIdentity) else {
            throw MarkdownExportError.publicationUnconfirmed
        }
    }

    private static func localPath(_ url: URL, error: MarkdownExportError) throws -> String {
        guard url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.query == nil, url.fragment == nil else { throw error }
        let path = url.path
        guard path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw error
        }
        // The system's /var and /tmp aliases are canonicalized without following user links.
        for alias in ["/var/", "/tmp/"] where path.hasPrefix(alias) {
            return "/private" + path
        }
        return path
    }

    private static func openParent(of components: [String]) throws -> Int32 {
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw systemError("打开根目录") }
        do {
            for component in components.dropLast() {
                let next = openat(directory, component,
                                  O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw systemError("打开导出目录") }
                close(directory)
                directory = next
            }
            return directory
        } catch {
            close(directory)
            throw error
        }
    }

    private static func requireUnused(directory: Int32, name: String, sourcePath: String) throws {
        guard let destination = try entryStatus(directory: directory, name: name) else { return }
        var source = stat()
        if stat(sourcePath, &source) == 0, sameFile(source, destination) {
            throw MarkdownExportError.sourceDestinationSame
        }
        throw MarkdownExportError.destinationExists
    }

    private static func entryStatus(directory: Int32, name: String) throws -> stat? {
        var result = stat()
        if fstatat(directory, name, &result, AT_SYMLINK_NOFOLLOW) == 0 { return result }
        if errno == ENOENT { return nil }
        throw systemError("检查导出目标")
    }

    private static func createTemporaryFile(in directory: Int32) throws -> (String, Int32) {
        for _ in 0..<8 {
            let name = ".findernotes-export-\(UUID().uuidString).tmp"
            let fd = openat(directory, name,
                            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                            mode_t(0o600))
            if fd >= 0 { return (name, fd) }
            if errno != EEXIST { throw systemError("创建导出临时文件") }
        }
        throw MarkdownExportError.system(operation: "创建导出临时文件", code: EEXIST)
    }

    private static func writeAll(_ bytes: Data, to fd: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let amount = min(buffer.count - offset, Int(Int32.max))
                let count = write(fd, base.advanced(by: offset), amount)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError("写入导出内容")
                }
                if count == 0 {
                    throw MarkdownExportError.system(operation: "写入导出内容", code: EIO)
                }
                offset += count
            }
        }
    }

    private static func sync(_ fd: Int32) throws {
        while fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw systemError("同步导出临时文件")
        }
    }

    private static func verify(_ expected: Data, in fd: Int32) throws {
        let initial = try status(of: fd, operation: "检查导出大小")
        guard initial.st_size == expected.count,
              lseek(fd, 0, SEEK_SET) == 0 else {
            throw MarkdownExportError.readbackMismatch
        }
        var actual = Data(count: expected.count)
        try actual.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = read(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError("回读导出内容")
                }
                if count == 0 { throw MarkdownExportError.readbackMismatch }
                offset += count
            }
        }
        var extra: UInt8 = 0
        var trailing: Int
        repeat { trailing = read(fd, &extra, 1) } while trailing < 0 && errno == EINTR
        if trailing < 0 { throw systemError("回读导出结尾") }
        let final = try status(of: fd, operation: "复核导出大小")
        guard trailing == 0, final.st_size == expected.count, actual == expected else {
            throw MarkdownExportError.readbackMismatch
        }
    }

    private static func status(of fd: Int32, operation: String) throws -> stat {
        var result = stat()
        guard fstat(fd, &result) == 0 else { throw systemError(operation) }
        return result
    }

    private static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino &&
            first.st_birthtimespec.tv_sec == second.st_birthtimespec.tv_sec &&
            first.st_birthtimespec.tv_nsec == second.st_birthtimespec.tv_nsec
    }

    private static func unlinkIfSameFile(directory: Int32, name: String, expected: stat) {
        guard let current = try? entryStatus(directory: directory, name: name),
              sameFile(current, expected) else { return }
        _ = unlinkat(directory, name, 0)
    }

    private static func systemError(_ operation: String) -> MarkdownExportError {
        .system(operation: operation, code: errno)
    }
}
