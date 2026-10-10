import Foundation

/// One replacement in unchanged-source UTF-16 coordinates. Old presentation
/// ranges can be retained only when they are wholly outside this replacement.
struct MarkdownTextEdit: Sendable {
    let oldRange: NSRange
    let newRange: NSRange
    var delta: Int { newRange.length - oldRange.length }

    /// AppKit reports the edited range in the new storage. Prefer that range
    /// when its surrounding UTF-16 source matches exactly; otherwise derive a
    /// conservative replacement from the complete old and new source strings.
    static func resolve(oldSource: String, newSource: String,
                        editedRange: NSRange, changeInLength: Int) -> MarkdownTextEdit? {
        guard !oldSource.utf8.elementsEqual(newSource.utf8) else { return nil }
        let old = Array(oldSource.utf16)
        let new = Array(newSource.utf16)
        let actualDelta = new.count - old.count
        if changeInLength == actualDelta,
           let newEnd = checkedEnd(editedRange), newEnd <= new.count {
            let (oldLength, overflow) = editedRange.length.subtractingReportingOverflow(changeInLength)
            if !overflow, oldLength >= 0 {
                let oldRange = NSRange(location: editedRange.location, length: oldLength)
                if let oldEnd = checkedEnd(oldRange), oldEnd <= old.count,
                   isScalarBoundary(editedRange.location, in: old),
                   isScalarBoundary(editedRange.location, in: new),
                   isScalarBoundary(oldEnd, in: old),
                   isScalarBoundary(newEnd, in: new),
                   old[..<editedRange.location].elementsEqual(new[..<editedRange.location]),
                   old[oldEnd...].elementsEqual(new[newEnd...]) {
                    return MarkdownTextEdit(oldRange: oldRange, newRange: editedRange)
                }
            }
        }

        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        // Shared high surrogates alone do not represent an unchanged scalar.
        while !isScalarBoundary(prefix, in: old) || !isScalarBoundary(prefix, in: new) { prefix -= 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        // A shared low surrogate likewise belongs to the replaced scalar.
        while !isScalarBoundary(old.count - suffix, in: old) ||
              !isScalarBoundary(new.count - suffix, in: new) { suffix -= 1 }
        return MarkdownTextEdit(oldRange: NSRange(location: prefix, length: old.count - prefix - suffix),
                                newRange: NSRange(location: prefix, length: new.count - prefix - suffix))
    }

    /// Map only unchanged old-source characters. At a pure insertion, a range
    /// ending at the insertion stays left, and a range starting there moves right.
    func mapUnchanged(_ range: NSRange) -> NSRange? {
        guard let end = Self.checkedEnd(range), let oldEnd = Self.checkedEnd(oldRange) else { return nil }
        if end <= oldRange.location { return range }
        if range.location >= oldEnd {
            let (location, overflow) = range.location.addingReportingOverflow(delta)
            guard !overflow, location >= 0 else { return nil }
            let mapped = NSRange(location: location, length: range.length)
            return Self.checkedEnd(mapped) == nil ? nil : mapped
        }
        return nil
    }

    /// Conservatively carry an affected region across the replacement, covering
    /// newly inserted characters. This is for invalidation/expansion, never hiding.
    func mapCovering(_ range: NSRange) -> NSRange? {
        guard let end = Self.checkedEnd(range), let oldEnd = Self.checkedEnd(oldRange),
              let newEnd = Self.checkedEnd(newRange) else { return nil }
        let start: Int
        if range.location <= oldRange.location { start = range.location }
        else if range.location >= oldEnd {
            let (shifted, overflow) = range.location.addingReportingOverflow(delta)
            guard !overflow else { return nil }
            start = shifted
        } else { start = oldRange.location }

        let mappedEnd: Int
        if oldRange.length == 0, end == oldRange.location {
            // Touching an insertion boundary is affected for a covering range,
            // even though the same left-hand boundary is unchanged for hiding.
            mappedEnd = newEnd
        } else if end <= oldRange.location { mappedEnd = end }
        else if end >= oldEnd {
            let (shifted, overflow) = end.addingReportingOverflow(delta)
            guard !overflow else { return nil }
            mappedEnd = shifted
        } else { mappedEnd = newEnd }
        guard start >= 0, mappedEnd >= start else { return nil }
        let mapped = NSRange(location: start, length: mappedEnd - start)
        return Self.checkedEnd(mapped) == nil ? nil : mapped
    }

    private static func checkedEnd(_ range: NSRange) -> Int? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        return overflow ? nil : end
    }

    private static func isScalarBoundary(_ offset: Int, in units: [UInt16]) -> Bool {
        guard offset >= 0, offset <= units.count else { return false }
        guard offset > 0, offset < units.count else { return true }
        return !(0xD800...0xDBFF).contains(units[offset - 1]) || !(0xDC00...0xDFFF).contains(units[offset])
    }
}
