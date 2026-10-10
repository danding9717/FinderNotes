import AppKit
import Darwin
import Foundation

/// Component checks only: no Finder invocation, real input method, installed application,
/// permission dialog or user media. Every note/recovery/export write uses one temporary root;
/// layout preferences use a separate disposable UserDefaults suite.
#if FN11_TASK_REVIEW_UI
@main
struct FN11TaskReviewEntrypoint {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do { try await launchFN11TaskReviewUI() }
            catch {
                FileHandle.standardError.write(Data("FN-11 task UI failed: \(error)\n".utf8))
                exit(1)
            }
        }
        // The UI-only binary starts AppKit outside an async MainActor job.
        app.run()
    }
}
#endif

#if !FN11_TASK_REVIEW_UI
@main
#endif
struct FN11Verification {
    @MainActor
    static func main() async {
        do {
            let checks = Checks()
            var failures: [String] = []
            do { try verifyParser(checks) } catch { failures.append("parser: \(error)") }
            do { try verifyTextEdits(checks) } catch { failures.append("text edits: \(error)") }
            do { try verifyListContinuationPlans(checks) } catch { failures.append("list continuation plans: \(error)") }
            do { try await verifyStorage(checks) } catch { failures.append("storage: \(error)") }
            do { try await verifyLayout(checks) } catch { failures.append("layout: \(error)") }
            do { try await verifyStability(checks) } catch { failures.append("input stability: \(error)") }
            do { try await verifyEditorIntegration(checks) } catch { failures.append("editor integration: \(error)") }
            do { try await verifyListContinuationIntegration(checks) } catch { failures.append("list continuation integration: \(error)") }
            do { try await verifyTaskListIntegration(checks) } catch { failures.append("task list integration: \(error)") }
            if let outputPath = CommandLine.arguments.dropFirst().first {
                do {
                    let output = URL(fileURLWithPath: outputPath)
                    try await verifyVisual(checks, output: output)
                    try verifyEOFRuleRendering(checks, directory: output.deletingLastPathComponent())
                }
                catch { failures.append("component rendering: \(error)") }
            }
            guard failures.isEmpty else { throw CheckFailure(failures.joined(separator: "\n")) }
            print("FN-11 component verification passed: \(checks.count) assertions")
            print("Evidence boundary: programmatic AppKit + temporary-file storage; real UI, Chinese IME, Finder/TCC and long-session performance require manual acceptance.")
        } catch {
            FileHandle.standardError.write(Data("FN-11 verification failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func verifyParser(_ checks: Checks) throws {
        let source = """
        # 一级标题
        ## 二级标题
        ### 三级标题
        #### 四级标题
        ##### 五级标题
        ###### 六级标题

        中文 **粗体**、*斜体*、~~删除~~，以及 [链接](https://example.com/a?q=1)。

        > 引用正文

        - 无序项
        1. 有序项

        ---

        `let 中文 = 1`

        ```swift
        let value = "**保留代码标记**"
        ```
        """
        let parsed = MarkdownPresentation.parse(source)
        try checks.expect(parsed.source.utf8.elementsEqual(source.utf8), "parser preserves the complete source bytes")
        try verifyRanges(parsed, checks: checks)
        for level in 1...6 {
            try checks.expect(hasStyle(parsed, at: "\(String(repeating: "#", count: level)) \(["一级", "二级", "三级", "四级", "五级", "六级"][level - 1])标题", style: .heading(level)), "heading level \(level) is supported")
        }
        let supported: [(String, MarkdownPresentation.Style)] = [
            ("粗体", .strong), ("斜体", .emphasis), ("删除", .strikethrough),
            ("引用正文", .quote), ("无序项", .list), ("有序项", .list),
            ("链接", .link), ("---", .rule), ("let 中文 = 1", .code),
            ("let value", .codeBlock)
        ]
        for (text, style) in supported {
            try checks.expect(hasStyle(parsed, at: text, style: style), "supported construct styles \(text)")
        }
        try checks.expect(!parsed.markers.isEmpty, "supported constructs expose reversible marker ranges")
        let codeContent = nsRange("**保留代码标记**", in: source)
        try checks.expect(!parsed.markers.contains { NSIntersectionRange($0, codeContent).length > 0 }, "fenced code keeps internal Markdown markers literal")
        for ruleSource in ["---\n\nfollowing", "***\n\nfollowing", "___\r\n\r\nfollowing"] {
            let ruleResult = MarkdownPresentation.parse(ruleSource)
            try verifyRanges(ruleResult, checks: checks)
            let ruleRange = NSRange(location: 0, length: 3)
            try checks.expect(ruleResult.spans.contains { $0.style == .rule && $0.range == ruleRange }, "rule followed by blank line is styled without consuming newline")
            try checks.expect(ruleResult.markers.contains(ruleRange), "rule followed by blank line hides only its three delimiter characters")
            let markerText = ruleResult.markers.map { (ruleSource as NSString).substring(with: $0) }
            let hidesNewline = markerText.contains { marker in marker.unicodeScalars.contains { $0.value == 10 || $0.value == 13 } }
            try checks.expect(!hidesNewline, "rule marker preserves CR/LF source layout")
        }

        let unicode = "# 👩🏽‍🚀 中文 e\u{301}\r\n\r\n**加粗👨‍👩‍👧‍👦** 与 _重音é_，`代码🚀`\r\n"
        let unicodeResult = MarkdownPresentation.parse(unicode)
        try verifyRanges(unicodeResult, checks: checks)
        try checks.expect(unicodeResult.source.utf8.elementsEqual(unicode.utf8), "CRLF, decomposed accents and emoji bytes survive parsing")
        try checks.expect(hasStyle(unicodeResult, at: "加粗👨‍👩‍👧‍👦", style: .strong), "UTF-8 parser positions map to UTF-16 after emoji")
        try checks.expect(hasStyle(unicodeResult, at: "重音é", style: .emphasis), "accented inline source maps to the intended UTF-16 range")
        try checks.expect(hasStyle(unicodeResult, at: "代码🚀", style: .code), "Unicode code span is mapped safely")

        let nested = "**粗体含 *内层斜体* 文本**\n\n> - 引用内列表 **粗体项**\n"
        let nestedResult = MarkdownPresentation.parse(nested)
        try verifyRanges(nestedResult, checks: checks)
        try checks.expect(hasStyle(nestedResult, at: "内层斜体", style: .strong), "outer strong style covers nested emphasis")
        try checks.expect(hasStyle(nestedResult, at: "内层斜体", style: .emphasis), "nested emphasis is retained")
        try checks.expect(hasStyle(nestedResult, at: "粗体项", style: .strong), "nested block construct retains inline style")

        let incompleteCases = ["**尚未闭合", "*尚未闭合", "~~尚未闭合", "`尚未闭合", "[尚未闭合](", "```swift\nlet a = **1**\n"]
        for source in incompleteCases {
            let result = MarkdownPresentation.parse(source)
            try verifyRanges(result, checks: checks)
            try checks.expect(result.source.utf8.elementsEqual(source.utf8), "incomplete syntax keeps raw bytes: \(source.debugDescription)")
            try checks.expect(result.markers.isEmpty, "incomplete construct does not hide syntax: \(source.debugDescription)")
        }

        let unsupportedCases = [
            "| 列一 | 列二 |\n| --- | --- |\n| **原文** | 数据 |\n",
            "![**图像原文**](https://example.com/a.png)\n",
            "<div>**HTML 原文**</div>\n",
            "$**公式原文**$\n",
            "$$\n**公式原文**\n$$\n"
        ]
        for source in unsupportedCases {
            let result = MarkdownPresentation.parse(source)
            try verifyRanges(result, checks: checks)
            try checks.expect(result.source.utf8.elementsEqual(source.utf8), "unsupported syntax preserves bytes: \(source.debugDescription)")
            try checks.expect(result.markers.isEmpty, "unsupported syntax keeps all markers visible: \(source.debugDescription)")
        }

        let taskSource = "- [ ] **未完成任务**\n- [x] 已完成任务\n1. [X] 编号完成任务\n"
        let tasks = MarkdownPresentation.parse(taskSource)
        try verifyRanges(tasks, checks: checks)
        try checks.expect(tasks.source.utf8.elementsEqual(taskSource.utf8), "task parsing retains exact checkbox and source bytes")
        try checks.expect(hasStyle(tasks, at: "未完成任务", style: .task(false)), "unchecked task is recognized")
        try checks.expect(hasStyle(tasks, at: "已完成任务", style: .task(true)), "checked task is recognized")
        try checks.expect(hasStyle(tasks, at: "编号完成任务", style: .task(true)), "ordered uppercase-X task is recognized without normalizing its source")
        try checks.expect(hasStyle(tasks, at: "未完成任务", style: .strong), "task body retains ordinary inline Markdown styles")
        for prefix in ["- [ ] ", "- [x] ", "1. [X] "] {
            let range = nsRange(prefix, in: taskSource)
            try checks.expect(tasks.markers.contains { NSIntersectionRange($0, range).length == range.length }, "task presentation hides the complete list and checkbox source prefix")
        }

        let escaped = "\\*原样星号\\* 和 \\`原样代码\\`\n"
        let escapedResult = MarkdownPresentation.parse(escaped)
        try verifyRanges(escapedResult, checks: checks)
        try checks.expect(escapedResult.markers.isEmpty, "escaped delimiter text remains visible")
        for source in ["", "\n", "\r\n", "普通中文与 👩🏽‍🚀。", String(repeating: "🚀", count: 500)] {
            let result = MarkdownPresentation.parse(source)
            try verifyRanges(result, checks: checks)
            try checks.expect(result.source.utf8.elementsEqual(source.utf8), "plain and empty inputs preserve source bytes")
            try checks.expect(result.markers.isEmpty, "plain and empty inputs have no hidden syntax")
        }
    }

    @MainActor
    static func verifyStorage(_ checks: Checks) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderNotes-FN11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("component-fixture.png")
        // File type resolution uses this valid 1x1 PNG fixture; it is never installed or opened.
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2nWQAAAAASUVORK5CYII=")!
        try image.write(to: media)
        let reader = NoteReader()
        let initial = try reader.read(urls: [media])
        try checks.expect(initial.content == .missing, "temporary fixture starts without FinderNotes xattr")
        let source = "# 标题 👩🏽‍🚀\r\n\r\n**粗体** 和 _斜体_、[链接](https://example.com)\r\n```swift\r\nlet raw = \"**源码**\"\r\n```\r\ne\u{301}\n"
        let sourceBytes = Data(source.utf8)
        let presentation = MarkdownPresentation.parse(source)
        try checks.expect(Data(presentation.source.utf8) == sourceBytes, "styled presentation retains the storage payload")

        let session = EditorSession()
        let loading = session.beginLoading()
        try checks.expect(session.resolve(initial, ticket: loading) == .installed, "session installs temporary baseline")
        session.updateDraft(presentation.source)
        let revision = session.draftRevision
        guard let recovery = session.recoveryRecord else { throw CheckFailure("dirty Markdown draft has no recovery record") }
        let store = DraftRecoveryStore(directory: root.appendingPathComponent("Recovery/v1", isDirectory: true))
        try await store.put(recovery)
        let records = try await store.records()
        try checks.expect(records.count == 1, "recovery creates exactly one temporary draft")
        try checks.expect(Data(records[0].draft.utf8) == sourceBytes, "recovery readback retains raw Markdown bytes")
        try checks.expect(records[0].revision == revision, "layout parsing does not change recovery revision")
        try checks.expect(records[0].snapshot.content == .missing, "recovery retains the original missing xattr baseline")
        let restored = EditorSession()
        try checks.expect(restored.restoreRecovery(record: records[0], current: initial), "session restores temporary recovery record")
        try checks.expect(Data(restored.draft.utf8) == sourceBytes, "restored session has the exact raw Markdown draft")
        try checks.expect(restored.recoveryNeedsAttention, "restored draft keeps explicit recovery confirmation boundary")

        guard let ticket = session.beginSaving() else { throw CheckFailure("session cannot begin temporary save") }
        try checks.expect(ticket.request.desiredContent == .present(sourceBytes), "save request contains raw UTF-8, not formatted text")
        let saved = try NoteWriter().save(ticket.request)
        try checks.expect(session.completeSaving(saved, ticket: ticket), "verified save advances the session baseline")
        let reread = try reader.read(urls: [media])
        try checks.expect(reread.content == .present(sourceBytes), "xattr readback matches every original source byte")
        try checks.expect(try Data(contentsOf: media) == image, "saving styled note preserves original media bytes")
        try checks.expect(!session.isDirty, "successful raw save clears dirty state")
        let destination = root.appendingPathComponent("raw.note.md")
        try MarkdownExporter().export(MarkdownExportRequest(source: media, destination: destination, bytes: Data(session.draft.utf8)))
        try checks.expect(try Data(contentsOf: destination) == sourceBytes, "Markdown export matches xattr and draft bytes exactly")
        try await store.remove(id: recovery.id)
        let remainingRecords = try await store.records()
        try checks.expect(remainingRecords.isEmpty, "confirmed-save recovery cleanup affects only temporary record")
    }

    @MainActor
    static func verifyLayout(_ checks: Checks) async throws {
        _ = NSApplication.shared
        let suiteName = "com.findernotes.FN11Verification.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw CheckFailure("cannot create isolated preference suite") }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            _ = defaults.synchronize()
            let preferenceFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suiteName).plist")
            try? FileManager.default.removeItem(at: preferenceFile)
        }
        let view = CompositionTextView()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        view.isRichText = false
        view.allowsUndo = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(view)
        defer { window.close() }
        let controller = MarkdownLayoutController(textView: view, defaults: defaults)
        view.inputStateWillChange = { [weak controller] in controller?.inputStateWillChange() }
        view.inputStateDidChange = { [weak controller] in controller?.inputStateDidChange() }
        let source = "# 标题\n\n**加粗** 普通文本\n\n" + String(repeating: "更多正文行\n", count: 60)
        view.string = source
        let selection = nsRange("普通文本", in: source)
        view.setSelectedRange(selection)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
        let scrollOrigin = scroll.contentView.bounds.origin
        let canUndo = view.undoManager?.canUndo
        controller.setEnabled(true)
        controller.installDocument()
        try await waitForPresentation(controller, source: source)
        try checks.expect(view.string.utf8.elementsEqual(source.utf8), "layout does not rewrite NSTextView source bytes")
        try checks.expect(view.selectedRange() == selection, "layout preserves current selection")
        try checks.expect(scroll.contentView.bounds.origin == scrollOrigin, "layout preserves existing scroll origin (before \(scrollOrigin), after \(scroll.contentView.bounds.origin))")
        try checks.expect(view.undoManager?.canUndo == canUndo, "layout introduces no undo operation")
        try checks.expect(!controller.hiddenMarkers.isEmpty, "supported inactive paragraph syntax is visually hidden")
        let boldRange = nsRange("**加粗** 普通文本", in: source)
        try checks.expect(!controller.hiddenMarkers.contains { NSIntersectionRange($0, boldRange).length > 0 }, "active paragraph reveals its raw syntax")
        controller.setEnabled(false)
        try checks.expect(controller.hiddenMarkers.isEmpty, "disabling presentation reveals every marker")
        try checks.expect(scroll.contentView.bounds.origin == scrollOrigin, "disabling presentation preserves the existing scroll origin")
        try checks.expect(!defaults.bool(forKey: MarkdownLayoutController.preferenceKey), "disabled preference is persisted in isolated suite")
        let disabledController = MarkdownLayoutController(textView: CompositionTextView(), defaults: defaults)
        try checks.expect(!disabledController.isEnabled, "a fresh controller reads the disabled preference")
        try checks.expect(view.string.utf8.elementsEqual(source.utf8), "disabling presentation keeps source bytes")
        try checks.expect(view.selectedRange() == selection, "disabling presentation preserves selection")
        controller.setEnabled(true)
        try await waitForPresentation(controller, source: source)
        try checks.expect(scroll.contentView.bounds.origin == scrollOrigin, "re-enabling presentation preserves the existing scroll origin")
        try checks.expect(view.string.utf8.elementsEqual(source.utf8), "re-enabling presentation keeps source bytes")
        try checks.expect(defaults.bool(forKey: MarkdownLayoutController.preferenceKey), "enabled preference is persisted in isolated suite")
        let headingFont = view.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        try checks.expect((headingFont?.pointSize ?? 0) > 16, "presentation applies heading typography in the editor")
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        controller.selectionDidChange()
        try checks.expect(controller.hiddenMarkers.contains { NSIntersectionRange($0, boldRange).length > 0 }, "leaving the active paragraph restores hidden bold delimiters")
        view.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        controller.selectionDidChange()
        try checks.expect(controller.hiddenMarkers.isEmpty, "selecting the whole draft reveals every syntax marker")
        let multipleSelections = [NSValue(range: NSRange(location: 0, length: 0)), NSValue(range: selection)]
        view.selectedRanges = multipleSelections
        controller.selectionDidChange()
        try checks.expect(controller.hiddenMarkers.isEmpty, "multiple selections reveal each selected paragraph")
        try checks.expect(view.selectedRanges == multipleSelections, "presentation preserves all native selection ranges")
        view.setSelectedRange(selection)
        controller.selectionDidChange()

        guard let undo = view.undoManager else { throw CheckFailure("programmatic editor has no undo manager") }
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        view.insertText("新增 **字**", replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
        undo.endUndoGrouping()
        controller.documentDidChange()
        let editedSource = view.string
        try await waitForPresentation(controller, source: editedSource)
        try checks.expect(undo.canUndo, "programmatic text edit creates a real undo record")
        undo.undo()
        controller.documentDidChange()
        try await waitForPresentation(controller, source: source)
        try checks.expect(view.string.utf8.elementsEqual(source.utf8), "undo after formatting restores source bytes")
        try checks.expect(undo.canRedo, "formatting preserves the redo record")
        undo.redo()
        controller.documentDidChange()
        try await waitForPresentation(controller, source: editedSource)
        try checks.expect(view.string.utf8.elementsEqual(editedSource.utf8), "redo after formatting restores exact edited source")

        // Programmatic marked text simulates NSTextInputClient state. It does not validate a real IME.
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        undo.beginUndoGrouping()
        view.setMarkedText("拼音候选", selectedRange: NSRange(location: 0, length: 4), replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedSource = view.string
        try checks.expect(view.hasMarkedText(), "simulated marked text enters NSTextInputClient composition state")
        try checks.expect(!controller.hiddenMarkers.isEmpty, "composition retains distant paragraphs' hidden syntax")
        try await pause(milliseconds: 200)
        try checks.expect(view.string.utf8.elementsEqual(markedSource.utf8), "layout does not rewrite simulated marked text")
        view.unmarkText()
        undo.endUndoGrouping()
        try await waitForPresentation(controller, source: view.string)
        try checks.expect(!view.hasMarkedText(), "simulated composition can commit without layout interference")

        let blocks = "首段\n\n```swift\nlet a = 1\nlet b = 2\n```\n\n末段\n"
        let blockResult = MarkdownPresentation.parse(blocks)
        let blockSelection = nsRange("let b", in: blocks)
        let expanded = MarkdownLayoutController.expandedRanges(source: blocks, selections: [NSRange(location: blockSelection.location, length: 0)], codeBlocks: blockResult.codeBlocks)
        try checks.expect(blockResult.codeBlocks.count == 1, "closed fence is one editable code block")
        try checks.expect(expanded.contains(blockResult.codeBlocks[0]), "caret inside code reveals the complete fence block")
        let fenceEnd = NSMaxRange(blockResult.codeBlocks[0])
        let atFenceEnd = MarkdownLayoutController.expandedRanges(source: blocks, selections: [NSRange(location: fenceEnd, length: 0)], codeBlocks: blockResult.codeBlocks)
        try checks.expect(atFenceEnd.contains(blockResult.codeBlocks[0]), "caret immediately after closing fence reveals the complete code block")
        let boundary = ("首段\n" as NSString).length
        let firstOnly = MarkdownLayoutController.expandedRanges(source: blocks, selections: [NSRange(location: 0, length: boundary)], codeBlocks: [])
        try checks.expect(firstOnly == [NSRange(location: 0, length: boundary)], "end-exclusive selection does not expand the following paragraph")

        try await verifyStaleLayout(checks, defaults: defaults)
    }

    @MainActor
    static func verifyStaleLayout(_ checks: Checks, defaults: UserDefaults) async throws {
        let view = CompositionTextView()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        let controller = MarkdownLayoutController(textView: view, defaults: defaults, parser: { source in
            // A continuation deliberately ignores task cancellation, modelling a parser that
            // has already started work when a newer document or switch invalidates its result.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + (source.contains("old") ? 0.45 : 0.02)) {
                    continuation.resume()
                }
            }
            return MarkdownPresentation.parse(source)
        })
        view.string = "# old document\n"
        controller.installDocument()
        try await pause(milliseconds: 160)
        view.string = "# new document\n"
        controller.installDocument()
        try await waitForPresentation(controller, source: view.string)
        try await pause(milliseconds: 500)
        try checks.expect(controller.presentation?.source == "# new document\n", "late parser result cannot replace the newer document presentation")
        try checks.expect(view.string == "# new document\n", "late parser result cannot change the newer document source")

        view.string = "# old pending switch\n"
        controller.installDocument()
        try await pause(milliseconds: 160)
        controller.setEnabled(false)
        try await pause(milliseconds: 500)
        try checks.expect(controller.hiddenMarkers.isEmpty, "late parser result cannot re-hide syntax after disabling layout")
        try checks.expect(view.string == "# old pending switch\n", "disable during parse retains raw source")
        controller.setEnabled(true)

        let count = InvocationCounter()
        let sameSourceView = CompositionTextView()
        let sameSourceController = MarkdownLayoutController(textView: sameSourceView, defaults: defaults, parser: { source in
            let invocation = await count.next()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + (invocation == 1 ? 0.45 : 0.02)) {
                    continuation.resume()
                }
            }
            return MarkdownPresentation(source: source, spans: [], markers: invocation == 1 ? [NSRange(location: 0, length: 1)] : [], codeBlocks: [])
        })
        sameSourceView.string = "# same bytes\n\nbody\n"
        sameSourceController.installDocument()
        try await pause(milliseconds: 160)
        sameSourceController.installDocument()
        try await waitForPresentation(sameSourceController, source: sameSourceView.string)
        try await pause(milliseconds: 500)
        let invocationCount = await count.value
        try checks.expect(invocationCount == 2, "same-source document replacement starts a new parser generation")
        try checks.expect(sameSourceController.presentation?.markers.isEmpty == true, "late same-source result cannot cross the document generation boundary")

        let byteView = CompositionTextView()
        let byteController = MarkdownLayoutController(textView: byteView, defaults: defaults, parser: { source in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
            }
            return MarkdownPresentation.parse(source)
        })
        byteView.string = "# é\n\nbody\n"
        byteController.installDocument()
        try await pause(milliseconds: 160)
        let decomposed = "# e\u{301}\n\nbody\n"
        // Storage observes bytes even without the NSTextView delegate's later scheduling call.
        byteView.string = decomposed
        try await pause(milliseconds: 400)
        try checks.expect(byteController.presentation?.source == nil, "canonically equivalent strings with different UTF-8 bytes reject stale parser output")
        try checks.expect(Data(byteView.string.utf8) == Data(decomposed.utf8), "stale NFC output does not rewrite decomposed source")
    }

    @MainActor
    static func waitForPresentation(_ controller: MarkdownLayoutController, source: String) async throws {
        for _ in 0..<100 {
            if let presentation = controller.presentation, Data(presentation.source.utf8) == Data(source.utf8) { return }
            try await pause(milliseconds: 30)
        }
        throw CheckFailure("presentation did not settle for \(source.prefix(60).debugDescription)")
    }

    static func pause(milliseconds: UInt64) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    @MainActor
    static func verifyRanges(_ result: MarkdownPresentation, checks: Checks) throws {
        let count = (result.source as NSString).length
        for range in result.spans.map(\.range) + result.markers + result.codeBlocks {
            try checks.expect(range.location != NSNotFound && range.location >= 0 && range.length > 0 && NSMaxRange(range) <= count, "parser publishes only bounded nonempty UTF-16 ranges")
            try checks.expect(Range(range, in: result.source) != nil, "parser range begins and ends at valid Swift string boundaries")
        }
    }

    static func nsRange(_ needle: String, in source: String) -> NSRange {
        (source as NSString).range(of: needle)
    }

    static func hasStyle(_ result: MarkdownPresentation, at needle: String, style: MarkdownPresentation.Style) -> Bool {
        let needleRange = nsRange(needle, in: result.source)
        guard needleRange.location != NSNotFound else { return false }
        return result.spans.contains { $0.style == style && NSIntersectionRange($0.range, needleRange).length == needleRange.length }
    }
}

@MainActor
final class Checks {
    private(set) var count = 0

    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(message) }
        count += 1
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

actor InvocationCounter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}
