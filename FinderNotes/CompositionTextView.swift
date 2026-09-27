import AppKit

/// Committing marked text can leave its bytes unchanged, without a textDidChange notification.
/// Observe the native input methods after AppKit has settled its marked-text state.
@MainActor
final class CompositionTextView: NSTextView {
    var inputStateDidChange: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        inputStateDidChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        inputStateDidChange?()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        inputStateDidChange?()
    }
}
