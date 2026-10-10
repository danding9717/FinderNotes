import AppKit

/// A reusable semantic cache. Native text editing moves existing attributes; this
/// plan describes only the paragraphs that need a later presentation patch.
@MainActor
struct MarkdownDisplayPlan {
    let source: String
    let paragraphs: [Paragraph]
    let codeBlocks: [NSRange]

    struct RelativeDecoration: Equatable {
        enum Kind: Equatable { case list(String), task(Bool, stateRange: NSRange), quote, rule }
        let range: NSRange
        let kind: Kind
    }

    struct Paragraph {
        let range: NSRange
        private let collapsed: NSAttributedString
        private let expanded: NSAttributedString
        private let markers: [NSRange]
        private let relativeDecorations: [RelativeDecoration]
        private let isExpanded: Bool

        fileprivate init(range: NSRange, collapsed: NSAttributedString,
                         expanded: NSAttributedString, markers: [NSRange],
                         decorations: [RelativeDecoration], isExpanded: Bool = false) {
            self.range = range
            self.collapsed = collapsed
            self.expanded = expanded
            self.markers = markers
            relativeDecorations = decorations
            self.isExpanded = isExpanded
        }

        var attributedString: NSAttributedString { isExpanded ? expanded : collapsed }

        var hiddenRanges: [NSRange] {
            guard !isExpanded else { return [] }
            return markers.map { NSRange(location: range.location + $0.location, length: $0.length) }
        }

        var decorations: [MarkdownLayoutManager.Decoration] {
            guard !isExpanded else { return [] }
            return relativeDecorations.map { decoration in
                let kind: MarkdownLayoutManager.Decoration.Kind
                switch decoration.kind {
                case .list(let label): kind = .list(label)
                case .task(let checked, let stateRange):
                    kind = .task(checked, stateRange: NSRange(location: range.location + stateRange.location,
                                                            length: stateRange.length))
                case .quote: kind = .quote
                case .rule: kind = .rule
                }
                return .init(range: NSRange(location: range.location + decoration.range.location,
                                           length: decoration.range.length), kind: kind)
            }
        }

        /// Absolute offsets deliberately do not participate in presentation equality.
        func hasSamePresentation(as other: Paragraph) -> Bool {
            let content = attributedString
            let otherContent = other.attributedString
            guard content.string.utf8.elementsEqual(otherContent.string.utf8),
                  content.isEqual(to: otherContent) else { return false }
            return (isExpanded ? [] : markers) == (other.isExpanded ? [] : other.markers) &&
                (isExpanded ? [] : relativeDecorations) == (other.isExpanded ? [] : other.relativeDecorations)
        }

        func resolvingExpansion(_ ranges: [NSRange]) -> Paragraph {
            let shouldExpand = ranges.contains { NSIntersectionRange($0, range).length > 0 }
            return Paragraph(range: range, collapsed: collapsed, expanded: expanded,
                             markers: markers, decorations: relativeDecorations,
                             isExpanded: shouldExpand)
        }

        /// The caller owns the editing/undo transaction. This never changes characters.
        func applyAttributes(to storage: NSTextStorage) {
            let content = attributedString
            guard range.location >= 0, range.length == content.length,
                  range.location <= storage.length, range.length <= storage.length - range.location,
                  range.length > 0,
                  (storage.string as NSString).substring(with: range).utf8.elementsEqual(content.string.utf8) else { return }
            content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, localRange, _ in
                storage.setAttributes(attributes, range: NSRange(location: range.location + localRange.location,
                                                                length: localRange.length))
            }
        }

        fileprivate func relocated(to range: NSRange) -> Paragraph {
            Paragraph(range: range, collapsed: collapsed, expanded: expanded,
                      markers: markers, decorations: relativeDecorations, isExpanded: isExpanded)
        }

