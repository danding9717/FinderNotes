import CryptoKit
import Darwin
import Foundation

/// A command-line process probe linked to the production reader and recovery store.
/// It intentionally never prints note/draft text or raw encoded content.
@main
struct FN07CrashProbe {
    private static let baseline = Data("FN07 process probe baseline\n中文🙂\n".utf8)
    private static let draft = "FN07 process probe unsaved draft\n合成草稿🙂\0e\u{301}\r\n"
    private static let external = Data("FN07 process probe external version\n外部合成正文\n".utf8)

    private enum ProbeError: Error { case arguments, ownership, unexpectedRecords, unexpectedBaseline }

    private static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func metadata(_ content: NoteContent) -> [String: Any] {
        switch content {
        case .missing: return ["state": "missing"]
        case .present(let bytes):
            return ["state": bytes.isEmpty ? "empty" : "present",
                    "byteCount": bytes.count, "sha256": hash(bytes)]
        }
    }

    private static func metadata(_ identity: FileIdentity) -> [String: Any] {
        ["device": identity.device, "inode": identity.inode,
         "birthSeconds": identity.birthSeconds, "birthNanoseconds": identity.birthNanoseconds]
    }

    private static func emit(_ value: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        bytes.append(0x0a)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }

    private static func ownedRoot(_ path: String) throws -> URL {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard root.lastPathComponent.hasPrefix("findernotes-fn07-process-"),
              try NoteReader.localPath(path) == path else { throw ProbeError.ownership }
        let markerURL = root.appendingPathComponent(".fn07-process-owned.json")
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL))
        guard let marker = value as? [String: Any],
              marker["schema"] as? String == "findernotes-fn07-process-crash-v1",
              marker["root"] as? String == path else { throw ProbeError.ownership }
        return root
    }

    private static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4, let id = UUID(uuidString: arguments[3]) else { throw ProbeError.arguments }
        let root = try ownedRoot(arguments[2])
        let target = root.appendingPathComponent("work/original.png")
        let store = DraftRecoveryStore(directory: root.appendingPathComponent("Recovery/v1", isDirectory: true))
        switch arguments[1] {
        case "seed":
            guard arguments.count == 4 else { throw ProbeError.arguments }
            let current = try NoteReader().read(urls: [target])
            guard current.content == .present(baseline) else { throw ProbeError.unexpectedBaseline }
            let record = DraftRecoveryRecord(id: id, baseline: current, draft: draft, revision: 17)
            try await store.put(record)
            try emit(["event": "ready", "pid": getpid(), "recordID": id.uuidString,
                      "putReturned": true, "draftByteCount": Data(draft.utf8).count,
                      "draftSHA256": hash(Data(draft.utf8)), "baseline": metadata(current.content),
                      "identity": metadata(current.identity)])
            // Keep the production actor (and its real flock) alive until the parent kills us.
            // No Swift defer/deinit cleanup occurs on SIGKILL.
            withExtendedLifetime(store) {
                while true { _ = Darwin.pause() }
            }
        case "inspect":
            guard arguments.count == 5 else { throw ProbeError.arguments }
            let expectedCase = arguments[4]
            guard ["unchanged", "externalChanged", "replaced"].contains(expectedCase) else {
                throw ProbeError.arguments
            }
            let records = try await store.records()
            guard records.count == 1, let record = records.first, record.id == id else {
                throw ProbeError.unexpectedRecords
            }
            let current = try NoteReader().read(urls: [target])
            let identityMatches = current.identity == record.snapshot.identity && current.url == record.snapshot.url
            let baselineMatches = current.content == record.snapshot.content
            let draftMatches = Data(record.draft.utf8) == Data(draft.utf8)
            let recordedBaselineMatches = record.snapshot.content == .present(baseline)
            let caseMatches: Bool
            switch expectedCase {
            case "unchanged": caseMatches = identityMatches && baselineMatches
            case "externalChanged":
                caseMatches = identityMatches && !baselineMatches && current.content == .present(external)
            default:
                caseMatches = !identityMatches && baselineMatches
            }
            let passed = draftMatches && recordedBaselineMatches && record.revision == 17 && caseMatches
            try emit(["event": "inspection", "case": expectedCase, "pid": getpid(),
                      "recordID": record.id.uuidString, "recordCount": records.count,
                      "recordVersion": record.version, "recordRevision": record.revision,
                      "draftMatchesExpected": draftMatches, "draftByteCount": Data(record.draft.utf8).count,
                      "draftSHA256": hash(Data(record.draft.utf8)),
                      "recordedBaselineMatchesExpected": recordedBaselineMatches,
                      "recordBaseline": metadata(record.snapshot.content), "currentNote": metadata(current.content),
                      "recordIdentity": metadata(record.snapshot.identity), "currentIdentity": metadata(current.identity),
                      "identityMatches": identityMatches, "baselineMatches": baselineMatches,
                      "readSucceeded": true, "casePassed": passed, "formalNoteWriteAttempted": false])
            if !passed { exit(1) }
        default: throw ProbeError.arguments
        }
    }

    static func main() async {
        do { try await run() }
        catch {
            // The type, not its associated data, is enough for a failed probe report.
            try? emit(["event": "error", "pid": getpid(), "errorType": String(reflecting: type(of: error))])
            exit(2)
        }
    }
}
