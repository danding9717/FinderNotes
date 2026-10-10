import Foundation

@MainActor
func verifyListContinuationPlans(_ checks: Checks) throws {
    func continued(_ source: String, selection: NSRange? = nil) throws -> String {
        let chosen = selection ?? NSRange(location: (source as NSString).length, length: 0)
        guard let plan = MarkdownListContinuation.plan(source: source, selection: chosen) else {
            throw CheckFailure("list continuation unexpectedly rejected \(source.debugDescription)")
        }
        try checks.expect(plan.range.location != NSNotFound && NSMaxRange(plan.range) <= (source as NSString).length, "list planner emits a bounded source replacement")
        return (source as NSString).replacingCharacters(in: plan.range, with: plan.replacement)
    }
    try checks.expect(try continued("1.this is a test.") == "1.this is a test.\n2. ", "compact ordered Return preserves old source and adds a spaced next prefix")
    try checks.expect(try continued("9)正文") == "9)正文\n10) ", "compact closing-parenthesis ordered prefix increments")
    try checks.expect(try continued("0. 正文") == "0. 正文\n1. ", "zero-based ordered source increments normally")
    try checks.expect(try continued("001. 正文") == "001. 正文\n2. ", "number increment does not rewrite the old leading-zero marker")
    try checks.expect(try continued("  12.  正文") == "  12.  正文\n  13.  ", "ordered continuation preserves indentation and existing separator width")
    try checks.expect(try continued("\t3)\t正文") == "\t3)\t正文\n\t4)\t", "ordered continuation preserves tab indentation and separator")
    for marker in ["-", "+", "*"] {
        let source = " \t\(marker) \t正文"
        try checks.expect(try continued(source) == source + "\n \t\(marker) \t", "unordered continuation preserves \(marker), indentation and separator")
    }
    try checks.expect(try continued("- 中文👩🏽‍🚀e\u{301}") == "- 中文👩🏽‍🚀e\u{301}\n- ", "Unicode source remains exact during continuation")

    for source in ["1.", "1. ", "  9)\t ", "-", "- \t", "\t+ ", "  *  "] {
        let indent = String(source.prefix { $0 == " " || $0 == "\t" })
        try checks.expect(try continued(source) == indent, "empty list Return removes only marker and separator without a newline")
    }
    try checks.expect(try continued("999999999. ") == "", "empty maximum-number item can still exit")
    try checks.expect(try continued("1. \u{00A0}") == "", "whitespace-only body exits as an empty item")
    try checks.expect(try continued("before\r\n1. text") == "before\r\n1. text\r\n2. ", "last-line continuation inherits the preceding CRLF style")
    try checks.expect(try continued("before\r1. text") == "before\r1. text\r2. ", "last-line continuation inherits a lone-CR line ending")
    let crlf = "1. hello\r\nnext"
    try checks.expect(try continued(crlf, selection: NSRange(location: 8, length: 0)) == "1. hello\r\n2. \r\nnext", "mid-document continuation preserves the current CRLF terminator")
    let split = "1. hello world"
    try checks.expect(try continued(split, selection: NSRange(location: 8, length: 0)) == "1. hello\n2.  world", "Return splits at the caret without rewriting adjacent source")
    try checks.expect(try continued(split, selection: NSRange(location: 3, length: 5)) == "1. \n2.  world", "single-line selection is replaced once by newline and next prefix")
    try checks.expect(try continued("1. first\n2. second", selection: NSRange(location: 8, length: 0)) == "1. first\n2. \n2. second", "continuation does not renumber a following existing item")
    try checks.expect(try continued("- \nnext", selection: NSRange(location: 2, length: 0)) == "\nnext", "empty exit retains the existing following line ending")

    for state in [" ", "x", "X"] {
        let source = "- [\(state)] 完成状态 👩🏽‍🚀"
        try checks.expect(try continued(source) == source + "\n- [ ] ", "task Return creates an unchecked item regardless of the old task state")
        try checks.expect(try continued("  - [\(state)] \t") == "  ", "empty task Return removes its complete prefix and retains indentation")
    }
    try checks.expect(try continued("9) [x] ordered") == "9) [x] ordered\n10) [ ] ", "ordered task continuation increments the list number and clears its checkbox")
    try checks.expect(try continued(" \t+ \t[X]\t中文") == " \t+ \t[X]\t中文\n \t+ \t[ ]\t", "task continuation retains both original separator runs and indentation")
    try checks.expect(try continued("before\r\n- [x] text") == "before\r\n- [x] text\r\n- [ ] ", "task continuation preserves CRLF source style")
    let taskSplit = "- [x] hello world"
    try checks.expect(try continued(taskSplit, selection: NSRange(location: 11, length: 0)) == "- [x] hello\n- [ ]  world", "task Return splits at the caret while clearing only the new checkbox")
    try checks.expect(try continued(taskSplit, selection: NSRange(location: 6, length: 5)) == "- [x] \n- [ ]  world", "task Return replaces a single-line body selection once")
    try checks.expect(try continued("- [y] literal") == "- [y] literal\n- ", "malformed checkbox source remains literal ordinary-list content")
    try checks.expect(try continued("- [ ]nospace") == "- [ ]nospace\n- ", "checkbox without a following separator is not promoted to a task")
    try checks.expect(try continued("- [ ]") == "- [ ]\n- ", "bare checkbox without a trailing separator keeps literal list content")
    for selection in [NSRange(location: 2, length: 0), NSRange(location: 3, length: 0), NSRange(location: 4, length: 0), NSRange(location: 5, length: 0), NSRange(location: 2, length: 3)] {
        try checks.expect(MarkdownListContinuation.plan(source: "- [x] text", selection: selection) == nil, "caret or selection inside a task prefix uses ordinary Return")
        try checks.expect(MarkdownListContinuation.plan(source: "- [ ] ", selection: selection) == nil, "empty task prefix cannot be removed by a marker-internal caret or selection")
    }

    let rejected = ["plain text", "-compact", "+compact", "*compact", "---", "***", "* * *", "- - -", "  ___", "> - quote", "> 1. quote", "１. fullwidth", "1234567890. too many digits", "999999999. maximum", "```\n1. code", "~~~swift\n- code", "````\n```\n1. still code", "~~~\n```\n1. still code", "\t```swift\n1. code", "- ```swift", "1. ```swift", "1) \t~~~swift", "- ```swift\n  1. code", "1. ```\n   - code", "1) ~~~\n   - code", "- - ```\n    1. code", "```\n- [ ] code task", "~~~swift\n1. [x] code task", "- ```\n  - [ ] nested code task"]
    for source in rejected {
        try checks.expect(MarkdownListContinuation.plan(source: source, selection: NSRange(location: (source as NSString).length, length: 0)) == nil, "planner preserves unsupported or fenced source: \(source.debugDescription)")
    }
    for source in ["```\n- ```\n1. still code", "~~~\n1. ~~~\n- still code"] {
        try checks.expect(MarkdownListContinuation.plan(source: source, selection: NSRange(location: (source as NSString).length, length: 0)) == nil, "list-like code content cannot close an active fence")
    }
    try checks.expect(try continued("```swift\n1. code\n```\n1. text") == "```swift\n1. code\n```\n1. text\n2. ", "ordered continuation resumes after a closed backtick fence")
    try checks.expect(try continued("~~~\n- code\n~~~~ \t\n- text") == "~~~\n- code\n~~~~ \t\n- text\n- ", "unordered continuation resumes after a longer matching tilde close")
    try checks.expect(try continued("```bad`info\n1. text") == "```bad`info\n1. text\n2. ", "invalid backtick info does not create a false open fence")
    try checks.expect(try continued("- ```swift\n  1. code\n  ```\n1. text") == "- ```swift\n  1. code\n  ```\n1. text\n2. ", "continuation resumes after a closed fence opened in a list body")
    try checks.expect(MarkdownListContinuation.plan(source: "12.  ", selection: NSRange(location: 1, length: 0)) == nil, "caret inside an empty item's marker uses ordinary Return")
    try checks.expect(MarkdownListContinuation.plan(source: "12.  ", selection: NSRange(location: 0, length: 1)) == nil, "selection inside an empty item's marker uses ordinary Return")
    try checks.expect(MarkdownListContinuation.plan(source: "12.  ", selection: NSRange(location: 4, length: 0)) == nil, "caret inside an empty item's separator uses ordinary Return")
    try checks.expect(MarkdownListContinuation.plan(source: "1. hello\n2. next", selection: NSRange(location: 3, length: 7)) == nil, "multiline selection uses ordinary Return")
    try checks.expect(MarkdownListContinuation.plan(source: "1. text", selection: NSRange(location: 1, length: 0)) == nil, "caret inside a nonempty marker uses ordinary Return")
    try checks.expect(MarkdownListContinuation.plan(source: "1. text", selection: NSRange(location: NSNotFound, length: 0)) == nil, "planner rejects NSNotFound selection")
    try checks.expect(MarkdownListContinuation.plan(source: "1. text", selection: NSRange(location: Int.max - 1, length: 4)) == nil, "planner rejects overflowing selection")
    try checks.expect(MarkdownListContinuation.plan(source: "1. text", selection: NSRange(location: 0, length: 99)) == nil, "planner rejects out-of-bounds selection")
    try checks.expect(MarkdownListContinuation.plan(source: "1. 😀", selection: NSRange(location: 4, length: 0)) == nil, "planner rejects a caret splitting a Unicode surrogate pair")
    try checks.expect(MarkdownListContinuation.plan(source: "1. a\r\nb", selection: NSRange(location: 5, length: 0)) == nil, "planner rejects a caret inside the CRLF pair")
}
