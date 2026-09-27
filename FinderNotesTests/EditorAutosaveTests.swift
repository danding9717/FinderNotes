import AppKit
import XCTest
@testable import FinderNotes

/// No wall-clock timer and no implicit filesystem access in editor tests.
@MainActor
final class TestAutosaveScheduler: EditorAutosaveScheduling {
    private(set) var pending: (@MainActor () -> Void)?

    func schedule(_ action: @escaping @MainActor () -> Void) { pending = action }
    func cancel() { pending = nil }
    func fire() {
        let action = pending
        pending = nil
        action?()
    }
}

private final class AutosaveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [NoteSaveRequest] = []
    private var savedError: NoteWriteError?
    let firstSaveGate: DispatchSemaphore?

    init(error: NoteWriteError? = nil, firstSaveGate: DispatchSemaphore? = nil) {
        savedError = error
        self.firstSaveGate = firstSaveGate
    }

    var requests: [NoteSaveRequest] { lock.withLock { recorded } }
    func setError(_ error: NoteWriteError?) { lock.withLock { savedError = error } }

    func save(_ request: NoteSaveRequest) throws -> NoteSnapshot {
        let (count, error) = lock.withLock {
            recorded.append(request)
            return (recorded.count, savedError)
        }
        if count == 1 { firstSaveGate?.wait() }
        if let error { throw error }
        return NoteSnapshot(url: request.baseline.url, identity: request.baseline.identity,
                            content: request.desiredContent)
    }
}

@MainActor
final class EditorAutosaveTests: XCTestCase {
    private func note(_ name: String = "autosave.png", inode: UInt64 = 1, text: String = "原文") -> NoteSnapshot {
        NoteSnapshot(url: URL(fileURLWithPath: "/tmp/" + name),
                     identity: FileIdentity(device: 1, inode: inode), content: .present(Data(text.utf8)))
    }

    private func controller(_ recorder: AutosaveRecorder, scheduler: TestAutosaveScheduler,
                            snapshot: NoteSnapshot? = nil,
                            read: (@Sendable ([URL]) throws -> NoteSnapshot)? = nil) -> EditorWindowController {
        let snapshot = snapshot ?? note()
        let session = EditorSession()
        _ = session.resolve(snapshot, ticket: session.beginLoading())
        return EditorWindowController(session: session, read: read ?? { _ in snapshot },
                                      save: { try recorder.save($0) }, autosaveScheduler: scheduler)
    }

