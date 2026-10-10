import AppKit
import Foundation

/// Exercises the production editor delegate and save orchestration in a hidden
/// window. Every xattr write, preference and pasteboard is an isolated fixture.
@MainActor
func verifyEditorIntegration(_ checks: Checks) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderNotes-FN11-Editor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("editor-component.png")
    let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nWQAAAAASUVORK5CYII=")!
    try image.write(to: media)
    let initial = "# 隐藏窗口标题 👩🏽‍🚀\r\n\r\n初始 **粗体** 与 _斜体_。\r\n\r\n末段\n"
    let missing = try NoteReader().read(urls: [media])
    let installed = try NoteWriter().save(.init(baseline: missing, desiredContent: .present(Data(initial.utf8))))
    let session = EditorSession()
    let loading = session.beginLoading()
    try checks.expect(session.resolve(installed, ticket: loading) == .installed, "editor integration installs its temporary xattr snapshot before controller creation")

    let suiteName = "com.findernotes.FN11EditorVerification.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { throw CheckFailure("cannot create editor integration preference suite") }
    defaults.set(true, forKey: MarkdownLayoutController.preferenceKey)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        _ = defaults.synchronize()
        let preferenceFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: preferenceFile)
    }
    let scheduler = FN11ManualAutosaveScheduler()
    let saver = FN11ControlledSaver()
    let preview = MediaPreviewController(validate: { _ in }, makeBackend: { nil })
    let controller = EditorWindowController(session: session, save: { try saver.save($0) }, autosaveScheduler: scheduler, preview: preview, defaults: defaults)
    defer {
        saver.releaseBlockedSave()
        scheduler.cancel()
        preview.close()
        controller.window?.delegate = nil
        controller.window?.close()
    }
    try checks.expect(controller.window?.isVisible == false, "editor integration never orders its component window front")
    try checks.expect(controller.editor.delegate === controller, "production editor owns the NSTextView delegate hooks")
    try checks.expect(Data(controller.editor.string.utf8) == Data(initial.utf8), "installed editor keeps exact CRLF and Unicode Markdown bytes")
    controller.editor.setSelectedRange(NSRange(location: (initial as NSString).length, length: 0))
    try await FN11Verification.waitForPresentation(controller.markdownLayout, source: initial)
    try checks.expect(!controller.markdownLayout.hiddenMarkers.isEmpty, "production editor applies hidden Markdown markers before integration operations")

    let initialRevision = session.draftRevision
    let initialStatus = session.status
    let initialSaveEnabled = controller.saveButton.isEnabled
    controller.toggleMarkdown(nil)
    controller.toggleMarkdown(nil)
    try await FN11Verification.waitForPresentation(controller.markdownLayout, source: initial)
    try checks.expect(session.draftRevision == initialRevision && session.status == initialStatus, "Markdown toggles preserve installed session revision and status")
    try checks.expect(!session.isSaving && !session.isDirty && controller.saveButton.isEnabled == initialSaveEnabled, "Markdown toggles preserve clean state and save availability")
    try checks.expect(saver.requests.isEmpty && !scheduler.hasPendingAction, "presentation toggles schedule no persistence work")

    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    try checks.expect(controller.copyDraft(to: pasteboard), "complete draft copy succeeds through an isolated pasteboard")
    try checks.expect(Data((pasteboard.string(forType: .string) ?? "").utf8) == Data(initial.utf8), "copyDraft returns exact raw Markdown while other paragraphs are rendered")
    let nativeSelection = (initial as NSString).range(of: "**粗体**")
    controller.editor.setSelectedRange(nativeSelection)
    controller.markdownLayout.selectionDidChange()
    try checks.expect(!controller.markdownLayout.hiddenMarkers.isEmpty, "native copy fixture retains rendered markers outside the selected paragraph")
    pasteboard.clearContents()
    // NSTextView advertises NSStringPboardType on this AppKit runtime; the
    // pasteboard bridges it to modern .string when reading the copied payload.
    guard let nativeTextType = controller.editor.writablePasteboardTypes.first(where: {
        $0 == .string || $0.rawValue == "NSStringPboardType"
    }) else { throw CheckFailure("native editor does not advertise a plain-text pasteboard type") }
    pasteboard.declareTypes([nativeTextType], owner: nil)
    try checks.expect(controller.editor.writeSelection(to: pasteboard, type: nativeTextType), "native text selection copies through an isolated pasteboard")
    try checks.expect(pasteboard.string(forType: .string) == "**粗体**", "native plain-text copy retains original selected Markdown delimiters")
    try checks.expect(session.draftRevision == initialRevision && session.status == initialStatus, "both copy paths preserve session revision and status")

    let autoSource = initial + "自动保存 **原始标记** e\u{301} 🚀\r\n"
    insertFN11EditorText(controller, text: String(autoSource.dropFirst(initial.count)))
    try checks.expect(Data(session.draft.utf8) == Data(autoSource.utf8), "native insertion reaches textDidChange and captures raw source")
    try checks.expect(session.draftRevision == initialRevision + 1 && session.isDirty, "textDidChange advances the draft once and marks it dirty")
    try checks.expect(scheduler.hasPendingAction, "production textDidChange schedules autosave")
    try checks.expect(scheduler.fire(), "deterministic scheduler fires the production autosave callback")
    try checks.expect(session.isSaving, "autosave callback starts the actual editor save flow")
    try await waitForFN11EditorState("autosave completion") { !session.isSaving && !session.isDirty }
    try checks.expect(try NoteReader().read(urls: [media]).content == .present(Data(autoSource.utf8)), "editor autosave writes exact raw Markdown bytes to temporary xattr")
    try checks.expect(saver.requests.last == Data(autoSource.utf8), "autosave passes source bytes to the writer")
    try checks.expect(controller.statusLabel.stringValue == session.status && controller.saveButton.isEnabled, "autosave completion refreshes production status and save controls")

    let manualSource = autoSource + "手动保存 [链接](https://example.com)\n"
    insertFN11EditorText(controller, text: String(manualSource.dropFirst(autoSource.count)))
    let manualRevision = session.draftRevision
    controller.saveNote(nil)
    try checks.expect(session.isSaving && !scheduler.hasPendingAction, "manual save starts persistence and cancels the pending autosave timer")
    try await waitForFN11EditorState("manual save completion") { !session.isSaving && !session.isDirty }
    try checks.expect(try NoteReader().read(urls: [media]).content == .present(Data(manualSource.utf8)), "editor manual save persists exact raw Markdown bytes")
    try checks.expect(session.draftRevision == manualRevision && saver.requests.last == Data(manualSource.utf8), "manual save preserves draft revision and sends the current raw payload")

    let olderSource = manualSource + "较早草稿 **A**\n"
    insertFN11EditorText(controller, text: String(olderSource.dropFirst(manualSource.count)))
    saver.blockNextSave()
    try checks.expect(scheduler.fire(), "older draft begins through the production autosave callback")
    try await waitForFN11EditorState("controlled save arrival") { saver.isBlocked }
    try checks.expect(session.isSaving && !controller.saveButton.isEnabled && controller.editor.isEditable, "pending save disables repeat saves while retaining editable draft")
    let pendingRevision = session.draftRevision
    let pendingStatus = session.status
    controller.toggleMarkdown(nil)
    controller.toggleMarkdown(nil)
    try checks.expect(session.isSaving && session.draftRevision == pendingRevision && session.status == pendingStatus, "layout toggles cannot complete or alter an in-flight save")

    let newerSource = olderSource + "保存期间继续输入 _B_ 👨‍👩‍👧‍👦\r\n"
    insertFN11EditorText(controller, text: String(newerSource.dropFirst(olderSource.count)))
    let newerRevision = session.draftRevision
    try checks.expect(session.isSaving && Data(session.draft.utf8) == Data(newerSource.utf8), "edits during a blocked save retain the newer raw draft")
    try checks.expect(newerRevision == pendingRevision + 1 && saver.requests.last == Data(olderSource.utf8), "pending writer remains bound to its older payload after the new revision")
    saver.releaseBlockedSave()
    try await waitForFN11EditorState("older save completion") { !session.isSaving }
    try checks.expect(session.snapshot?.content == .present(Data(olderSource.utf8)), "older save advances only the confirmed storage baseline")
    try checks.expect(Data(session.draft.utf8) == Data(newerSource.utf8) && session.draftRevision == newerRevision && session.isDirty, "older completion cannot replace or mark the newer draft saved")
    try checks.expect(try NoteReader().read(urls: [media]).content == .present(Data(olderSource.utf8)), "controlled older save writes only the captured older source")
    try checks.expect(scheduler.hasPendingAction, "older completion schedules the remaining newer draft for another autosave")
    try checks.expect(scheduler.fire(), "next autosave begins for the newer draft")
    try await waitForFN11EditorState("newer save completion") { !session.isSaving && !session.isDirty }
    try checks.expect(try NoteReader().read(urls: [media]).content == .present(Data(newerSource.utf8)), "next autosave persists the exact newer raw source")
    try checks.expect(session.draftRevision == newerRevision && saver.requests.last == Data(newerSource.utf8), "saving the newer draft preserves its revision and writer payload")
    try checks.expect(try Data(contentsOf: media) == image, "all editor integration saves preserve the temporary media bytes")
    try checks.expect(controller.window?.isVisible == false, "all save, copy and layout integration operations remain in a hidden window")
}

