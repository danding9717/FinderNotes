import Darwin
import Foundation
import XCTest
@testable import FinderNotes

@MainActor
final class DraftRecoveryStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let directory: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("findernotes-fn07-recovery-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            directory = root.appendingPathComponent("Recovery/v1", isDirectory: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    }

    private func record(_ fixture: Fixture, id: UUID = UUID(), content: NoteContent = .missing,
                        draft: String = "本地草稿🙂\n  \0e\u{301}\r\n", revision: UInt64 = 3) -> DraftRecoveryRecord {
        DraftRecoveryRecord(id: id,
            baseline: NoteSnapshot(url: fixture.root.appendingPathComponent("original.png"),
                identity: FileIdentity(device: 12, inode: 34, birthSeconds: 56, birthNanoseconds: 78),
                content: content), draft: draft, revision: revision)
    }

    private func expect(_ error: DraftRecoveryError,
                        operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(error)", file: file, line: line) }
        catch let actual as DraftRecoveryError { XCTAssertEqual(actual, error, file: file, line: line) }
        catch { XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line) }
    }

    private func seed(_ record: DraftRecoveryRecord, fixture: Fixture) async throws {
        let store = DraftRecoveryStore(directory: fixture.directory)
        try await store.put(record)
    }

    func testExactUTF8MissingAndEmptyBaselinesRoundTripAndCleanup() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let missing = record(fixture)
        let empty = record(fixture, content: .present(Data()), draft: "")
        let text = record(fixture, content: .present(Data("外部基线\0🙂\r\n ".utf8)))
        for value in [missing, empty, text] { try await store.put(value) }
        let firstRead = try await store.records()
        XCTAssertEqual(Data(try XCTUnwrap(firstRead.first(where: { $0.id == missing.id })).draft.utf8),
                       Data(missing.draft.utf8))
        let secondRead = try await store.records()
        XCTAssertEqual(Set(firstRead.map(\.id)), Set([missing.id, empty.id, text.id]))
        XCTAssertEqual(firstRead, secondRead, "enumerating twice must not retain a shared directory offset")
        XCTAssertEqual(firstRead.first { $0.id == missing.id }?.snapshot.content, .missing)
        XCTAssertEqual(firstRead.first { $0.id == empty.id }?.snapshot.content, .present(Data()))
        XCTAssertEqual(firstRead.first { $0.id == text.id }, text)
        XCTAssertEqual(firstRead.first { $0.id == text.id }?.snapshot.content.text, "外部基线\0🙂\r\n ")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? Int
        let recordMode = try FileManager.default.attributesOfItem(atPath: fixture.file(missing.id).path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(recordMode, 0o600)
        for value in [missing, empty, text] { try await store.remove(id: value.id) }
        try await store.remove(id: missing.id)
        let remaining = try await store.records()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), [".lock"])
    }

    func testReplacingPublishedRevisionAndRejectingOlderRevision() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let first = record(fixture, revision: 7)
        let next = record(fixture, id: first.id, draft: "后续编辑", revision: 8)
        try await store.put(first)
        try await store.put(next)
        await expect(.staleRevision) { try await store.put(first) }
        let stored = try await store.records()
        XCTAssertEqual(stored, [next])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .contains { $0.hasSuffix(".tmp") })
    }

    func testFailureBeforeRenamePreservesPreviousFileByteForByte() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let first = record(fixture)
        try await seed(first, fixture: fixture)
        let bytesBefore = try Data(contentsOf: fixture.file(first.id))
        let store = DraftRecoveryStore(directory: fixture.directory, beforePublish: {
            throw DraftRecoveryError.system(operation: "测试注入", code: EIO)
        })
        let next = record(fixture, id: first.id, draft: "不能发布的草稿", revision: 4)
        await expect(.system(operation: "测试注入", code: EIO)) { try await store.put(next) }
        XCTAssertEqual(try Data(contentsOf: fixture.file(first.id)), bytesBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted(),
                       [".lock", first.id.uuidString + ".json"].sorted())
    }

    func testTemporaryReplacementIsNotPublishedOrDeleted() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let first = record(fixture)
        try await seed(first, fixture: fixture)
        let directory = fixture.directory
        let replacement = Data("replacement owned by test".utf8)
        let store = DraftRecoveryStore(directory: directory, beforePublish: {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let name = try XCTUnwrap(names.first { $0.hasPrefix(".draft-") && $0.hasSuffix(".tmp") })
            let url = directory.appendingPathComponent(name)
            try FileManager.default.removeItem(at: url)
            try replacement.write(to: url, options: .withoutOverwriting)
        })
        await expect(.temporaryFileChanged) {
            try await store.put(self.record(fixture, id: first.id, draft: "new", revision: 4))
        }
        let records = try await store.records()
        XCTAssertEqual(records, [first])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let temporary = try XCTUnwrap(files.first { $0.pathExtension == "tmp" })
        XCTAssertEqual(try Data(contentsOf: temporary), replacement)
    }

    func testLifetimeLockExcludesSecondInstanceAndReleasesWhenOwnerEnds() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var first: DraftRecoveryStore? = DraftRecoveryStore(directory: fixture.directory)
        weak var weakFirst = first
        let value = record(fixture)
        try await first?.put(value)
        let second = DraftRecoveryStore(directory: fixture.directory)
        await expect(.storeBusy) { _ = try await second.records() }
        await expect(.storeBusy) { try await second.remove(id: value.id) }
        first = nil
        XCTAssertNil(weakFirst)
        let recovered = try await second.records()
        XCTAssertEqual(recovered, [value])
    }

    func testCorruptRecordRemainsAndBlocksOverwriteAndCleanup() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let value = record(fixture)
        try await store.put(value)
        let corrupt = Data("{broken-json-with-private-text".utf8)
        try corrupt.write(to: fixture.file(value.id))
        await expect(.invalidRecord) { _ = try await store.records() }
        await expect(.invalidRecord) { try await store.put(value) }
        await expect(.invalidRecord) { try await store.remove(id: value.id) }
        XCTAssertEqual(try Data(contentsOf: fixture.file(value.id)), corrupt)
        XCTAssertFalse(DraftRecoveryError.invalidRecord.localizedDescription.contains("private-text"))
    }

    func testUnknownVersionInvalidUTF8AndRecordIDMismatchFailClosed() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let value = record(fixture, content: .present(Data("baseline".utf8)))
        try await store.put(value)
        let original = try Data(contentsOf: fixture.file(value.id))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var version = object
        version["version"] = 2
        let unknown = try JSONSerialization.data(withJSONObject: version)
        try unknown.write(to: fixture.file(value.id))
        await expect(.unsupportedVersion) { _ = try await store.records() }
        XCTAssertEqual(try Data(contentsOf: fixture.file(value.id)), unknown)

        var invalid = object
        var baseline = try XCTUnwrap(invalid["baseline"] as? [String: Any])
        baseline["content"] = ["kind": "present", "bytes": Data([0xff]).base64EncodedString()]
        invalid["baseline"] = baseline
        try JSONSerialization.data(withJSONObject: invalid).write(to: fixture.file(value.id))
        await expect(.invalidUTF8) { _ = try await store.records() }
        var mismatch = object
        mismatch["id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: mismatch).write(to: fixture.file(value.id))
        await expect(.invalidRecord) { _ = try await store.records() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file(value.id).path))
    }

    func testInvalidUTF8InputCannotPublishARecord() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        await expect(.invalidUTF8) { try await store.put(self.record(fixture, content: .present(Data([0xff])))) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testInsecureDirectoryAndFileModesAreRejectedWithoutRepair() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let value = record(fixture)
        try await store.put(value)
        XCTAssertEqual(chmod(fixture.file(value.id).path, 0o644), 0)
        await expect(.insecureFile) { _ = try await store.records() }
        await expect(.insecureFile) { try await store.remove(id: value.id) }
        XCTAssertEqual(chmod(fixture.file(value.id).path, 0o600), 0)
        XCTAssertEqual(chmod(fixture.directory.path, 0o755), 0)
        await expect(.directoryChanged) { _ = try await store.records() }
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o755)
        let another = DraftRecoveryStore(directory: fixture.directory)
        await expect(.insecureDirectory) { _ = try await another.records() }
    }

    func testSymbolicLinkDirectoryAndRecordAndHardLinkAreRejected() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let value = record(fixture)
        try await store.put(value)
        let linkedDirectory = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: fixture.directory)
        let viaLink = DraftRecoveryStore(directory: linkedDirectory)
        do { _ = try await viaLink.records(); XCTFail("symlink directory accepted") } catch { }
        let external = fixture.root.appendingPathComponent("external.json")
        try FileManager.default.moveItem(at: fixture.file(value.id), to: external)
        let original = try Data(contentsOf: external)
        try FileManager.default.createSymbolicLink(at: fixture.file(value.id), withDestinationURL: external)
        await expect(.insecureFile) { _ = try await store.records() }
        await expect(.insecureFile) { try await store.put(value) }
        XCTAssertEqual(try Data(contentsOf: external), original)
        try FileManager.default.removeItem(at: fixture.file(value.id))
        try FileManager.default.linkItem(at: external, to: fixture.file(value.id))
        await expect(.insecureFile) { _ = try await store.records() }
        await expect(.insecureFile) { try await store.remove(id: value.id) }
        XCTAssertEqual(try Data(contentsOf: external), original)
    }

    func testDirectoryReplacementIsDetectedAndOriginalRecordPreserved() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let value = record(fixture)
        try await store.put(value)
        let moved = fixture.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: fixture.directory, to: moved)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        await expect(.directoryChanged) { _ = try await store.records() }
        await expect(.directoryChanged) { try await store.remove(id: value.id) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(value.id.uuidString + ".json").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testSameContentWithDistinctIdentityRemainsSeparateAndDoesNotReadMedia() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let first = record(fixture, content: .present(Data("same baseline".utf8)))
        let copy = DraftRecoveryRecord(id: UUID(),
            baseline: NoteSnapshot(url: fixture.root.appendingPathComponent("copy.png"),
                identity: FileIdentity(device: 12, inode: 35, birthSeconds: 57, birthNanoseconds: 79),
                content: first.snapshot.content), draft: first.draft, revision: first.revision)
        try await store.put(first)
        try await store.put(copy)
        let records = try await store.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertNotEqual(records[0].snapshot.identity, records[1].snapshot.identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.snapshot.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.snapshot.url.path))
    }
}
