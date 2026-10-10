import AppKit
import Foundation

private actor TaskListParserGate {
    private var blocked = false
    private var pending: [(String, CheckedContinuation<MarkdownPresentation, Never>)] = []
    func parse(_ source: String) async -> MarkdownPresentation {
        guard blocked else { return .parse(source) }
        return await withCheckedContinuation { pending.append((source, $0)) }
    }
    func hold() { blocked = true }
    func contains(_ source: String) -> Bool { pending.contains { $0.0.utf8.elementsEqual(source.utf8) } }
    func release() {
        blocked = false
        let jobs = pending
        pending = []
        for (source, continuation) in jobs { continuation.resume(returning: .parse(source)) }
    }
}

private final class TaskListCharacterRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [NSRange] = []
    func record(_ mask: NSTextStorageEditActions, _ range: NSRange) {
        guard mask.contains(.editedCharacters) else { return }
        lock.lock(); defer { lock.unlock() }
        ranges.append(range)
    }
    func take() -> [NSRange] {
        lock.lock(); defer { lock.unlock() }
        let result = ranges
        ranges = []
        return result
    }
}

@MainActor
private final class TaskListFixture {
    let view = CompositionTextView()
    let controller: MarkdownLayoutController
    let gate = TaskListParserGate()
    let changes = TaskListCharacterRecorder()
    private let suite = "com.findernotes.FN11Verification.Task.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let window: NSWindow
    private var observer: NSObjectProtocol?

