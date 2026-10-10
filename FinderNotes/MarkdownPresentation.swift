import Foundation
import Markdown

/// A description of presentation attributes only. All offsets refer to the unchanged source.
struct MarkdownPresentation: Sendable {
    struct Span: Sendable {
        let range: NSRange
        let style: Style
    }

    enum Style: Sendable, Equatable {
        case heading(Int), strong, emphasis, strikethrough, quote, list, link, rule, code, codeBlock
        case task(Bool)
    }

    let source: String
    let spans: [Span]
    let markers: [NSRange]
    let codeBlocks: [NSRange]

    static func parse(_ source: String) -> MarkdownPresentation {
        var parser = PresentationParser(source: source)
        return parser.parse()
    }
}

private struct PresentationParser {
    let source: String
    let map: MarkdownSourceMap
    var spans: [MarkdownPresentation.Span] = []
    var markers: [Range<Int>] = []
    var codeBlocks: [NSRange] = []
    var protected: [Range<Int>] = []
    var verbatim: [Range<Int>] = []

    init(source: String) {
        self.source = source
        map = MarkdownSourceMap(source)
    }

    mutating func parse() -> MarkdownPresentation {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        collectUnsupported(document)
        protectMath()
        visit(document, ancestorMarkers: [])
        let visibleMarkers = Set(markers.compactMap { map.nsRange($0) })
            .sorted { $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location }
        return MarkdownPresentation(source: source, spans: spans, markers: visibleMarkers, codeBlocks: codeBlocks)
    }

    /// Unsupported constructs retain their source, including nested Markdown syntax.
    mutating func collectUnsupported(_ node: any Markup) {
        if node is CodeBlock || node is InlineCode, let range = map.byteRange(node.range) {
            verbatim.append(range)
        }
        let unsupported = node is Table || node is Image || node is HTMLBlock ||
            (node is Paragraph && containsInlineHTML(node))
        if unsupported {
            if let range = map.byteRange(node.range) { protected.append(range) }
            return
        }
        for child in node.children { collectUnsupported(child) }
    }

    func containsInlineHTML(_ node: any Markup) -> Bool {
        node is InlineHTML || node.children.contains { containsInlineHTML($0) }
    }

    mutating func visit(_ node: any Markup, ancestorMarkers: [Range<Int>]) {
        if let range = map.byteRange(node.range), protected.contains(where: { $0.overlaps(range) }) {
            if protected.contains(where: { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }) { return }
            let task = (node as? ListItem).flatMap { taskMarker($0, range: range) }
            if task == nil || protected.contains(where: { $0.overlaps(task!.range) }) {
                // Preserve the unsupported fragment and still visit ordinary siblings.
                for child in node.children { visit(child, ancestorMarkers: ancestorMarkers) }
                return
            }
        }
        var localMarkers: [Range<Int>] = []
        if let range = map.byteRange(node.range), !range.isEmpty {
            switch node {
            case let heading as Heading:
                if let result = headingMarkers(heading, range: range) {
                    appendSpan(result.range, .heading(heading.level))
                    localMarkers = result.markers
                }
            case is Strong:
                localMarkers = emphasisMarkers(node, range: range, width: 2, ancestors: ancestorMarkers)
                if !localMarkers.isEmpty { appendSpan(range, .strong) }
            case is Emphasis:
                localMarkers = emphasisMarkers(node, range: range, width: 1, ancestors: ancestorMarkers)
                if !localMarkers.isEmpty { appendSpan(range, .emphasis) }
            case is Strikethrough:
                localMarkers = pairedMarkers(range, byte: 126, width: 2)
                if !localMarkers.isEmpty { appendSpan(range, .strikethrough) }
            case is InlineCode:
                let width = run(96, from: range.lowerBound, to: range.upperBound)
                if width > 0, runBackward(96, in: range) == width, range.count > width * 2 {
                    appendSpan(range, .code)
                    localMarkers = [range.lowerBound..<(range.lowerBound + width), (range.upperBound - width)..<range.upperBound]
                }
            case is CodeBlock:
                if let fence = fenceMarkers(node, range: range) {
                    appendSpan(range, .codeBlock)
                    localMarkers = fence
                    if let nsRange = map.nsRange(range) { codeBlocks.append(nsRange) }
                } else if map.bytes[range.lowerBound] != 96 && map.bytes[range.lowerBound] != 126 {
                    // Indented code has no delimiter to hide.
                    appendSpan(range, .codeBlock)
                }
            case is BlockQuote:
                appendSpan(range, .quote)
                localMarkers = quoteMarkers(node, range: range)
            case let item as ListItem:
                if let task = taskMarker(item, range: range) {
                    appendSpan(range, .task(task.checked))
                    localMarkers = [task.range]
                } else if item.checkbox == nil, let marker = listMarker(range) {
                    appendSpan(range, .list)
                    localMarkers = [marker]
                }
            case is Link:
                localMarkers = linkMarkers(range)
                if !localMarkers.isEmpty { appendSpan(range, .link) }
            case is ThematicBreak:
                // cmark may include the following line's column 1 in a rule's
                // range. A rule is one line, and its line ending stays visible.
                let end = node.range.map { map.lines[$0.lowerBound.line - 1].end } ?? range.upperBound
                let ruleRange = range.lowerBound..<min(end, range.upperBound)
                let body = map.bytes[ruleRange].filter { $0 != 32 && $0 != 9 }
                if let byte = body.first, [UInt8(42), 45, 95].contains(byte), body.count >= 3, body.allSatisfy({ $0 == byte }) {
                    appendSpan(ruleRange, .rule)
                    localMarkers = [ruleRange]
                }
            default:
                break
            }
        }
        markers.append(contentsOf: localMarkers)
        for child in node.children { visit(child, ancestorMarkers: ancestorMarkers + localMarkers) }
    }

