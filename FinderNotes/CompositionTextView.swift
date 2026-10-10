import AppKit

/// Committing marked text can leave its bytes unchanged, without a textDidChange notification.
/// Observe the native input methods after AppKit has settled its marked-text state.
@MainActor
final class CompositionTextView: NSTextView {
    var inputStateDidChange: (() -> Void)?
    var inputStateWillChange: (() -> Void)?
    var continuesMarkdownLists: (() -> Bool)?
    var markdownTaskClickHandler: ((NSPoint) -> Bool)?

    /// Construct TextKit 1 explicitly; the display layer needs its glyph-generation delegate.
    convenience init() {
        let storage = NSTextStorage()
        let manager = MarkdownLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    override func paste(_ sender: Any?) {
        // Foreign RTF/HTML styles must never become the document or its typing attributes.
        pasteAsPlainText(sender)
    }

    /// Local view coordinates keep drawing and hit testing on the same geometry.
    func handleMarkdownTaskClick(at point: NSPoint) -> Bool {
        markdownTaskClickHandler?(point) == true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !handleMarkdownTaskClick(at: point) else { return }
        super.mouseDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable, continuesMarkdownLists?() == true, !hasMarkedText(),
              selectedRanges.count == 1,
              let continuation = MarkdownListContinuation.plan(source: string, selection: selectedRange()) else {
            super.insertNewline(sender)
            return
        }
        // Keep Return and its generated prefix in one native edit and undo step.
        // Paste and input-method commits continue through their normal routes.
        breakUndoCoalescing()
        insertText(continuation.replacement, replacementRange: continuation.range)
        breakUndoCoalescing()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inputStateWillChange?()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        inputStateDidChange?()
    }

    override func unmarkText() {
        inputStateWillChange?()
        super.unmarkText()
        inputStateDidChange?()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        inputStateWillChange?()
        super.insertText(string, replacementRange: replacementRange)
        inputStateDidChange?()
    }
}
