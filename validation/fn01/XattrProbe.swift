import AppKit
import CryptoKit
import Darwin
import Foundation

// Validation only: v1 describes the raw UTF-8 value format, not a product limit.
let attributeName = "com.findernotes.note.v1"
let rootPrefix = "findernotes-fn01-xattr-"
let markerName = ".fn01-xattr-owned"
let markerBody = Data("FinderNotes FN-01 xattr synthetic run v1\n".utf8)

struct ProbeFailure: Error {
    let message: String
    var code: Int32? = nil
    var details: [String: String] = [:]
}

func systemFailure(_ operation: String, code: Int32 = errno) -> ProbeFailure {
    ProbeFailure(message: "\(operation): \(String(cString: strerror(code)))", code: code)
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeFailure(message: message) }
}

func json(_ value: [String: Any], to output: FileHandle = .standardOutput) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    bytes.append(10)
    output.write(bytes)
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func elapsed(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func sample(_ name: String) throws -> Data {
    let text: String
    switch name {
    case "empty": text = ""
    case "initial": text = "FN-01 已有注释：中文🙂 末尾"
    case "mixed":
        text = "  中文🙂👩🏽‍🚀 '双引号\\\"' 反斜杠\\\\\n第二段\n\n末尾空白  \n"
    case "cjk2000": text = String(repeating: "航", count: 2_000)
    case "utf8-16k":
        let prefix = "首行🙂\n  引号\\\" 与反斜杠\\\\  \n"
        let suffix = "\n末行空白  \n"
        let remaining = 16_384 - Data((prefix + suffix).utf8).count
        text = prefix + String(repeating: "文", count: remaining / 3)
            + String(repeating: "x", count: remaining % 3) + suffix
    default: throw ProbeFailure(message: "Unknown sample: \(name)")
    }
    return Data(text.utf8)
}

func fileStatus(_ fd: Int32) throws -> stat {
    var status = stat()
    guard fstat(fd, &status) == 0 else { throw systemFailure("fstat") }
    return status
}

func regularFile(_ fd: Int32) throws -> stat {
    let status = try fileStatus(fd)
    try require((status.st_mode & S_IFMT) == S_IFREG, "Target is not a regular file")
    try require(status.st_nlink == 1, "Hard-linked files are outside this probe's boundary")
    return status
}

func mediaHash(_ fd: Int32) throws -> String {
    var hash = SHA256()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    var offset: off_t = 0
    while true {
        let count = pread(fd, &buffer, buffer.count, offset)
        if count < 0 {
            if errno == EINTR { continue }
            throw systemFailure("pread media")
        }
        if count == 0 { break }
        hash.update(data: Data(buffer.prefix(count)))
        offset += off_t(count)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func openChild(_ parent: Int32, _ name: String, directory: Bool = false) throws -> Int32 {
    // The fd remains bound to this object even if its path is replaced later.
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
    guard fd >= 0 else { throw systemFailure("openat \(name)") }
    return fd
}

struct Target {
    let fd: Int32
    let directoryFD: Int32
    let name: String
    let path: String
    let identity: stat
    let seedHash: String

    func verifyBinding() throws {
        var current = stat()
        guard fstatat(directoryFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw systemFailure("fstatat target after operation")
        }
        try require((current.st_mode & S_IFMT) == S_IFREG
                    && current.st_dev == identity.st_dev && current.st_ino == identity.st_ino,
                    "Target path changed identity during the operation")
        _ = try regularFile(fd)
    }

    var identityJSON: [String: Any] {
        ["device": Int64(identity.st_dev), "inode": UInt64(identity.st_ino)]
    }
}

func withTarget(_ rawRoot: String, _ relative: String, _ body: (Target) throws -> Void) throws {
    let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let root = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    try require(root.deletingLastPathComponent().path == temp.path
                && root.lastPathComponent.hasPrefix(rootPrefix),
                "Root must be an xattr probe run directly under \(temp.path)")
    let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    try require(components.count == 2 && ["work", "moved"].contains(components[0])
                && !components[1].isEmpty && ![".", ".."].contains(components[1]),
                "Only work/FILE or moved/FILE inside this run may be accessed")
    let ext = URL(fileURLWithPath: components[1]).pathExtension
    try require(["png", "mov"].contains(ext), "Only synthetic .png and .mov copies are allowed")

    let tempFD = open(temp.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard tempFD >= 0 else { throw systemFailure("open temporary directory") }
    defer { close(tempFD) }
    let rootFD = try openChild(tempFD, root.lastPathComponent, directory: true)
    defer { close(rootFD) }
    let markerFD = try openChild(rootFD, markerName)
    defer { close(markerFD) }
    let markerStat = try regularFile(markerFD)
    try require(markerStat.st_size == markerBody.count, "Invalid xattr run marker")
    var markerBytes = [UInt8](repeating: 0, count: markerBody.count)
    let markerCount = pread(markerFD, &markerBytes, markerBytes.count, 0)
    try require(markerCount == markerBody.count && Data(markerBytes) == markerBody, "Invalid xattr run marker")

    let seedFD = try openChild(rootFD, "seed.\(ext)")
    defer { close(seedFD) }
    _ = try regularFile(seedFD)
    let seedHash = try mediaHash(seedFD)
    let directoryFD = try openChild(rootFD, components[0], directory: true)
    defer { close(directoryFD) }
    let fileFD = try openChild(directoryFD, components[1])
    defer { close(fileFD) }
    let identity = try regularFile(fileFD)
    try require(try mediaHash(fileFD) == seedHash, "Media content differs from this run's synthetic seed")
    let target = Target(fd: fileFD, directoryFD: directoryFD, name: components[1],
                        path: root.appendingPathComponent(relative).path, identity: identity, seedHash: seedHash)
    try target.verifyBinding()
    try body(target)
}

func readAttribute(_ fd: Int32, _ name: String) throws -> Data? {
    for _ in 0..<4 {
        let size = fgetxattr(fd, name, nil, 0, 0, 0)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw systemFailure("fgetxattr size \(name)")
        }
        var bytes = [UInt8](repeating: 0, count: max(1, size))
        let count = fgetxattr(fd, name, &bytes, size, 0, 0)
        if count >= 0 {
            if count > size { continue }
            return Data(bytes.prefix(count))
        }
        if errno == ENOATTR { return nil }
        if errno == ERANGE { continue }
        throw systemFailure("fgetxattr value \(name)")
    }
    throw ProbeFailure(message: "Attribute changed size repeatedly while reading: \(name)")
}

func attributeNames(_ fd: Int32) throws -> [String] {
    for _ in 0..<4 {
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0 else { throw systemFailure("flistxattr size") }
        var bytes = [UInt8](repeating: 0, count: max(1, size))
        let count = flistxattr(fd, &bytes, size, 0)
        if count < 0 {
            if errno == ERANGE { continue }
            throw systemFailure("flistxattr names")
        }
        if count > size { continue }
        return try bytes.prefix(count).split(separator: 0).map { name in
            guard let text = String(bytes: name, encoding: .utf8) else {
                throw ProbeFailure(message: "An attribute name is not valid UTF-8")
            }
            return text
        }.sorted()
    }
    throw ProbeFailure(message: "Attribute list changed repeatedly while reading")
}

func otherAttributes(_ fd: Int32) throws -> [String: Data] {
    var values: [String: Data] = [:]
    for name in try attributeNames(fd) where name != attributeName {
        guard let data = try readAttribute(fd, name) else {
            throw ProbeFailure(message: "Non-owned attribute disappeared during snapshot: \(name)")
        }
        values[name] = data
    }
    return values
}

func noteJSON(_ value: Data?) throws -> [String: Any] {
    guard let value else { return ["state": "missing"] }
    try require(String(data: value, encoding: .utf8) != nil, "Stored note is not valid UTF-8; it is not an empty note")
    return ["state": "present", "utf8_bytes": value.count, "sha256": digest(value)]
}

func checkExpected(_ actual: Data?, _ expectation: String) throws {
    if expectation == "missing" {
        try require(actual == nil, "Expected missing attribute, found a present attribute")
    } else {
        let expected = try sample(expectation)
        try require(actual == expected,
                    "Note differs from \(expectation): actual=\(actual.map { "\($0.count) bytes/\(digest($0))" } ?? "missing"), expected=\(expected.count) bytes/\(digest(expected))")
    }
}

func inspect(_ target: Target, expectation: String?) throws {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try readAttribute(target.fd, attributeName)
    let readMS = elapsed(start)
    let note = try noteJSON(value)
    if let expectation { try checkExpected(value, expectation) }
    let hash = try mediaHash(target.fd)
    try require(hash == target.seedHash, "Media changed during read")
    try target.verifyBinding()
    var result: [String: Any] = ["ok": true, "command": "read", "attribute": attributeName,
        "path": target.path, "identity": target.identityJSON, "note": note,
        "media_sha256": hash, "media_matches_seed": true, "read_ms": readMS]
    if let expectation { result["expected"] = expectation; result["note_verified"] = true }
    try json(result)
}

func mutate(_ target: Target, body: Data?) throws {
    let before = try readAttribute(target.fd, attributeName)
    let otherBefore = try otherAttributes(target.fd)
    let start = DispatchTime.now().uptimeNanoseconds
    let status: Int32
    if let body {
        // O_RDONLY prevents writes to media bytes, but is not a metadata permission policy.
        status = body.withUnsafeBytes { fsetxattr(target.fd, attributeName, $0.baseAddress, body.count, 0, 0) }
    } else {
        status = fremovexattr(target.fd, attributeName, 0)
    }
    let mutationErrno = status == 0 ? nil : errno
    let writeMS = elapsed(start)
    let readStart = DispatchTime.now().uptimeNanoseconds
    let after = try readAttribute(target.fd, attributeName)
    let readMS = elapsed(readStart)
    let otherAfter = try otherAttributes(target.fd)
    let hash = try mediaHash(target.fd)
    try target.verifyBinding()
    try require(hash == target.seedHash, "Media content changed during metadata mutation")
    try require(otherBefore == otherAfter, "Non-owned xattrs changed during metadata mutation")
    if let code = mutationErrno {
        throw ProbeFailure(message: "\(body == nil ? "fremovexattr" : "fsetxattr"): \(String(cString: strerror(code)))",
                           code: code, details: ["original_note_preserved": String(before == after),
                           "other_xattrs_preserved": "true", "media_matches_seed": "true"])
    }
    try require(after == body, "Write/readback mismatch, including missing versus empty state")
    try json(["ok": true, "command": body == nil ? "clear-verify" : "write-verify",
        "attribute": attributeName, "path": target.path, "identity": target.identityJSON,
        "note": try noteJSON(after), "note_verified": true, "media_sha256": hash,
        "media_matches_seed": true, "other_xattrs_preserved": true,
        "other_xattrs": otherAfter.mapValues { ["bytes": $0.count, "sha256": digest($0)] as [String: Any] },
        "write_ms": writeMS, "readback_ms": readMS])
}

func prepare() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        .appendingPathComponent(rootPrefix + UUID().uuidString.lowercased(), isDirectory: true)
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    try markerBody.write(to: root.appendingPathComponent(markerName), options: .withoutOverwriting)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        throw ProbeFailure(message: "Could not allocate synthetic PNG")
    }
    bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw ProbeFailure(message: "Could not encode synthetic PNG")
    }
    try png.write(to: root.appendingPathComponent("seed.png"), options: .withoutOverwriting)
    let video = Process()
    video.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    video.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        "color=c=blue:s=16x16:r=1:d=1", "-c:v", "mpeg4", "-n", root.appendingPathComponent("seed.mov").path]
    video.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    video.standardError = errors
    try video.run()
    let errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
    video.waitUntilExit()
    try require(video.terminationStatus == 0,
                "Synthetic MOV generation failed: \(String(decoding: errorBytes, as: UTF8.self))")
    for directory in ["work", "moved"] {
        try files.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: false)
    }
    var hashes: [String: String] = [:]
    for ext in ["png", "mov"] {
        let seed = root.appendingPathComponent("seed.\(ext)")
        hashes[ext] = digest(try Data(contentsOf: seed))
        for name in ["mixed", "cjk2000", "utf8-16k", "lifecycle"] {
            try files.copyItem(at: seed, to: root.appendingPathComponent("work/\(name).\(ext)"))
        }
    }
    for name in ["mixed", "cjk2000", "utf8-16k", "initial", "empty"] {
        try sample(name).write(to: root.appendingPathComponent("\(name).txt"), options: .withoutOverwriting)
    }
    try json(["ok": true, "command": "prepare", "root": root.path,
              "attribute": attributeName, "seed_hashes": hashes, "marker": markerName])
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["prepare"] { try prepare(); return }
    if args.count == 2 && args[0] == "sample" {
        FileHandle.standardOutput.write(try sample(args[1])); return
    }
    try require(args.count >= 3,
        "Usage: xattr-probe prepare | sample NAME | read ROOT FILE [SAMPLE|missing] | write-verify ROOT FILE SAMPLE | clear-verify ROOT FILE")
    try withTarget(args[1], args[2]) { target in
        switch args[0] {
        case "read" where (3...4).contains(args.count):
            try inspect(target, expectation: args.count == 4 ? args[3] : nil)
        case "write-verify" where args.count == 4:
            try mutate(target, body: sample(args[3]))
        case "clear-verify" where args.count == 3:
            try mutate(target, body: nil)
        default: throw ProbeFailure(message: "Unknown command or arguments")
        }
    }
}

do {
    try main()
} catch {
    var result: [String: Any] = ["ok": false, "error": String(describing: error)]
    if let failure = error as? ProbeFailure {
        result["error"] = failure.message
        if let code = failure.code { result["errno"] = code }
        if !failure.details.isEmpty { result["details"] = failure.details }
    }
    try? json(result, to: .standardError)
    exit(1)
}