    mutating func appendSpan(_ range: Range<Int>, _ style: MarkdownPresentation.Style) {
        if let nsRange = map.nsRange(range), nsRange.length > 0 { spans.append(.init(range: nsRange, style: style)) }
    }

    func pairedMarkers(_ range: Range<Int>, byte: UInt8, width: Int) -> [Range<Int>] {
        guard range.count > width * 2,
              run(byte, from: range.lowerBound, to: range.upperBound) == width,
              runBackward(byte, in: range) == width else { return [] }
        return [range.lowerBound..<(range.lowerBound + width), (range.upperBound - width)..<range.upperBound]
    }

    /// cmark shares delimiter-run ranges between nested emphasis nodes. Account for
    /// the complete AST edge before hiding any part of that run; unmatched extras stay visible.
    func emphasisMarkers(_ node: any Markup, range: Range<Int>, width: Int, ancestors: [Range<Int>]) -> [Range<Int>] {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, ancestors.contains(where: { $0.contains(lower) }) { lower += 1 }
        while lower < upper, ancestors.contains(where: { $0.contains(upper - 1) }) { upper -= 1 }
        guard lower < upper, [UInt8(42), 95].contains(map.bytes[lower]) else { return [] }
        let byte = map.bytes[lower]
        let available = lower..<upper
        guard run(byte, from: lower, to: upper) == emphasisEdgeWidth(node, opening: true),
              runBackward(byte, in: available) == emphasisEdgeWidth(node, opening: false),
              available.count > width * 2 else { return [] }
        return [lower..<(lower + width), (upper - width)..<upper]
    }

    func emphasisEdgeWidth(_ node: any Markup, opening: Bool) -> Int {
        let width = node is Strong ? 2 : node is Emphasis ? 1 : 0
        guard width > 0, let range = node.range else { return 0 }
        let nested = node.children.compactMap { child -> Int? in
            guard child is Strong || child is Emphasis, let childRange = child.range,
                  opening ? childRange.lowerBound == range.lowerBound : childRange.upperBound == range.upperBound else { return nil }
            return emphasisEdgeWidth(child, opening: opening)
        }.max() ?? 0
        return width + nested
    }

