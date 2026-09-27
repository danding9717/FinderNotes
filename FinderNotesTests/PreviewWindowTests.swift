import AppKit
import XCTest
@testable import FinderNotes

@MainActor
final class PreviewWindowTests: XCTestCase {
    private final class FocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class Backend: MediaPreviewBackend {
        let view: NSView = FocusView()
        var autostarts = true
        var presented: [URL] = []
        var closes = 0
        func present(_ url: URL) { presented.append(url) }
        func close() { closes += 1 }
    }

    private final class IdleScheduler: EditorAutosaveScheduling {
        func schedule(_ action: @escaping @MainActor () -> Void) {}
        func cancel() {}
    }

    private func note(_ name: String = "one.png", inode: UInt64 = 1) -> NoteSnapshot {
        NoteSnapshot(url: URL(fileURLWithPath: "/tmp/" + name),
                     identity: FileIdentity(device: 1, inode: inode),
                     content: .present(Data("预览测试正文".utf8)))
    }

    private func controller(preview: MediaPreviewController,
                            read: @escaping @Sendable ([URL]) throws -> NoteSnapshot) -> EditorWindowController {
        _ = NSApplication.shared
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        return EditorWindowController(session: session, read: read, save: { request in
            NoteSnapshot(url: request.baseline.url, identity: request.baseline.identity,
                         content: request.desiredContent)
        }, autosaveScheduler: IdleScheduler(), preview: preview)
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Operation did not settle")
    }

    func testCollapseFillsEditorWithoutChangingNativeInputState() async throws {
        let backend = Backend()
        let preview = MediaPreviewController(validate: { _ in }, makeBackend: { backend })
        let snapshot = note()
        let controller = controller(preview: preview, read: { _ in snapshot })
        controller.showEditor()
        defer { preview.close(); controller.window?.orderOut(nil) }
        try await settle { preview.state == .systemPreview }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let expandedWidth = try XCTUnwrap(controller.editor.enclosingScrollView).frame.width
        XCTAssertGreaterThanOrEqual(expandedWidth, preview.view.frame.width)
        controller.editor.setSelectedRange(NSRange(location: 0, length: 0))
        controller.editor.insertText("已提交", replacementRange: controller.editor.selectedRange())
        controller.editor.breakUndoCoalescing()
        controller.editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0),
                                        replacementRange: NSRange(location: NSNotFound, length: 0))
        let text = controller.editor.string
        let selection = controller.editor.selectedRange()
        let marked = controller.editor.markedRange()
        let undo = controller.editor.undoManager?.canUndo
        controller.togglePreview(nil)
        XCTAssertFalse(preview.isExpanded)
        XCTAssertEqual(backend.closes, 1)
        XCTAssertGreaterThan(try XCTUnwrap(controller.editor.enclosingScrollView).frame.width, expandedWidth)
        XCTAssertEqual(controller.editor.string, text)
        XCTAssertEqual(controller.editor.selectedRange(), selection)
        XCTAssertEqual(controller.editor.markedRange(), marked)
        XCTAssertEqual(controller.editor.undoManager?.canUndo, undo)
        controller.togglePreview(nil)
        try await settle { preview.state == .systemPreview }
        XCTAssertEqual(controller.editor.string, text)
        XCTAssertEqual(controller.editor.markedRange(), marked)
        controller.editor.unmarkText()
    }

    func testRepeatReadFailureAndSaveKeepPreviewUntilInstalledTargetChanges() async throws {
        var backends: [Backend] = []
        let preview = MediaPreviewController(validate: { _ in }, makeBackend: {
            let backend = Backend()
            backends.append(backend)
            return backend
        })
        let first = note()
        let second = note("two.mov", inode: 2)
        let controller = controller(preview: preview, read: { urls in
            if urls[0].lastPathComponent == "invalid.png" { throw NoteReadError.invalidUTF8 }
            return urls[0] == first.url ? first : second
        })
        defer { preview.close(); controller.window?.orderOut(nil) }
        try await settle { preview.state == .systemPreview }
        controller.receive([first.url])
        try await settle { !controller.session.isLoading }
        controller.receive([URL(fileURLWithPath: "/tmp/invalid.png")])
        try await settle { !controller.session.isLoading }
        XCTAssertEqual(backends.count, 1)
        XCTAssertEqual(preview.target?.identity, first.identity)
        controller.editor.string = "保存不重载预览"
        controller.captureDraft()
        controller.saveNote(nil)
        try await settle { !controller.session.isSaving }
        XCTAssertEqual(backends.count, 1)
        XCTAssertEqual(backends[0].closes, 0)
        controller.receive([second.url])
        try await settle { !controller.session.isLoading && preview.target?.identity == second.identity && preview.state == .systemPreview }
        XCTAssertEqual(backends.count, 2)
        XCTAssertEqual(backends[0].closes, 1)
        XCTAssertFalse(backends[1].autostarts)
        controller.session.close()
        controller.renderInstalledSnapshot()
        XCTAssertEqual(backends[1].closes, 1)
        XCTAssertNil(preview.target)
    }

    func testUnavailablePreviewStillAllowsEditingSavingAndExport() async throws {
        let preview = MediaPreviewController(validate: { _ in throw NoteReadError.targetChanged })
        let snapshot = note()
        let controller = controller(preview: preview, read: { _ in snapshot })
        defer { preview.close(); controller.window?.orderOut(nil) }
        try await settle { preview.state == .unavailable }
        XCTAssertTrue(controller.editor.isEditable)
        XCTAssertNil(controller.session.failure)
        XCTAssertTrue(controller.saveButton.isEnabled)
        XCTAssertTrue(controller.exportButton.isEnabled)
        controller.editor.string = "预览失败仍可保存"
        controller.captureDraft()
        controller.saveNote(nil)
        try await settle { !controller.session.isSaving }
        XCTAssertEqual(controller.session.snapshot?.content.text, "预览失败仍可保存")
        XCTAssertEqual(preview.state, .unavailable)
        XCTAssertNil(controller.session.saveIssue)
    }

    func testCollapsingFocusedPreviewReturnsKeyboardToEditor() async throws {
        let backend = Backend()
        let preview = MediaPreviewController(validate: { _ in }, makeBackend: { backend })
        let snapshot = note()
        let controller = controller(preview: preview, read: { _ in snapshot })
        controller.showEditor()
        defer { preview.close(); controller.window?.orderOut(nil) }
        try await settle { preview.state == .systemPreview }
        XCTAssertTrue(controller.window!.makeFirstResponder(backend.view))
        controller.togglePreview(nil)
        XCTAssertTrue(controller.window?.firstResponder === controller.editor)
    }
}
