import AppKit
import CryptoKit
import Darwin
import Foundation

let noteKey = "com.findernotes.note.v1"
struct Failure: Error, CustomStringConvertible {
    let description: String
}
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(description: message) }
}
func posix(_ operation: String) -> Failure {
    let code = errno
    return Failure(description: "\(operation): errno=\(code) \(String(cString: strerror(code)))")
}
func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
struct Config: Decodable {
    let root: String
    let seedHashes: [String: String]
}
func status(_ fd: Int32) throws -> stat {
    var s = stat()
    guard fstat(fd, &s) == 0 else { throw posix("fstat") }
    return s
}
func readNote(_ fd: Int32) throws -> Data? {
    for _ in 0..<4 {
        let size = fgetxattr(fd, noteKey, nil, 0, 0, 0)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw posix("fgetxattr size")
        }
        var bytes = [UInt8](repeating: 0, count: max(1, size))
        let n = fgetxattr(fd, noteKey, &bytes, size, 0, 0)
        if n >= 0 { return Data(bytes.prefix(n)) }
        if errno == ERANGE { continue }
        throw posix("fgetxattr body")
    }
    throw Failure(description: "笔记在读取期间持续变化")
}
func mediaHash(_ fd: Int32) throws -> String {
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 65536)
    var offset: off_t = 0
    while true {
        let n = pread(fd, &bytes, bytes.count, offset)
        if n < 0 { if errno == EINTR { continue }; throw posix("pread") }
        if n == 0 { break }
        data.append(contentsOf: bytes.prefix(n)); offset += off_t(n)
        try check(data.count <= 1_048_576, "验证副本超过 1 MiB")
    }
    return sha256(data)
}

final class Target {
    let fd: Int32
    let path: String
    let identity: stat
    let config: Config
    var baseline: Data?
    var text: String { baseline.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    // Walk from / with O_NOFOLLOW for every directory, including the fixture root.
    static func openPath(_ path: String) throws -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        try check(path.hasPrefix("/") && !parts.isEmpty && !parts.contains(".."), "非法路径")
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw posix("open root") }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw posix("open directory") }
            close(parent); parent = next
        }
        let result = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard result >= 0 else { throw posix("open target") }
        return result
    }
    init(url: URL, config: Config) throws {
        try check(url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost"), "只接受本机文件 URL")
        // Foundation standardization strips /private; accept only the known system /var alias.
        let path = url.path.hasPrefix("/var/") ? "/private" + url.path : url.path
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try check(parent == config.root + "/work", "仅允许本次临时 work 目录的合成副本")
        try check(config.seedHashes[url.pathExtension] != nil, "仅允许合成 PNG/MOV")
        let fd = try Self.openPath(path)
        do {
            let s = try status(fd)
            try check((s.st_mode & S_IFMT) == S_IFREG, "拒绝目录或非普通文件")
            try check(s.st_nlink == 1, "拒绝硬链接")
            let alias = try url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile ?? false
            try check(!alias, "拒绝 Finder 替身")
            try check(try mediaHash(fd) == config.seedHashes[url.pathExtension], "媒体内容不匹配本次合成种子")
            let note = try readNote(fd)
            if let note { try check(String(data: note, encoding: .utf8) != nil, "已有笔记不是合法 UTF-8；不当作空值") }
            self.fd = fd; self.path = path; self.identity = s; self.config = config; self.baseline = note
        } catch { close(fd); throw error }
        try verify()
    }
    deinit { close(fd) }
    var id: String { "\(identity.st_dev):\(identity.st_ino)" }
    func verify() throws {
        let currentFD = try Self.openPath(path)
        defer { close(currentFD) }
        let current = try status(currentFD)
        let held = try status(fd)
        try check(current.st_dev == identity.st_dev && current.st_ino == identity.st_ino,
                  "目标同名替换或路径身份变化；停止保存")
        try check(current.st_nlink == 1 && held.st_nlink == 1, "文件已被删除或成为硬链接；停止保存")
        try check(try mediaHash(fd) == config.seedHashes[URL(fileURLWithPath: path).pathExtension], "媒体内容已改变；停止保存")
    }
    func save(_ draft: String) throws {
        try verify()
        try check(try readNote(fd) == baseline, "自有笔记已被外部修改；保留草稿，停止覆盖")
        let bytes = Data(draft.utf8)
        // Held fd prevents a path replacement from redirecting a write to the new file.
        let result = bytes.withUnsafeBytes { fsetxattr(fd, noteKey, $0.baseAddress, bytes.count, 0, 0) }
        guard result == 0 else { throw posix("fsetxattr") }
        try verify()
        try check(try readNote(fd) == bytes, "写后回读不一致；无法确认保存")
        baseline = bytes
    }
}

final class Session {
    let config: Config
    var target: Target?
    var draft = ""
    var dirty: Bool { draft != (target?.text ?? "") }
    init(_ config: Config) { self.config = config }
    func receive(_ urls: [URL]) throws -> String {
        try check(urls.count == 1, "只接受一个文件；拒绝多选或空输入")
        let candidate = try Target(url: urls[0], config: config)
        if let target, target.id == candidate.id && target.path == candidate.path {
            try target.verify()
            return "重复触发：复用当前会话，草稿保持"
        }
        try check(!dirty, "当前有未保存草稿；请保存或复制后明确丢弃，再切换文件")
        target = candidate; draft = candidate.text
        return "已接收文件：\(candidate.path)"
    }
    func save() throws {
        guard let target else { throw Failure(description: "尚未接收文件") }
        try target.save(draft)
    }
}