    func headingMarkers(_ node: Heading, range: Range<Int>) -> (range: Range<Int>, markers: [Range<Int>])? {
        guard let positions = node.range else { return nil }
        let firstLine = map.lines[positions.lowerBound.line - 1]
        if map.bytes[range.lowerBound] == 35 {
            let count = run(35, from: range.lowerBound, to: firstLine.end)
            guard count == node.level, count <= 6 else { return nil }
            var end = range.lowerBound + count
            guard end == firstLine.end || isSpace(map.bytes[end]) else { return nil }
            while end < firstLine.end, isSpace(map.bytes[end]) { end += 1 }
            var result = [range.lowerBound..<end]
            var suffixEnd = firstLine.end
            while suffixEnd > end, isSpace(map.bytes[suffixEnd - 1]) { suffixEnd -= 1 }
            var suffixStart = suffixEnd
            while suffixStart > end, map.bytes[suffixStart - 1] == 35 { suffixStart -= 1 }
            if suffixStart < suffixEnd, suffixStart > end, isSpace(map.bytes[suffixStart - 1]) {
                while suffixStart > end, isSpace(map.bytes[suffixStart - 1]) { suffixStart -= 1 }
                result.append(suffixStart..<firstLine.end)
            }
            return (range.lowerBound..<firstLine.end, result)
        }
        // Setext heading underlines occupy a separate source line.
        let lastLine = map.lines[positions.upperBound.line - 1]
        var start = lastLine.start
        while start < lastLine.end, map.bytes[start] == 32 { start += 1 }
        let byte: UInt8 = node.level == 1 ? 61 : 45
        let count = run(byte, from: start, to: lastLine.end)
        guard positions.upperBound.line > positions.lowerBound.line, count > 0,
              map.bytes[(start + count)..<lastLine.end].allSatisfy({ isSpace($0) }) else { return nil }
        return (range, [start..<lastLine.end])
    }

    func fenceMarkers(_ node: any Markup, range: Range<Int>) -> [Range<Int>]? {
        guard let positions = node.range, positions.upperBound.line > positions.lowerBound.line else { return nil }
        let firstLine = map.lines[positions.lowerBound.line - 1]
        let lastLine = map.lines[positions.upperBound.line - 1]
        let byte = map.bytes[range.lowerBound]
        guard byte == 96 || byte == 126 else { return nil }
        let openingCount = run(byte, from: range.lowerBound, to: firstLine.end)
        guard openingCount >= 3 else { return nil }
        var closingStart = lastLine.start
        var quoteDepth = 0
        var parent = node.parent
        var inList = false
        while let current = parent {
            if current is BlockQuote { quoteDepth += 1 }
            if current is ListItem { inList = true }
            parent = current.parent
        }
        let indentAllowance = inList ? positions.lowerBound.column + 2 : 3
        for _ in 0..<quoteDepth {
            var spaces = 0
            while closingStart < lastLine.end, map.bytes[closingStart] == 32, spaces < indentAllowance {
                closingStart += 1
                spaces += 1
            }
            guard closingStart < lastLine.end, map.bytes[closingStart] == 62 else { return nil }
            closingStart += 1
            if closingStart < lastLine.end, isSpace(map.bytes[closingStart]) { closingStart += 1 }
        }
        var spaces = 0
        while closingStart < lastLine.end, map.bytes[closingStart] == 32, spaces < indentAllowance {
            closingStart += 1
            spaces += 1
        }
        let closingCount = run(byte, from: closingStart, to: lastLine.end)
        guard closingCount >= openingCount,
              map.bytes[(closingStart + closingCount)..<lastLine.end].allSatisfy({ isSpace($0) }) else { return nil }
        return [range.lowerBound..<firstLine.end, closingStart..<lastLine.end]
    }

    func quoteMarkers(_ node: any Markup, range: Range<Int>) -> [Range<Int>] {
        guard let positions = node.range else { return [] }
        var quoteDepth = 0
        var inList = false
        var parent = node.parent
        while let current = parent {
            if current is BlockQuote { quoteDepth += 1 }
            if current is ListItem { inList = true }
            parent = current.parent
        }
        let indentAllowance = inList ? positions.lowerBound.column + 2 : 3
        var result: [Range<Int>] = []
        for number in positions.lowerBound.line...positions.upperBound.line {
            let line = map.lines[number - 1]
            var cursor = number == positions.lowerBound.line ? range.lowerBound : line.start
            let prefixesToSkip = number == positions.lowerBound.line ? 0 : quoteDepth
            for level in 0...prefixesToSkip {
                var spaces = 0
                while cursor < line.end, map.bytes[cursor] == 32, spaces < indentAllowance {
                    cursor += 1
                    spaces += 1
                }
                guard cursor < line.end, map.bytes[cursor] == 62 else { break }
                let start = cursor
                cursor += 1
                if cursor < line.end, isSpace(map.bytes[cursor]) { cursor += 1 }
                if level == prefixesToSkip { result.append(start..<cursor) }
            }
        }
        return result
    }

