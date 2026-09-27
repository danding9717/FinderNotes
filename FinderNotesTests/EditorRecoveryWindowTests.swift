import AppKit
import XCTest
@testable import FinderNotes

private final class RecoverySaveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NoteSaveRequest] = []
    private let firstSaveGate: DispatchSemaphore?

    init(firstSaveGate: DispatchSemaphore? = nil) { self.firstSaveGate = firstSaveGate }
    var requests: [NoteSaveRequest] { lock.withLock { values } }

    func save(_ request: NoteSaveRequest) -> NoteSnapshot {
        let count = lock.withLock { values.append(request); return values.count }
        if count == 1 { firstSaveGate?.wait() }
        return NoteSnapshot(url: request.baseline.url, identity: request.baseline.identity,
                            content: request.desiredContent)
    }
}

private final class RecoveryPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    let gate = DispatchSemaphore(value: 0)
    var isEntered: Bool { lock.withLock { entered } }

    func beforePublish() {
        let shouldWait = lock.withLock {
            guard !entered else { return false }
            entered = true
            return true
        }
        if shouldWait { gate.wait() }
    }
}

/// Controller scheduling and native sheets against a real, isolated recovery directory.
/// Save/read callbacks are deterministic; these tests do not claim Finder or real IME coverage.
@MainActor
final class EditorRecoveryWindowTests: XCTestCase {
    private struct Fixture {
        let root: URL
        var directory: URL { root.appendingPathComponent("recovery", isDirectory: true) }
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("findernotes-fn07-window-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func note(inode: UInt64 = 10, text: String = "打开时正文") -> NoteSnapshot {
        NoteSnapshot(url: URL(fileURLWithPath: "/private/tmp/fn07-synthetic.png"),
                     identity: FileIdentity(device: 1, inode: inode, birthSeconds: 100,
                                            birthNanoseconds: 200),
                     content: .present(Data(text.utf8)))
    }

    private func controller(store: DraftRecoveryStore, recorder: RecoverySaveRecorder,
                            scheduler: TestAutosaveScheduler,
                            read: (@Sendable ([URL]) throws -> NoteSnapshot)? = nil,
                            export: @escaping @Sendable (MarkdownExportRequest) throws -> Void = { _ in },
                            protectedExportDestination: (@MainActor (URL, String, String) async -> URL?)? = nil) -> EditorWindowController {
        _ = NSApplication.shared
        let baseline = note()
        let session = EditorSession()
        _ = session.resolve(baseline, ticket: session.beginLoading())
        let preview = MediaPreviewController(validate: { _ in throw NoteReadError.unsupportedType })
        return EditorWindowController(session: session, read: read ?? { _ in baseline },
                                      save: { recorder.save($0) }, export: export,
                                      autosaveScheduler: scheduler, preview: preview, recoveryStore: store,
                                      protectedExportDestination: protectedExportDestination)
    }

