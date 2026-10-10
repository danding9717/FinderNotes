import AppKit
import Foundation

/// The gate pauses real parser results after debounce, so checks observe the
/// intermediate native-edit state instead of only the eventual correct display.
private actor StabilityParserGate {
    private var blocked = false
    private var waiting: [(String, CheckedContinuation<MarkdownPresentation, Never>)] = []

    func parse(_ source: String) async -> MarkdownPresentation {
        guard blocked else { return MarkdownPresentation.parse(source) }
        return await withCheckedContinuation { waiting.append((source, $0)) }
    }
    func hold() { blocked = true }
    func contains(_ source: String) -> Bool {
        waiting.contains { $0.0.utf8.elementsEqual(source.utf8) }
    }
    func release() {
        blocked = false
        let jobs = waiting
        waiting = []
        for (source, continuation) in jobs { continuation.resume(returning: .parse(source)) }
    }
}

private final class StabilityEditRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var attributeRanges: [NSRange] = []
    func record(_ mask: NSTextStorageEditActions, _ range: NSRange) {
        guard mask.contains(.editedAttributes), !mask.contains(.editedCharacters) else { return }
        lock.lock(); defer { lock.unlock() }
        attributeRanges.append(range)
    }
    func take() -> [NSRange] {
        lock.lock(); defer { lock.unlock() }
        let result = attributeRanges
        attributeRanges = []
        return result
    }
}

@MainActor
private final class StabilityFixture {
    let view: CompositionTextView
    let controller: MarkdownLayoutController
    let gate = StabilityParserGate()
    let recorder = StabilityEditRecorder()
    private let defaults: UserDefaults
    private let suiteName = "com.findernotes.FN11Verification.Stability.\(UUID().uuidString)"
    private let window: NSWindow
    private var observer: NSObjectProtocol?

    init(source: String, caret: Int) throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw CheckFailure("stability preference suite unavailable") }
        self.defaults = defaults
        defaults.set(true, forKey: MarkdownLayoutController.preferenceKey)
        view = CompositionTextView()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
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
        let gate = gate
        controller = MarkdownLayoutController(textView: view, defaults: defaults, parser: { await gate.parse($0) })
        let controller = controller
        view.inputStateWillChange = { [weak controller] in controller?.inputStateWillChange() }
        view.inputStateDidChange = { [weak controller] in controller?.inputStateDidChange() }
        let recorder = recorder
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                           object: view.textStorage, queue: nil) { notification in
            guard let storage = notification.object as? NSTextStorage else { return }
            recorder.record(storage.editedMask, storage.editedRange)
        }
        view.string = source
        view.setSelectedRange(NSRange(location: caret, length: 0))
        controller.installDocument()
    }

    func close() async {
        await gate.release()
        controller.setEnabled(false)
        view.inputStateWillChange = nil
        view.inputStateDidChange = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        defaults.removePersistentDomain(forName: suiteName)
        _ = defaults.synchronize()
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
        window.close()
    }

    func ready() async throws {
        try await FN11Verification.waitForPresentation(controller, source: view.string)
        view.undoManager?.removeAllActions()
        view.undoManager?.groupsByEvent = false
        _ = recorder.take()
    }

    func waitForBlockedParse() async throws {
        let source = view.string
        for _ in 0..<100 {
            if await gate.contains(source) { return }
            try await FN11Verification.pause(milliseconds: 20)
        }
        throw CheckFailure("delayed parser did not receive the edited source")
    }

    func settle() async throws {
        await gate.release()
        try await FN11Verification.waitForPresentation(controller, source: view.string)
        _ = recorder.take()
    }

    func edit(_ replacement: String, range: NSRange) throws {
        guard let undo = view.undoManager else { throw CheckFailure("native stability editor lacks undo manager") }
        view.setSelectedRange(range)
        controller.selectionDidChange()
        undo.beginUndoGrouping()
        view.insertText(replacement, replacementRange: range)
        undo.endUndoGrouping()
        controller.documentDidChange()
    }
}

@MainActor
private struct StabilitySnapshot {
    let attributed: NSAttributedString
    let masks: [NSRange]
    let decorationKeys: [String]