    func listMarker(_ range: Range<Int>) -> Range<Int>? {
        var cursor = range.lowerBound
        if [UInt8(42), 43, 45].contains(map.bytes[cursor]) { cursor += 1 }
        else {
            while cursor < range.upperBound, (48...57).contains(map.bytes[cursor]) { cursor += 1 }
            guard cursor > range.lowerBound, cursor - range.lowerBound <= 9,
                  cursor < range.upperBound, map.bytes[cursor] == 46 || map.bytes[cursor] == 41 else { return nil }
            cursor += 1
        }
        guard cursor == range.upperBound || isSpace(map.bytes[cursor]) else { return nil }
        if cursor < range.upperBound { cursor += 1 }
        return range.lowerBound..<cursor
    }

    /// Keep the display and click target bound to an AST list item's exact source
    /// prefix. The span starts at the list marker, never at its indentation.
    func taskMarker(_ item: ListItem, range: Range<Int>) -> (range: Range<Int>, checked: Bool)? {
        guard let sourceRange = item.range,
              let list = listMarker(range) else { return nil }
        // cmark-gfm omits checkbox metadata within block quotes. Only that known
        // AST omission permits source validation to supply the task state.
        if item.checkbox == nil {
            var parent = item.parent
            while let ancestor = parent, !(ancestor is BlockQuote) { parent = ancestor.parent }
            guard parent is BlockQuote else { return nil }
        }
        let lineEnd = map.lines[sourceRange.lowerBound.line - 1].end
        var cursor = list.upperBound
        while cursor < lineEnd, isSpace(map.bytes[cursor]) { cursor += 1 }
        guard cursor + 3 < lineEnd, map.bytes[cursor] == 91, map.bytes[cursor + 2] == 93,
              isSpace(map.bytes[cursor + 3]) else { return nil }
        let state = map.bytes[cursor + 1]
        guard state == 32 || state == 120 || state == 88 else { return nil }
        let checked = state != 32
        if let checkbox = item.checkbox {
            switch checkbox {
            case .checked: guard checked else { return nil }
            case .unchecked: guard !checked else { return nil }
            }
        }
        cursor += 3
        while cursor < lineEnd, isSpace(map.bytes[cursor]) { cursor += 1 }
        return (range.lowerBound..<cursor, checked)
    }

    func linkMarkers(_ range: Range<Int>) -> [Range<Int>] {
        let first = range.lowerBound
        let last = range.upperBound - 1
        if map.bytes[first] == 60, map.bytes[last] == 62 { return [first..<(first + 1), last..<range.upperBound] }
        guard map.bytes[first] == 91 else { return [] }
        var depth = 1
        var cursor = first + 1
        while cursor < range.upperBound {
            if map.bytes[cursor] == 92 { cursor += 2; continue }
            if map.bytes[cursor] == 91 { depth += 1 }
            if map.bytes[cursor] == 93 { depth -= 1 }
            if depth == 0 {
                let next = cursor + 1
                if next == range.upperBound ||
                    (next < range.upperBound && map.bytes[next] == 40 && map.bytes[last] == 41) ||
                    (next < range.upperBound && map.bytes[next] == 91 && map.bytes[last] == 93) {
                    return [first..<(first + 1), cursor..<range.upperBound]
                }
                return []
            }
            cursor += 1
        }
        return []
    }

