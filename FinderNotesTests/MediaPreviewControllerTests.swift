import AppKit
import XCTest
@testable import FinderNotes

@MainActor
private final class FakeMediaPreview: MediaPreviewBackend {
    let view = NSView()
    var autostarts = true
    private(set) var presentedURLs: [URL] = []
    private(set) var autostartsAtPresentation: [Bool] = []
    private(set) var closeCount = 0

    func present(_ url: URL) {
        autostartsAtPresentation.append(autostarts)
        presentedURLs.append(url)
    }

    func close() { closeCount += 1 }
}

private actor PreviewValidationGate {
    private var nextIdentifier = 0
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]

    var requestCount: Int { nextIdentifier }

    func validate(_ snapshot: NoteSnapshot) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let identifier = nextIdentifier
            nextIdentifier += 1
            pending[identifier] = continuation
        }
    }

    func finish(_ identifier: Int, error: (any Error)? = nil) {
        guard let continuation = pending.removeValue(forKey: identifier) else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}

@MainActor
final class MediaPreviewControllerTests: XCTestCase {
    private func snapshot(name: String = "one.png", inode: UInt64 = 1, text: String = "正文") -> NoteSnapshot {
        NoteSnapshot(url: URL(fileURLWithPath: "/tmp/\(name)"),
                     identity: FileIdentity(device: 1, inode: inode),
                     content: .present(Data(text.utf8)))
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Preview operation did not reach the expected state")
    }

    func testStartsExpandedAndDisablesAutoplayBeforePresenting() async throws {
        let backend = FakeMediaPreview()
        let controller = MediaPreviewController(validate: { _ in }, makeBackend: { backend })
        defer { controller.close() }
        XCTAssertTrue(controller.isExpanded)
        XCTAssertEqual(controller.state, .empty)
        let note = snapshot(name: "video.mov")
        controller.install(snapshot: note)
        try await waitUntil { controller.state == .systemPreview }
        XCTAssertEqual(backend.presentedURLs, [note.url])
        XCTAssertEqual(backend.autostartsAtPresentation, [false])
        XCTAssertTrue(backend.view.superview === controller.view)
    }