    init(_ fixture: StabilityFixture, needle: String) throws {
        let range = (fixture.view.string as NSString).range(of: needle)
        guard range.location != NSNotFound, let storage = fixture.view.textStorage,
              let manager = fixture.view.layoutManager as? MarkdownLayoutManager else {
            throw CheckFailure("missing stability paragraph \(needle.debugDescription)")
        }
        attributed = NSAttributedString(attributedString: storage.attributedSubstring(from: range))
        masks = fixture.controller.hiddenMarkers.compactMap {
            let overlap = NSIntersectionRange($0, range)
            return overlap.length == 0 ? nil : NSRange(location: overlap.location - range.location, length: overlap.length)
        }
        decorationKeys = manager.decorations.compactMap { decoration in
            let overlap = NSIntersectionRange(decoration.range, range)
            guard overlap.length > 0 else { return nil }
            let kind: String
            switch decoration.kind {
            case .list(let label): kind = "list:\(label)"
            case .quote: kind = "quote"
            case .rule: kind = "rule"
            case .task(let checked, let state): kind = "task:\(checked):\(state.location - range.location):\(state.length)"
            }
            return "\(overlap.location - range.location):\(overlap.length):\(kind)"
        }
    }

    func check(_ fixture: StabilityFixture, needle: String, checks: Checks, phase: String) throws {
        let current = try StabilitySnapshot(fixture, needle: needle)
        try checks.expect(attributed.isEqual(to: current.attributed), "\(phase) retains distant fonts and attributes: \(needle)")
        try checks.expect(masks == current.masks, "\(phase) retains distant hidden delimiters: \(needle)")
        try checks.expect(decorationKeys == current.decorationKeys, "\(phase) retains distant decorations: \(needle)")
    }
}

@MainActor
func verifyStability(_ checks: Checks) async throws {
    try verifyDisplayPlan(checks)
    try await verifyNativeEditStability(checks)
    try await verifyCompositionStability(checks)
    try await verifySemanticEditStability(checks)
    try await verifyHeadingTyping(checks)
}

