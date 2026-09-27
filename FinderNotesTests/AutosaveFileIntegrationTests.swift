import AppKit
import CryptoKit
import Darwin
import ImageIO
import XCTest
@testable import FinderNotes

/// Real APFS file I/O through the production editor/writer; these are not Finder UI tests.
@MainActor
final class AutosaveFileIntegrationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let url: URL
        let bytes: Data
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("findernotes-fn06-integration-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            url = root.appendingPathComponent("original.png")
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            memset(bitmap.bitmapData, 180, bitmap.bytesPerRow * bitmap.pixelsHigh)
            bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
            try bytes.write(to: url, options: .withoutOverwriting)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func set(_ url: URL, _ text: String, name: String = NoteReader.attributeName) throws {
        let bytes = Data(text.utf8)
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

    private func controller(_ url: URL, scheduler: any EditorAutosaveScheduling) throws -> EditorWindowController {
        _ = NSApplication.shared
        let session = EditorSession()
        _ = session.resolve(try NoteReader().read(urls: [url]), ticket: session.beginLoading())
        let preview = MediaPreviewController(validate: { _ in throw NoteReadError.unsupportedType })
        return EditorWindowController(session: session, autosaveScheduler: scheduler, preview: preview)
    }

    private func edit(_ text: String, _ controller: EditorWindowController) {
        controller.editor.string = text
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.editor))
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Real file operation did not settle")
    }

    func testProductionOneSecondTimerWritesAndReadsRealPNGWithoutChangingMedia() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try set(fixture.url, "原文")
        try set(fixture.url, "preserve", name: "com.findernotes.fn06.integration")
        let controller = try controller(fixture.url, scheduler: EditorAutosaveScheduler())
        let draft = "  中文🙂\n" + String(repeating: "航", count: 2_000) + "\n"
        edit(draft, controller)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try raw(fixture.url), Data("原文".utf8))
        try await settle { !controller.session.isDirty && !controller.session.isSaving }
        XCTAssertEqual(try raw(fixture.url), Data(draft.utf8))
        XCTAssertEqual(try NoteReader().read(urls: [fixture.url]).content.text, draft)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: fixture.url)), SHA256.hash(data: fixture.bytes))
        XCTAssertEqual(try raw(fixture.url, name: "com.findernotes.fn06.integration"), Data("preserve".utf8))
    }

    func testExternalBodyConflictPausesAndPreservesBothVersions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try set(fixture.url, "原文")
        let scheduler = TestAutosaveScheduler()
        let controller = try controller(fixture.url, scheduler: scheduler)
        try set(fixture.url, "外部版本")
        edit("本地草稿", controller)
        scheduler.fire()
        try await settle { !controller.session.isSaving }
        XCTAssertNotNil(controller.session.saveIssue)
        XCTAssertEqual(try raw(fixture.url), Data("外部版本".utf8))
        XCTAssertEqual(controller.session.draft, "本地草稿")
        edit("继续写字", controller)
        XCTAssertNil(scheduler.pending)
        XCTAssertEqual(try raw(fixture.url), Data("外部版本".utf8))
    }

    func testUnrelatedAttributeChangeDoesNotPauseAutosave() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try set(fixture.url, "原文")
        let scheduler = TestAutosaveScheduler()
        let controller = try controller(fixture.url, scheduler: scheduler)
        try set(fixture.url, "outside", name: "com.findernotes.fn06.integration")
        edit("新正文", controller)
        scheduler.fire()
        try await settle { !controller.session.isSaving }
        XCTAssertNil(controller.session.saveIssue)
        XCTAssertEqual(try raw(fixture.url), Data("新正文".utf8))
        XCTAssertEqual(try raw(fixture.url, name: "com.findernotes.fn06.integration"), Data("outside".utf8))
    }

    func testPermissionFailureRequiresManualSuccessBeforeAutomaticResume() async throws {
        if geteuid() == 0 { throw XCTSkip("Root bypasses the mode-bit permission check") }
        let fixture = try Fixture()
        defer { chmod(fixture.url.path, 0o600); fixture.cleanup() }
        try set(fixture.url, "原文")
        let scheduler = TestAutosaveScheduler()
        let controller = try controller(fixture.url, scheduler: scheduler)
        XCTAssertEqual(chmod(fixture.url.path, 0o444), 0)
        edit("权限失败草稿", controller)
        scheduler.fire()
        try await settle { !controller.session.isSaving }
        XCTAssertNotNil(controller.session.saveIssue)
        XCTAssertEqual(try raw(fixture.url), Data("原文".utf8))
        XCTAssertEqual(chmod(fixture.url.path, 0o600), 0)
        edit("恢复权限后仍暂停", controller)
        XCTAssertNil(scheduler.pending)
        controller.saveNote(nil)
        try await settle { !controller.session.isSaving }
        XCTAssertNil(controller.session.saveIssue)
        edit("自动恢复下一版", controller)
        XCTAssertNotNil(scheduler.pending)
        scheduler.fire()
        try await settle { !controller.session.isSaving }
        XCTAssertEqual(try raw(fixture.url), Data("自动恢复下一版".utf8))
    }

    func testCopiedFileHasSeparateIdentityAndSaveSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try set(fixture.url, "原文")
        let copy = fixture.root.appendingPathComponent("copy.png")
        try FileManager.default.copyItem(at: fixture.url, to: copy)
        let scheduler = TestAutosaveScheduler()
        let controller = try controller(fixture.url, scheduler: scheduler)
        let originalIdentity = controller.session.snapshot?.identity
        edit("原件新正文", controller)
        scheduler.fire()
        try await settle { !controller.session.isSaving }
        controller.receive([copy])
        defer { controller.window?.orderOut(nil) }
        try await settle { !controller.session.isLoading }
        XCTAssertNotEqual(controller.session.snapshot?.identity, originalIdentity)
        edit("副本新正文", controller)
        scheduler.fire()
        try await settle { !controller.session.isSaving }
        XCTAssertEqual(try raw(fixture.url), Data("原件新正文".utf8))
        XCTAssertEqual(try raw(copy), Data("副本新正文".utf8))
    }

    func testReplacementAtSamePathCannotReceiveOldDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try set(fixture.url, "原文")
        let scheduler = TestAutosaveScheduler()
        let controller = try controller(fixture.url, scheduler: scheduler)
        let held = fixture.root.appendingPathComponent("held.png")
        try FileManager.default.moveItem(at: fixture.url, to: held)
        try fixture.bytes.write(to: fixture.url, options: .withoutOverwriting)
        try set(fixture.url, "替换文件")
        edit("旧对象草稿", controller)
        scheduler.fire()
        try await settle { !controller.session.isSaving }
        XCTAssertNotNil(controller.session.saveIssue)
        XCTAssertNil(scheduler.pending)
        XCTAssertEqual(controller.session.draft, "旧对象草稿")
        XCTAssertEqual(try raw(fixture.url), Data("替换文件".utf8))
        XCTAssertEqual(try raw(held), Data("原文".utf8))
    }
}