    private func edit(_ text: String, in controller: EditorWindowController) {
        controller.editor.string = text
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.editor))
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected asynchronous editor condition", file: file, line: line)
    }

    func testRapidEditsSaveOnlyLatestRevisionAndDoNotRepeatUnchangedBody() async throws {
        let recorder = AutosaveRecorder()
        let scheduler = TestAutosaveScheduler()
        let controller = controller(recorder, scheduler: scheduler)
        edit("第一版", in: controller)
        let expired = try XCTUnwrap(scheduler.pending)
        edit("第二版🙂\n", in: controller)
        expired()
        XCTAssertFalse(controller.session.isSaving)
        XCTAssertTrue(recorder.requests.isEmpty)
        scheduler.fire()
        try await eventually { !controller.session.isSaving }
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.desiredContent.text, "第二版🙂\n")
        XCTAssertEqual(controller.session.status, "笔记已保存")
        XCTAssertNil(scheduler.pending)
        edit("第二版🙂\n", in: controller)
        scheduler.fire()
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testUndoToBaselineCancelsPendingWriteAndMissingEmptyDoesNotAutosave() throws {
        let recorder = AutosaveRecorder()
        let scheduler = TestAutosaveScheduler()
        let controller = controller(recorder, scheduler: scheduler)
        edit("新草稿", in: controller)
        let expired = try XCTUnwrap(scheduler.pending)
        edit("原文", in: controller)
        XCTAssertNil(scheduler.pending)
        expired()
        XCTAssertTrue(recorder.requests.isEmpty)

        let missing = NoteSnapshot(url: note().url, identity: note().identity, content: .missing)
        let emptyController = self.controller(recorder, scheduler: scheduler, snapshot: missing)
        edit("", in: emptyController)
        XCTAssertNil(scheduler.pending)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testEditDuringSaveWaitsForVerifiedBaselineThenSavesNewerDraft() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let recorder = AutosaveRecorder(firstSaveGate: gate)
        let scheduler = TestAutosaveScheduler()
        let controller = controller(recorder, scheduler: scheduler)
        edit("先保存", in: controller)
        scheduler.fire()
        try await eventually { recorder.requests.count == 1 }
        edit("更新草稿", in: controller)
        XCTAssertNil(scheduler.pending)
        XCTAssertTrue(controller.session.isSaving)
        XCTAssertEqual(controller.session.snapshot?.content.text, "原文")
        gate.signal()
        try await eventually { !controller.session.isSaving }
        XCTAssertEqual(controller.session.snapshot?.content.text, "先保存")
        XCTAssertEqual(controller.editor.string, "更新草稿")
        XCTAssertNotNil(scheduler.pending)
        scheduler.fire()
        try await eventually { !controller.session.isSaving }
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(recorder.requests.last?.baseline.content.text, "先保存")
        XCTAssertEqual(controller.session.snapshot?.content.text, "更新草稿")
        XCTAssertFalse(controller.session.isDirty)
    }

    func testEverySaveFailurePausesUntilSuccessfulManualRetry() async throws {
        for error in [NoteWriteError.conflict, .identityChanged,
                      .writeFailed(operation: "测试", code: EACCES), .resultUnconfirmed] {
            let recorder = AutosaveRecorder(error: error)
            let scheduler = TestAutosaveScheduler()
            let controller = controller(recorder, scheduler: scheduler)
            edit("失败时草稿", in: controller)
            scheduler.fire()
            try await eventually { !controller.session.isSaving }
            XCTAssertNotNil(controller.session.saveIssue)
            XCTAssertTrue(controller.statusLabel.stringValue.contains("自动保存已暂停"))
            edit("失败后继续编辑", in: controller)
            XCTAssertNil(scheduler.pending)
            XCTAssertEqual(recorder.requests.count, 1)
            XCTAssertTrue(controller.copyButton.isEnabled)
            XCTAssertTrue(controller.exportButton.isEnabled)
            recorder.setError(nil)
            controller.saveNote(nil)
            try await eventually { !controller.session.isSaving }
            XCTAssertNil(controller.session.saveIssue)
            XCTAssertEqual(controller.session.snapshot?.content.text, "失败后继续编辑")
            edit("恢复后下一版", in: controller)
            XCTAssertNotNil(scheduler.pending)
        }
    }

    func testMismatchedSaveResultNeverReportsSavedOrRetries() async throws {
        let scheduler = TestAutosaveScheduler()
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        let controller = EditorWindowController(session: session, save: { request in
            NoteSnapshot(url: request.baseline.url, identity: FileIdentity(device: 99, inode: 99),
                         content: request.desiredContent)
        }, autosaveScheduler: scheduler)
        edit("草稿", in: controller)
        scheduler.fire()
        try await eventually { !controller.session.isSaving }
        XCTAssertEqual(controller.session.snapshot?.content.text, "原文")
        XCTAssertEqual(controller.session.draft, "草稿")
        XCTAssertNotNil(controller.session.saveIssue)
        XCTAssertNil(scheduler.pending)
    }

    func testCompositionCancelsCountdownAndUnmarkSchedulesEvenWithoutByteChange() async throws {
        let recorder = AutosaveRecorder()
        let scheduler = TestAutosaveScheduler()
        let controller = controller(recorder, scheduler: scheduler)
        edit("草稿", in: controller)
        let expired = try XCTUnwrap(scheduler.pending)
        controller.editor.setSelectedRange(NSRange(location: 0, length: 0))
        controller.editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0),
                                        replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(controller.editor.hasMarkedText())
        XCTAssertNil(scheduler.pending)
        expired()
        XCTAssertTrue(recorder.requests.isEmpty)
        let bytes = Data(controller.editor.string.utf8)
        controller.editor.unmarkText()
        XCTAssertFalse(controller.editor.hasMarkedText())
        XCTAssertEqual(Data(controller.editor.string.utf8), bytes)
        XCTAssertNotNil(scheduler.pending)
        scheduler.fire()
        try await eventually { !controller.session.isSaving }
        XCTAssertEqual(recorder.requests.first?.desiredContent, .present(bytes))
    }

    func testAutosavePreservesNativeSelectionScrollUndoAndRedo() async throws {
        let recorder = AutosaveRecorder()
        let scheduler = TestAutosaveScheduler()
        let original = (0..<100).map { "第\($0)行 中文🙂" }.joined(separator: "\n")
        let controller = controller(recorder, scheduler: scheduler, snapshot: note(text: original))
        controller.showEditor()
        defer { controller.window?.orderOut(nil) }
        controller.editor.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        controller.editor.insertText("新增", replacementRange: controller.editor.selectedRange())
        controller.editor.breakUndoCoalescing()
        controller.editor.setSelectedRange(NSRange(location: 10, length: 4))
        controller.editor.scrollRangeToVisible(NSRange(location: 200, length: 0))
        let selected = controller.editor.selectedRanges
        let scroll = controller.editor.enclosingScrollView?.contentView.bounds.origin
        let edited = controller.editor.string
        scheduler.fire()
        try await eventually { !controller.session.isSaving }
        XCTAssertEqual(controller.editor.string, edited)
        XCTAssertEqual(controller.editor.selectedRanges, selected)
        XCTAssertEqual(controller.editor.enclosingScrollView?.contentView.bounds.origin, scroll)
        XCTAssertTrue(controller.editor.undoManager?.canUndo ?? false)
        controller.editor.undoManager?.undo()
        XCTAssertEqual(controller.editor.string, original)
        controller.editor.undoManager?.redo()
        XCTAssertEqual(controller.editor.string, edited)
    }

    func testQuitConfirmationCancelsCountdownAndReturnToEditingRestartsIt() async throws {
        let recorder = AutosaveRecorder()
        let scheduler = TestAutosaveScheduler()
        let controller = controller(recorder, scheduler: scheduler)
        controller.showEditor()
        defer { controller.window?.orderOut(nil) }
        edit("要保留的草稿", in: controller)
        let expired = try XCTUnwrap(scheduler.pending)
        let quit = Task { await controller.prepareToQuit() }
        try await eventually { controller.isConfirming }
        XCTAssertNil(scheduler.pending)
        expired()
        XCTAssertTrue(recorder.requests.isEmpty)
        let sheet = try XCTUnwrap(controller.window?.attachedSheet)
        controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        let canQuit = await quit.value
        XCTAssertFalse(canQuit)
        XCTAssertNotNil(scheduler.pending)
        scheduler.fire()
        try await eventually { !controller.session.isSaving }
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testDiscardSwitchInvalidatesOldCountdownAndSavesOnlyNewIdentity() async throws {
        let recorder = AutosaveRecorder()
        let scheduler = TestAutosaveScheduler()
        let next = note("copy.png", inode: 2, text: "副本原文")
        let controller = controller(recorder, scheduler: scheduler, read: { _ in next })
        controller.showEditor()
        defer { controller.window?.orderOut(nil) }
        edit("丢弃的旧草稿", in: controller)
        let expired = try XCTUnwrap(scheduler.pending)
        controller.receive([next.url])
        try await eventually { controller.isConfirming }
        expired()
        XCTAssertTrue(recorder.requests.isEmpty)
        let sheet = try XCTUnwrap(controller.window?.attachedSheet)
        controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        try await eventually { controller.session.snapshot?.identity == next.identity }
        XCTAssertNil(scheduler.pending)
        expired()
        edit("副本新正文", in: controller)
        scheduler.fire()
        try await eventually { !controller.session.isSaving }
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.baseline.identity, next.identity)
        XCTAssertEqual(controller.session.draft, "副本新正文")
    }

    func testRepeatServiceRestartsCountdownWithoutLosingDraft() async throws {
        let recorder = AutosaveRecorder()
        let scheduler = TestAutosaveScheduler()
        let controller = controller(recorder, scheduler: scheduler)
        defer { controller.window?.orderOut(nil) }
        edit("未保存的新草稿", in: controller)
        let expired = try XCTUnwrap(scheduler.pending)
        controller.receive([note().url])
        XCTAssertNil(scheduler.pending)
        try await eventually { !controller.session.isLoading }
        expired()
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(controller.session.draft, "未保存的新草稿")
        XCTAssertNotNil(scheduler.pending)
        scheduler.fire()
        try await eventually { !controller.session.isSaving }
        XCTAssertEqual(recorder.requests.count, 1)
    }
}
