import AppKit
import Foundation

extension FN11Verification {
    /// Draw the actual production text view without ordering a window front or using Finder.
    @MainActor
    static func verifyVisual(_ checks: Checks, output: URL) async throws {
        let suiteName = "com.findernotes.FN11Verification.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw CheckFailure("cannot create visual preference suite") }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            _ = defaults.synchronize()
            let preferenceFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suiteName).plist")
            try? FileManager.default.removeItem(at: preferenceFile)
        }
        let view = CompositionTextView()
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 1000)
        view.isRichText = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.font = .systemFont(ofSize: 16)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 24, height: 24)
        view.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let source = """
        # Markdown 原地排版
        ## 二级标题 · 中文与 Unicode 👩🏽‍🚀

        正文包含 **粗体**、*斜体*、~~删除线~~ 与 [链接文字](https://example.com)。

        > 引用第一行
        > 引用第二行

        - 无序列表第一项
        - 无序列表第二项

        10. 有序列表第十项
        11. 有序列表第十一项

        ---

        行内代码：`let value = "中文"`

        ```swift
        let markdown = "**源码标记保留**"
        print(markdown)
        ```

        表格保留原文：

        | 列一 | 列二 |
        | --- | --- |
        | **原文** | 数据 |

        编辑位置在此，其他段落显示排版。
        """
        view.string = source
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let controller = MarkdownLayoutController(textView: view, defaults: defaults)
        controller.installDocument()
        try await waitForPresentation(controller, source: source)
        guard let manager = view.layoutManager as? MarkdownLayoutManager,
              let container = view.textContainer else { throw CheckFailure("visual component is not using production TextKit 1 graph") }
        manager.ensureLayout(for: container)
        let marker = nsRange("**", in: source)
        try checks.expect(controller.hiddenMarkers.contains(marker), "visual fixture hides the inactive strong opening delimiter")
        let markerGlyphs = manager.glyphRange(forCharacterRange: marker, actualCharacterRange: nil)
        // TextKit may expand the returned glyph range to the preceding elastic space.
        // Retain only glyphs whose source character index belongs to the actual delimiter.
        let markerGlyphIndices = (markerGlyphs.location..<NSMaxRange(markerGlyphs)).filter {
            NSLocationInRange(manager.characterIndexForGlyph(at: $0), marker)
        }
        try checks.expect(markerGlyphIndices.count == marker.length, "hidden syntax retains addressable source glyph positions")
        guard !markerGlyphIndices.isEmpty else {
            throw CheckFailure("hidden syntax has no mapped source glyphs")
        }
        let nextGlyph = manager.glyphIndexForCharacter(at: NSMaxRange(marker))
        let nextPosition = manager.location(forGlyphAt: nextGlyph)
        let markerPositions = markerGlyphIndices.map { manager.location(forGlyphAt: $0) }
        try checks.expect(view.string.utf8.elementsEqual(source.utf8), "component bitmap rendering preserves raw source bytes")
        let usedHeight = ceil(manager.usedRect(for: container).maxY + view.textContainerInset.height * 2)
        view.setFrameSize(NSSize(width: 760, height: max(usedHeight, 600)))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CheckFailure("cannot allocate AppKit component bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure("cannot encode AppKit component bitmap") }
        try png.write(to: output, options: .atomic)
        print("AppKit component bitmap: \(output.path)")
        for glyph in markerGlyphIndices {
            try checks.expect(manager.propertyForGlyph(at: glyph).contains(.null), "hidden syntax generates actual null glyph properties")
        }
        try checks.expect(markerPositions.allSatisfy { abs($0.x - nextPosition.x) <= 0.01 }, "hidden syntax has zero horizontal layout advance (markers \(markerPositions), next \(nextPosition))")
    }
}
