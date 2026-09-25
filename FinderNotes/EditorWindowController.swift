import AppKit

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    enum LeaveAction { case switchFile, closeWindow, quit }
    enum DraftDecision { case keepEditing, discard }

    let session: EditorSession
    let editor = NSTextView()
    let filePath = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let saveButton = NSButton(title: "保存", target: nil, action: nil)
    let copyButton = NSButton(title: "复制草稿", target: nil, action: nil)
    let exportButton = NSButton(title: "导出 Markdown…", target: nil, action: nil)
    private(set) var isConfirming = false
    private var readingTask: Task<Void, Never>?
    private var savingTask: Task<Void, Never>?
    private var isExporting = false
    private var allowClosing = false
    private let read: @Sendable ([URL]) throws -> NoteSnapshot
    private let save: @Sendable (NoteSaveRequest) throws -> NoteSnapshot
    private let export: @Sendable (MarkdownExportRequest) throws -> Void

    init(session: EditorSession = EditorSession(),
         read: @escaping @Sendable ([URL]) throws -> NoteSnapshot = { try NoteReader().read(urls: $0) },
         save: @escaping @Sendable (NoteSaveRequest) throws -> NoteSnapshot = { try NoteWriter().save($0) },
         export: @escaping @Sendable (MarkdownExportRequest) throws -> Void = { try MarkdownExporter().export($0) }) {
        self.session = session
        self.read = read
        self.save = save
        self.export = export
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "FinderNotes"
        window.minSize = NSSize(width: 500, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        configureContent()
        renderInstalledSnapshot()
    }

    required init?(coder: NSCoder) { fatalError("Use init(session:)") }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        filePath.font = .systemFont(ofSize: 11)
        filePath.textColor = .secondaryLabelColor
        filePath.isSelectable = true
        filePath.maximumNumberOfLines = 1
        filePath.lineBreakMode = .byTruncatingMiddle
        filePath.setAccessibilityIdentifier("fn-file-path")

        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = .systemFont(ofSize: 16)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = self
        editor.setAccessibilityIdentifier("fn-note-editor")
        editor.setAccessibilityLabel("笔记正文")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = editor
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130)
        ])
        let controls = NSStackView()
        controls.spacing = 10
        saveButton.target = self
        saveButton.action = #selector(saveNote(_:))
        saveButton.setAccessibilityIdentifier("fn-save")
        copyButton.target = self
        copyButton.action = #selector(copyDraft(_:))
        exportButton.target = self
        exportButton.action = #selector(exportMarkdown(_:))
        exportButton.setAccessibilityIdentifier("fn-export-markdown")
        controls.addArrangedSubview(saveButton)
        controls.addArrangedSubview(copyButton)
        controls.addArrangedSubview(exportButton)
        stack.addArrangedSubview(controls)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.setAccessibilityIdentifier("fn-status")
        stack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(filePath)
        filePath.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func showEditor() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func receive(_ urls: [URL]) {
        showEditor()
        guard !isConfirming, !session.isSaving, !isExporting else {
            NSSound.beep()
            if session.isSaving { showActionMessage("正在保存笔记，请等待结果后再切换文件。") }
            if isExporting { showActionMessage("正在导出 Markdown，请等待结果后再切换文件。") }
            return
        }
        captureDraft()
        let ticket = session.beginLoading()
        renderStatus()
        readingTask?.cancel()
        let read = self.read
        readingTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try read(urls) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.captureDraft()
            switch result {
            case .failure(let error):
                self.session.reject(error.localizedDescription, ticket: ticket)
            case .success(let candidate):
                switch self.session.resolve(candidate, ticket: ticket, protectsMarkedText: self.editor.hasMarkedText()) {
                case .stale: return
                case .reused: break // Never assign editor.string or touch its input state.
                case .installed: self.renderInstalledSnapshot()
                case .needsDiscard:
                    let revision = self.session.draftRevision
                    if await self.confirmLeaving(.switchFile) {
                        if self.session.acceptReplacement(candidate, ticket: ticket, confirmedRevision: revision) {
                            self.renderInstalledSnapshot()
                        } else if self.session.isCurrent(ticket) {
                            self.session.reject("草稿刚有变化，已保留当前文件；请重新选择要打开的文件。", ticket: ticket)
                        }
                    }
                }
            }
            self.renderStatus()
        }
    }

    func captureDraft() {
        if session.snapshot != nil { session.updateDraft(editor.string) }
    }

    func textDidChange(_ notification: Notification) {
        captureDraft()
        renderStatus()
    }

    /// Called only after changing the target (never for status changes or repeated services).
    func renderInstalledSnapshot() {
        editor.string = session.draft
        editor.undoManager?.removeAllActions()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollToBeginningOfDocument(nil)
        editor.isEditable = session.snapshot != nil
        editor.isSelectable = session.snapshot != nil
        filePath.stringValue = session.snapshot?.url.path ?? ""
        filePath.toolTip = session.snapshot?.url.path
        window?.title = session.snapshot.map { "\($0.url.lastPathComponent) — FinderNotes" } ?? "FinderNotes"
        window?.representedURL = session.snapshot?.url
        renderStatus()
        if session.snapshot != nil { window?.makeFirstResponder(editor) }
    }

    func renderStatus() {
        statusLabel.stringValue = session.status
        statusLabel.textColor = session.failure == nil && session.saveIssue == nil ? .secondaryLabelColor : .systemRed
        saveButton.isEnabled = session.canBeginSave && !isConfirming
        copyButton.isEnabled = session.snapshot != nil
        exportButton.isEnabled = session.snapshot != nil && !isExporting
        window?.isDocumentEdited = session.requiresLeaveConfirmation
    }

    var canSaveFromMenu: Bool { session.canBeginSave && !isConfirming }
    var canExportFromMenu: Bool { session.snapshot != nil && !isExporting }

    private func showActionMessage(_ message: String, isError: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    @objc func saveNote(_ sender: Any?) {
        guard !isConfirming else { return }
        guard !editor.hasMarkedText() else {
            showActionMessage("请先完成中文输入，再保存笔记。")
            return
        }
        captureDraft()
        guard let ticket = session.beginSaving() else {
            NSSound.beep()
            return
        }
        renderStatus()
        let save = self.save
        savingTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try save(ticket.request) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let candidate):
                if !self.session.completeSaving(candidate, ticket: ticket) {
                    _ = self.session.failSaving("保存结果与请求不符，请重新打开文件核对。",
                                                uncertain: true, ticket: ticket)
                }
            case .failure(let error):
                let uncertain = (error as? NoteWriteError)?.resultWasUnconfirmed ?? false
                _ = self.session.failSaving(error.localizedDescription, uncertain: uncertain, ticket: ticket)
            }
            self.savingTask = nil
            self.renderStatus()
        }
    }

    @objc func exportMarkdown(_ sender: Any?) {
        guard session.snapshot != nil, !isExporting else { return }
        guard !editor.hasMarkedText() else {
            showActionMessage("请先完成中文输入，再导出 Markdown。")
            return
        }
        captureDraft()
        guard let source = session.snapshot?.url, let window else { return }
        // The sheet may stay open while the editor changes. Export these exact bytes.
        let bytes = Data(session.draft.utf8)
        let panel = NSSavePanel()
        panel.title = "导出 Markdown 快照"
        panel.prompt = "导出"
        panel.nameFieldStringValue = MarkdownExporter.defaultFileName(for: source)
        panel.directoryURL = source.deletingLastPathComponent()
        panel.canCreateDirectories = true
        isExporting = true
        renderStatus()
        let export = self.export
        Task { [weak self] in
            let response = await panel.beginSheetModal(for: window)
            guard let self else { return }
            guard response == .OK, let destination = panel.url else {
                self.isExporting = false
                self.renderStatus()
                return
            }
            let request = MarkdownExportRequest(source: source, destination: destination, bytes: bytes)
            let result = await Task.detached(priority: .userInitiated) {
                Result { try export(request) }
            }.value
            self.isExporting = false
            self.renderStatus()
            switch result {
            case .success:
                self.showActionMessage("\(self.session.status)\n已导出 Markdown 快照：\(destination.lastPathComponent)",
                                       isError: self.session.failure != nil || self.session.saveIssue != nil)
            case .failure(let error):
                self.showActionMessage("\(self.session.status)\n导出失败：\(error.localizedDescription) 草稿仍保留。", isError: true)
            }
        }
    }

    @objc func copyDraft(_ sender: Any?) {
        captureDraft()
        _ = copyDraft(to: .general)
    }

    @discardableResult
    func copyDraft(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let copied = pasteboard.setString(session.draft, forType: .string)
        if !copied { statusLabel.stringValue = "复制失败；草稿仍保留，请重试。" }
        return copied
    }

    func makeDiscardAlert(for action: LeaveAction) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "草稿尚未保存"
        let label: String
        switch action {
        case .switchFile: label = "丢弃并切换"
        case .closeWindow: label = "丢弃并关闭"
        case .quit: label = "丢弃并退出"
        }
        alert.informativeText = "请先返回编辑器完成输入并点击“保存”。选择“\(label)”会放弃未保存的改动。"
        alert.addButton(withTitle: "返回编辑")
        alert.addButton(withTitle: label)
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].hasDestructiveAction = true
        return alert
    }

    func applyDecision(_ decision: DraftDecision) -> Bool {
        switch decision {
        case .keepEditing: return false
        case .discard: return true
        }
    }

    func confirmLeaving(_ action: LeaveAction) async -> Bool {
        guard !session.isSaving else { return false }
        captureDraft()
        guard session.requiresLeaveConfirmation || editor.hasMarkedText() else { return true }
        guard !isConfirming, let window else { return false }
        isConfirming = true
        renderStatus()
        defer {
            isConfirming = false
            renderStatus()
        }
        let response = await makeDiscardAlert(for: action).beginSheetModal(for: window)
        switch response {
        case .alertSecondButtonReturn: return applyDecision(.discard)
        default: return applyDecision(.keepEditing)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClosing { return true }
        guard !isConfirming, !session.isSaving, !isExporting else { return false }
        session.invalidateLoading()
        readingTask?.cancel()
        Task {
            guard await confirmLeaving(.closeWindow) else { renderStatus(); return }
            session.close()
            renderInstalledSnapshot()
            allowClosing = true
            sender.close()
            allowClosing = false
        }
        return false
    }

    func prepareToQuit() async -> Bool {
        guard !isConfirming, !session.isSaving, !isExporting else { return false }
        session.invalidateLoading()
        readingTask?.cancel()
        return await confirmLeaving(.quit)
    }
}
