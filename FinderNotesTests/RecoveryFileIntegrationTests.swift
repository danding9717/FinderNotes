import AppKit
import CryptoKit
import Darwin
import ImageIO
import XCTest
@testable import FinderNotes

/// Real synthetic PNG/xattr/recovery I/O. Recreating a Store/Session simulates reopening;
/// these tests do not claim an OS process crash, Finder interaction, or real IME coverage.
@MainActor
final class RecoveryFileIntegrationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let url: URL
        let directory: URL
        let bytes: Data

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("findernotes-fn07-file-integration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            url = root.appendingPathComponent("original.png")
            directory = root.appendingPathComponent("Recovery/v1", isDirectory: true)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            memset(bitmap.bitmapData, 160, bitmap.bytesPerRow * bitmap.pixelsHigh)
            bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
            try bytes.write(to: url, options: .withoutOverwriting)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func recordURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    }

    private let sentinel = "com.findernotes.fn07.integration"

    private func set(_ url: URL, _ bytes: Data, name: String = NoteReader.attributeName) throws {
        let result = bytes.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, bytes.count, 0, 0) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }

    private func raw(_ url: URL, name: String = NoteReader.attributeName) throws -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
        var bytes = [UInt8](repeating: 0, count: max(1, size))
        let count = getxattr(url.path, name, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        return Data(bytes.prefix(count))
    }

    private func session(_ url: URL) throws -> EditorSession {
        let result = EditorSession()
        XCTAssertEqual(result.resolve(try NoteReader().read(urls: [url]), ticket: result.beginLoading()), .installed)
        return result
    }

    /// The writer and its lock go out of scope before a new Store opens the on-disk record.
    private func persist(_ session: EditorSession, fixture: Fixture) async throws -> DraftRecoveryRecord {
        let record = try XCTUnwrap(session.recoveryRecord)
        let store = DraftRecoveryStore(directory: fixture.directory)
        try await store.put(record)
        return record
    }

    private func restore(_ store: DraftRecoveryStore, current: NoteSnapshot?) async throws -> EditorSession {
        let records = try await store.records()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        let result = EditorSession()
        XCTAssertTrue(result.restoreRecovery(record: record, current: current))
        XCTAssertNil(result.autosaveTicket)
        return result
    }

    private func controller(_ session: EditorSession, store: DraftRecoveryStore) -> EditorWindowController {
        _ = NSApplication.shared
        let preview = MediaPreviewController(validate: { _ in throw NoteReadError.unsupportedType })
        return EditorWindowController(session: session, autosaveScheduler: TestAutosaveScheduler(),
                                      preview: preview, recoveryStore: store)
    }

    private func awaitSavedAndCleaned(_ session: EditorSession, store: DraftRecoveryStore) async throws {
        for _ in 0..<300 {
            let records = try await store.records()
            if !session.isDirty && !session.isSaving && records.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Real save and recovery cleanup did not settle")
    }

    private func assertMediaPreserved(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: fixture.url)), SHA256.hash(data: fixture.bytes),
                       file: file, line: line)
    }

    func testPublishedDraftSurvivesStoreAndSessionRecreationThenManualSaveCleansRecord() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let baseline = Data("正式基线\r\n".utf8)
        let local = "未保存草稿🙂\n  e\u{301}\0\r\n"
        try set(fixture.url, baseline)
        try set(fixture.url, Data([0, 255, 5]), name: sentinel)
        let original = try session(fixture.url)
        original.updateDraft(local)
        let record = try await persist(original, fixture: fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.recordURL(record.id).path))
        XCTAssertEqual(try raw(fixture.url), baseline)

        let reopened = DraftRecoveryStore(directory: fixture.directory)
        let recovered = try await restore(reopened, current: NoteReader().read(urls: [fixture.url]))
        XCTAssertEqual(Data(recovered.draft.utf8), Data(local.utf8))
        XCTAssertEqual(recovered.snapshot?.content, record.snapshot.content)
        XCTAssertFalse(recovered.recoveryWriteBlocked)
        XCTAssertTrue(recovered.recoveryNeedsAttention)
        XCTAssertEqual(try raw(fixture.url), baseline, "Restoration itself must not write the formal note")
        let controller = controller(recovered, store: reopened)
        defer { controller.window?.orderOut(nil) }
        controller.saveNote(nil)
        try await awaitSavedAndCleaned(recovered, store: reopened)
        XCTAssertEqual(try raw(fixture.url), Data(local.utf8))
        XCTAssertNil(recovered.recoveryRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recordURL(record.id).path))
        XCTAssertEqual(try raw(fixture.url, name: sentinel), Data([0, 255, 5]))
        try assertMediaPreserved(fixture)
    }

    func testExternalChangedDeletedAndEmptyBodiesKeepBothVersionsAndRejectUnconfirmedWrite() async throws {
        let variants: [Data?] = [Data("外部更新🙂".utf8), nil, Data()]
        for externalBytes in variants {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            try set(fixture.url, Data("打开时正文".utf8))
            let original = try session(fixture.url)
            original.updateDraft("本地保护草稿")
            let record = try await persist(original, fixture: fixture)
            if let externalBytes { try set(fixture.url, externalBytes) }
            else { XCTAssertEqual(removexattr(fixture.url.path, NoteReader.attributeName, XATTR_NOFOLLOW), 0) }
            let current = try NoteReader().read(urls: [fixture.url])
            XCTAssertEqual(current.content, externalBytes.map(NoteContent.present) ?? .missing)
            let reopened = DraftRecoveryStore(directory: fixture.directory)
            let recovered = try await restore(reopened, current: current)
            XCTAssertNotNil(recovered.saveIssue)
            XCTAssertFalse(recovered.recoveryWriteBlocked)
            XCTAssertEqual(recovered.snapshot?.content, record.snapshot.content)
            let ticket = try XCTUnwrap(recovered.beginSaving())
            XCTAssertThrowsError(try NoteWriter().save(ticket.request)) {
                XCTAssertEqual($0 as? NoteWriteError, .conflict)
            }
            XCTAssertTrue(recovered.failSaving("检测到真实外部正文冲突", uncertain: false, ticket: ticket))
            XCTAssertEqual(try raw(fixture.url), externalBytes)
            XCTAssertEqual(recovered.draft, record.draft)
            let exported = fixture.root.appendingPathComponent("local-draft.md")
            try MarkdownExporter().export(MarkdownExportRequest(source: fixture.url, destination: exported,
                                                                bytes: Data(recovered.draft.utf8)))
            XCTAssertEqual(try Data(contentsOf: exported), Data(record.draft.utf8))
            let remaining = try await reopened.records()
            XCTAssertEqual(remaining, [record], "Exporting alone must not discard the recovery record")
            try assertMediaPreserved(fixture)
        }
    }

    func testExternalBaselineCanBeAdoptedOnlyAfterPreservingBothVersionsThenManuallySaved() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try set(fixture.url, Data("打开时版本".utf8))
        let original = try session(fixture.url)
        original.updateDraft("本地最终版本")
        _ = try await persist(original, fixture: fixture)
        let external = Data("外部应先导出的版本".utf8)
        try set(fixture.url, external)
        let reopened = DraftRecoveryStore(directory: fixture.directory)
        let current = try NoteReader().read(urls: [fixture.url])
        let recovered = try await restore(reopened, current: current)
        let localCopy = fixture.root.appendingPathComponent("local.md")
        let externalCopy = fixture.root.appendingPathComponent("external.md")
        try MarkdownExporter().export(MarkdownExportRequest(source: fixture.url, destination: localCopy,
                                                            bytes: Data(recovered.draft.utf8)))
        try MarkdownExporter().export(MarkdownExportRequest(source: fixture.url, destination: externalCopy,
                                                            bytes: external))
        // This calls the model's explicit-confirmation boundary. It does not simulate a dialog click.
        XCTAssertTrue(recovered.applyExternal(current, replacingDraft: false,
                                               confirmedRevision: recovered.draftRevision))
        XCTAssertEqual(recovered.snapshot?.content, current.content)
        XCTAssertNil(recovered.autosaveTicket)
        let controller = controller(recovered, store: reopened)
        defer { controller.window?.orderOut(nil) }
        controller.saveNote(nil)
        try await awaitSavedAndCleaned(recovered, store: reopened)
        XCTAssertEqual(try raw(fixture.url), Data("本地最终版本".utf8))
        XCTAssertEqual(try Data(contentsOf: localCopy), Data("本地最终版本".utf8))
        XCTAssertEqual(try Data(contentsOf: externalCopy), external)
        try assertMediaPreserved(fixture)
    }

    func testMissingAndPresentEmptyBaselinesStayDistinctAcrossDiskRecovery() async throws {
        for startsEmpty in [false, true] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            if startsEmpty { try set(fixture.url, Data()) }
            let original = try session(fixture.url)
            original.updateDraft("待恢复正文")
            let record = try await persist(original, fixture: fixture)
            XCTAssertEqual(record.snapshot.content, startsEmpty ? .present(Data()) : .missing)
            if startsEmpty { XCTAssertEqual(removexattr(fixture.url.path, NoteReader.attributeName, XATTR_NOFOLLOW), 0) }
            else { try set(fixture.url, Data()) }
            let reopened = DraftRecoveryStore(directory: fixture.directory)
            let current = try NoteReader().read(urls: [fixture.url])
            let recovered = try await restore(reopened, current: current)
            XCTAssertNotNil(recovered.saveIssue, "Empty and missing must conflict even though both display empty text")
            XCTAssertEqual(recovered.snapshot?.content, record.snapshot.content)
            XCTAssertEqual(current.content, startsEmpty ? .missing : .present(Data()))
            let ticket = try XCTUnwrap(recovered.beginSaving())
            XCTAssertThrowsError(try NoteWriter().save(ticket.request)) {
                XCTAssertEqual($0 as? NoteWriteError, .conflict)
            }
            XCTAssertEqual(try raw(fixture.url), startsEmpty ? nil : Data())
        }
    }

    func testUnrelatedAttributeChangeDoesNotCreateBodyConflictOrGetOverwritten() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try set(fixture.url, Data("基线".utf8))
        try set(fixture.url, Data("原哨兵".utf8), name: sentinel)
        let original = try session(fixture.url)
        original.updateDraft("恢复后手动保存正文")
        _ = try await persist(original, fixture: fixture)
        let externalSentinel = Data([255, 0, 1, 2, 3])
        try set(fixture.url, externalSentinel, name: sentinel)
        let reopened = DraftRecoveryStore(directory: fixture.directory)
        let recovered = try await restore(reopened, current: NoteReader().read(urls: [fixture.url]))
        XCTAssertNil(recovered.saveIssue)
        let controller = controller(recovered, store: reopened)
        defer { controller.window?.orderOut(nil) }
        controller.saveNote(nil)
        try await awaitSavedAndCleaned(recovered, store: reopened)
        XCTAssertEqual(try raw(fixture.url), Data("恢复后手动保存正文".utf8))
        XCTAssertEqual(try raw(fixture.url, name: sentinel), externalSentinel)
        try assertMediaPreserved(fixture)
    }

    func testCopiedMediaAndBodyCannotReuseOriginalRecoveryIdentity() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try set(fixture.url, Data("复制时正式正文".utf8))
        let original = try session(fixture.url)
        original.updateDraft("只属于原件的草稿")
        let record = try await persist(original, fixture: fixture)
        let copy = fixture.root.appendingPathComponent("copy.png")
        try FileManager.default.copyItem(at: fixture.url, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), fixture.bytes)
        XCTAssertEqual(try raw(copy), try raw(fixture.url))
        let copySnapshot = try NoteReader().read(urls: [copy])
        XCTAssertNotEqual(copySnapshot.identity, record.snapshot.identity)
        let reopened = DraftRecoveryStore(directory: fixture.directory)
        let recovered = try await restore(reopened, current: copySnapshot)
        XCTAssertTrue(recovered.recoveryWriteBlocked)
        XCTAssertNil(recovered.beginSaving())
        let copySession = try session(copy)
        XCTAssertNil(copySession.recoveryRecord)
        XCTAssertEqual(copySession.draft, "复制时正式正文")
        XCTAssertEqual(recovered.draft, "只属于原件的草稿")
        XCTAssertEqual(try raw(copy), Data("复制时正式正文".utf8))
        try assertMediaPreserved(fixture)
    }

    func testSamePathReplacementIsBlockedEvenWithIdenticalMediaAndBody() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let formal = Data("媒体和正文完全相同".utf8)
        try set(fixture.url, formal)
        let original = try session(fixture.url)
        original.updateDraft("旧身份未保存草稿")
        let record = try await persist(original, fixture: fixture)
        let archived = fixture.root.appendingPathComponent("archived-original.png")
        try FileManager.default.moveItem(at: fixture.url, to: archived)
        try fixture.bytes.write(to: fixture.url, options: .withoutOverwriting)
        try set(fixture.url, formal)
        let replacement = try NoteReader().read(urls: [fixture.url])
        XCTAssertNotEqual(replacement.identity, record.snapshot.identity)
        XCTAssertEqual(replacement.content, record.snapshot.content)
        let reopened = DraftRecoveryStore(directory: fixture.directory)
        let recovered = try await restore(reopened, current: replacement)
        XCTAssertTrue(recovered.recoveryWriteBlocked)
        XCTAssertNil(recovered.beginSaving())
        XCTAssertThrowsError(try NoteWriter().save(NoteSaveRequest(baseline: record.snapshot,
            desiredContent: .present(Data(record.draft.utf8))))) {
            XCTAssertEqual($0 as? NoteWriteError, .identityChanged)
        }
        XCTAssertEqual(try raw(fixture.url), formal)
        XCTAssertEqual(try raw(archived), formal)
        let remaining = try await reopened.records()
        XCTAssertEqual(remaining, [record])
        try assertMediaPreserved(fixture)
    }

    func testMissingOriginalStillExportsDraftAndKeepsRecoveryWithoutCreatingTarget() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try set(fixture.url, Data("原始正式正文".utf8))
        let original = try session(fixture.url)
        original.updateDraft("原目标消失后仍可导出🙂")
        let record = try await persist(original, fixture: fixture)
        let archived = fixture.root.appendingPathComponent("moved-original.png")
        try FileManager.default.moveItem(at: fixture.url, to: archived)
        XCTAssertThrowsError(try NoteReader().read(urls: [fixture.url]))
        let reopened = DraftRecoveryStore(directory: fixture.directory)
        let recovered = try await restore(reopened, current: nil)
        XCTAssertTrue(recovered.recoveryWriteBlocked)
        XCTAssertNil(recovered.beginSaving())
        let export = fixture.root.appendingPathComponent("orphan-draft.md")
        try MarkdownExporter().export(MarkdownExportRequest(source: fixture.url, destination: export,
                                                            bytes: Data(recovered.draft.utf8)))
        XCTAssertEqual(try Data(contentsOf: export), Data(record.draft.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
        XCTAssertEqual(try raw(archived), Data("原始正式正文".utf8))
        XCTAssertEqual(try Data(contentsOf: archived), fixture.bytes)
        let remaining = try await reopened.records()
        XCTAssertEqual(remaining, [record])
    }

    func testUnreadableExternalUTF8IsAnErrorAndNeverAnEmptyBaseline() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try set(fixture.url, Data("有效的打开基线".utf8))
        let original = try session(fixture.url)
        original.updateDraft("读取失败也要保留的草稿")
        let record = try await persist(original, fixture: fixture)
        let invalid = Data([0xff, 0xfe, 0xfd])
        try set(fixture.url, invalid)
        XCTAssertThrowsError(try NoteReader().read(urls: [fixture.url])) {
            XCTAssertEqual($0 as? NoteReadError, .invalidUTF8)
        }
        let reopened = DraftRecoveryStore(directory: fixture.directory)
        let recovered = try await restore(reopened, current: nil)
        XCTAssertTrue(recovered.recoveryWriteBlocked)
        XCTAssertNil(recovered.beginSaving())
        XCTAssertEqual(recovered.snapshot?.content, record.snapshot.content)
        XCTAssertEqual(recovered.draft, record.draft)
        XCTAssertEqual(try raw(fixture.url), invalid)
        let remaining = try await reopened.records()
        XCTAssertEqual(remaining, [record])
        try assertMediaPreserved(fixture)
    }
}
