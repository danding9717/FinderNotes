import AppKit

/// TextKit owns the characters; this layer only changes how those characters are laid out.
// NSLayoutManager and its drawing/delegate callbacks are nonisolated in the SDK.
// This instance is owned by one main-actor editor and is never sent to parsing tasks.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var hiddenCharacters = IndexSet()
    var decorations: [Decoration] = [] {
        didSet {
            quoteRanges = decorations.compactMap {
                if case .quote = $0.kind { return $0.range }
                return nil
            }
        }
    }
    private var quoteRanges: [NSRange] = []

    struct Decoration: Equatable {
        enum Kind: Equatable { case list(String), task(Bool, stateRange: NSRange), quote, rule }
        let range: NSRange
        let kind: Kind
    }

    struct DecorationParagraph {
        let range: NSRange
        let decorations: [Decoration]
    }

    private var decorationParagraphs: [DecorationParagraph] = []

    func setDecorationParagraphs(_ paragraphs: [DecorationParagraph]) {
        decorationParagraphs = paragraphs
        decorations = paragraphs.flatMap(\.decorations)
    }

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !hiddenCharacters.isEmpty else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for index in properties.indices where hiddenCharacters.contains(charIndexes[index]) {
            properties[index].insert(.null)
            changed = true
        }
        guard changed else { return 0 }
        properties.withUnsafeBufferPointer {
            setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: charIndexes,
                      font: aFont, forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawDecorations(for: glyphsToShow, at: origin)
    }

    private func drawDecorations(for glyphsToShow: NSRange, at origin: NSPoint) {
        guard glyphsToShow.length > 0, !decorationParagraphs.isEmpty else { return }
        let visibleCharacters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard visibleCharacters.length > 0 else { return }
        let visibleEnd = NSMaxRange(visibleCharacters)

        // Paragraph groups are in source order and do not overlap. Start at the
        // first group intersecting this draw pass so scrolling never lays out
        // decorations for offscreen paragraphs.
        var lower = 0
        var upper = decorationParagraphs.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(decorationParagraphs[middle].range) <= visibleCharacters.location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        for paragraph in decorationParagraphs[lower...] {
            if paragraph.range.location >= visibleEnd { break }
            for decoration in paragraph.decorations {
                guard let placement = decorationLine(for: decoration),
                      NSLocationInRange(placement.glyph, glyphsToShow) else { continue }
                let container = placement.container
                let line = placement.line.offsetBy(dx: origin.x, dy: origin.y)
                NSColor.secondaryLabelColor.set()
                switch decoration.kind {
                case .list(let label):
                    (label as NSString).draw(at: NSPoint(x: line.minX + container.lineFragmentPadding,
                                                         y: line.minY),
                                            withAttributes: [.font: NSFont.systemFont(ofSize: 16),
                                                             .foregroundColor: NSColor.secondaryLabelColor])
                case .task(let checked, _):
                    drawCheckbox(in: checkboxRectangle(for: decoration, line: line, container: container), checked: checked)
                case .quote:
                    NSRect(x: line.minX + container.lineFragmentPadding, y: line.minY + 2,
                           width: 2, height: max(2, line.height - 4)).fill()
                case .rule:
                    NSRect(x: line.minX + container.lineFragmentPadding, y: line.midY,
                           width: max(1, line.width - container.lineFragmentPadding * 2), height: 1).fill()
                }
            }
        }
    }

    /// The very same rectangle is used by drawing and native mouse hit testing.
    @MainActor
    func checkboxRect(for decoration: Decoration, in textView: NSTextView) -> NSRect? {
        guard case .task = decoration.kind, textView.layoutManager === self,
              let storage = textStorage, decoration.range.location >= 0,
              decoration.range.length > 0, decoration.range.location < storage.length,
              decoration.range.length <= storage.length - decoration.range.location else { return nil }
        ensureLayout(forCharacterRange: decoration.range)
        guard let placement = decorationLine(for: decoration), placement.container === textView.textContainer else { return nil }
        return checkboxRectangle(for: decoration, line: placement.line, container: placement.container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }

    @MainActor
    func taskDecoration(at point: NSPoint, in textView: NSTextView) -> Decoration? {
        guard textView.layoutManager === self, let storage = textStorage, storage.length > 0 else { return nil }
        let character = textView.characterIndexForInsertion(at: point)
        guard character != NSNotFound, character <= storage.length else { return nil }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: character, length: 0))
        return decorations.first { decoration in
            guard case .task = decoration.kind,
                  NSIntersectionRange(decoration.range, paragraph).length > 0 || NSMaxRange(decoration.range) == storage.length else { return false }
            // The all-hidden EOF item can have no insertion glyph in its own line.
            return checkboxRect(for: decoration, in: textView)?.contains(point) == true
        }
    }

    private func decorationLine(for decoration: Decoration) -> (glyph: Int, container: NSTextContainer, line: NSRect)? {
        guard let storage = textStorage, storage.length > 0, decoration.range.location >= 0,
              decoration.range.length > 0, decoration.range.location < storage.length,
              decoration.range.length <= storage.length - decoration.range.location else { return nil }
        // Null prefix glyphs may belong to the preceding line. Anchor to visible
        // content, a retained newline, or the extra fragment for an empty EOF item.
        var anchor = decoration.range.location
        while anchor < NSMaxRange(decoration.range), hiddenCharacters.contains(anchor) { anchor += 1 }
        let isHiddenAtEnd = anchor >= storage.length
        if anchor >= storage.length { anchor = storage.length - 1 }
        let glyph = glyphIndexForCharacter(at: anchor)
        if isHiddenAtEnd, let container = extraLineFragmentTextContainer, !extraLineFragmentRect.isEmpty {
            return (glyph, container, extraLineFragmentRect)
        }
        guard let container = textContainer(forGlyphAt: glyph, effectiveRange: nil) else { return nil }
        return (glyph, container, lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
    }

    private func checkboxRectangle(for decoration: Decoration, line: NSRect, container: NSTextContainer) -> NSRect {
        let quoted = quoteRanges.contains { NSIntersectionRange($0, decoration.range).length > 0 }
        return NSRect(x: line.minX + container.lineFragmentPadding + (quoted ? 6 : 0),
                      y: line.midY - 7, width: 14, height: 14)
    }

    private func drawCheckbox(in rect: NSRect, checked: Bool) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
        box.lineWidth = 1.5
        if checked {
            NSColor.controlAccentColor.setFill()
            box.fill()
            let check = NSBezierPath()
            check.lineWidth = 1.7
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: rect.minX + 3.4, y: rect.midY))
            check.line(to: NSPoint(x: rect.minX + 6, y: rect.minY + 9.4))
            check.line(to: NSPoint(x: rect.minX + 10.6, y: rect.minY + 4.5))
            NSColor.white.setStroke()
            check.stroke()
        } else {
            NSColor.secondaryLabelColor.setStroke()
            box.stroke()
        }
    }
}