    private func edit(_ text: String, _ controller: EditorWindowController) {
        controller.editor.string = text
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: controller.editor))
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath,
                            line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Controller condition did not settle", file: file, line: line)
    }

    private func persist(_ controller: EditorWindowController, file: StaticString = #filePath,
                         line: UInt = #line) async {
        let result = await controller.queueCurrentRecovery()?.value
        XCTAssertEqual(result, true, file: file, line: line)
    }

    func testEditingDuringSavePersistsNewDraftAgainstConfirmedNewBaseline() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let recorder = RecoverySaveRecorder(firstSaveGate: gate)
        let scheduler = TestAutosaveScheduler()
        let controller = controller(store: store, recorder: recorder, scheduler: scheduler)
        edit("先保存的正文", controller)
        await persist(controller)
        let identifier = controller.session.recoveryIdentifier
        controller.saveNote(nil)
        try await eventually { recorder.requests.count == 1 }
        edit("保存途中继续输入🙂\n", controller)
        await persist(controller)
        let before = try await store.records()
        XCTAssertEqual(before.first?.snapshot.content, note().content)
        gate.signal()
        try await eventually { !controller.session.isSaving }
        await persist(controller)
        let records = try await store.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, identifier)
        XCTAssertEqual(records.first?.draft, "保存途中继续输入🙂\n")
        XCTAssertEqual(records.first?.snapshot.content, .present(Data("先保存的正文".utf8)))
        XCTAssertEqual(controller.editor.string, "保存途中继续输入🙂\n")
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertNotNil(scheduler.pending)
    }

    func testExplicitDiscardWaitsForQueuedPutAndCannotResurrectItsRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let publication = RecoveryPublicationGate()
        defer { publication.gate.signal() }
        let store = DraftRecoveryStore(directory: fixture.directory,
                                       beforePublish: { publication.beforePublish() })
        let controller = controller(store: store, recorder: RecoverySaveRecorder(),
                                    scheduler: TestAutosaveScheduler())
        edit("明确放弃的草稿", controller)
        let writing = try XCTUnwrap(controller.queueCurrentRecovery())
        try await eventually { publication.isEntered }
        let discarding = Task { await controller.discardRecovery() }
        publication.gate.signal()
        let writeSucceeded = await writing.value
        let discarded = await discarding.value
        XCTAssertTrue(writeSucceeded)
        XCTAssertTrue(discarded)
        let records = try await store.records()
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(controller.session.draft, "明确放弃的草稿",
                       "Disk cleanup alone must not reset the native editor")
    }

    func testMarkedTextNeverReplacesLastCompletedPersistedDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let scheduler = TestAutosaveScheduler()
        let controller = controller(store: store, recorder: RecoverySaveRecorder(), scheduler: scheduler)
        edit("上次已落盘的完整输入", controller)
        await persist(controller)
        let previous = try await store.records()
        controller.editor.setSelectedRange(NSRange(location: (controller.editor.string as NSString).length,
                                                    length: 0))
        controller.editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0),
                                        replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(controller.editor.hasMarkedText())
        XCTAssertNil(controller.queueCurrentRecovery())
        XCTAssertNil(scheduler.pending)
        let current = try await store.records()
        XCTAssertEqual(current, previous)
        XCTAssertTrue(controller.session.draft.contains("zhongwen"))
    }

    func testRestoredDraftCanPersistFurtherEditsWithoutSchedulingAutosave() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let scheduler = TestAutosaveScheduler()
        let recorder = RecoverySaveRecorder()
        let controller = controller(store: store, recorder: recorder, scheduler: scheduler)
        let record = DraftRecoveryRecord(id: UUID(), baseline: note(), draft: "已落盘恢复稿", revision: 3)
        try await store.put(record)
        XCTAssertTrue(controller.session.restoreRecovery(record: record, current: note()))
        controller.renderInstalledSnapshot()
        edit("恢复后继续输入", controller)
        await persist(controller)
        XCTAssertNil(scheduler.pending)
        scheduler.fire()
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertTrue(controller.saveButton.isEnabled)
        let records = try await store.records()
        XCTAssertEqual(records.first?.id, record.id)
        XCTAssertEqual(records.first?.draft, "恢复后继续输入")
        XCTAssertEqual(records.first?.snapshot.content, record.snapshot.content)
    }

    func testExternalCheckRejectsReplacementBeforeOfferingOverwrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let recorder = RecoverySaveRecorder()
        let replacement = note(inode: 999, text: "同名新文件正文")
        let controller = controller(store: store, recorder: recorder, scheduler: TestAutosaveScheduler(),
                                    read: { _ in replacement })
        edit("旧文件草稿", controller)
        await persist(controller)
        controller.resolveConflict(nil)
        try await eventually { !controller.isConfirming }
        XCTAssertTrue(controller.session.recoveryWriteBlocked)
        XCTAssertFalse(controller.saveButton.isEnabled)
        XCTAssertTrue(controller.copyButton.isEnabled)
        XCTAssertTrue(controller.exportButton.isEnabled)
        XCTAssertNil(controller.window?.attachedSheet)
        controller.saveNote(nil)
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(controller.session.snapshot?.identity, note().identity)
        XCTAssertEqual(controller.editor.string, "旧文件草稿")
        await persist(controller)
        let records = try await store.records()
        XCTAssertEqual(records.first?.snapshot.identity, note().identity)
        XCTAssertEqual(records.first?.draft, "旧文件草稿")
    }

    func testCancellingProtectedExportKeepsDraftBaselineAndRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let external = note(text: "外部版本")
        let recorder = RecoverySaveRecorder()
        let controller = controller(store: store, recorder: recorder, scheduler: TestAutosaveScheduler(),
                                    read: { _ in external })
        controller.showEditor()
        defer { controller.window?.orderOut(nil) }
        edit("导出取消时的本地草稿", controller)
        await persist(controller)
        let previous = try await store.records()
        controller.resolveConflict(nil)
        try await eventually { controller.window?.attachedSheet != nil }
        let alert = try XCTUnwrap(controller.window?.attachedSheet)
        controller.window?.endSheet(alert, returnCode: .alertSecondButtonReturn)
        try await eventually { controller.window?.attachedSheet is NSSavePanel }
        let panel = try XCTUnwrap(controller.window?.attachedSheet as? NSSavePanel)
        panel.cancel(nil)
        try await eventually { !controller.isConfirming }
        XCTAssertEqual(controller.editor.string, "导出取消时的本地草稿")
        XCTAssertEqual(controller.session.snapshot?.content, note().content)
        XCTAssertTrue(recorder.requests.isEmpty)
        let current = try await store.records()
        XCTAssertEqual(current, previous)
    }

    func testFailedProtectedExportKeepsDraftBaselineAndRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let external = note(text: "外部版本")
        let recorder = RecoverySaveRecorder()
        let destination = fixture.root.appendingPathComponent("failed-export.md")
        let controller = controller(store: store, recorder: recorder, scheduler: TestAutosaveScheduler(),
                                    read: { _ in external },
                                    export: { _ in throw MarkdownExportError.system(operation: "合成导出失败", code: EIO) },
                                    protectedExportDestination: { _, _, _ in destination })
        controller.showEditor()
        defer { controller.window?.orderOut(nil) }
        edit("导出失败时的本地草稿", controller)
        await persist(controller)
        let previous = try await store.records()
        controller.resolveConflict(nil)
        try await eventually { controller.window?.attachedSheet != nil }
        let choice = try XCTUnwrap(controller.window?.attachedSheet)
        controller.window?.endSheet(choice, returnCode: .alertSecondButtonReturn)
        try await eventually {
            guard let sheet = controller.window?.attachedSheet else { return false }
            return sheet !== choice && !(sheet is NSSavePanel)
        }
        let failure = try XCTUnwrap(controller.window?.attachedSheet)
        controller.window?.endSheet(failure, returnCode: .alertFirstButtonReturn)
        try await eventually { !controller.isConfirming }
        XCTAssertEqual(controller.editor.string, "导出失败时的本地草稿")
        XCTAssertEqual(controller.session.snapshot?.content, note().content)
        XCTAssertTrue(recorder.requests.isEmpty)
        let current = try await store.records()
        XCTAssertEqual(current, previous)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancellingRecoveryChooserDoesNotDiscardActiveRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let controller = controller(store: store, recorder: RecoverySaveRecorder(),
                                    scheduler: TestAutosaveScheduler())
        controller.showEditor()
        defer { controller.window?.orderOut(nil) }
        edit("当前正在编辑的草稿🙂\n", controller)
        await persist(controller)
        let activeIdentifier = controller.session.recoveryIdentifier
        let activeURL = fixture.directory.appendingPathComponent(activeIdentifier.uuidString + ".json")
        let activeBytes = try Data(contentsOf: activeURL)
        let previousBaseline = controller.session.snapshot?.content
        let older = DraftRecoveryRecord(id: UUID(), baseline: note(inode: 11),
                                         draft: "另一个未保存草稿", revision: 5)
        try await store.put(older)
        controller.showRecovery(nil)
        try await eventually { controller.window?.attachedSheet != nil }
        let chooser = try XCTUnwrap(controller.window?.attachedSheet)
        controller.window?.endSheet(chooser, returnCode: .alertFirstButtonReturn)
        try await eventually { !controller.isConfirming }
        XCTAssertEqual(controller.session.recoveryIdentifier, activeIdentifier)
        XCTAssertEqual(controller.editor.string, "当前正在编辑的草稿🙂\n")
        XCTAssertEqual(controller.session.snapshot?.content, previousBaseline)
        XCTAssertEqual(try Data(contentsOf: activeURL), activeBytes)
        let records = try await store.records()
        XCTAssertEqual(Set(records.map(\.id)), Set([activeIdentifier, older.id]))
    }

    func testUndoToBaselineThenSwitchCleansThePreviousRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let next = note(inode: 12, text: "下一个文件正文")
        let controller = controller(store: store, recorder: RecoverySaveRecorder(),
                                    scheduler: TestAutosaveScheduler(), read: { _ in next })
        defer { controller.window?.orderOut(nil) }
        edit("曾经修改的草稿", controller)
        await persist(controller)
        let previousIdentifier = controller.session.recoveryIdentifier
        edit(note().content.text, controller)
        await persist(controller)
        XCTAssertFalse(controller.session.requiresLeaveConfirmation)
        let before = try await store.records()
        XCTAssertEqual(before.first?.id, previousIdentifier)
        XCTAssertEqual(before.first?.draft, note().content.text)
        controller.receive([next.url])
        try await eventually { !controller.session.isLoading && controller.session.snapshot?.identity == next.identity }
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertEqual(controller.editor.string, next.content.text)
        XCTAssertNotEqual(controller.session.recoveryIdentifier, previousIdentifier)
        let records = try await store.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testLoadingExternalVersionFirstExportsExactLocalDraftThenCleansRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let external = note(text: "外部版本🙂\n")
        let local = "  本地草稿e\u{301}\n"
        let destination = fixture.root.appendingPathComponent("preserved-local.md")
        let recorder = RecoverySaveRecorder()
        let controller = controller(store: store, recorder: recorder, scheduler: TestAutosaveScheduler(),
                                    read: { _ in external }, export: { try MarkdownExporter().export($0) },
                                    protectedExportDestination: { _, _, _ in destination })
        controller.showEditor()
        defer { controller.window?.orderOut(nil) }
        edit(local, controller)
        await persist(controller)
        let oldIdentifier = controller.session.recoveryIdentifier
        controller.resolveConflict(nil)
        try await eventually { controller.window?.attachedSheet != nil }
        let choice = try XCTUnwrap(controller.window?.attachedSheet)
        controller.window?.endSheet(choice, returnCode: .alertSecondButtonReturn)
        try await eventually {
            !controller.isConfirming && controller.session.snapshot?.content == external.content
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data(local.utf8))
        XCTAssertEqual(controller.editor.string, external.content.text)
        XCTAssertEqual(controller.session.snapshot?.content, external.content)
        XCTAssertFalse(controller.session.requiresLeaveConfirmation)
        XCTAssertNotEqual(controller.session.recoveryIdentifier, oldIdentifier)
        XCTAssertTrue(recorder.requests.isEmpty)
        let records = try await store.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testExplicitOverwriteBacksUpExternalAndUsesItsConfirmedBaseline() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = DraftRecoveryStore(directory: fixture.directory)
        let external = note(text: "  外部版本e\u{301}\n")
        let local = "本地决定保留的正文🙂\n"
        let destination = fixture.root.appendingPathComponent("preserved-external.md")
        let recorder = RecoverySaveRecorder()
        let controller = controller(store: store, recorder: recorder, scheduler: TestAutosaveScheduler(),
                                    read: { _ in external }, export: { try MarkdownExporter().export($0) },
                                    protectedExportDestination: { _, _, _ in destination })
        controller.showEditor()
        defer { controller.window?.orderOut(nil) }
        edit(local, controller)
        await persist(controller)
        controller.resolveConflict(nil)
        try await eventually { controller.window?.attachedSheet != nil }
        let choice = try XCTUnwrap(controller.window?.attachedSheet)
        controller.window?.endSheet(choice, returnCode: .alertThirdButtonReturn)
        try await eventually {
            guard let sheet = controller.window?.attachedSheet else { return false }
            return sheet !== choice
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data(external.content.text.utf8))
        XCTAssertTrue(recorder.requests.isEmpty, "Backup alone must not authorize overwrite")
        let confirmation = try XCTUnwrap(controller.window?.attachedSheet)
        controller.window?.endSheet(confirmation, returnCode: .alertSecondButtonReturn)
        try await eventually {
            recorder.requests.count == 1 && !controller.session.isSaving && !controller.isConfirming
        }
        XCTAssertEqual(recorder.requests.first?.baseline.identity, external.identity)
        XCTAssertEqual(recorder.requests.first?.baseline.content, external.content)
        XCTAssertEqual(recorder.requests.first?.desiredContent, .present(Data(local.utf8)))
        XCTAssertEqual(controller.editor.string, local)
        XCTAssertEqual(controller.session.snapshot?.content, .present(Data(local.utf8)))
        XCTAssertFalse(controller.session.requiresLeaveConfirmation)
        // The verified save queues its cleanup asynchronously; wait only for that operation.
        var records = try await store.records()
        for _ in 0..<500 where !records.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            records = try await store.records()
        }
        XCTAssertTrue(records.isEmpty)
    }

    func testCleanAndBlankWindowsCanQuitWithoutAcquiringAnotherStoresLock() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let owner = DraftRecoveryStore(directory: fixture.directory)
        let initial = try await owner.records()
        XCTAssertTrue(initial.isEmpty)
        for blank in [false, true] {
            let blockedStore = DraftRecoveryStore(directory: fixture.directory)
            let controller = controller(store: blockedStore, recorder: RecoverySaveRecorder(),
                                        scheduler: TestAutosaveScheduler())
            if blank {
                controller.session.close()
                controller.renderInstalledSnapshot()
            }
            XCTAssertNil(controller.session.recoveryRecord)
            let canQuit = await controller.prepareToQuit()
            XCTAssertTrue(canQuit)
            XCTAssertNil(controller.session.recoveryIssue)
            XCTAssertNil(controller.window?.attachedSheet)
        }
        let remaining = try await owner.records()
        XCTAssertTrue(remaining.isEmpty)
    }
}
