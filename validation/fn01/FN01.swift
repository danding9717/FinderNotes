import AppKit
import CryptoKit
import Foundation

enum ProbeError: Error, CustomStringConvertible {
    case usage(String)
    case invalidRoot(String)
    case unsafePath(String)
    case command(String)
    case mismatch(String)

    var description: String {
        switch self {
        case .usage(let message), .invalidRoot(let message), .unsafePath(let message),
             .command(let message), .mismatch(let message): message
        }
    }
}

let script = """
on run argv
    set operation to item 1 of argv
    set targetPath to item 2 of argv
    set targetFile to (POSIX file targetPath) as alias
    tell application "Finder"
        if operation is "read" then
            return comment of targetFile
        else if operation is "write" then
            set comment of targetFile to item 3 of argv
            return "written"
        else
            error "Unknown operation"
        end if
    end tell
end run
"""

struct CommandResult {
    let stdout: Data
    let stderr: Data
    let durationMS: Double
    let status: Int32
}

func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    let start = DispatchTime.now().uptimeNanoseconds
    try process.run()
    let watchdog = DispatchWorkItem {
        if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)
    // Read stdout before waiting: a 16 KiB comment may fill the pipe.
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    if process.terminationReason == .uncaughtSignal && process.terminationStatus == 15 {
        throw ProbeError.command("\(executable) exceeded the 120-second timeout")
    }
    return CommandResult(stdout: stdout,
                         stderr: stderr,
                         durationMS: elapsed, status: process.terminationStatus)
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func oneLine(_ data: Data) throws -> Data {
    guard data.last == 10 else { throw ProbeError.command("osascript reply lacked its line terminator") }
    return data.dropLast()
}

func finder(_ operation: String, file: URL, text: String? = nil) throws -> (Data, Double) {
    let arguments = ["-e", script, operation, file.path] + (text.map { [$0] } ?? [])
    let result = try run("/usr/bin/osascript", arguments)
    guard result.status == 0 else {
        let detail = String(data: result.stderr, encoding: .utf8) ?? "unreadable AppleScript error"
        throw ProbeError.command("Finder \(operation) failed (exit \(result.status)): \(detail.trimmingCharacters(in: .newlines))")
    }
    return (try oneLine(result.stdout), result.durationMS)
}

func checkedRoot(_ raw: String) throws -> URL {
    let root = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
    guard root.path.hasPrefix(temp.path + "/"), root.lastPathComponent.hasPrefix("findernotes-fn01-"),
          FileManager.default.fileExists(atPath: root.appendingPathComponent(".fn01-owned").path) else {
        throw ProbeError.invalidRoot("Root must be an FN-01 directory created under \(temp.path)")
    }
    return root
}

func checkedFile(_ root: URL, _ relative: String) throws -> URL {
    let components = relative.split(separator: "/")
    guard !relative.hasPrefix("/"), !components.contains(".."),
          components.first == "work" || components.first == "moved" else {
        throw ProbeError.unsafePath("Only work/ and moved/ copies inside this run can be accessed")
    }
    let path = root.appendingPathComponent(relative).standardizedFileURL
    let resolved = path.resolvingSymlinksInPath()
    let workPrefix = root.appendingPathComponent("work").path + "/"
    let movedPrefix = root.appendingPathComponent("moved").path + "/"
    guard resolved.path.hasPrefix(workPrefix) || resolved.path.hasPrefix(movedPrefix),
          FileManager.default.fileExists(atPath: resolved.path),
          (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          ["png", "mov"].contains(resolved.pathExtension) else {
        throw ProbeError.unsafePath("Target must be an existing synthetic .png or .mov inside the run root")
    }
    return resolved
}

func sample(_ name: String) throws -> Data {
    let text: String
    switch name {
    case "mixed":
        text = "  中文🙂👩🏽‍🚀 '双引号\\\"' 反斜杠\\\\\n第二段\n\n末尾空白  \n"
    case "cjk2000":
        text = String(repeating: "航", count: 2_000)
    case "utf8-16k":
        let prefix = "首行🙂\n  引号\\\" 与反斜杠\\\\  \n"
        let suffix = "\n末行空白  \n"
        let remaining = 16_384 - Data((prefix + suffix).utf8).count
        guard remaining > 0 else { throw ProbeError.command("Sample calculation failed") }
        let chineseCount = remaining / 3
        let asciiCount = remaining % 3
        text = prefix + String(repeating: "文", count: chineseCount)
             + String(repeating: "x", count: asciiCount) + suffix
    case "initial":
        text = "FN-01 已有注释：中文🙂 末尾"
    default:
        throw ProbeError.usage("Unknown sample: \(name)")
    }
    return Data(text.utf8)
}

func measure(_ label: String, _ data: Data, _ ms: Double) {
    print("\(label) bytes=\(data.count) sha256=\(digest(data)) duration_ms=\(String(format: "%.2f", ms))")
}

func assertEqual(_ actual: Data, _ expected: Data, _ label: String) throws {
    guard actual == expected else {
        let mismatch = zip(actual, expected).enumerated().first {
            $0.element.0 != $0.element.1
        }?.offset ?? min(actual.count, expected.count)
        throw ProbeError.mismatch("\(label): UTF-8 differs at byte \(mismatch); actual=\(actual.count)/\(digest(actual)); expected=\(expected.count)/\(digest(expected))")
    }
}

func contentHash(_ file: URL) throws -> String { digest(try Data(contentsOf: file)) }

func describeIdentity(_ file: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let device = attributes[.systemNumber] as? NSNumber
    let inode = attributes[.systemFileNumber] as? NSNumber
    print("file_identity device=\(device?.stringValue ?? "unknown") inode=\(inode?.stringValue ?? "unknown") path=\(file.path)")
}

func generatePNG(_ url: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                       bitsPerPixel: 0),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw ProbeError.command("Could not generate synthetic PNG")
    }
    try png.write(to: url)
}