    func testRepeatedTargetAndSavedBaselineDoNotRestartPreview() async throws {
        var created: [FakeMediaPreview] = []
        let controller = MediaPreviewController(validate: { _ in }, makeBackend: {
            let backend = FakeMediaPreview()
            created.append(backend)
            return backend
        })
        defer { controller.close() }
        controller.install(snapshot: snapshot())
        try await waitUntil { controller.state == .systemPreview }
        controller.install(snapshot: snapshot(text: "自动保存后的新基线"))
        controller.setExpanded(true)
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].presentedURLs.count, 1)
        XCTAssertEqual(created[0].closeCount, 0)
        XCTAssertEqual(controller.target?.content.text, "自动保存后的新基线")
    }

    func testCollapseReleasesPlaybackAndExpansionCreatesFreshBackend() async throws {
        var created: [FakeMediaPreview] = []
        let controller = MediaPreviewController(validate: { _ in }, makeBackend: {
            let backend = FakeMediaPreview()
            created.append(backend)
            return backend
        })
        defer { controller.close() }
        controller.install(snapshot: snapshot(name: "video.mov"))
        try await waitUntil { controller.state == .systemPreview }
        controller.setExpanded(false)
        XCTAssertEqual(created[0].closeCount, 1)
        XCTAssertNil(created[0].view.superview)
        XCTAssertFalse(controller.isExpanded)
        XCTAssertTrue(controller.view.isHidden)
        controller.setExpanded(true)
        try await waitUntil { controller.state == .systemPreview }
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created[1].autostartsAtPresentation, [false])
        XCTAssertFalse(controller.view.isHidden)
    }

    func testDifferentIdentityAtSamePathReleasesOldPreview() async throws {
        var created: [FakeMediaPreview] = []
        let controller = MediaPreviewController(validate: { _ in }, makeBackend: {
            let backend = FakeMediaPreview()
            created.append(backend)
            return backend
        })
        controller.install(snapshot: snapshot())
        try await waitUntil { controller.state == .systemPreview }
        controller.install(snapshot: snapshot(inode: 2))
        XCTAssertEqual(created[0].closeCount, 1)
        try await waitUntil { controller.state == .systemPreview }
        XCTAssertEqual(created.count, 2)
        controller.close()
        controller.close()
        XCTAssertEqual(created[1].closeCount, 1)
        XCTAssertNil(created[1].view.superview)
        XCTAssertNil(controller.target)
        XCTAssertEqual(controller.state, .empty)
    }

    func testFailureHasIndependentPlaceholderAndKeepsTarget() async throws {
        var created = 0
        let controller = MediaPreviewController(validate: { _ in throw NoteReadError.targetChanged },
                                                makeBackend: { created += 1; return FakeMediaPreview() })
        defer { controller.close() }
        controller.install(snapshot: snapshot(text: "保留正文"))
        try await waitUntil { controller.state == .unavailable }
        XCTAssertEqual(created, 0)
        XCTAssertEqual(controller.target?.content.text, "保留正文")
        XCTAssertEqual(controller.messageLabel.stringValue, "预览不可用，仍可编辑笔记")
        XCTAssertNotNil(controller.messageLabel.toolTip)
    }

    func testUnavailableSystemComponentUsesSameFallback() async throws {
        let controller = MediaPreviewController(validate: { _ in }, makeBackend: { nil })
        defer { controller.close() }
        controller.install(snapshot: snapshot())
        try await waitUntil { controller.state == .unavailable }
        XCTAssertEqual(controller.messageLabel.stringValue, "预览不可用，仍可编辑笔记")
    }

    func testLateValidationCannotRestoreOldTargetAfterSwitch() async throws {
        let gate = PreviewValidationGate()
        var created: [FakeMediaPreview] = []
        let controller = MediaPreviewController(validate: { try await gate.validate($0) }, makeBackend: {
            let backend = FakeMediaPreview()
            created.append(backend)
            return backend
        })
        defer { controller.close() }
        controller.install(snapshot: snapshot())
        try await waitUntil { await gate.requestCount == 1 }
        let second = snapshot(name: "two.mov", inode: 2)
        controller.install(snapshot: second)
        try await waitUntil { await gate.requestCount == 2 }
        await gate.finish(1)
        try await waitUntil { controller.state == .systemPreview }
        await gate.finish(0, error: NoteReadError.targetChanged)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.state, .systemPreview)
        XCTAssertEqual(controller.target?.url, second.url)
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created[0].presentedURLs, [second.url])
    }

    func testLateValidationAfterCollapseOrCloseNeverCreatesPreview() async throws {
        let gate = PreviewValidationGate()
        var created = 0
        let controller = MediaPreviewController(validate: { try await gate.validate($0) }, makeBackend: {
            created += 1
            return FakeMediaPreview()
        })
        controller.install(snapshot: snapshot())
        try await waitUntil { await gate.requestCount == 1 }
        controller.setExpanded(false)
        await gate.finish(0)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(created, 0)
        controller.install(snapshot: snapshot(name: "two.mov", inode: 2))
        XCTAssertEqual(controller.state, .empty)
        controller.setExpanded(true)
        try await waitUntil { await gate.requestCount == 2 }
        controller.close()
        await gate.finish(1)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(created, 0)
        XCTAssertNil(controller.target)
        XCTAssertEqual(controller.state, .empty)
    }

    func testAccessProbeRejectsReplacementAndSymbolicLinkWithoutReadingNotes() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("findernotes-fn06-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        let replacement = root.appendingPathComponent("replacement.png")
        try Data("synthetic image bytes".utf8).write(to: original)
        try Data("replacement bytes".utf8).write(to: replacement)
        let note = try NoteReader().read(urls: [original])
        let bytes = try Data(contentsOf: original)
        XCTAssertNoThrow(try MediaPreviewController.validateAccess(to: note))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: replacement, to: original)
        XCTAssertThrowsError(try MediaPreviewController.validateAccess(to: note)) { error in
            XCTAssertEqual(error as? NoteReadError, .targetChanged)
        }
        try FileManager.default.moveItem(at: original, to: replacement)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: replacement)
        XCTAssertThrowsError(try MediaPreviewController.validateAccess(to: note))
    }
}