    /// Math is deliberately outside FN-11. Protect balanced conventional math
    /// delimiters so Markdown inside an unsupported formula remains readable source.
    mutating func protectMath() {
        let bytes = map.bytes
        var cursor = 0
        while cursor < bytes.count {
            if let range = verbatim.first(where: { $0.contains(cursor) }) {
                cursor = range.upperBound
                continue
            }
            var opening: [UInt8] = []
            var closing: [UInt8] = []
            if bytes[cursor] == 36, !escaped(cursor) {
                opening = cursor + 1 < bytes.count && bytes[cursor + 1] == 36 ? [36, 36] : [36]
                closing = opening
            } else if bytes[cursor] == 92, cursor + 1 < bytes.count, !escaped(cursor) {
                if bytes[cursor + 1] == 40 { opening = [92, 40]; closing = [92, 41] }
                if bytes[cursor + 1] == 91 { opening = [92, 91]; closing = [92, 93] }
            }
            guard !opening.isEmpty else { cursor += 1; continue }
            var end = cursor + opening.count
            var found: Int?
            while end + closing.count <= bytes.count {
                if opening == [36], bytes[end] == 10 || bytes[end] == 13 { break }
                if !escaped(end), Array(bytes[end..<(end + closing.count)]) == closing { found = end + closing.count; break }
                end += 1
            }
            if let found { protected.append(cursor..<found); cursor = found }
            else {
                // An incomplete formula also remains source while typing. Stop
                // scanning its body so repeated openers cannot cause quadratic work.
                let end = opening == [36] ? end : bytes.count
                protected.append(cursor..<end)
                cursor = end
            }
        }
    }

    func escaped(_ offset: Int) -> Bool {
        var cursor = offset
        while cursor > 0, map.bytes[cursor - 1] == 92 { cursor -= 1 }
        return (offset - cursor) % 2 == 1
    }

    func run(_ byte: UInt8, from start: Int, to end: Int) -> Int {
        var cursor = start
        while cursor < end, map.bytes[cursor] == byte { cursor += 1 }
        return cursor - start
    }

    func runBackward(_ byte: UInt8, in range: Range<Int>) -> Int {
        var cursor = range.upperBound
        while cursor > range.lowerBound, map.bytes[cursor - 1] == byte { cursor -= 1 }
        return range.upperBound - cursor
    }

    func isSpace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 }
}

/// swift-markdown reports one-based UTF-8 columns; AppKit uses UTF-16 offsets.
/// Only exact Unicode scalar boundaries are accepted, and CRLF is one line break.
private struct MarkdownSourceMap {
    struct Line { let start: Int; let end: Int }
    let bytes: [UInt8]
    let lines: [Line]
    let utf16Offsets: [Int]

    init(_ source: String) {
        bytes = Array(source.utf8)
        var offsets = Array(repeating: -1, count: bytes.count + 1)
        var byteOffset = 0
        var utf16Offset = 0
        for scalar in source.unicodeScalars {
            offsets[byteOffset] = utf16Offset
            byteOffset += scalar.utf8.count
            utf16Offset += scalar.utf16.count
        }
        offsets[byteOffset] = utf16Offset
        utf16Offsets = offsets
        var records: [Line] = []
        var start = 0
        var cursor = 0
        while cursor < bytes.count {
            if bytes[cursor] == 10 || bytes[cursor] == 13 {
                records.append(Line(start: start, end: cursor))
                if bytes[cursor] == 13, cursor + 1 < bytes.count, bytes[cursor + 1] == 10 { cursor += 1 }
                cursor += 1
                start = cursor
            } else { cursor += 1 }
        }
        records.append(Line(start: start, end: bytes.count))
        lines = records
    }

    func byteOffset(_ location: SourceLocation) -> Int? {
        guard location.line > 0, location.line <= lines.count, location.column > 0 else { return nil }
        let line = lines[location.line - 1]
        let offset = line.start + location.column - 1
        guard offset <= line.end, utf16Offsets[offset] >= 0 else { return nil }
        return offset
    }

    func byteRange(_ sourceRange: SourceRange?) -> Range<Int>? {
        guard let sourceRange, let start = byteOffset(sourceRange.lowerBound), let end = byteOffset(sourceRange.upperBound), start <= end else { return nil }
        return start..<end
    }

    func nsRange(_ range: Range<Int>) -> NSRange? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count,
              utf16Offsets[range.lowerBound] >= 0, utf16Offsets[range.upperBound] >= 0 else { return nil }
        return NSRange(location: utf16Offsets[range.lowerBound], length: utf16Offsets[range.upperBound] - utf16Offsets[range.lowerBound])
    }
}