/// Isolate the native textDidChange delegate path from the additional composition
/// callback, proving an ordinary edit updates the production session on its own.
@MainActor
private func insertFN11EditorText(_ controller: EditorWindowController, text: String) {
    let inputStateCallback = controller.editor.inputStateDidChange
    let inputStateWillCallback = controller.editor.inputStateWillChange
    controller.editor.inputStateDidChange = nil
    controller.editor.inputStateWillChange = nil
    defer {
        controller.editor.inputStateDidChange = inputStateCallback
        controller.editor.inputStateWillChange = inputStateWillCallback
    }
    controller.editor.insertText(text, replacementRange: NSRange(location: (controller.editor.string as NSString).length, length: 0))
}

@MainActor
private func waitForFN11EditorState(_ description: String, condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw CheckFailure("editor integration timed out waiting for \(description)")
}

@MainActor
private final class FN11ManualAutosaveScheduler: EditorAutosaveScheduling {
    private var action: (@MainActor () -> Void)?
    var hasPendingAction: Bool { action != nil }
    func schedule(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() { action = nil }
    func fire() -> Bool {
        guard let pending = action else { return false }
        action = nil
        pending()
        return true
    }
}

/// The synchronous writer runs on the editor's real detached save task. A lock
/// protects observations; only its controlled background write waits on a semaphore.
private final class FN11ControlledSaver: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var nextSaveIsBlocked = false
    private var blocked = false
    private var payloads: [Data] = []

    var requests: [Data] { lock.lock(); defer { lock.unlock() }; return payloads }
    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    func blockNextSave() { lock.lock(); nextSaveIsBlocked = true; lock.unlock() }
    func releaseBlockedSave() { release.signal() }

    func save(_ request: NoteSaveRequest) throws -> NoteSnapshot {
        lock.lock()
        let shouldBlock = nextSaveIsBlocked
        nextSaveIsBlocked = false
        blocked = shouldBlock
        if case .present(let bytes) = request.desiredContent { payloads.append(bytes) }
        lock.unlock()
        if shouldBlock {
            guard release.wait(timeout: .now() + 8) == .success else {
                lock.lock(); blocked = false; lock.unlock()
                throw CheckFailure("controlled integration writer was not released")
            }
        }
        defer { lock.lock(); blocked = false; lock.unlock() }
        return try NoteWriter().save(request)
    }
}