@MainActor
private func verifyDisplayPlan(_ checks: Checks) throws {
    let source = "# **标题 *嵌套***\n\n正文\n\n- 尾段 **粗体**\n"
    let plan = MarkdownDisplayPlan.make(presentation: .parse(source), expanded: [])
    let headingRange = (source as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
    guard let heading = plan.paragraphs.first(where: { $0.range == headingRange }) else { throw CheckFailure("heading display cache missing") }
    let expanded = heading.resolvingExpansion([headingRange])
    let nested = (expanded.attributedString.string as NSString).range(of: "嵌套")
    let font = expanded.attributedString.attribute(.font, at: nested.location, effectiveRange: nil) as? NSFont
    let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
    try checks.expect(expanded.hiddenRanges.isEmpty, "expanded semantic heading reveals source delimiters")
    try checks.expect((font?.pointSize ?? 0) == 28 && traits.contains(.boldFontMask) && traits.contains(.italicFontMask), "expanded heading retains heading size and nested bold/italic traits")
    try checks.expect(expanded.resolvingExpansion([]).hasSamePresentation(as: heading), "cached expansion reverses without losing semantic styles")
    let prefix = "新增 🚀\n\n"
    let newSource = prefix + source
    guard let edit = MarkdownTextEdit.resolve(oldSource: source, newSource: newSource, editedRange: NSRange(location: 0, length: (prefix as NSString).length), changeInLength: (prefix as NSString).length) else { throw CheckFailure("prefix rebase has no edit") }
    let shifted = plan.rebased(to: newSource, edit: edit)
    for paragraph in plan.paragraphs where paragraph.range.length > 0 {
        let expected = NSRange(location: paragraph.range.location + (prefix as NSString).length, length: paragraph.range.length)
        try checks.expect(shifted.paragraphs.contains { $0.range == expected && $0.hasSamePresentation(as: paragraph) }, "prefix insertion rebases a complete untouched paragraph with identical presentation")
    }
    let eofSource = "# 前段\n\n**末段**"
    let eofPlan = MarkdownDisplayPlan.make(presentation: .parse(eofSource), expanded: [])
    let appended = eofSource + "新增"
    guard let eofEdit = MarkdownTextEdit.resolve(oldSource: eofSource, newSource: appended, editedRange: NSRange(location: (eofSource as NSString).length, length: 2), changeInLength: 2) else { throw CheckFailure("EOF append has no edit") }
    let rebased = eofPlan.rebased(to: appended, edit: eofEdit)
    let last = (eofSource as NSString).paragraphRange(for: NSRange(location: (eofSource as NSString).length, length: 0))
    try checks.expect(!rebased.paragraphs.contains { $0.range == last }, "EOF append drops the former final paragraph rather than retaining a partial cache")
    try checks.expect(rebased.paragraphs.contains { $0.range.location == 0 }, "EOF append retains the unaffected heading cache")
}

@MainActor
private func verifyNativeEditStability(_ checks: Checks) async throws {
    let source = "# 前标题 **加粗**\n\n> 前引用\n\n- 前列表\n\n编辑区 alpha beta\n合并行\n\n## 后标题\n\n**后粗体** 与 `后代码`\n\n1. 后列表\n\n> 后引用\n"
    let fixture = try StabilityFixture(source: source, caret: (source as NSString).range(of: "alpha").location)
    do {
        try await fixture.ready()
        let needles = ["# 前标题 **加粗**\n", "> 前引用\n", "- 前列表\n", "## 后标题\n", "**后粗体** 与 `后代码`\n", "1. 后列表\n", "> 后引用\n"]
        let snapshots = try needles.map { try StabilitySnapshot(fixture, needle: $0) }
        try checks.expect(!snapshots[0].masks.isEmpty && !snapshots[1].decorationKeys.isEmpty && !snapshots[2].decorationKeys.isEmpty, "stability fixture starts with hidden syntax, quote and list decoration")
        func verifyRemote(_ phase: String) throws {
            for (needle, snapshot) in zip(needles, snapshots) { try snapshot.check(fixture, needle: needle, checks: checks, phase: phase) }
            let count = (fixture.view.string as NSString).length
            try checks.expect(fixture.controller.hiddenMarkers.allSatisfy { $0.location <= count && $0.length <= count - $0.location }, "\(phase) publishes bounded rebased masks")
            let manager = fixture.view.layoutManager as! MarkdownLayoutManager
            var expectedCharacters = IndexSet()
            for marker in fixture.controller.hiddenMarkers { expectedCharacters.insert(integersIn: marker.location..<NSMaxRange(marker)) }
            try checks.expect(manager.hiddenCharacters == expectedCharacters, "\(phase) glyph-manager masks match the current rebased marker ranges")
        }
        func oneEdit(_ replacement: String, range: NSRange, label: String) async throws {
            await fixture.gate.hold()
            try verifyRemote("\(label) before native input")
            let expected = (fixture.view.string as NSString).replacingCharacters(in: range, with: replacement)
            _ = fixture.recorder.take()
            try fixture.edit(replacement, range: range)
            try checks.expect(fixture.view.string.utf8.elementsEqual(expected.utf8), "\(label) preserves exact expected raw UTF-8")
            try verifyRemote("\(label) immediately")
            let remoteRanges = needles.map { (fixture.view.string as NSString).range(of: $0) }
            let attributeWrites = fixture.recorder.take()
            try checks.expect(!attributeWrites.contains { write in remoteRanges.contains { NSIntersectionRange(write, $0).length > 0 } }, "\(label) does not rewrite distant paragraph attributes")
            try await fixture.waitForBlockedParse()
            try verifyRemote("\(label) while parser blocked")
            try await fixture.settle()
            try verifyRemote("\(label) after parser result")
            try checks.expect(!fixture.controller.lastAttributeUpdateRanges.contains { update in remoteRanges.contains { NSIntersectionRange(update, $0).length > 0 } }, "\(label) parse applies only changed paragraphs")
        }
        let alpha = (fixture.view.string as NSString).range(of: "alpha")
        try await oneEdit("X", range: NSRange(location: alpha.location + alpha.length, length: 0), label: "single-character insert")
        let alphaX = (fixture.view.string as NSString).range(of: "alphaX")
        try await oneEdit("👩🏽‍🚀", range: NSRange(location: NSMaxRange(alphaX), length: 0), label: "UTF-16 emoji insertion")
        try await oneEdit("", range: (fixture.view.string as NSString).range(of: "👩🏽‍🚀"), label: "UTF-16 emoji deletion")
        let newline = (fixture.view.string as NSString).range(of: "\n合并行")
        try await oneEdit("", range: NSRange(location: newline.location, length: 1), label: "newline merge")
        let beta = (fixture.view.string as NSString).range(of: "beta")
        try await oneEdit("beta\n新段 **待解析**\n第三段", range: beta, label: "multiple-paragraph paste simulation")

        await fixture.gate.hold()
        let beforeUndo = fixture.view.string
        fixture.view.undoManager?.undo()
        fixture.controller.documentDidChange()
        try verifyRemote("undo immediately")
        try await fixture.waitForBlockedParse()
        try verifyRemote("undo while parser blocked")
        try await fixture.settle()
        try verifyRemote("undo after parser result")
        await fixture.gate.hold()
        fixture.view.undoManager?.redo()
        fixture.controller.documentDidChange()
        try checks.expect(fixture.view.string.utf8.elementsEqual(beforeUndo.utf8), "redo restores exact multiple-paragraph raw source")
        try verifyRemote("redo immediately")
        try await fixture.waitForBlockedParse()
        try verifyRemote("redo while parser blocked")
        try await fixture.settle()
        try verifyRemote("redo after parser result")

        await fixture.gate.hold()
        try fixture.edit("Q", range: NSRange(location: (fixture.view.string as NSString).range(of: "alpha").location, length: 0))
        try await fixture.waitForBlockedParse()
        let heading = (fixture.view.string as NSString).range(of: "# 前标题 **加粗**\n")
        fixture.view.setSelectedRange(NSRange(location: heading.location + 2, length: 0))
        fixture.controller.selectionDidChange()
        try checks.expect(!fixture.controller.hiddenMarkers.contains { NSIntersectionRange($0, heading).length > 0 }, "pending parse selection immediately expands a cached heading")
        let size = fixture.view.textStorage?.attribute(.font, at: heading.location + 2, effectiveRange: nil) as? NSFont
        try checks.expect(size?.pointSize == 28, "pending parse expansion retains heading typography")
        let other = (fixture.view.string as NSString).range(of: "## 后标题\n")
        fixture.view.setSelectedRange(NSRange(location: other.location + 3, length: 0))
        fixture.controller.selectionDidChange()
        try snapshots[0].check(fixture, needle: needles[0], checks: checks, phase: "pending parse leaving heading")
        try checks.expect(!fixture.controller.hiddenMarkers.contains { NSIntersectionRange($0, other).length > 0 }, "pending parse selection immediately expands the next cached paragraph")
        try await fixture.settle()
        await fixture.close()
    } catch { await fixture.close(); throw error }
}

@MainActor
private func verifyHeadingTyping(_ checks: Checks) async throws {
    let source = "# 标题 **粗体**\n\n普通正文\n"
    let text = source as NSString
    let newline = text.range(of: "\n").location
    let cases: [(Int, CGFloat, Bool, String)] = [
        (text.range(of: "标题").location + 1, 28, true, "heading middle"),
        (newline, 28, true, "heading end before newline"),
        (newline + 1, 16, false, "blank paragraph following heading")
    ]
    for (location, expectedSize, expectedBold, label) in cases {
        let fixture = try StabilityFixture(source: source, caret: text.range(of: "普通").location)
        do {
            try await fixture.ready()
            await fixture.gate.hold()
            fixture.view.setSelectedRange(NSRange(location: location, length: 0))
            fixture.controller.selectionDidChange()
            let beforeFont = fixture.view.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            let beforeTypingFont = fixture.view.typingAttributes[.font] as? NSFont
            try fixture.edit("首次", range: NSRange(location: location, length: 0))
            let inserted = (fixture.view.string as NSString).range(of: "首次")
            let font = fixture.view.textStorage?.attribute(.font, at: inserted.location, effectiveRange: nil) as? NSFont
            try checks.expect(font?.pointSize == expectedSize, "first native input in \(label) immediately uses semantic font (prior display \(beforeFont?.pointSize ?? 0), prior typing \(beforeTypingFont?.pointSize ?? 0), inserted \(font?.pointSize ?? 0), expected \(expectedSize))")
            try checks.expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == expectedBold, "first native input in \(label) uses its semantic bold trait")
            try await fixture.waitForBlockedParse()
            let pendingFont = fixture.view.textStorage?.attribute(.font, at: inserted.location, effectiveRange: nil) as? NSFont
            try checks.expect(pendingFont?.pointSize == expectedSize, "first input in \(label) keeps its font while parsing is pending")
            try await fixture.settle()
            try compareToFreshDisplay(fixture, checks: checks, label: "first input in \(label)")
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }
}

@MainActor
private func verifyCompositionStability(_ checks: Checks) async throws {
    let source = "# 标题 **固定**\n\n- 远列表\n\n输入区\n\n> 远引用\n\n**远粗体**\n"
    let fixture = try StabilityFixture(source: source, caret: (source as NSString).range(of: "输入区").location + 3)
    do {
        try await fixture.ready()
        let needles = ["# 标题 **固定**\n", "- 远列表\n", "> 远引用\n", "**远粗体**\n"]
        let snapshots = try needles.map { try StabilitySnapshot(fixture, needle: $0) }
        func check(_ phase: String) throws {
            for (needle, snapshot) in zip(needles, snapshots) { try snapshot.check(fixture, needle: needle, checks: checks, phase: phase) }
            let remoteRanges = needles.map { (fixture.view.string as NSString).range(of: $0) }
            let writes = fixture.recorder.take()
            // AppKit may update its own marked-clause attributes in the candidate.
            try checks.expect(!writes.contains { write in remoteRanges.contains { NSIntersectionRange(write, $0).length > 0 } }, "\(phase) writes no distant presentation attributes while marked")
        }
        await fixture.gate.hold()
        // Ensure a real parser result is in flight before native marked text begins.
        try fixture.edit("x", range: NSRange(location: fixture.view.selectedRange().location, length: 0))
        try await fixture.waitForBlockedParse()
        fixture.view.undoManager?.beginUndoGrouping()
        _ = fixture.recorder.take()
        for candidate in ["拼", "拼音候选", "拼音"] {
            fixture.view.setMarkedText(candidate, selectedRange: NSRange(location: (candidate as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            try checks.expect(fixture.view.hasMarkedText(), "simulated IME candidate retains marked state")
            try checks.expect((fixture.view.string as NSString).substring(with: fixture.view.markedRange()) == candidate, "simulated IME grow/shrink uses exact candidate bytes")
            try check("IME candidate \(candidate)")
        }
        await fixture.gate.release()
        try await FN11Verification.pause(milliseconds: 100)
        try checks.expect(fixture.view.hasMarkedText(), "late parser return leaves simulated IME candidate marked")
        try check("late parser result during IME")
        await fixture.gate.hold()
        let beforeCommit = fixture.view.string
        fixture.view.unmarkText()
        fixture.view.undoManager?.endUndoGrouping()
        fixture.controller.documentDidChange()
        try checks.expect(fixture.view.string.utf8.elementsEqual(beforeCommit.utf8), "no-byte simulated IME commit preserves exact source")
        try checks.expect(!fixture.view.hasMarkedText(), "no-byte simulated IME commit settles marked state")
        for (needle, snapshot) in zip(needles, snapshots) { try snapshot.check(fixture, needle: needle, checks: checks, phase: "no-byte IME commit before parse") }
        try await fixture.waitForBlockedParse()
        try await fixture.settle()
        fixture.view.undoManager?.beginUndoGrouping()
        await fixture.gate.hold()
        _ = fixture.recorder.take()
        fixture.view.setMarkedText("取消候选", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try check("IME cancel candidate")
        fixture.view.insertText("", replacementRange: fixture.view.markedRange())
        if fixture.view.hasMarkedText() { fixture.view.unmarkText() }
        fixture.view.undoManager?.endUndoGrouping()
        fixture.controller.documentDidChange()
        try checks.expect(fixture.view.string.utf8.elementsEqual(beforeCommit.utf8), "simulated IME cancel removes only its transient candidate")
        try checks.expect(!fixture.view.hasMarkedText(), "simulated IME cancellation leaves no marked region")
        for (needle, snapshot) in zip(needles, snapshots) { try snapshot.check(fixture, needle: needle, checks: checks, phase: "IME cancel before parse") }
        try await fixture.waitForBlockedParse()
        try await fixture.settle()
        await fixture.close()
    } catch {
        while (fixture.view.undoManager?.groupingLevel ?? 0) > 0 { fixture.view.undoManager?.endUndoGrouping() }
        await fixture.close()
        throw error
    }
}

@MainActor
private func verifySemanticEditStability(_ checks: Checks) async throws {
    let longList = (1...180).map { "\($0). 项目\($0) **粗体**\n" }.joined()
    let cases: [(String, String, String, String)] = [
        ("# 安全前段\n\n编辑区\n\n```swift\nlet a = 1\n```\n\n**代码后正文**\n", "```swift", "", "fence opening removal"),
        ("# 安全前段\n\n编辑区\n\n" + longList + "\n**列表后正文**\n", "1. 项目1", "普通 项目1", "long-list semantic change")
    ]
    for (source, needle, replacement, label) in cases {
        let fixture = try StabilityFixture(source: source, caret: (source as NSString).range(of: "编辑区").location)
        do {
            try await fixture.ready()
            let remote = try StabilitySnapshot(fixture, needle: "# 安全前段\n")
            await fixture.gate.hold()
            let range = (fixture.view.string as NSString).range(of: needle)
            let expected = (fixture.view.string as NSString).replacingCharacters(in: range, with: replacement)
            try fixture.edit(replacement, range: range)
            try remote.check(fixture, needle: "# 安全前段\n", checks: checks, phase: "\(label) immediately")
            try await fixture.waitForBlockedParse()
            try remote.check(fixture, needle: "# 安全前段\n", checks: checks, phase: "\(label) pending")
            try await fixture.settle()
            try checks.expect(fixture.view.string.utf8.elementsEqual(expected.utf8), "\(label) preserves exact source bytes")
            try compareToFreshDisplay(fixture, checks: checks, label: label)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }
}

@MainActor
private func compareToFreshDisplay(_ fixture: StabilityFixture, checks: Checks, label: String) throws {
    let source = fixture.view.string
    let presentation = MarkdownPresentation.parse(source)
    let expanded = MarkdownLayoutController.expandedRanges(source: source, selections: fixture.view.selectedRanges.map(\.rangeValue), codeBlocks: presentation.codeBlocks)
    let expected = MarkdownDisplayPlan.make(presentation: presentation, expanded: expanded)
    let expectedStorage = NSTextStorage(string: source)
    for paragraph in expected.paragraphs { paragraph.applyAttributes(to: expectedStorage) }
    try checks.expect(fixture.view.textStorage?.isEqual(to: expectedStorage) == true, "\(label) final typography equals a complete fresh parse")
    try checks.expect(fixture.controller.hiddenMarkers == expected.paragraphs.flatMap(\.hiddenRanges), "\(label) final masks equal a complete fresh parse")
    let actualDecorations = (fixture.view.layoutManager as? MarkdownLayoutManager)?.decorations ?? []
    let expectedDecorations = expected.paragraphs.flatMap(\.decorations)
    func keys(_ values: [MarkdownLayoutManager.Decoration]) -> [String] {
        values.map {
            let kind: String
            switch $0.kind {
            case .list(let value): kind = "list:\(value)"
            case .quote: kind = "quote"
            case .rule: kind = "rule"
            case .task(let checked, let state): kind = "task:\(checked):\(state.location):\(state.length)"
            }
            return "\($0.range.location):\($0.range.length):\(kind)"
        }
    }
    try checks.expect(keys(actualDecorations) == keys(expectedDecorations), "\(label) final decorations equal a complete fresh parse")
}
