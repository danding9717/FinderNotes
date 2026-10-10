import AppKit
import Foundation

/// Native AppKit Return dispatch and existing session/save orchestration only.
/// Marked-text checks are simulated; no real input method or general pasteboard is used.
@MainActor
func verifyListContinuationIntegration(_ checks: Checks) async throws {
    _ = NSApplication.shared
    try await verifyListReturnCases(checks)
    try await verifyMarkedListReturn(checks)
    try await verifyListEditorAutosave(checks)
}

private final class ListCharacterEdits: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record(_ mask: NSTextStorageEditActions) {
        guard mask.contains(.editedCharacters) else { return }
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
    func take() -> Int {
        lock.lock(); defer { lock.unlock() }
        let result = count
        count = 0
        return result
    }
}

@MainActor
private final class ListReturnFixture {
    let view = CompositionTextView()
    let controller: MarkdownLayoutController
    let edits = ListCharacterEdits()
    private let suite = "com.findernotes.FN11Verification.List.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let window: NSWindow
    private var observer: NSObjectProtocol?

    init(source: String, selection: NSRange, enabled: Bool = true) throws {
        guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure("list Return preferences unavailable") }
        self.defaults = defaults
        defaults.set(enabled, forKey: MarkdownLayoutController.preferenceKey)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        view.isRichText = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        scroll.documentView = view
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(view)
        controller = MarkdownLayoutController(textView: view, defaults: defaults)
        let controller = controller
        view.inputStateWillChange = { [weak controller] in controller?.inputStateWillChange() }
        view.inputStateDidChange = { [weak controller] in controller?.inputStateDidChange() }
        view.continuesMarkdownLists = { [weak controller] in controller?.isEnabled == true }
        let edits = edits
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                           object: view.textStorage, queue: nil) { notification in
            if let storage = notification.object as? NSTextStorage { edits.record(storage.editedMask) }
        }
        view.string = source
        view.setSelectedRange(selection)
        controller.installDocument()
    }

    func ready() async throws {
        if controller.isEnabled { try await FN11Verification.waitForPresentation(controller, source: view.string) }
        view.undoManager?.removeAllActions()
        view.undoManager?.groupsByEvent = false
        _ = edits.take()
    }

    func pressReturn() {
        view.undoManager?.beginUndoGrouping()
        view.doCommand(by: #selector(NSTextView.insertNewline(_:)))
        view.undoManager?.endUndoGrouping()
        controller.documentDidChange()
    }

    func close() {
        while (view.undoManager?.groupingLevel ?? 0) > 0 { view.undoManager?.endUndoGrouping() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        view.inputStateWillChange = nil
        view.inputStateDidChange = nil
        view.continuesMarkdownLists = nil
        controller.setEnabled(false)
        defaults.removePersistentDomain(forName: suite)
        _ = defaults.synchronize()
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist"))
        window.close()
    }
}

@MainActor
private struct ListRemotePresentation {
    let needle: String
    let content: NSAttributedString
    let masks: [NSRange]
    let decorations: [String]
    init(_ fixture: ListReturnFixture, needle: String) throws {
        self.needle = needle
        let range = (fixture.view.string as NSString).range(of: needle)
        guard range.location != NSNotFound, let storage = fixture.view.textStorage,
              let manager = fixture.view.layoutManager as? MarkdownLayoutManager else { throw CheckFailure("list remote fixture unavailable") }
        content = NSAttributedString(attributedString: storage.attributedSubstring(from: range))
        masks = fixture.controller.hiddenMarkers.compactMap {
            let overlap = NSIntersectionRange($0, range)
            return overlap.length > 0 ? NSRange(location: overlap.location - range.location, length: overlap.length) : nil
        }
        decorations = manager.decorations.compactMap {
            let overlap = NSIntersectionRange($0.range, range)
            guard overlap.length > 0 else { return nil }
            let kind: String
            switch $0.kind {
            case .list(let label): kind = "list:\(label)"
            case .quote: kind = "quote"
            case .rule: kind = "rule"
            case .task(let checked, let state): kind = "task:\(checked):\(state.location - range.location):\(state.length)"
            }
            return "\(overlap.location - range.location):\(overlap.length):\(kind)"
        }
    }
    func verify(_ fixture: ListReturnFixture, checks: Checks, label: String) throws {
        let value = try ListRemotePresentation(fixture, needle: needle)
        try checks.expect(content.isEqual(to: value.content), "\(label) keeps distant paragraph typography")
        try checks.expect(masks == value.masks, "\(label) keeps distant paragraph syntax hidden")
        try checks.expect(decorations == value.decorations, "\(label) keeps distant paragraph decorations")
    }
}

@MainActor
private func verifyListReturnCases(_ checks: Checks) async throws {
    let prefix = "# 固定标题 **粗体**\n\n> 固定引用\n\n- 固定列表\n\n"
    let suffix = "\n\n后段 **固定**\n"
    struct Case {
        let name: String
        let fragment: String
        let selection: NSRange
        let result: String
        let caretPrefix: String
        let enabled: Bool
        init(_ name: String, _ fragment: String, _ result: String, caretPrefix: String? = nil,
             selection: NSRange? = nil, enabled: Bool = true) {
            self.name = name
            self.fragment = fragment
            self.selection = selection ?? NSRange(location: (fragment as NSString).length, length: 0)
            self.result = result
            self.caretPrefix = caretPrefix ?? result
            self.enabled = enabled
        }
    }
    let cases = [
        Case("standard ordered", "1. text", "1. text\n2. "),
        Case("compact user example", "1.this is a test.", "1.this is a test.\n2. "),
        Case("parenthesis width change", "9) text", "9) text\n10) "),
        Case("two-digit period", "10. text", "10. text\n11. "),
        Case("unordered hyphen", "- text", "- text\n- "),
        Case("unordered plus", "+ text", "+ text\n+ "),
        Case("unordered star", "* text", "* text\n* "),
        Case("preserved indentation", "  3. text", "  3. text\n  4. "),
        Case("preserved separator", "1.  \ttext", "1.  \ttext\n2.  \t"),
        Case("split middle", "1. alpha beta", "1. alpha\n2.  beta", caretPrefix: "1. alpha\n2. ", selection: NSRange(location: 8, length: 0)),
        Case("selected item text", "1. abcd", "1. a\n2. d", caretPrefix: "1. a\n2. ", selection: NSRange(location: 4, length: 2)),
        Case("empty ordered exits", "1. ", ""),
        Case("empty indented item exits", "  - \t", "  "),
        Case("empty item marker interior native Return", "12.  ", "1\n2.  ", caretPrefix: "1\n", selection: NSRange(location: 1, length: 0)),
        Case("Markdown off native Return", "1. text", "1. text\n", enabled: false),
        Case("closed fence native Return", "```text\n1. text\n```", "```text\n1. text\n\n```", caretPrefix: "```text\n1. text\n", selection: NSRange(location: 15, length: 0)),
        Case("unclosed fence native Return", "```text\n1. text", "```text\n1. text\n"),
        Case("unordered list-body fence native Return", "- ```swift\n  1. text\n  ```", "- ```swift\n  1. text\n\n  ```", caretPrefix: "- ```swift\n  1. text\n", selection: NSRange(location: ("- ```swift\n  1. text" as NSString).length, length: 0)),
        Case("ordered list-body tilde fence native Return", "1. ~~~text\n   - code\n   ~~~", "1. ~~~text\n   - code\n\n   ~~~", caretPrefix: "1. ~~~text\n   - code\n", selection: NSRange(location: ("1. ~~~text\n   - code" as NSString).length, length: 0)),
        Case("selected marker native Return", "1. text", "\ntext", caretPrefix: "\n", selection: NSRange(location: 0, length: 3)),
        Case("cross-paragraph selection native Return", "1. first\n2. second", "1. \ncond", caretPrefix: "1. \n", selection: NSRange(location: 3, length: 11)),
        Case("unchecked task Return", "- [ ] task", "- [ ] task\n- [ ] "),
        Case("checked task Return resets state", "- [x] task", "- [x] task\n- [ ] "),
        Case("ordered task Return", "9) [X] task", "9) [X] task\n10) [ ] "),
        Case("empty task exits", "- [ ] ", ""),
        Case("empty checked task retains indentation", "  - [x] \t", "  ")
    ]
    for item in cases {
        let source = prefix + item.fragment + suffix
        let selection = NSRange(location: (prefix as NSString).length + item.selection.location, length: item.selection.length)
        let fixture = try ListReturnFixture(source: source, selection: selection, enabled: item.enabled)
        defer { fixture.close() }
        try await fixture.ready()
        let remoteNeedles = ["# 固定标题 **粗体**\n", "> 固定引用\n", "- 固定列表\n"]
        let remotes = try remoteNeedles.map { try ListRemotePresentation(fixture, needle: $0) }
        if item.enabled { try checks.expect(!remotes[0].masks.isEmpty && !remotes[1].decorations.isEmpty, "\(item.name) starts with rendered distant Markdown") }
        fixture.pressReturn()
        let expected = prefix + item.result + suffix
        try checks.expect(fixture.view.string.utf8.elementsEqual(expected.utf8), "\(item.name) Return writes the exact expected raw source (got \(fixture.view.string.debugDescription))")
        let expectedCaret = (prefix as NSString).length + (item.caretPrefix as NSString).length
        try checks.expect(fixture.view.selectedRange() == NSRange(location: expectedCaret, length: 0), "\(item.name) Return leaves one caret after the inserted prefix")
        try checks.expect(fixture.edits.take() == 1, "\(item.name) Return produces one native character-edit transaction")
        for remote in remotes { try remote.verify(fixture, checks: checks, label: "\(item.name) immediately") }
        if item.enabled { try await FN11Verification.waitForPresentation(fixture.controller, source: expected) }
        for remote in remotes { try remote.verify(fixture, checks: checks, label: "\(item.name) after parse") }
        try checks.expect(fixture.view.undoManager?.canUndo == true, "\(item.name) Return is undoable")
        fixture.view.undoManager?.undo()
        fixture.controller.documentDidChange()
        try checks.expect(fixture.view.string.utf8.elementsEqual(source.utf8), "\(item.name) single undo restores original raw source")
        try checks.expect(fixture.view.undoManager?.canUndo == false && fixture.view.undoManager?.canRedo == true, "\(item.name) Return creates exactly one undo step")
        fixture.view.undoManager?.redo()
        fixture.controller.documentDidChange()
        try checks.expect(fixture.view.string.utf8.elementsEqual(expected.utf8), "\(item.name) single redo restores continuation source")
        try checks.expect(fixture.view.selectedRange() == NSRange(location: expectedCaret, length: 0), "\(item.name) redo restores continuation caret")
    }
}

@MainActor
private func verifyMarkedListReturn(_ checks: Checks) async throws {
    let source = "# 固定标题\n\n1. 中文"
    let selection = NSRange(location: (source as NSString).length, length: 0)
    let active = try ListReturnFixture(source: source, selection: selection)
    let native = try ListReturnFixture(source: source, selection: selection)
    defer { active.close(); native.close() }
    try await active.ready()
    try await native.ready()
    native.view.continuesMarkdownLists = { false }
    for fixture in [active, native] {
        fixture.view.undoManager?.beginUndoGrouping()
        fixture.view.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try checks.expect(fixture.view.hasMarkedText(), "list Return IME fixture has simulated marked text")
    }
    active.pressReturn()
    native.pressReturn()
    try checks.expect(active.view.string.utf8.elementsEqual(native.view.string.utf8), "Return during simulated marked text uses identical native source behavior with list continuation enabled or disabled")
    try checks.expect(active.view.selectedRange() == native.view.selectedRange() && active.view.hasMarkedText() == native.view.hasMarkedText(), "marked Return keeps native selection and marked-state behavior")
    try checks.expect(!active.view.string.contains("\n2. "), "marked Return does not inject an automatic ordered-list prefix")
    for fixture in [active, native] {
        if fixture.view.hasMarkedText() { fixture.view.unmarkText() }
        fixture.view.undoManager?.endUndoGrouping()
    }
}

@MainActor
private final class ListAutosaveScheduler: EditorAutosaveScheduling {
    private var action: (@MainActor () -> Void)?
    var hasPendingAction: Bool { action != nil }
    func schedule(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() { action = nil }
    func fire() -> Bool {
        guard let action else { return false }
        self.action = nil
        action()
        return true
    }
}

@MainActor
private func verifyListEditorAutosave(_ checks: Checks) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderNotes-FN11-List-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("list.png")
    let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nWQAAAAASUVORK5CYII=")!
    try image.write(to: media)
    let source = "# 已存标题\n\n1.this is a test."
    let missing = try NoteReader().read(urls: [media])
    let snapshot = try NoteWriter().save(.init(baseline: missing, desiredContent: .present(Data(source.utf8))))
    let session = EditorSession()
    let ticket = session.beginLoading()
    try checks.expect(session.resolve(snapshot, ticket: ticket) == .installed, "list autosave fixture installs temporary source")
    let suite = "com.findernotes.FN11Verification.ListEditor.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure("list editor defaults unavailable") }
    defaults.set(true, forKey: MarkdownLayoutController.preferenceKey)
    defer {
        defaults.removePersistentDomain(forName: suite)
        _ = defaults.synchronize()
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist"))
    }
    let scheduler = ListAutosaveScheduler()
    let preview = MediaPreviewController(validate: { _ in }, makeBackend: { nil })
    let controller = EditorWindowController(session: session, autosaveScheduler: scheduler, preview: preview, defaults: defaults)
    defer {
        scheduler.cancel()
        preview.close()
        controller.window?.delegate = nil
        controller.window?.close()
    }
    try await FN11Verification.waitForPresentation(controller.markdownLayout, source: source)
    controller.editor.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
    controller.markdownLayout.selectionDidChange()
    controller.editor.undoManager?.removeAllActions()
    controller.editor.undoManager?.groupsByEvent = false
    let revision = session.draftRevision
    controller.editor.undoManager?.beginUndoGrouping()
    controller.editor.doCommand(by: #selector(NSTextView.insertNewline(_:)))
    controller.editor.undoManager?.endUndoGrouping()
    let expected = source + "\n2. "
    try checks.expect(controller.editor.string.utf8.elementsEqual(expected.utf8), "production editor Return inserts the automatic prefix")
    try checks.expect(session.draft.utf8.elementsEqual(expected.utf8), "automatic prefix reaches the existing session draft capture")
    try checks.expect(session.draftRevision == revision + 1 && session.isDirty, "automatic prefix advances session revision exactly once")
    try checks.expect(scheduler.hasPendingAction && scheduler.fire(), "automatic prefix schedules and fires the existing autosave callback")
    for _ in 0..<200 {
        if !session.isSaving && !session.isDirty { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try checks.expect(!session.isSaving && !session.isDirty, "automatic prefix completes a confirmed autosave")
    try checks.expect(try NoteReader().read(urls: [media]).content == .present(Data(expected.utf8)), "autosave persists the exact automatic prefix as raw UTF-8")
    controller.editor.undoManager?.undo()
    try checks.expect(session.draft.utf8.elementsEqual(source.utf8) && session.isDirty, "one native undo also captures the original source in the session")
    controller.editor.undoManager?.redo()
    try checks.expect(session.draft.utf8.elementsEqual(expected.utf8), "one native redo also captures continuation source in the session")
    try checks.expect(try Data(contentsOf: media) == image, "list Return and autosave preserve the fixture media bytes")
    try checks.expect(controller.window?.isVisible == false, "list editor autosave stays in its hidden component window")
}
