import AppKit
import XCTest
@testable import FinderNotes

@MainActor
final class EditorWindowTests: XCTestCase {
    private func note() -> NoteSnapshot {
        NoteSnapshot(url: URL(fileURLWithPath: "/tmp/FN04-window-test.png"),
                     identity: FileIdentity(device: 1, inode: 1),
                     content: .present(Data("第一行\n中文🙂 笔记\n第三行".utf8)))
    }

    private func controller() -> EditorWindowController {
        let snapshot = note()
        let session = EditorSession()
        _ = session.resolve(snapshot, ticket: session.beginLoading())
        return EditorWindowController(session: session, read: { _ in snapshot })
    }

    private func finishRead(_ controller: EditorWindowController) async throws {
        for _ in 0..<200 {
            if !controller.session.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Background load did not finish")
    }

    private func finishSave(_ controller: EditorWindowController) async throws {
        for _ in 0..<200 {
            if !controller.session.isSaving { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Background save did not finish")
    }

    func testPlainEditorAndReadOnlyInformationAndSaveAvailability() {
        let controller = controller()
        XCTAssertFalse(controller.editor.isRichText)
        XCTAssertFalse(controller.editor.importsGraphics)
        XCTAssertTrue(controller.editor.allowsUndo)
        XCTAssertTrue(controller.editor.usesFindBar)
        XCTAssertFalse(controller.fileName.isEditable)
        XCTAssertTrue(controller.fileName.isSelectable)
        XCTAssertFalse(controller.filePath.isEditable)
        XCTAssertTrue(controller.filePath.isSelectable)
        XCTAssertTrue(controller.saveButton.isEnabled)
        XCTAssertTrue(controller.exportButton.isEnabled)
        XCTAssertTrue(controller.window!.styleMask.contains(.resizable))
        XCTAssertNil(controller.window!.appearance, "Follow system appearance")
        let delegate = AppDelegate()
        let save = NSMenuItem(title: "保存", action: #selector(AppDelegate.saveNote(_:)), keyEquivalent: "s")
        XCTAssertFalse(delegate.validateMenuItem(save))
    }

    func testNativeUndoRedoSelectionAndRepeatServicePreserveText() async throws {
        let controller = controller()
        controller.showEditor()
        defer { controller.window?.orderOut(nil) }
        let original = controller.editor.string
        controller.editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        controller.editor.insertText("新增文本", replacementRange: controller.editor.selectedRange())
        controller.captureDraft()
        controller.editor.breakUndoCoalescing()
        XCTAssertTrue(controller.editor.undoManager?.canUndo ?? false)
        controller.editor.setSelectedRange(NSRange(location: 0, length: 3))
        let selected = controller.editor.selectedRange()
        let edited = controller.editor.string
        controller.receive([note().url])
        try await finishRead(controller)
        XCTAssertEqual(controller.editor.string, edited)
        XCTAssertEqual(controller.editor.selectedRange(), selected)
        XCTAssertTrue(controller.editor.undoManager?.canUndo ?? false)
        controller.editor.undoManager?.undo()
        XCTAssertEqual(controller.editor.string, original)
        controller.editor.undoManager?.redo()
        XCTAssertEqual(controller.editor.string, edited)
    }

    func testMarkedTextSurvivesRepeatWithoutResettingEditor() async throws {
        let controller = controller()
        controller.showEditor()
        defer { controller.editor.unmarkText(); controller.window?.orderOut(nil) }
        controller.editor.setSelectedRange(NSRange(location: 0, length: 0))
        controller.editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = controller.editor.markedRange()
        let selected = controller.editor.selectedRange()
        XCTAssertTrue(controller.editor.hasMarkedText())
        controller.receive([note().url])
        try await finishRead(controller)
        XCTAssertTrue(controller.editor.hasMarkedText())
        XCTAssertEqual(controller.editor.markedRange(), marked)
        XCTAssertEqual(controller.editor.selectedRange(), selected)
    }

    func testDiscardDefaultAndCopyKeepDraftForEveryLeaveAction() {
        let controller = controller()
        controller.editor.string = "需要保留的中文草稿🙂"
        controller.captureDraft()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for action: EditorWindowController.LeaveAction in [.switchFile, .closeWindow, .quit] {
            let alert = controller.makeDiscardAlert(for: action)
            XCTAssertEqual(alert.buttons[0].title, "继续编辑")
            XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
            XCTAssertTrue(alert.buttons[2].hasDestructiveAction)
            XCTAssertFalse(controller.applyDecision(.keepEditing, pasteboard: pasteboard))
            XCTAssertFalse(controller.applyDecision(.copy, pasteboard: pasteboard))
            XCTAssertEqual(pasteboard.string(forType: .string), "需要保留的中文草稿🙂")
            XCTAssertEqual(controller.session.draft, "需要保留的中文草稿🙂")
            XCTAssertTrue(controller.applyDecision(.discard, pasteboard: pasteboard))
        }
    }

    func testNoTargetCannotEditAndFailureNeverLooksLikeEmptyNote() {
        let session = EditorSession()
        session.reject("已有正文不是 UTF-8", ticket: session.beginLoading())
        let controller = EditorWindowController(session: session)
        XCTAssertFalse(controller.editor.isEditable)
        XCTAssertFalse(controller.copyButton.isEnabled)
        XCTAssertFalse(controller.exportButton.isEnabled)
        XCTAssertFalse(controller.saveButton.isEnabled)
        XCTAssertTrue(controller.statusLabel.stringValue.contains("读取失败"))
    }

    func testSaveUsesCapturedBytesAndKeepsNewerDraftAndSelection() async throws {
        let snapshot = note()
        let session = EditorSession()
        _ = session.resolve(snapshot, ticket: session.beginLoading())
        let controller = EditorWindowController(session: session,
                                                read: { _ in snapshot },
                                                save: { request in
            Thread.sleep(forTimeInterval: 0.1)
            return NoteSnapshot(url: request.baseline.url,
                                identity: request.baseline.identity,
                                content: request.desiredContent)
        })
        defer { controller.window?.orderOut(nil) }
        controller.editor.string = "第一版🙂\n"
        controller.captureDraft()
        controller.saveNote(nil)
        XCTAssertTrue(controller.session.isSaving)
        XCTAssertFalse(controller.saveButton.isEnabled)
        XCTAssertTrue(controller.exportButton.isEnabled)
        XCTAssertFalse(controller.windowShouldClose(controller.window!))
        let canQuit = await controller.prepareToQuit()
        XCTAssertFalse(canQuit)
        controller.receive([URL(fileURLWithPath: "/tmp/another.mov")])
        XCTAssertEqual(controller.session.snapshot?.url, snapshot.url)
        XCTAssertFalse(controller.session.isLoading)
        controller.editor.string = "第二版🙂\n"
        controller.editor.setSelectedRange(NSRange(location: 2, length: 1))
        controller.captureDraft()
        let selected = controller.editor.selectedRange()
        try await finishSave(controller)
        XCTAssertEqual(controller.session.snapshot?.content, .present(Data("第一版🙂\n".utf8)))
        XCTAssertEqual(controller.editor.string, "第二版🙂\n")
        XCTAssertEqual(controller.editor.selectedRange(), selected)
        XCTAssertTrue(controller.session.isDirty)
        XCTAssertTrue(controller.statusLabel.stringValue.contains("当前草稿尚未保存"))
    }

    func testSaveFailurePreservesDraftAndCopyExportAvailability() async throws {
        let snapshot = note()
        let session = EditorSession()
        _ = session.resolve(snapshot, ticket: session.beginLoading())
        let controller = EditorWindowController(session: session,
                                                save: { _ in throw NoteWriteError.conflict })
        controller.editor.string = "冲突时保留🙂"
        controller.captureDraft()
        controller.saveNote(nil)
        try await finishSave(controller)
        XCTAssertEqual(controller.session.draft, "冲突时保留🙂")
        XCTAssertTrue(controller.session.requiresLeaveConfirmation)
        XCTAssertTrue(controller.statusLabel.stringValue.contains("外部改变"))
        XCTAssertTrue(controller.copyButton.isEnabled)
        XCTAssertTrue(controller.exportButton.isEnabled)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(controller.copyDraft(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "冲突时保留🙂")
    }

    func testMarkedTextRefusesSaveAndExportBeforeWriting() {
        let controller = controller()
        controller.editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0),
                                        replacementRange: NSRange(location: NSNotFound, length: 0))
        defer { controller.editor.unmarkText() }
        controller.saveNote(nil)
        XCTAssertFalse(controller.session.isSaving)
        XCTAssertTrue(controller.statusLabel.stringValue.contains("完成中文输入"))
        controller.exportMarkdown(nil)
        XCTAssertTrue(controller.statusLabel.stringValue.contains("完成中文输入"))
    }

    func testServiceReadsOnlyGivenPasteboardAndPreservesMultipleURLs() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let expected = [URL(fileURLWithPath: "/tmp/one.png"), URL(fileURLWithPath: "/tmp/two.mov")]
        pasteboard.writeObjects(expected as [NSURL])
        XCTAssertEqual(AppDelegate.fileURLs(from: pasteboard), expected)
        pasteboard.clearContents()
        pasteboard.setPropertyList(expected.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        XCTAssertEqual(AppDelegate.fileURLs(from: pasteboard), expected)
        pasteboard.clearContents()
        XCTAssertTrue(AppDelegate.fileURLs(from: pasteboard).isEmpty)
    }

}
