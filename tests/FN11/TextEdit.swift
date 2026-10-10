import Foundation

@MainActor
func verifyTextEdits(_ checks: Checks) throws {
    func resolve(_ old: String, _ new: String, _ range: NSRange, _ delta: Int) throws -> MarkdownTextEdit {
        guard let result = MarkdownTextEdit.resolve(oldSource: old, newSource: new, editedRange: range, changeInLength: delta) else {
            throw CheckFailure("changed text unexpectedly has no resolved edit")
        }
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        let oldEnd = NSMaxRange(result.oldRange)
        let newEnd = NSMaxRange(result.newRange)
        try checks.expect(result.oldRange.location == result.newRange.location, "resolved replacements share their unchanged-prefix boundary")
        try checks.expect(oldUnits[..<result.oldRange.location].elementsEqual(newUnits[..<result.newRange.location]), "resolved edit preserves exact UTF-16 prefix")
        try checks.expect(oldUnits[oldEnd...].elementsEqual(newUnits[newEnd...]), "resolved edit preserves exact UTF-16 suffix")
        try checks.expect(result.delta == newUnits.count - oldUnits.count, "resolved edit delta matches complete source length change")
        return result
    }

    let insertion = try resolve("ab", "aXb", NSRange(location: 1, length: 1), 1)
    try checks.expect(insertion.oldRange == NSRange(location: 1, length: 0) && insertion.newRange == NSRange(location: 1, length: 1), "valid AppKit insertion resolves in old and new coordinates")
    try checks.expect(insertion.mapUnchanged(NSRange(location: 0, length: 1)) == NSRange(location: 0, length: 1), "range ending at insertion remains left")
    try checks.expect(insertion.mapUnchanged(NSRange(location: 1, length: 1)) == NSRange(location: 2, length: 1), "range starting at insertion moves right without hiding inserted text")
    try checks.expect(insertion.mapUnchanged(NSRange(location: 0, length: 2)) == nil, "insertion drops a presentation range crossing the inserted characters")
    try checks.expect(insertion.mapUnchanged(NSRange(location: 1, length: 0)) == NSRange(location: 1, length: 0), "zero-length insertion boundary follows the left-end rule")
    try checks.expect(insertion.mapCovering(NSRange(location: 0, length: 1)) == NSRange(location: 0, length: 2), "covering range ending at insertion includes new characters")
    try checks.expect(insertion.mapCovering(NSRange(location: 1, length: 1)) == NSRange(location: 1, length: 2), "covering range starting at insertion includes new characters")
    try checks.expect(insertion.mapCovering(NSRange(location: 1, length: 0)) == insertion.newRange, "zero-length covering range at insertion becomes the new characters")
    try checks.expect(insertion.mapCovering(NSRange(location: 0, length: 0)) == NSRange(location: 0, length: 0), "covering range strictly before insertion remains unchanged")
    try checks.expect(insertion.mapCovering(NSRange(location: 2, length: 1)) == NSRange(location: 3, length: 1), "covering range strictly after insertion shifts right")

    let replacement = try resolve("abcDEFghi", "abcXghi", NSRange(location: 3, length: 1), -2)
    try checks.expect(replacement.oldRange == NSRange(location: 3, length: 3), "AppKit replacement computes old length from new range and delta")
    try checks.expect(replacement.mapUnchanged(NSRange(location: 6, length: 3)) == NSRange(location: 4, length: 3), "right-side range rebases after a shorter replacement")
    try checks.expect(replacement.mapUnchanged(NSRange(location: 3, length: 3)) == nil, "replaced source receives no inherited presentation range")
    try checks.expect(replacement.mapUnchanged(NSRange(location: 2, length: 2)) == nil, "partially intersecting source receives no inherited presentation range")
    try checks.expect(replacement.mapCovering(NSRange(location: 4, length: 1)) == replacement.newRange, "covering range inside replacement becomes the complete new replacement")
    try checks.expect(replacement.mapCovering(NSRange(location: 2, length: 2)) == NSRange(location: 2, length: 2), "left intersection conservatively extends to new replacement end")
    try checks.expect(replacement.mapCovering(NSRange(location: 4, length: 4)) == NSRange(location: 3, length: 3), "right intersection conservatively begins at replacement start")
    try checks.expect(replacement.mapCovering(NSRange(location: 0, length: 3)) == NSRange(location: 0, length: 3), "covering range ending before nonempty replacement stays unchanged")
    try checks.expect(replacement.mapCovering(NSRange(location: 6, length: 2)) == NSRange(location: 4, length: 2), "covering range beginning at replacement end shifts by delta")

    let deletion = try resolve("abc", "ac", NSRange(location: 1, length: 0), -1)
    try checks.expect(deletion.oldRange == NSRange(location: 1, length: 1) && deletion.newRange == NSRange(location: 1, length: 0), "deletion keeps its exact old and new boundaries")
    try checks.expect(deletion.mapUnchanged(NSRange(location: 2, length: 1)) == NSRange(location: 1, length: 1), "range after deletion maps to the collapsed new boundary")
    try checks.expect(deletion.mapUnchanged(NSRange(location: 1, length: 1)) == nil, "deleted character cannot retain hidden-marker state")

    let invalid = NSRange(location: NSNotFound, length: 0)
    let fallback = try resolve("abXcdYef", "abQcdRef", invalid, Int.max)
    try checks.expect(fallback.oldRange == NSRange(location: 2, length: 4) && fallback.newRange == NSRange(location: 2, length: 4), "invalid AppKit metadata falls back to one conservative replacement")
    let wrongLocation = try resolve("abc", "aXbc", NSRange(location: 2, length: 1), 1)
    try checks.expect(wrongLocation.oldRange == NSRange(location: 1, length: 0), "mismatched candidate prefix triggers source-based fallback")
    let wrongDelta = try resolve("abc", "aXc", NSRange(location: 1, length: 1), 2)
    try checks.expect(wrongDelta.oldRange == NSRange(location: 1, length: 1) && wrongDelta.delta == 0, "invalid candidate delta cannot distort old source coordinates")
    let broadCandidate = try resolve("abc", "aXc", NSRange(location: 0, length: 3), 0)
    try checks.expect(broadCandidate.oldRange == NSRange(location: 0, length: 3), "verified AppKit replacement is retained even when its range is conservative")

    let emoji = try resolve("a😀z", "a😃z", invalid, 0)
    try checks.expect(emoji.oldRange == NSRange(location: 1, length: 2) && emoji.newRange == NSRange(location: 1, length: 2), "fallback expands a shared high surrogate to complete Unicode scalars")
    let sharedLowSurrogate = try resolve("\u{10000}", "\u{10400}", invalid, 0)
    try checks.expect(sharedLowSurrogate.oldRange == NSRange(location: 0, length: 2) && sharedLowSurrogate.newRange == NSRange(location: 0, length: 2), "fallback expands a shared low surrogate to complete Unicode scalars")
    let splitCandidate = try resolve("a😀b", "aX😀b", NSRange(location: 2, length: 1), 1)
    try checks.expect(splitCandidate.oldRange == NSRange(location: 1, length: 0) && splitCandidate.newRange == NSRange(location: 1, length: 1), "candidate splitting an old surrogate pair falls back safely")
    let normalized = try resolve("é", "e\u{301}", invalid, 1)
    try checks.expect(normalized.oldRange == NSRange(location: 0, length: 1) && normalized.newRange == NSRange(location: 0, length: 2), "canonically equivalent but byte-different strings are real edits")
    let combining = try resolve("e\u{301}", "a\u{301}", invalid, 0)
    try checks.expect(combining.oldRange == NSRange(location: 0, length: 1) && combining.newRange == NSRange(location: 0, length: 1), "scalar boundaries preserve an unchanged combining scalar")
    let crlf = try resolve("a\r\nb", "a\nb", invalid, -1)
    try checks.expect(crlf.oldRange == NSRange(location: 1, length: 1) && crlf.newRange == NSRange(location: 1, length: 0), "CRLF edits preserve exact remaining line-break units")

    try checks.expect(MarkdownTextEdit.resolve(oldSource: "", newSource: "", editedRange: invalid, changeInLength: Int.max) == nil, "unchanged empty bytes have no edit")
    try checks.expect(MarkdownTextEdit.resolve(oldSource: "👩🏽‍🚀 e\u{301}", newSource: "👩🏽‍🚀 e\u{301}", editedRange: NSRange(location: 0, length: 1), changeInLength: 1) == nil, "unchanged Unicode bytes have no edit regardless of candidate metadata")
    try checks.expect(insertion.mapUnchanged(invalid) == nil, "mapping rejects NSNotFound")
    try checks.expect(insertion.mapCovering(invalid) == nil, "covering mapping rejects NSNotFound")
    try checks.expect(insertion.mapUnchanged(NSRange(location: Int.max - 1, length: 3)) == nil, "mapping rejects an overflowing old range")
    try checks.expect(insertion.mapUnchanged(NSRange(location: Int.max - 1, length: 1)) == nil, "mapping rejects overflow after shifting a right range")
    try checks.expect(insertion.mapCovering(NSRange(location: Int.max - 1, length: 1)) == nil, "covering mapping rejects overflow after shifting a right range")
}