@MainActor
final class MarkdownLayoutController: NSObject, @MainActor NSTextStorageDelegate {
    static let preferenceKey = "markdownLayoutEnabled"
    typealias Parser = @Sendable (String) async -> MarkdownPresentation

    private weak var textView: CompositionTextView?
    private let defaults: UserDefaults
    private let parser: Parser
    private var documentGeneration: UInt64 = 0
    private var sourceRevision: UInt64 = 0
    private var parseGeneration: UInt64 = 0
    private var parseTask: Task<Void, Never>?
    private var source: String
    private var semanticPlan: MarkdownDisplayPlan?
    private var displayedPlan: MarkdownDisplayPlan?
    private var pendingInvalidation: [NSRange] = []
    private var pendingAttributeRanges: [NSRange] = []
    private var taskInteractionBlockedFrom: Int?
    private var nativeInputDepth = 0
    private var isApplying = false
    private var needsReset = false
    private(set) var isEnabled: Bool
    private(set) var presentation: MarkdownPresentation?
    private(set) var hiddenMarkers: [NSRange] = []
    private(set) var lastAttributeUpdateRanges: [NSRange] = []

    init(textView: CompositionTextView, defaults: UserDefaults = .standard,
         parser: @escaping Parser = { MarkdownPresentation.parse($0) }) {
        self.textView = textView
        self.defaults = defaults
        self.parser = parser
        source = textView.string
        isEnabled = defaults.object(forKey: Self.preferenceKey) == nil || defaults.bool(forKey: Self.preferenceKey)
        super.init()
        textView.textStorage?.delegate = self
        textView.markdownTaskClickHandler = { [weak self] point in self?.toggleTaskCheckbox(at: point) == true }
    }

