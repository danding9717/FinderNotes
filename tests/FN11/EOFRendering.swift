import AppKit
import Foundation

extension FN11Verification {
    /// Exercise the production glyph manager's fully hidden final rule, including the
    /// single-paragraph case which a normal caret would otherwise keep expanded.
    @MainActor
    static func verifyEOFRuleRendering(_ checks: Checks, directory: URL) throws {
        for (index, source) in ["上文\n\n---", "---"].enumerated() {
            let view = CompositionTextView()
            view.frame = NSRect(x: 0, y: 0, width: 760, height: 200)
            view.isRichText = false
            view.isVerticallyResizable = false
            view.textContainer?.widthTracksTextView = true
            view.textContainerInset = NSSize(width: 24, height: 24)
            view.backgroundColor = .white
            view.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            view.string = source
            guard let storage = view.textStorage,
                  let manager = view.layoutManager as? MarkdownLayoutManager,
                  let container = view.textContainer else { throw CheckFailure("EOF rule fixture has no production glyph manager") }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            storage.setAttributes([.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black, .paragraphStyle: paragraph], range: NSRange(location: 0, length: storage.length))
            let parsed = MarkdownPresentation.parse(source)
            guard let rule = parsed.spans.first(where: { $0.style == .rule }) else { throw CheckFailure("EOF rule fixture did not parse as rule") }
            for marker in parsed.markers { manager.hiddenCharacters.insert(integersIn: marker.location..<NSMaxRange(marker)) }
            manager.decorations = [.init(range: rule.range, kind: .rule)]
            manager.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
            manager.ensureLayout(for: container)
            let extra = manager.extraLineFragmentRect
            let lastGlyph = manager.glyphIndexForCharacter(at: storage.length - 1)
            let finalLine = extra.isEmpty ? manager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil) : extra
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CheckFailure("cannot allocate EOF rule bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure("cannot encode EOF rule bitmap") }
            let output = directory.appendingPathComponent("rule-eof-\(index + 1).png")
            try png.write(to: output, options: .atomic)
            let scale = Double(bitmap.pixelsHigh) / view.bounds.height
            let expectedRow = (finalLine.midY + view.textContainerOrigin.y) * scale
            let column = bitmap.pixelsWide / 2
            let rows = (0..<bitmap.pixelsHigh).filter { row in
                guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent < 0.9 && color.greenComponent < 0.9 && color.blueComponent < 0.9
            }
            try checks.expect(!finalLine.isEmpty, "fully hidden EOF rule retains a final layout line")
            if source.contains("\n") {
                try checks.expect(!extra.isEmpty && manager.extraLineFragmentTextContainer === container, "EOF rule after earlier paragraphs uses its extra final line fragment")
            } else {
                try checks.expect(finalLine.minY == 0, "standalone EOF rule renders in its only line fragment")
            }
            try checks.expect(!rows.isEmpty, "EOF rule bitmap contains a rendered horizontal line at its center column")
            try checks.expect(rows.allSatisfy { abs(Double($0) - expectedRow) <= max(2, scale * 2) }, "EOF rule renders in its own final line (rows \(rows), expected \(expectedRow))")
            try checks.expect(view.string.utf8.elementsEqual(source.utf8), "EOF rule rendering preserves the exact source bytes")
            print("EOF rule component bitmap: \(output.path)")
        }
    }
}