        fileprivate func updatingTaskState(at stateRange: NSRange, replacement: String,
                                          checked: Bool) -> Paragraph? {
            let local = NSRange(location: stateRange.location - range.location, length: 1)
            guard local.location >= 0, local.location < collapsed.length,
                  relativeDecorations.contains(where: {
                      if case .task(_, let range) = $0.kind { return range == local }
                      return false
                  }) else { return nil }
            let nextCollapsed = NSMutableAttributedString(attributedString: collapsed)
            let nextExpanded = NSMutableAttributedString(attributedString: expanded)
            nextCollapsed.replaceCharacters(in: local, with: replacement)
            nextExpanded.replaceCharacters(in: local, with: replacement)
            let nextDecorations = relativeDecorations.map { decoration in
                guard case .task(_, let range) = decoration.kind, range == local else { return decoration }
                return RelativeDecoration(range: decoration.range, kind: .task(checked, stateRange: range))
            }
            return Paragraph(range: range, collapsed: nextCollapsed, expanded: nextExpanded,
                             markers: markers, decorations: nextDecorations, isExpanded: isExpanded)
        }
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraph.copy() as! NSParagraphStyle, .ligature: 0]
    }

    static func make(presentation: MarkdownPresentation, expanded: [NSRange]) -> MarkdownDisplayPlan {
        let text = presentation.source as NSString
        let full = NSRange(location: 0, length: text.length)
        let common = NSMutableAttributedString(string: presentation.source, attributes: baseAttributes)

        // Preserve the original style priority, including heading traits and nested emphasis.
        for span in presentation.spans where isValid(span.range, length: text.length) && span.range.length > 0 {
            switch span.style {
            case .heading(let level):
                let size = [28.0, 24, 21, 19, 17, 16][max(0, min(5, level - 1))]
                common.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: span.range)
            case .strong, .emphasis:
                var fonts: [(NSRange, NSFont)] = []
                common.enumerateAttribute(.font, in: span.range) { font, range, _ in
                    let trait: NSFontTraitMask = span.style == .strong ? .boldFontMask : .italicFontMask
                    let original = font as? NSFont ?? NSFont.systemFont(ofSize: 16)
                    fonts.append((range, NSFontManager.shared.convert(original, toHaveTrait: trait)))
                }
                for (range, font) in fonts { common.addAttribute(.font, value: font, range: range) }
            case .strikethrough:
                common.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
            case .link:
                common.addAttributes([.foregroundColor: NSColor.linkColor,
                                      .underlineStyle: NSUnderlineStyle.single.rawValue], range: span.range)
            case .code, .codeBlock:
                common.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                                      .backgroundColor: NSColor.quaternaryLabelColor], range: span.range)
            case .quote, .list, .task(_), .rule:
                break
            }
        }

        let collapsed = NSMutableAttributedString(attributedString: common)
        var decorations: [RelativeDecoration] = []
        for span in presentation.spans where isValid(span.range, length: text.length) && span.range.length > 0 {
            switch span.style {
            case .quote, .list, .task(_):
                var task: (checked: Bool, range: NSRange)?
                if case .task(let checked) = span.style {
                    guard let stateRange = taskStateRange(in: span.range, text: text),
                          (text.character(at: stateRange.location) != 32) == checked else { continue }
                    task = (checked, stateRange)
                }
                let raw = text.substring(with: span.range)
                let prefix = raw.prefix { $0.isNumber || $0 == "." || $0 == ")" }
                let label = prefix.isEmpty ? "•" : String(prefix)
                let indent = span.style == .quote ? 16 :
                    max(24, (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width + 10)
                var cursor = span.range.location
                while cursor < NSMaxRange(span.range) {
                    let paragraphRange = text.paragraphRange(for: NSRange(location: cursor, length: 0))
                    let part = NSIntersectionRange(paragraphRange, span.range)
                    guard part.length > 0 else { break }
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.lineSpacing = 3
                    paragraph.headIndent = indent
                    paragraph.firstLineHeadIndent = indent
                    // Paragraph attributes must be uniform, including any source
                    // indentation preceding the AST node's own range.
                    collapsed.addAttribute(.paragraphStyle, value: paragraph.copy() as! NSParagraphStyle,
                                           range: paragraphRange)
                    if span.style == .quote || cursor == span.range.location {
                        let kind: RelativeDecoration.Kind
                        if let task { kind = .task(task.checked, stateRange: task.range) }
                        else { kind = span.style == .quote ? .quote : .list(label) }
                        decorations.append(.init(range: part, kind: kind))
                    }
                    cursor = NSMaxRange(paragraphRange)
                }
            case .rule:
                decorations.append(.init(range: span.range, kind: .rule))
            default:
                break
            }
        }

        let markers = presentation.markers.filter { isValid($0, length: text.length) && $0.length > 0 }
        let paragraphs = paragraphRanges(in: text).map { range in
            let localMarkers = markers.compactMap { relativeIntersection($0, paragraph: range) }
            let localDecorations = decorations.compactMap { decoration -> RelativeDecoration? in
                guard let local = relativeIntersection(decoration.range, paragraph: range) else { return nil }
                let kind: RelativeDecoration.Kind
                if case .task(let checked, let stateRange) = decoration.kind {
                    guard let localState = relativeIntersection(stateRange, paragraph: range),
                          localState.length == 1 else { return nil }
                    kind = .task(checked, stateRange: localState)
                } else { kind = decoration.kind }
                return .init(range: local, kind: kind)
            }
            return Paragraph(range: range, collapsed: collapsed.attributedSubstring(from: range),
                             expanded: common.attributedSubstring(from: range), markers: localMarkers,
                             decorations: localDecorations).resolvingExpansion(expanded)
        }
        return MarkdownDisplayPlan(source: presentation.source, paragraphs: paragraphs,
                                   codeBlocks: presentation.codeBlocks.filter { isValid($0, length: full.length) })
    }

    func resolvingExpansion(_ expanded: [NSRange]) -> MarkdownDisplayPlan {
        MarkdownDisplayPlan(source: source, paragraphs: paragraphs.map { $0.resolvingExpansion(expanded) },
                            codeBlocks: codeBlocks)
    }

    /// Only untouched complete paragraphs retain cached attributes or masks.
    func rebased(to source: String, edit: MarkdownTextEdit) -> MarkdownDisplayPlan {
        let text = source as NSString
        let retained = paragraphs.compactMap { paragraph -> Paragraph? in
            guard let range = edit.mapUnchanged(paragraph.range), Self.isValid(range, length: text.length),
                  text.paragraphRange(for: range) == range,
                  text.substring(with: range).utf8.elementsEqual(paragraph.attributedString.string.utf8) else { return nil }
            return paragraph.relocated(to: range)
        }
        let blocks = codeBlocks.compactMap { edit.mapCovering($0) }
            .filter { Self.isValid($0, length: text.length) && $0.length > 0 }
        return MarkdownDisplayPlan(source: source, paragraphs: retained, codeBlocks: blocks)
    }

    /// This edit cannot change Markdown structure. Preserve its known prefix and
    /// styles immediately, including undo/redo, while the full parse is pending.
    func updatingTaskState(to newSource: String, edit: MarkdownTextEdit) -> MarkdownDisplayPlan? {
        let old = source as NSString
        let new = newSource as NSString
        guard edit.oldRange == edit.newRange, edit.oldRange.length == 1,
              Self.isValid(edit.oldRange, length: old.length), old.length == new.length else { return nil }
        let oldState = old.character(at: edit.oldRange.location)
        let newState = new.character(at: edit.newRange.location)
        guard [UInt16(32), 120, 88].contains(oldState), [UInt16(32), 120, 88].contains(newState) else { return nil }
        let replacement = new.substring(with: edit.newRange)
        guard old.replacingCharacters(in: edit.oldRange, with: replacement).utf8.elementsEqual(newSource.utf8) else { return nil }
        var updated = paragraphs
        guard let index = paragraphs.firstIndex(where: {
            edit.oldRange.location >= $0.range.location && NSMaxRange(edit.oldRange) <= NSMaxRange($0.range)
        }), let paragraph = paragraphs[index].updatingTaskState(at: edit.oldRange, replacement: replacement,
                                                               checked: newState != 32) else { return nil }
        updated[index] = paragraph
        return MarkdownDisplayPlan(source: newSource, paragraphs: updated, codeBlocks: codeBlocks)
    }

    private static func taskStateRange(in range: NSRange, text: NSString) -> NSRange? {
        let end = NSMaxRange(range)
        var cursor = range.location
        while cursor < end, text.character(at: cursor) == 32 || text.character(at: cursor) == 9 { cursor += 1 }
        guard cursor < end else { return nil }
        if (48...57).contains(text.character(at: cursor)) {
            let start = cursor
            while cursor < end, (48...57).contains(text.character(at: cursor)) {
                guard cursor - start < 9 else { return nil }
                cursor += 1
            }
            guard cursor < end, text.character(at: cursor) == 46 || text.character(at: cursor) == 41 else { return nil }
            cursor += 1
        } else if [UInt16(45), 43, 42].contains(text.character(at: cursor)) { cursor += 1 }
        else { return nil }
        let separator = cursor
        while cursor < end, text.character(at: cursor) == 32 || text.character(at: cursor) == 9 { cursor += 1 }
        guard cursor > separator, end - cursor >= 3, text.character(at: cursor) == 91,
              [UInt16(32), 120, 88].contains(text.character(at: cursor + 1)),
              text.character(at: cursor + 2) == 93 else { return nil }
        return NSRange(location: cursor + 1, length: 1)
    }

    private static func paragraphRanges(in text: NSString) -> [NSRange] {
        guard text.length > 0 else { return [NSRange(location: 0, length: 0)] }
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < text.length {
            let range = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            guard range.length > 0 else { break }
            ranges.append(range)
            cursor = NSMaxRange(range)
        }
        let tail = text.paragraphRange(for: NSRange(location: text.length, length: 0))
        if tail.length == 0 { ranges.append(tail) }
        return ranges
    }

    private static func relativeIntersection(_ range: NSRange, paragraph: NSRange) -> NSRange? {
        let intersection = NSIntersectionRange(range, paragraph)
        guard intersection.length > 0 else { return nil }
        return NSRange(location: intersection.location - paragraph.location, length: intersection.length)
    }

    private static func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length >= 0 &&
            range.location <= length && range.length <= length - range.location
    }
}
