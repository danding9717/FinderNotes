import Darwin
import Foundation
import UniformTypeIdentifiers

/// A successful read preserves the distinction between no attribute and an empty attribute.
enum NoteContent: Equatable, Sendable {
    case missing
    case present(Data)

    var text: String {
        switch self {
        case .missing:
            return ""
        case .present(let data):
            // NoteReader validates bytes before publishing a snapshot. Invalid bytes are an error,
            // never a lossy conversion or an apparently empty note.
            guard let text = String(data: data, encoding: .utf8) else {
                preconditionFailure("NoteContent must contain validated UTF-8")
            }
            return text
        }
    }
}

struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    init(device: UInt64, inode: UInt64, birthSeconds: Int64 = 0, birthNanoseconds: Int64 = 0) {
        self.device = device
        self.inode = inode
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
    }

    fileprivate init(_ status: stat) {
        self.init(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino),
                  birthSeconds: Int64(status.st_birthtimespec.tv_sec),
                  birthNanoseconds: Int64(status.st_birthtimespec.tv_nsec))
    }
}

struct NoteSnapshot: Sendable {
    let url: URL
    let identity: FileIdentity
    let content: NoteContent
}

enum NoteReadError: Error, LocalizedError, Equatable {
    case selectionCount
    case localFileRequired
    case invalidPath
    case regularFileRequired
    case hardLink
    case finderAlias
    case unsupportedType
    case invalidUTF8
    case targetChanged
    case attributeChanging
    case system(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .selectionCount: return "请仅选择一个图片或视频文件。"
        case .localFileRequired: return "只支持本机磁盘上的文件。"
        case .invalidPath: return "文件路径无效；不支持符号链接路径。"
        case .regularFileRequired: return "请选择普通文件；不支持文件夹或符号链接。"
        case .hardLink: return "暂不支持硬链接文件。"
        case .finderAlias: return "暂不支持 Finder 替身，请选择原始文件。"
        case .unsupportedType: return "只支持图片或视频文件。"
        case .invalidUTF8: return "笔记不是有效的 UTF-8 文本，无法读取；原内容未被修改。"
        case .targetChanged: return "文件在读取期间被移动、删除或替换，请重新选择。"
        case .attributeChanging: return "笔记在读取期间持续变化，请稍后重试。"
        case .system(let operation, let code):
            return "读取失败（\(operation)，\(code)：\(String(cString: strerror(code)))）。"
        }
    }
}

struct NoteReader: Sendable {
    static let attributeName = "com.findernotes.note.v1"

    #if DEBUG
    /// Deterministic race injection for isolated tests; absent from release builds.
    private let beforeFinalValidation: (@Sendable () throws -> Void)?
    init(beforeFinalValidation: (@Sendable () throws -> Void)? = nil) {
        self.beforeFinalValidation = beforeFinalValidation
    }
    #else
    init() {}
    #endif

    func read(urls: [URL]) throws -> NoteSnapshot {
        guard urls.count == 1 else { throw NoteReadError.selectionCount }
        let input = urls[0]
        guard input.isFileURL,
              input.host == nil || input.host == "" || input.host?.lowercased() == "localhost",
              input.query == nil, input.fragment == nil else { throw NoteReadError.localFileRequired }
        let path = try Self.localPath(input.path)
        // Use a fresh URL so resource-value caches on a service-provided URL cannot outlive a file.
        let url = URL(fileURLWithPath: path)
        let fd = try Self.openPath(path)
        defer { close(fd) }
        let original = try Self.regularStatus(fd)
        let identity = FileIdentity(original)

        var volume = statfs()
        guard fstatfs(fd, &volume) == 0 else { throw Self.systemError("fstatfs") }
        guard volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw NoteReadError.localFileRequired }

        // Finder alias identity comes from the same held fd, independent of path metadata races.
        if let finderInfo = try Self.attribute(fd, name: "com.apple.FinderInfo"),
           finderInfo.count >= 10, finderInfo[8] & 0x80 != 0 {
            throw NoteReadError.finderAlias
        }
        let resource = try url.resourceValues(forKeys: [.contentTypeKey, .isAliasFileKey])
        guard resource.isAliasFile != true else { throw NoteReadError.finderAlias }
        guard let type = resource.contentType,
              type.conforms(to: .image) || type.conforms(to: .movie) else {
            throw NoteReadError.unsupportedType
        }

        let content: NoteContent
        if let bytes = try Self.attribute(fd, name: Self.attributeName) {
            guard String(data: bytes, encoding: .utf8) != nil else { throw NoteReadError.invalidUTF8 }
            content = .present(bytes)
        } else {
            content = .missing
        }
        #if DEBUG
        try beforeFinalValidation?()
        #endif
        // Re-walk the entire path, including parents, to detect rename/replacement of a directory.
        // Both descriptors stay open until this check completes, so inode reuse cannot hide a swap.
        let currentFD: Int32
        do { currentFD = try Self.openPath(path) }
        catch { throw NoteReadError.targetChanged }
        defer { close(currentFD) }
        let held = try Self.regularStatus(fd)
        let current = try Self.regularStatus(currentFD)
        guard FileIdentity(held) == identity, FileIdentity(current) == identity else {
            throw NoteReadError.targetChanged
        }
        return NoteSnapshot(url: url, identity: identity, content: content)
    }

    private static func localPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw NoteReadError.invalidPath
        }
        // macOS exposes these system-owned aliases. Do not resolve arbitrary user symlinks.
        for alias in ["/var/", "/tmp/"] where path.hasPrefix(alias) { return "/private" + path }
        return path
    }

    private static func openPath(_ path: String) throws -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw NoteReadError.regularFileRequired }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw systemError("打开根目录") }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw systemError("打开上级目录") }
            close(parent)
            parent = next
        }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw systemError("打开文件") }
        return fd
    }

    private static func regularStatus(_ fd: Int32) throws -> stat {
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw systemError("检查文件身份") }
        guard status.st_mode & S_IFMT == S_IFREG else { throw NoteReadError.regularFileRequired }
        guard status.st_nlink != 0 else { throw NoteReadError.targetChanged }
        guard status.st_nlink == 1 else { throw NoteReadError.hardLink }
        return status
    }

    private static func attribute(_ fd: Int32, name: String) throws -> Data? {
        for _ in 0..<4 {
            let size = fgetxattr(fd, name, nil, 0, 0, 0)
            guard size >= 0 else {
                if errno == ENOATTR { return nil }
                throw systemError("读取扩展属性大小")
            }
            // A zero-size second call would be another size query. Allocate one byte so a
            // concurrent empty-to-nonempty change is handled as a real value read or ERANGE.
            var bytes = [UInt8](repeating: 0, count: max(1, size))
            let count = fgetxattr(fd, name, &bytes, bytes.count, 0, 0)
            if count >= 0, count <= bytes.count { return Data(bytes.prefix(count)) }
            if count > bytes.count || errno == ERANGE { continue }
            if errno == ENOATTR { return nil }
            throw systemError("读取扩展属性正文")
        }
        throw NoteReadError.attributeChanging
    }

    private static func systemError(_ operation: String) -> NoteReadError {
        .system(operation: operation, code: errno)
    }
}