    init(source: String, selection: NSRange) throws {
        guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure("task fixture defaults unavailable") }
        self.defaults = defaults
        defaults.set(true, forKey: MarkdownLayoutController.preferenceKey)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 1100)
        view.isRichText = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 350))
        scroll.documentView = view
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(view)
        let gate = gate
        controller = MarkdownLayoutController(textView: view, defaults: defaults, parser: { await gate.parse($0) })
        let controller = controller
        view.inputStateWillChange = { [weak controller] in controller?.inputStateWillChange() }
        view.inputStateDidChange = { [weak controller] in controller?.inputStateDidChange() }
        view.continuesMarkdownLists = { [weak controller] in controller?.isEnabled == true }
        let changes = changes
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                           object: view.textStorage, queue: nil) { notification in
            if let storage = notification.object as? NSTextStorage { changes.record(storage.editedMask, storage.editedRange) }
        }
        view.string = source
        view.setSelectedRange(selection)
        controller.installDocument()
    }

    func ready() async throws {
        try await FN11Verification.waitForPresentation(controller, source: view.string)
        view.undoManager?.removeAllActions()
        view.undoManager?.groupsByEvent = false
        _ = changes.take()
    }

    func task(_ needle: String, phase: String = "unspecified") throws -> (MarkdownLayoutManager.Decoration, NSRect, NSRange, Bool) {
        let range = (view.string as NSString).range(of: needle)
        guard range.location != NSNotFound, let manager = view.layoutManager as? MarkdownLayoutManager else { throw CheckFailure("task fixture has no body range/layout manager") }
        let taskDecorations = manager.decorations.filter { if case .task = $0.kind { return true }; return false }
        guard let decoration = taskDecorations.first(where: { NSIntersectionRange($0.range, range).length > 0 }),
              case .task(let checked, let stateRange) = decoration.kind else {
            throw CheckFailure("collapsed task decoration unavailable: \(needle), phase \(phase), body \(range), selection \(view.selectedRanges), tasks \(taskDecorations), spans \(String(describing: controller.presentation?.spans))")
        }
        guard let rect = manager.checkboxRect(for: decoration, in: view) else {
            throw CheckFailure("checkbox rectangle unavailable: \(needle), phase \(phase), decoration \(decoration), selection \(view.selectedRanges), hidden markers \(controller.hiddenMarkers.count)")
        }
        return (decoration, rect, stateRange, checked)
    }

    func click(_ point: NSPoint) throws {
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                             clickCount: 1, pressure: 1) else { throw CheckFailure("cannot create native task mouse event") }
        view.undoManager?.beginUndoGrouping()
        view.mouseDown(with: event)
        view.undoManager?.endUndoGrouping()
        controller.documentDidChange()
    }

    func edit(_ replacement: String, range: NSRange) {
        view.setSelectedRange(range)
        controller.selectionDidChange()
        view.undoManager?.beginUndoGrouping()
        view.insertText(replacement, replacementRange: range)
        view.undoManager?.endUndoGrouping()
        controller.documentDidChange()
    }

    func waitForPending() async throws {
        let source = view.string
        for _ in 0..<100 {
            if await gate.contains(source) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckFailure("task fixture parser did not reach its gate")
    }

    func settle() async throws {
        await gate.release()
        try await FN11Verification.waitForPresentation(controller, source: view.string)
    }

    func close() async {
        await gate.release()
        while (view.undoManager?.groupingLevel ?? 0) > 0 { view.undoManager?.endUndoGrouping() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        view.inputStateWillChange = nil
        view.inputStateDidChange = nil
        view.markdownTaskClickHandler = nil
        controller.setEnabled(false)
        defaults.removePersistentDomain(forName: suite)
        _ = defaults.synchronize()
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist"))
        window.close()
    }
}

@MainActor
func verifyTaskListIntegration(_ checks: Checks) async throws {
    try await verifyNativeTaskClicks(checks)
    try await verifyMappedTaskClick(checks)
    try await verifyPendingFenceInteractionGuard(checks)
    try await verifyEmptyEOFTask(checks)
    try await verifyQuotedTaskHit(checks)
    try await verifyTaskEditorAutosave(checks)
}

@MainActor
private func verifyPendingFenceInteractionGuard(_ checks: Checks) async throws {
    let source = "前段正文\n\n- [ ] 待保护任务\n\n末段编辑\n"
    for (name, opener) in [("code fence", "```\n"), ("display math", "\\[\n"), ("parenthesized math", "\\(\n")] {
        let fixture = try TaskListFixture(source: source, selection: NSRange(location: (source as NSString).length, length: 0))
        do {
            try await fixture.ready()
            await fixture.gate.hold()
            fixture.edit(opener, range: NSRange(location: 0, length: 0))
            try await fixture.waitForPending()
            let (_, rect, _, checked) = try fixture.task("待保护任务")
            let manager = fixture.view.layoutManager as! MarkdownLayoutManager
            let center = NSPoint(x: rect.midX, y: rect.midY)
            try checks.expect(!checked && manager.taskDecoration(at: center, in: fixture.view) != nil, "\(name) edit preserves the cached checkbox display while parsing is pending")
            let pendingSource = fixture.view.string
            try checks.expect(!fixture.view.handleMarkdownTaskClick(at: center), "pending earlier \(name) insertion blocks interaction with a now-ambiguous cached task")
            try checks.expect(fixture.view.string.utf8.elementsEqual(pendingSource.utf8), "blocked \(name) task click preserves every raw source byte")
            try await fixture.settle()
            try checks.expect(fixture.controller.presentation?.spans.contains { if case .task = $0.style { return true }; return false } == false, "accepted fresh \(name) parse treats the former task as protected source")
            try checks.expect(!manager.decorations.contains { if case .task = $0.kind { return true }; return false }, "fresh \(name) parse removes the obsolete task hit target")
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }
}

@MainActor
private func verifyQuotedTaskHit(_ checks: Checks) async throws {
    let source = "- [ ] 普通任务\n\n> - [ ] 引用任务\n\n末段编辑\n"
    let fixture = try TaskListFixture(source: source, selection: NSRange(location: (source as NSString).length, length: 0))
    do {
        try await fixture.ready()
        let (_, normal, _, _) = try fixture.task("普通任务")
        let (_, quoted, state, _) = try fixture.task("引用任务")
        try checks.expect(abs(quoted.minX - normal.minX - 6) < 0.01, "quoted task checkbox leaves six points of clearance from the quote-bar column")
        let manager = fixture.view.layoutManager as! MarkdownLayoutManager
        try checks.expect(manager.taskDecoration(at: NSPoint(x: quoted.midX, y: quoted.midY), in: fixture.view) != nil, "quoted checkbox shared hit geometry includes its shifted center")
        try fixture.click(NSPoint(x: quoted.midX, y: quoted.midY))
        let expected = (source as NSString).replacingCharacters(in: state, with: "x")
        try checks.expect(fixture.view.string.utf8.elementsEqual(expected.utf8), "native quoted checkbox click changes its exact raw task state")
        try checks.expect(try fixture.task("引用任务").3, "quoted task becomes checked immediately")
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@MainActor
private struct TaskRemoteSnapshot {
    let needle: String
    let content: NSAttributedString
    let hidden: IndexSet
    let decorations: [String]
    init(_ fixture: TaskListFixture, needle: String) throws {
        self.needle = needle
        let range = (fixture.view.string as NSString).range(of: needle)
        guard range.location != NSNotFound, let storage = fixture.view.textStorage,
              let manager = fixture.view.layoutManager as? MarkdownLayoutManager else { throw CheckFailure("remote task snapshot unavailable") }
        content = NSAttributedString(attributedString: storage.attributedSubstring(from: range))
        hidden = IndexSet(manager.hiddenCharacters.filter { NSLocationInRange($0, range) }.map { $0 - range.location })
        decorations = manager.decorations.compactMap {
            let overlap = NSIntersectionRange($0.range, range)
            guard overlap.length > 0 else { return nil }
            let kind: String
            switch $0.kind {
            case .list(let label): kind = "list:\(label)"
            case .task(let checked, let state): kind = "task:\(checked):\(state.location - range.location):\(state.length)"
            case .quote: kind = "quote"
            case .rule: kind = "rule"
            }
            return "\(overlap.location - range.location):\(overlap.length):\(kind)"
        }
    }
    func verify(_ fixture: TaskListFixture, checks: Checks, phase: String) throws {
        let next = try TaskRemoteSnapshot(fixture, needle: needle)
        try checks.expect(content.isEqual(to: next.content), "\(phase) preserves remote heading/paragraph attributes")
        try checks.expect(hidden == next.hidden, "\(phase) preserves the manager's remote hidden-character subset")
        try checks.expect(decorations == next.decorations, "\(phase) preserves remote decorations")
    }
}

@MainActor
private func verifyNativeTaskClicks(_ checks: Checks) async throws {
    let source = "# 固定标题 **加粗**\n\n> 固定引用\n\n- 固定列表\n\n- [ ] **任务甲**\n- [X] 任务乙\n\n当前编辑段落\n" + String(repeating: "更多正文行\n", count: 40)
    let selected = (source as NSString).range(of: "编辑")
    let fixture = try TaskListFixture(source: source, selection: selected)
    do {
        try await fixture.ready()
        let manager = fixture.view.layoutManager as! MarkdownLayoutManager
        manager.ensureLayout(for: fixture.view.textContainer!)
        let remotes = try ["# 固定标题 **加粗**\n", "> 固定引用\n", "- 固定列表\n"].map { try TaskRemoteSnapshot(fixture, needle: $0) }
        let clip = fixture.view.enclosingScrollView!.contentView
        clip.scroll(to: NSPoint(x: 0, y: 60))
        let scrollOrigin = clip.bounds.origin
        try checks.expect(scrollOrigin.y > 0, "checkbox scroll-retention fixture starts at an actual nonzero scroll offset")
        let (_, rect, state, checked) = try fixture.task("任务甲", phase: "initial collapsed display")
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let expectedState = NSRange(location: (source as NSString).range(of: "[ ]").location + 1, length: 1)
        try checks.expect(!checked && state == expectedState, "unchecked task decoration targets exactly its raw status character")
        try checks.expect(rect.width > 0 && rect.height > 0 && manager.taskDecoration(at: center, in: fixture.view) != nil, "drawn checkbox rectangle and native hit test use the same nonempty geometry")
        try checks.expect(manager.taskDecoration(at: NSPoint(x: rect.maxX + 2, y: rect.midY), in: fixture.view) == nil, "checkbox hit test excludes adjacent text outside its rectangle")
        let prefix = (source as NSString).range(of: "- [ ] ")
        try checks.expect(fixture.controller.hiddenMarkers.contains { NSIntersectionRange($0, prefix).length == prefix.length }, "collapsed task hides the complete raw source prefix")
        let originalSelections = fixture.view.selectedRanges
        await fixture.gate.hold()
        try fixture.click(center)
        let expected = (source as NSString).replacingCharacters(in: state, with: "x")
        try checks.expect(fixture.view.string.utf8.elementsEqual(expected.utf8), "native checkbox mouseDown changes only the raw status character")
        let writes = fixture.changes.take()
        try checks.expect(writes == [state], "native checkbox mouseDown performs one one-character source edit")
        try checks.expect(fixture.view.selectedRanges == originalSelections, "native checkbox click preserves the existing text selection")
        try checks.expect(clip.bounds.origin == scrollOrigin, "native checkbox click preserves the actual scroll offset")
        try checks.expect(fixture.view.undoManager?.canUndo == true, "native checkbox click creates an undoable edit")
        for remote in remotes { try remote.verify(fixture, checks: checks, phase: "native checkbox click immediately") }
        try checks.expect(try fixture.task("任务甲", phase: "immediately after native click").3, "checkbox becomes checked immediately while parsing is blocked")
        try checks.expect(fixture.controller.hiddenMarkers.contains { NSIntersectionRange($0, prefix).length == prefix.length }, "native click preserves its collapsed prefix while parsing is blocked")
        try await fixture.waitForPending()
        try checks.expect(try fixture.task("任务甲", phase: "parser held after click").3, "delayed parse keeps the immediate checked task decoration")
        for remote in remotes { try remote.verify(fixture, checks: checks, phase: "checkbox click while parse held") }
        fixture.view.undoManager?.undo()
        fixture.controller.documentDidChange()
        try checks.expect(fixture.view.string.utf8.elementsEqual(source.utf8), "one native undo restores unchecked raw task source")
        try checks.expect(!fixture.view.undoManager!.canUndo && fixture.view.undoManager!.canRedo, "checkbox state edit is exactly one native undo step")
        // Native undo may move its caret into the changed paragraph, which correctly
        // reveals raw syntax. Leave that paragraph before checking its collapsed box.
        fixture.view.selectedRanges = originalSelections
        fixture.controller.selectionDidChange()
        try checks.expect(!(try fixture.task("任务甲", phase: "undo then leave current task paragraph").3), "leaving the natively undone task immediately restores its unchecked decoration")
        fixture.view.undoManager?.redo()
        fixture.controller.documentDidChange()
        try checks.expect(fixture.view.string.utf8.elementsEqual(expected.utf8), "one native redo restores checked raw task source")
        fixture.view.selectedRanges = originalSelections
        fixture.controller.selectionDidChange()
        try checks.expect(try fixture.task("任务甲", phase: "redo then leave current task paragraph").3, "leaving the natively redone task immediately restores its checked decoration")
        try await fixture.waitForPending()
        try await fixture.settle()
        for remote in remotes { try remote.verify(fixture, checks: checks, phase: "checkbox click after parser result") }

        let (_, upperRect, upperState, upperChecked) = try fixture.task("任务乙")
        try checks.expect(upperChecked && (fixture.view.string as NSString).substring(with: upperState) == "X", "uppercase-X checkbox remains exact source until explicitly toggled")
        let beforeUpper = fixture.view.string
        try fixture.click(NSPoint(x: upperRect.midX, y: upperRect.midY))
        try checks.expect(fixture.view.string.utf8.elementsEqual((beforeUpper as NSString).replacingCharacters(in: upperState, with: " ").utf8), "checked uppercase-X task click changes only its state to a space")
        try await FN11Verification.waitForPresentation(fixture.controller, source: fixture.view.string)

        let (_, currentRect, _, _) = try fixture.task("任务甲", phase: "after toggling uppercase task")
        let currentPoint = NSPoint(x: currentRect.midX, y: currentRect.midY)
        fixture.controller.setEnabled(false)
        let offSource = fixture.view.string
        try checks.expect(!fixture.view.handleMarkdownTaskClick(at: currentPoint), "Markdown-off mode declines checkbox click handling")
        try checks.expect(fixture.view.string.utf8.elementsEqual(offSource.utf8), "Markdown-off click handling preserves the raw draft")
        fixture.controller.setEnabled(true)
        try await FN11Verification.waitForPresentation(fixture.controller, source: fixture.view.string)
        fixture.view.setSelectedRange((fixture.view.string as NSString).range(of: "任务甲"))
        fixture.controller.selectionDidChange()
        let expandedSource = fixture.view.string
        try checks.expect(manager.taskDecoration(at: currentPoint, in: fixture.view) == nil, "current task paragraph reveals raw source and removes the checkbox hit target")
        try checks.expect(!fixture.view.handleMarkdownTaskClick(at: currentPoint) && fixture.view.string.utf8.elementsEqual(expandedSource.utf8), "current raw paragraph cannot toggle through a former checkbox rectangle")

        fixture.view.setSelectedRange(NSRange(location: (fixture.view.string as NSString).range(of: "编辑段落").location, length: 0))
        fixture.controller.selectionDidChange()
        let (_, composingRect, _, _) = try fixture.task("任务甲")
        fixture.view.undoManager?.beginUndoGrouping()
        fixture.view.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedSource = fixture.view.string
        try checks.expect(fixture.view.hasMarkedText(), "checkbox protection fixture has simulated marked text")
        try checks.expect(!fixture.view.handleMarkdownTaskClick(at: NSPoint(x: composingRect.midX, y: composingRect.midY)), "marked text prevents checkbox mutation")
        try checks.expect(fixture.view.string.utf8.elementsEqual(markedSource.utf8) && fixture.view.hasMarkedText(), "ignored checkbox click preserves candidate bytes and marked state")
        fixture.view.unmarkText()
        fixture.view.undoManager?.endUndoGrouping()
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@MainActor
private func verifyEmptyEOFTask(_ checks: Checks) async throws {
    let source = "首段可编辑\n\n- [ ] "
    let fixture = try TaskListFixture(source: source, selection: NSRange(location: 1, length: 0))
    do {
        try await fixture.ready()
        fixture.view.backgroundColor = .white
        fixture.view.appearance = NSAppearance(named: .aqua)
        let manager = fixture.view.layoutManager as! MarkdownLayoutManager
        manager.ensureLayout(for: fixture.view.textContainer!)
        let (_, rect, state, checked) = try fixture.task("- [ ] ")
        let previousGlyph = manager.glyphIndexForCharacter(at: 0)
        let priorLine = manager.lineFragmentRect(forGlyphAt: previousGlyph, effectiveRange: nil)
            .offsetBy(dx: fixture.view.textContainerOrigin.x, dy: fixture.view.textContainerOrigin.y)
        try checks.expect(!checked && state == NSRange(location: (source as NSString).range(of: "[ ]").location + 1, length: 1), "empty EOF task retains an exact unchecked state range")
        try checks.expect(rect.minY > priorLine.maxY, "fully hidden empty EOF checkbox renders below the prior paragraph")
        try checks.expect(manager.taskDecoration(at: NSPoint(x: rect.midX, y: rect.midY), in: fixture.view) != nil, "empty EOF checkbox uses its rendered rectangle for hit testing")
        let render = NSRect(x: 0, y: 0, width: 700, height: max(120, ceil(rect.maxY + 24)))
        guard let bitmap = fixture.view.bitmapImageRepForCachingDisplay(in: render) else { throw CheckFailure("cannot create empty-task bitmap") }
        fixture.view.cacheDisplay(in: render, to: bitmap)
        let scaleX = CGFloat(bitmap.pixelsWide) / render.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / render.height
        let xs = max(0, Int(floor(rect.minX * scaleX)))..<min(bitmap.pixelsWide, Int(ceil(rect.maxX * scaleX)))
        let ys = max(0, Int(floor(rect.minY * scaleY)))..<min(bitmap.pixelsHigh, Int(ceil(rect.maxY * scaleY)))
        let hasBoxPixels = ys.contains { y in xs.contains { x in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.redComponent < 0.85 && color.greenComponent < 0.85 && color.blueComponent < 0.85
        } }
        try checks.expect(hasBoxPixels, "empty EOF task bitmap contains the checkbox inside its hit rectangle")
        try checks.expect(fixture.view.string.utf8.elementsEqual(source.utf8), "empty EOF checkbox rendering preserves exact raw source bytes")
        if let output = CommandLine.arguments.dropFirst().first, output != "--task-ui" {
            let path = URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("task-checkbox-empty-eof.png")
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure("cannot encode empty-task bitmap") }
            try png.write(to: path, options: .atomic)
            print("Empty EOF task component bitmap: \(path.path)")
        }
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@MainActor
private func verifyMappedTaskClick(_ checks: Checks) async throws {
    let source = "前段正文\n\n- [ ] 位移后的任务\n\n末段编辑\n"
    let fixture = try TaskListFixture(source: source, selection: NSRange(location: (source as NSString).length, length: 0))
    do {
        try await fixture.ready()
        let (_, _, originalState, _) = try fixture.task("位移后的任务")
        await fixture.gate.hold()
        let inserted = "👩🏽‍🚀 e\u{301}\n"
        fixture.edit(inserted, range: NSRange(location: 0, length: 0))
        try await fixture.waitForPending()
        let (_, movedRect, movedState, _) = try fixture.task("位移后的任务")
        try checks.expect(movedState.location == originalState.location + (inserted as NSString).length, "pending parse rebases task status positions by UTF-16 length after an earlier emoji/combining edit")
        let beforeClick = fixture.view.string
        let selections = fixture.view.selectedRanges
        _ = fixture.changes.take()
        try fixture.click(NSPoint(x: movedRect.midX, y: movedRect.midY))
        let expected = (beforeClick as NSString).replacingCharacters(in: movedState, with: "x")
        try checks.expect(fixture.view.string.utf8.elementsEqual(expected.utf8), "clicking a mapped cached checkbox edits the current status character, preserving earlier UTF-8 edits")
        try checks.expect(fixture.changes.take() == [movedState], "mapped cached task click performs one current-coordinate source edit")
        try checks.expect(fixture.view.selectedRanges == selections, "mapped cached task click preserves the current selection")
        try checks.expect(try fixture.task("位移后的任务").3, "mapped task becomes checked before its full parser result")
        try await fixture.waitForPending()
        try await fixture.settle()
        let (_, _, finalState, finalChecked) = try fixture.task("位移后的任务")
        try checks.expect(finalChecked && finalState == movedState, "fresh parse agrees with the mapped checked task and status range")
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@MainActor
private final class TaskAutosaveScheduler: EditorAutosaveScheduling {
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
private func verifyTaskEditorAutosave(_ checks: Checks) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderNotes-FN11-Task-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("task.png")
    let image = taskFixturePNG
    try image.write(to: media)
    let source = "# 已存标题\n\n- [ ] 自动保存任务\n\n末段编辑\n"
    let snapshot = try NoteWriter().save(.init(baseline: NoteReader().read(urls: [media]), desiredContent: .present(Data(source.utf8))))
    let session = EditorSession()
    let loading = session.beginLoading()
    try checks.expect(session.resolve(snapshot, ticket: loading) == .installed, "task autosave fixture installs its temporary raw source")
    let suite = "com.findernotes.FN11Verification.TaskEditor.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure("task editor defaults unavailable") }
    defaults.set(true, forKey: MarkdownLayoutController.preferenceKey)
    defer {
        defaults.removePersistentDomain(forName: suite)
        _ = defaults.synchronize()
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist"))
    }
    let scheduler = TaskAutosaveScheduler()
    let preview = MediaPreviewController(validate: { _ in }, makeBackend: { nil })
    let controller = EditorWindowController(session: session, autosaveScheduler: scheduler, preview: preview, defaults: defaults)
    defer {
        scheduler.cancel()
        preview.close()
        controller.window?.delegate = nil
        controller.window?.close()
    }
    controller.window?.makeFirstResponder(controller.editor)
    controller.editor.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
    try await FN11Verification.waitForPresentation(controller.markdownLayout, source: source)
    guard let manager = controller.editor.layoutManager as? MarkdownLayoutManager,
          let task = manager.decorations.first(where: { if case .task = $0.kind { return true }; return false }),
          case .task(_, let state) = task.kind,
          let rect = manager.checkboxRect(for: task, in: controller.editor),
          let window = controller.window,
          let event = NSEvent.mouseEvent(with: .leftMouseDown, location: controller.editor.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 2,
                                          clickCount: 1, pressure: 1) else { throw CheckFailure("production editor task checkbox unavailable") }
    let selection = controller.editor.selectedRanges
    let revision = session.draftRevision
    controller.editor.undoManager?.removeAllActions()
    controller.editor.undoManager?.groupsByEvent = false
    controller.editor.undoManager?.beginUndoGrouping()
    controller.editor.mouseDown(with: event)
    controller.editor.undoManager?.endUndoGrouping()
    let expected = (source as NSString).replacingCharacters(in: state, with: "x")
    try checks.expect(controller.editor.string.utf8.elementsEqual(expected.utf8) && session.draft.utf8.elementsEqual(expected.utf8), "native production checkbox click reaches the raw session draft")
    try checks.expect(session.draftRevision == revision + 1 && session.isDirty, "checkbox click advances session revision exactly once")
    try checks.expect(controller.editor.selectedRanges == selection, "production checkbox click preserves its prior text selection")
    try checks.expect(scheduler.hasPendingAction && scheduler.fire(), "checkbox click schedules and starts the existing autosave flow")
    for _ in 0..<200 {
        if !session.isSaving && !session.isDirty { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    try checks.expect(!session.isSaving && !session.isDirty, "checkbox autosave confirms saved state")
    try checks.expect(try NoteReader().read(urls: [media]).content == .present(Data(expected.utf8)), "checkbox autosave persists the exact raw [x] source")
    controller.editor.undoManager?.undo()
    try checks.expect(session.draft.utf8.elementsEqual(source.utf8) && session.isDirty, "native checkbox undo also captures original raw source in the session")
    controller.editor.undoManager?.redo()
    try checks.expect(session.draft.utf8.elementsEqual(expected.utf8), "native checkbox redo also captures checked raw source in the session")
    try checks.expect(try Data(contentsOf: media) == image, "task checkbox persistence preserves the temporary PNG bytes")
    try checks.expect(!window.isVisible, "task autosave integration remains in a hidden window")
}

private var taskFixturePNG: Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nWQAAAAASUVORK5CYII=")!
}

/// Optional, explicitly launched review mode. It never runs during verification.
/// Keep its temporary source/preferences for root's real UI evidence and cleanup.
@MainActor
private var taskReviewRetainedObjects: [AnyObject] = []

@MainActor
func launchFN11TaskReviewUI() async throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderNotes-FN11-TaskUI-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let media = root.appendingPathComponent("FN11-task-review.png")
    try taskFixturePNG.write(to: media)
    let source = """
    # FN-11 任务复选框

    - [ ] 点击此复选框完成任务
    - [x] 点击此复选框取消完成

    1. [ ] 编号任务：行末按 Return

    - [ ] 中文输入：切换候选、确认和取消

    先在此段放置光标，再点击上方复选框。
    """
    try Data(source.utf8).write(to: root.appendingPathComponent("original.md"))
    let snapshot = try NoteWriter().save(.init(baseline: NoteReader().read(urls: [media]), desiredContent: .present(Data(source.utf8))))
    let session = EditorSession()
    let loading = session.beginLoading()
    guard session.resolve(snapshot, ticket: loading) == .installed else { throw CheckFailure("task review source could not install") }
    let suite = "com.findernotes.FN11TaskUI.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure("task review defaults unavailable") }
    defaults.set(true, forKey: MarkdownLayoutController.preferenceKey)
    let preview = MediaPreviewController(validate: { _ in }, makeBackend: { nil })
    let controller = EditorWindowController(session: session, preview: preview, defaults: defaults)
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(withTitle: "退出任务验收窗口", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let editMenu = NSMenu(title: "编辑")
    editItem.submenu = editMenu
    editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    app.mainMenu = main
    controller.showWindow(nil)
    controller.window?.title = "FN-11 task UI · 隔离任务复选框验收"
    controller.window?.makeFirstResponder(controller.editor)
    let caret = (controller.editor.string as NSString).range(of: "先在此段").location
    controller.editor.setSelectedRange(NSRange(location: caret, length: 0))
    controller.markdownLayout.selectionDidChange()
    app.activate(ignoringOtherApps: true)
    try await FN11Verification.waitForPresentation(controller.markdownLayout, source: source)
    guard let manager = controller.editor.layoutManager as? MarkdownLayoutManager,
          let window = controller.window else { throw CheckFailure("task review window unavailable") }
    manager.ensureLayout(for: controller.editor.textContainer!)
    let boxes: [[String: Any]] = manager.decorations.compactMap { decoration in
        guard case .task(let checked, let stateRange) = decoration.kind,
              let rect = manager.checkboxRect(for: decoration, in: controller.editor) else { return nil }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let screen = window.convertPoint(toScreen: controller.editor.convert(center, to: nil))
        return ["checked": checked, "stateLocation": stateRange.location,
                "rectInEditor": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height],
                "centerOnScreenBottomLeft": ["x": screen.x, "y": screen.y]]
    }
    let context: [String: Any] = ["fixtureRoot": root.path, "mediaPath": media.path, "originalPath": root.appendingPathComponent("original.md").path,
                                  "preferenceSuite": suite, "pid": ProcessInfo.processInfo.processIdentifier,
                                  "windowTitle": window.title, "windowFrame": ["x": window.frame.minX, "y": window.frame.minY, "width": window.frame.width, "height": window.frame.height],
                                  "checkboxes": boxes, "source": source]
    let data = try JSONSerialization.data(withJSONObject: context, options: [.prettyPrinted, .sortedKeys])
    let contextOutput = CommandLine.arguments.count > 2 ? CommandLine.arguments[2]
        : Bundle.main.object(forInfoDictionaryKey: "FN11TaskReviewContextPath") as? String
    if let contextOutput {
        let contextPath = URL(fileURLWithPath: contextOutput)
        try FileManager.default.createDirectory(at: contextPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: contextPath, options: .atomic)
        FileHandle.standardOutput.write(Data("FN-11 task UI context: \(contextPath.path)\n".utf8))
    }
    FileHandle.standardOutput.write(Data("FN-11 task UI fixture: \(root.path)\nFN-11 task UI preferences: \(suite)\n".utf8))
    taskReviewRetainedObjects = [controller, defaults, preview]
}
