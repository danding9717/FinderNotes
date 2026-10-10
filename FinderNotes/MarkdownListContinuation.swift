import Foundation

/// One native text replacement for an ordinary Return in a Markdown list.
/// The caller owns input-method, mode and undo handling; this planner edits no state.
struct MarkdownListContinuation: Sendable {
    let range: NSRange
    let replacement: String

    static func plan(source: String, selection: NSRange) -> MarkdownListContinuation? {
        let units = Array(source.utf16)
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0 else { return nil }
        let (selectionEnd, overflow) = selection.location.addingReportingOverflow(selection.length)
        guard !overflow, selectionEnd <= units.count,
              scalarBoundary(selection.location, units), scalarBoundary(selectionEnd, units) else { return nil }
        let lines = sourceLines(units)
        guard let lineIndex = lines.firstIndex(where: { selection.location >= $0.start && selection.location <= $0.contentEnd }) else { return nil }
        let line = lines[lineIndex]
        guard selectionEnd <= line.contentEnd, !insideFence(lines: lines, before: lineIndex, units: units),
              openingFence(line: line, units: units) == nil else { return nil }

        var markerStart = line.start
        while markerStart < line.contentEnd, horizontalSpace(units[markerStart]) { markerStart += 1 }
        guard markerStart < line.contentEnd, !isRule(markerStart..<line.contentEnd, units) else { return nil }
        var cursor = markerStart
        var nextMarker: String?
        var ordered = false
        if (48...57).contains(units[cursor]) {
            ordered = true
            var number = 0
            while cursor < line.contentEnd, (48...57).contains(units[cursor]) {
                guard cursor - markerStart < 9 else { return nil }
                number = number * 10 + Int(units[cursor] - 48)
                cursor += 1
            }
            guard cursor < line.contentEnd, units[cursor] == 46 || units[cursor] == 41 else { return nil }
            let punctuation = units[cursor] == 46 ? "." : ")"
            cursor += 1
            if number < 999_999_999 { nextMarker = "\(number + 1)\(punctuation)" }
        } else if [UInt16(45), 43, 42].contains(units[cursor]) {
            nextMarker = String(UnicodeScalar(units[cursor])!)
            cursor += 1
        } else { return nil }
        let separatorStart = cursor
        while cursor < line.contentEnd, horizontalSpace(units[cursor]) { cursor += 1 }
        guard ordered || cursor > separatorStart || cursor == line.contentEnd else { return nil }
        let listBodyStart = cursor
        let nsSource = source as NSString
        var taskSuffix = ""
        if cursor > separatorStart, taskCheckbox(cursor..<line.contentEnd, units) {
            cursor += 3
            let taskSeparatorStart = cursor
            while cursor < line.contentEnd, horizontalSpace(units[cursor]) { cursor += 1 }
            let separator = nsSource.substring(with: NSRange(location: taskSeparatorStart, length: cursor - taskSeparatorStart))
            taskSuffix = "[ ]" + separator
        }
        let bodyStart = cursor
        let body = nsSource.substring(with: NSRange(location: bodyStart, length: line.contentEnd - bodyStart))
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard selection.location >= bodyStart else { return nil }
            return MarkdownListContinuation(range: NSRange(location: markerStart, length: line.contentEnd - markerStart), replacement: "")
        }
        guard selection.location >= bodyStart, let nextMarker else { return nil }
        let indent = nsSource.substring(with: NSRange(location: line.start, length: markerStart - line.start))
        var separator = nsSource.substring(with: NSRange(location: separatorStart, length: listBodyStart - separatorStart))
        if separator.isEmpty { separator = " " }
        let newline: String
        if line.end > line.contentEnd {
            newline = nsSource.substring(with: NSRange(location: line.contentEnd, length: line.end - line.contentEnd))
        } else if let previous = lines[..<lineIndex].last(where: { $0.end > $0.contentEnd }) {
            newline = nsSource.substring(with: NSRange(location: previous.contentEnd, length: previous.end - previous.contentEnd))
        } else { newline = "\n" }
        return MarkdownListContinuation(range: selection, replacement: newline + indent + nextMarker + separator + taskSuffix)
    }

    private struct Line {
        let start: Int
        let contentEnd: Int
        let end: Int
    }

    private static func sourceLines(_ units: [UInt16]) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var cursor = 0
        while cursor < units.count {
            if units[cursor] == 10 || units[cursor] == 13 {
                let contentEnd = cursor
                if units[cursor] == 13, cursor + 1 < units.count, units[cursor + 1] == 10 { cursor += 1 }
                cursor += 1
                lines.append(Line(start: start, contentEnd: contentEnd, end: cursor))
                start = cursor
            } else { cursor += 1 }
        }
        lines.append(Line(start: start, contentEnd: units.count, end: units.count))
        return lines
    }

    /// Conservatively protect fences even with list indentation. Only a matching
    /// character run at least as long, followed by whitespace, closes the fence.
    private static func insideFence(lines: [Line], before target: Int, units: [UInt16]) -> Bool {
        var open: (character: UInt16, count: Int)?
        for line in lines[..<target] {
            guard let fence = open else {
                open = openingFence(line: line, units: units)
                continue
            }
            var start = line.start
            while start < line.contentEnd, horizontalSpace(units[start]) { start += 1 }
            guard start < line.contentEnd else { continue }
            let character = units[start]
            guard character == 96 || character == 126 else { continue }
            var end = start
            while end < line.contentEnd, units[end] == character { end += 1 }
            let count = end - start
            if character == fence.character, count >= fence.count,
               units[end..<line.contentEnd].allSatisfy({ horizontalSpace($0) }) { open = nil }
        }
        return open != nil
    }

    /// A fence may begin in the body of an indented list item. Require a real
    /// separator before skipping each list prefix; compact ordered text remains text.
    private static func openingFence(line: Line, units: [UInt16]) -> (character: UInt16, count: Int)? {
        var start = line.start
        while start < line.contentEnd, horizontalSpace(units[start]) { start += 1 }
        while let bodyStart = spacedListBody(start: start, end: line.contentEnd, units: units) { start = bodyStart }
        guard start < line.contentEnd, units[start] == 96 || units[start] == 126 else { return nil }
        let character = units[start]
        var end = start
        while end < line.contentEnd, units[end] == character { end += 1 }
        guard end - start >= 3 else { return nil }
        if character == 96, units[end..<line.contentEnd].contains(96) { return nil }
        return (character, end - start)
    }

    private static func spacedListBody(start: Int, end: Int, units: [UInt16]) -> Int? {
        guard start < end else { return nil }
        var cursor = start
        if (48...57).contains(units[cursor]) {
            while cursor < end, (48...57).contains(units[cursor]) {
                guard cursor - start < 9 else { return nil }
                cursor += 1
            }
            guard cursor < end, units[cursor] == 46 || units[cursor] == 41 else { return nil }
            cursor += 1
        } else if [UInt16(45), 43, 42].contains(units[cursor]) { cursor += 1 }
        else { return nil }
        guard cursor < end, horizontalSpace(units[cursor]) else { return nil }
        while cursor < end, horizontalSpace(units[cursor]) { cursor += 1 }
        return cursor
    }

    private static func isRule(_ range: Range<Int>, _ units: [UInt16]) -> Bool {
        let marks = units[range].filter { !horizontalSpace($0) }
        guard let first = marks.first, [UInt16(45), 42, 95].contains(first), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func taskCheckbox(_ range: Range<Int>, _ units: [UInt16]) -> Bool {
        guard range.count >= 3, units[range.lowerBound] == 91,
              [UInt16(32), 120, 88].contains(units[range.lowerBound + 1]), units[range.lowerBound + 2] == 93 else { return false }
        return range.count > 3 && horizontalSpace(units[range.lowerBound + 3])
    }

    private static func horizontalSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }

    private static func scalarBoundary(_ offset: Int, _ units: [UInt16]) -> Bool {
        guard offset >= 0, offset <= units.count else { return false }
        guard offset > 0, offset < units.count else { return true }
        return !(0xD800...0xDBFF).contains(units[offset - 1]) || !(0xDC00...0xDFFF).contains(units[offset])
    }
}