func prepare() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("findernotes-fn01-\(UUID().uuidString.lowercased())", isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath()
    let files = FileManager.default
    try files.createDirectory(at: root, withIntermediateDirectories: false)
    try Data("FN-01 synthetic run\n".utf8).write(to: root.appendingPathComponent(".fn01-owned"))
    let sourcePNG = root.appendingPathComponent("seed.png")
    let sourceMOV = root.appendingPathComponent("seed.mov")
    try generatePNG(sourcePNG)
    let video = try run("/opt/homebrew/bin/ffmpeg", ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=16x16:r=1:d=1", "-c:v", "mpeg4", "-y", sourceMOV.path])
    guard video.status == 0 else {
        throw ProbeError.command("Synthetic video generation failed: \(String(data: video.stderr, encoding: .utf8) ?? "")")
    }
    try files.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: false)
    try files.createDirectory(at: root.appendingPathComponent("moved"), withIntermediateDirectories: false)
    for ext in ["png", "mov"] {
        for key in ["mixed", "cjk2000", "utf8-16k", "lifecycle"] {
            try files.copyItem(at: ext == "png" ? sourcePNG : sourceMOV,
                               to: root.appendingPathComponent("work/\(key).\(ext)"))
        }
    }
    for key in ["mixed", "cjk2000", "utf8-16k", "initial"] {
        try sample(key).write(to: root.appendingPathComponent("\(key).txt"))
    }
    print("ROOT=\(root.path)")
    print("SEED_PNG_SHA256=\(try contentHash(sourcePNG))")
    print("SEED_MOV_SHA256=\(try contentHash(sourceMOV))")
}

func inspect(_ root: URL, _ relative: String, expected: Data? = nil) throws {
    let file = try checkedFile(root, relative)
    try describeIdentity(file)
    let (body, duration) = try finder("read", file: file)
    measure("read \(relative)", body, duration)
    let media = try contentHash(file)
    let baseline = try contentHash(root.appendingPathComponent("seed.\(file.pathExtension)"))
    guard media == baseline else { throw ProbeError.mismatch("Media content differs from seed: \(relative)") }
    print("media_sha256=\(media) matches_seed=true")
    if let expected {
        try assertEqual(body, expected, relative)
        print("PASS exact UTF-8")
    }
}

func writeVerify(_ root: URL, _ relative: String, _ body: Data) throws {
    let file = try checkedFile(root, relative)
    try describeIdentity(file)
    guard let text = String(data: body, encoding: .utf8) else { throw ProbeError.usage("Body must be UTF-8") }
    let before = try contentHash(file)
    let (_, writeMS) = try finder("write", file: file, text: text)
    measure("write \(relative)", body, writeMS)
    let (readback, readMS) = try finder("read", file: file)
    measure("readback \(relative)", readback, readMS)
    try assertEqual(readback, body, relative)
    let after = try contentHash(file)
    let baseline = try contentHash(root.appendingPathComponent("seed.\(file.pathExtension)"))
    guard before == after, after == baseline else {
        throw ProbeError.mismatch("Media content changed or differs from seed: \(relative)")
    }
    print("PASS exact UTF-8; media_sha256=\(after) matches_seed=true")
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { throw ProbeError.usage("Usage: fn01 prepare | read ROOT FILE [SAMPLE [SUFFIX]] | write-verify ROOT FILE SAMPLE | sample SAMPLE") }
    if command == "prepare", args.count == 1 { try prepare(); return }
    if command == "sample", args.count == 2 {
        FileHandle.standardOutput.write(try sample(args[1])); return
    }
    guard args.count >= 3 else { throw ProbeError.usage("Missing ROOT and FILE") }
    let root = try checkedRoot(args[1])
    switch command {
    case "read" where (3...5).contains(args.count):
        let expected = args.count >= 4 ? try sample(args[3]) + Data((args.count == 5 ? args[4] : "").utf8) : nil
        try inspect(root, args[2], expected: expected)
    case "write-verify" where args.count == 4:
        try writeVerify(root, args[2], try sample(args[3]))
    default:
        throw ProbeError.usage("Unknown command or arguments")
    }
}

do {
    try main()
} catch {
    fputs("FN-01 ERROR: \(error)\n", stderr)
    exit(1)
}