    deinit { parseTask?.cancel() }

    private var isComposing: Bool { nativeInputDepth > 0 || textView?.hasMarkedText() == true }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        invalidateParse()
        guard !isComposing else { needsReset = !enabled; return }
        if enabled {
            flushDisplay()
            if presentation == nil { scheduleParse() }
        } else { resetDisplay() }
    }

    /// Native input hooks bracket AppKit itself; actual character changes are
    /// observed once, by NSTextStorage, including paste, delete and undo/redo.
    func inputStateWillChange() {
        if !isComposing { refreshTypingAttributes(from: semanticPlan) }
        nativeInputDepth += 1
    }

    func inputStateDidChange() {
        nativeInputDepth = max(0, nativeInputDepth - 1)
        guard !isComposing else { invalidateParse(); invalidatePendingGlyphs(); return }
        if !isEnabled {
            if needsReset { resetDisplay() }
            return
        }
        if needsReset { resetDisplay() }
        flushDisplay()
        if presentation == nil { scheduleParse() }
    }

    func textStorage(_ storage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isApplying else { return }
        let newSource = storage.string
        guard let edit = MarkdownTextEdit.resolve(oldSource: source, newSource: newSource,
                                                  editedRange: editedRange, changeInLength: delta) else { return }
        let oldSource = source
        let oldBlocks = semanticPlan?.codeBlocks ?? []
        source = newSource
        sourceRevision &+= 1
        invalidateParse()
        presentation = nil
        pendingInvalidation = pendingInvalidation.compactMap { edit.mapCovering($0) }
        pendingAttributeRanges = pendingAttributeRanges.compactMap { edit.mapCovering($0) }
        let oldAffected = Self.expandedRanges(source: oldSource, selections: [edit.oldRange], codeBlocks: oldBlocks)
        pendingInvalidation += oldAffected.compactMap { edit.mapCovering($0) }
        pendingInvalidation += Self.expandedRanges(source: newSource, selections: [edit.newRange], codeBlocks: [])
        let updatedTaskPlan = semanticPlan?.updatingTaskState(to: newSource, edit: edit)
        if let boundary = taskInteractionBlockedFrom {
            taskInteractionBlockedFrom = edit.mapCovering(NSRange(location: boundary, length: 0))?.location ?? 0
        }
        if updatedTaskPlan == nil {
            var boundaries: [Int] = []
            if let oldBoundary = Self.structuralTaskBoundary(source: oldSource, range: edit.oldRange),
               let mapped = edit.mapCovering(NSRange(location: oldBoundary, length: 0)) {
                boundaries.append(mapped.location)
            }
            if let newBoundary = Self.structuralTaskBoundary(source: newSource, range: edit.newRange) {
                boundaries.append(newBoundary)
            }
            if let boundary = boundaries.min() {
                taskInteractionBlockedFrom = min(taskInteractionBlockedFrom ?? boundary, boundary)
            }
        }
        semanticPlan = updatedTaskPlan ?? semanticPlan?.rebased(to: newSource, edit: edit)
        displayedPlan = displayedPlan?.updatingTaskState(to: newSource, edit: edit) ??
            displayedPlan?.rebased(to: newSource, edit: edit)
        if updatedTaskPlan != nil { pendingAttributeRanges.append(edit.newRange) }
        // No attributes, layout, selection or scroll mutations are permitted in
        // this callback. Adjust masks before TextKit generates changed glyphs.
        publishMetadata(from: displayedPlan)
    }

    func documentDidChange() {
        guard !isApplying else { return }
        // Storage already captured the exact edit and rebased the display cache.
        guard !isComposing else { return }
        if isEnabled {
            flushDisplay()
            scheduleParse()
        }
    }

    func installDocument() {
        documentGeneration &+= 1
        sourceRevision &+= 1
        invalidateParse()
        source = textView?.string ?? ""
        presentation = nil
        semanticPlan = nil
        displayedPlan = nil
        pendingInvalidation = []
        pendingAttributeRanges = []
        taskInteractionBlockedFrom = nil
        needsReset = true
        guard !isComposing else { return }
        resetDisplay()
        scheduleParse()
    }

    func selectionDidChange() {
        guard !isApplying, !isComposing, isEnabled else { return }
        flushDisplay()
    }

    private func toggleTaskCheckbox(at point: NSPoint) -> Bool {
        guard isEnabled, !isComposing, !isApplying, let textView, textView.isEditable,
              let manager = textView.layoutManager as? MarkdownLayoutManager,
              let displayedPlan, displayedPlan.source.utf8.elementsEqual(textView.string.utf8),
              source.utf8.elementsEqual(textView.string.utf8),
              let decoration = manager.taskDecoration(at: point, in: textView),
              displayedPlan.paragraphs.flatMap(\.decorations).contains(decoration),
              case .task(let checked, let stateRange) = decoration.kind else { return false }
        if let boundary = taskInteractionBlockedFrom, stateRange.location >= boundary { return false }
        let raw = textView.string as NSString
        guard stateRange.length == 1, stateRange.location > 0, stateRange.location < raw.length - 1,
              raw.character(at: stateRange.location - 1) == 91,
              raw.character(at: stateRange.location + 1) == 93 else { return false }
        let state = raw.character(at: stateRange.location)
        guard [UInt16(32), 120, 88].contains(state), (state != 32) == checked else { return false }
        let replacement = checked ? " " : "x"
        let expected = raw.replacingCharacters(in: stateRange, with: replacement)
        let edit = MarkdownTextEdit(oldRange: stateRange, newRange: stateRange)
        guard semanticPlan?.updatingTaskState(to: expected, edit: edit) != nil else { return false }

        let selections = textView.selectedRanges
        let affinity = textView.selectionAffinity
        let clip = textView.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        let document = documentGeneration
        let revision = sourceRevision
        // AppKit temporarily moves its caret to the replaced state character.
        // Keep display work deferred until the original equal-length selections return.
        inputStateWillChange()
        textView.breakUndoCoalescing()
        textView.insertText(replacement, replacementRange: stateRange)
        textView.breakUndoCoalescing()
        if documentGeneration == document, sourceRevision == (revision &+ 1),
           textView.string.utf8.elementsEqual(expected.utf8) {
            textView.setSelectedRanges(selections, affinity: affinity, stillSelecting: false)
            if let clip, let origin {
                clip.scroll(to: origin)
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
        inputStateDidChange()
        return true
    }

    private func invalidateParse() {
        parseGeneration &+= 1
        parseTask?.cancel()
        parseTask = nil
    }

    private func scheduleParse() {
        guard isEnabled, !isComposing, let textView else { return }
        invalidateParse()
        let source = textView.string
        let ticket = parseGeneration
        let document = documentGeneration
        let revision = sourceRevision
        let parser = self.parser
        parseTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { await parser(source) }.value
            guard let self, !Task.isCancelled, self.parseGeneration == ticket,
                  self.documentGeneration == document, self.sourceRevision == revision,
                  self.isEnabled, !self.isComposing,
                  self.textView?.string.utf8.elementsEqual(source.utf8) == true,
                  result.source.utf8.elementsEqual(source.utf8) else { return }
            self.presentation = result
            self.semanticPlan = MarkdownDisplayPlan.make(presentation: result, expanded: [])
            self.taskInteractionBlockedFrom = nil
            self.flushDisplay()
        }
    }

    private func publishMetadata(from plan: MarkdownDisplayPlan?) {
        guard let manager = textView?.layoutManager as? MarkdownLayoutManager else { return }
        hiddenMarkers = plan?.paragraphs.flatMap(\.hiddenRanges) ?? []
        var characters = IndexSet()
        for marker in hiddenMarkers where marker.length > 0 {
            characters.insert(integersIn: marker.location..<NSMaxRange(marker))
        }
        manager.hiddenCharacters = characters
        let decorationParagraphs = (plan?.paragraphs ?? []).compactMap { paragraph -> MarkdownLayoutManager.DecorationParagraph? in
            guard !paragraph.decorations.isEmpty else { return nil }
            return .init(range: paragraph.range, decorations: paragraph.decorations)
        }
        manager.setDecorationParagraphs(decorationParagraphs)
    }

    private func flushDisplay() {
        guard isEnabled, !isComposing, let textView,
              let storage = textView.textStorage,
              let manager = textView.layoutManager as? MarkdownLayoutManager,
              let semanticPlan, semanticPlan.source.utf8.elementsEqual(textView.string.utf8) else {
            invalidatePendingGlyphs()
            return
        }
        let expanded = Self.expandedRanges(source: source, selections: textView.selectedRanges.map(\.rangeValue),
                                          codeBlocks: semanticPlan.codeBlocks)
        let target = semanticPlan.resolvingExpansion(expanded)
        let oldParagraphs = Dictionary((displayedPlan?.paragraphs ?? []).map { ($0.range, $0) }, uniquingKeysWith: { _, rhs in rhs })
        let changed = target.paragraphs.filter { paragraph in
            if pendingAttributeRanges.contains(where: { NSIntersectionRange($0, paragraph.range).length > 0 }) { return true }
            guard let old = oldParagraphs[paragraph.range] else { return true }
            return !paragraph.hasSamePresentation(as: old)
        }
        let previousHidden = manager.hiddenCharacters
        displayedPlan = target
        publishMetadata(from: target)
        let maskChanges = previousHidden.symmetricDifference(manager.hiddenCharacters)
        pendingInvalidation += maskChanges.rangeView.map { NSRange(location: $0.lowerBound, length: $0.count) }
        lastAttributeUpdateRanges = changed.filter { $0.range.length > 0 }.map(\.range)
        pendingAttributeRanges = []
        guard !changed.isEmpty || !pendingInvalidation.isEmpty else {
            refreshTypingAttributes(from: target)
            return
        }

        let clip = textView.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        let undo = textView.undoManager
        let undoWasEnabled = undo?.isUndoRegistrationEnabled == true
        if undoWasEnabled { undo?.disableUndoRegistration() }
        isApplying = true
        if !changed.isEmpty {
            storage.beginEditing()
            for paragraph in changed { paragraph.applyAttributes(to: storage) }
            storage.endEditing()
        }
        invalidatePendingGlyphs()
        for paragraph in changed where paragraph.range.length > 0 {
            manager.ensureLayout(forCharacterRange: paragraph.range)
        }
        if let clip, let origin { clip.scroll(to: origin); textView.enclosingScrollView?.reflectScrolledClipView(clip) }
        isApplying = false
        if undoWasEnabled { undo?.enableUndoRegistration() }
        refreshTypingAttributes(from: target)
        textView.needsDisplay = true
    }

    /// AppKit may retain the preceding paragraph's typing font when display
    /// attributes change after a selection notification. Use only a verified,
    /// complete current paragraph; an edited paragraph without a cache keeps
    /// its native typing attributes until the new parse arrives.
    private func refreshTypingAttributes(from plan: MarkdownDisplayPlan?) {
        guard isEnabled, !isComposing, let textView, let plan,
              plan.source.utf8.elementsEqual(textView.string.utf8),
              textView.selectedRanges.count == 1 else { return }
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location != NSNotFound,
              selection.location <= (textView.string as NSString).length else { return }
        let currentRange = (textView.string as NSString).paragraphRange(for: selection)
        guard let paragraph = plan.paragraphs.first(where: { $0.range == currentRange }) else { return }
        let content = paragraph.resolvingExpansion([paragraph.range]).attributedString
        guard content.length > 0 else {
            textView.typingAttributes = MarkdownDisplayPlan.baseAttributes
            return
        }
        var offset = min(selection.location - paragraph.range.location, content.length - 1)
        let text = content.string as NSString
        while offset > 0 && (text.character(at: offset) == 10 || text.character(at: offset) == 13) {
            offset -= 1
        }
        textView.typingAttributes = content.attributes(at: offset, effectiveRange: nil)
    }

    private func invalidatePendingGlyphs() {
        guard nativeInputDepth == 0, let textView,
              let manager = textView.layoutManager as? MarkdownLayoutManager else { return }
        let length = (textView.string as NSString).length
        let ranges = pendingInvalidation
        pendingInvalidation = []
        for range in ranges where range.location <= length {
            let safeRange = NSRange(location: range.location, length: min(range.length, length - range.location))
            if safeRange.length > 0 {
                manager.invalidateGlyphs(forCharacterRange: safeRange, changeInLength: 0, actualCharacterRange: nil)
            }
        }
        if !ranges.isEmpty { textView.needsDisplay = true }
    }

    private func resetDisplay() {
        needsReset = false
        guard !isComposing, let textView, let storage = textView.textStorage,
              let manager = textView.layoutManager as? MarkdownLayoutManager else { needsReset = true; return }
        let undo = textView.undoManager
        let undoWasEnabled = undo?.isUndoRegistrationEnabled == true
        if undoWasEnabled { undo?.disableUndoRegistration() }
        isApplying = true
        storage.setAttributes(MarkdownDisplayPlan.baseAttributes, range: NSRange(location: 0, length: storage.length))
        textView.typingAttributes = MarkdownDisplayPlan.baseAttributes
        hiddenMarkers = []
        manager.hiddenCharacters = []
        manager.setDecorationParagraphs([])
        displayedPlan = nil
        pendingAttributeRanges = []
        lastAttributeUpdateRanges = [NSRange(location: 0, length: storage.length)]
        pendingInvalidation = [NSRange(location: 0, length: storage.length)]
        invalidatePendingGlyphs()
        isApplying = false
        if undoWasEnabled { undo?.enableUndoRegistration() }
        textView.needsDisplay = true
    }

    /// Keep existing presentation stable while a structural edit is reparsed,
    /// but never act on a task that may now belong to code, math or HTML source.
    private static func structuralTaskBoundary(source: String, range: NSRange) -> Int? {
        let text = source as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= text.length, range.length <= text.length - range.location else { return 0 }
        let affected = text.paragraphRange(for: range)
        let units = Array(text.substring(with: affected).utf16)
        if units.contains(where: { [UInt16(96), 126, 36, 60, 92].contains($0) }) { return affected.location }
        var indentation = 0
        var atLineStart = true
        for unit in units {
            if unit == 10 || unit == 13 {
                indentation = 0
                atLineStart = true
            } else if atLineStart, unit == 32 || unit == 9 {
                indentation += unit == 9 ? 4 - indentation % 4 : 1
                if indentation >= 4 { return affected.location }
            } else { atLineStart = false }
        }
        return nil
    }

    /// End-exclusive selections expand exactly the paragraphs containing selected characters.
    static func expandedRanges(source: String, selections: [NSRange], codeBlocks: [NSRange]) -> [NSRange] {
        let text = source as NSString
        var ranges: [NSRange] = []
        for selection in selections {
            guard selection.location != NSNotFound, selection.location <= text.length else { continue }
            let length = min(selection.length, text.length - selection.location)
            let paragraph = text.paragraphRange(for: NSRange(location: selection.location, length: length))
            ranges.append(paragraph)
            for block in codeBlocks where NSIntersectionRange(block, paragraph).length > 0 { ranges.append(block) }
        }
        return ranges
    }
}
