import AppKit

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    enum LeaveAction { case switchFile, closeWindow, quit }
    enum DraftDecision { case keepEditing, copy, discard }

    let session: EditorSession
    let editor = NSTextView()
    let fileName = NSTextField(labelWithString: "未打开文件")
    let filePath = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let saveButton = NSButton(title: "保存", target: nil, action: nil)
    let copyButton = NSButton(title: "复制草稿", target: nil, action: nil)
    private(set) var isConfirming = false
    private var readingTask: Task<Void, Never>?
    private var allowClosing = false
    private let read: @Sendable ([URL]) throws -> NoteSnapshot

    init(session: EditorSession = EditorSession(),
         read: @escaping @Sendable ([URL]) throws -> NoteSnapshot = { try NoteReader().read(urls: $0) }) {
        self.session = session
        self.read = read
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
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        fileName.font = .systemFont(ofSize: 18, weight: .semibold)
        fileName.lineBreakMode = .byTruncatingMiddle
        fileName.isSelectable = true
        fileName.setAccessibilityIdentifier("fn-file-name")
        filePath.font = .systemFont(ofSize: 11)
        filePath.textColor = .secondaryLabelColor
        filePath.isSelectable = true
        filePath.maximumNumberOfLines = 2
        filePath.lineBreakMode = .byTruncatingMiddle
        filePath.setAccessibilityIdentifier("fn-file-path")
        stack.addArrangedSubview(fileName)
        stack.addArrangedSubview(filePath)

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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130),
            fileName.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filePath.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        let controls = NSStackView()
        controls.spacing = 10
        saveButton.isEnabled = false
        saveButton.toolTip = "当前尚不支持保存"
        copyButton.target = self
        copyButton.action = #selector(copyDraft(_:))
        controls.addArrangedSubview(saveButton)
        controls.addArrangedSubview(copyButton)
        stack.addArrangedSubview(controls)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.setAccessibilityIdentifier("fn-status")
        stack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let notice = NSTextField(wrappingLabelWithString: "当前尚不支持保存，草稿仅保留在本次运行中。离开前请复制需要保留的文字。")
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        stack.addArrangedSubview(notice)
        notice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func showEditor() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func receive(_ urls: [URL]) {
        showEditor()
        guard !isConfirming else {
            NSSound.beep()
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
        fileName.stringValue = session.snapshot?.url.lastPathComponent ?? "未打开文件"
        filePath.stringValue = session.snapshot?.url.path ?? ""
        filePath.toolTip = session.snapshot?.url.path
        window?.title = session.snapshot.map { "\($0.url.lastPathComponent) — FinderNotes" } ?? "FinderNotes"
        window?.representedURL = session.snapshot?.url
        renderStatus()
        if session.snapshot != nil { window?.makeFirstResponder(editor) }
    }

    func renderStatus() {
        statusLabel.stringValue = session.status
        statusLabel.textColor = session.failure == nil ? .secondaryLabelColor : .systemRed
        copyButton.isEnabled = session.snapshot != nil
        window?.isDocumentEdited = session.isDirty
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
        alert.informativeText = "当前尚不支持保存。继续编辑或复制草稿会保留当前窗口；只有明确丢弃才会离开。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "复制草稿")
        let label: String
        switch action {
        case .switchFile: label = "丢弃并切换"
        case .closeWindow: label = "丢弃并关闭"
        case .quit: label = "丢弃并退出"
        }
        alert.addButton(withTitle: label)
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[2].hasDestructiveAction = true
        return alert
    }

    func applyDecision(_ decision: DraftDecision, pasteboard: NSPasteboard = .general) -> Bool {
        switch decision {
        case .keepEditing: return false
        case .copy: _ = copyDraft(to: pasteboard); return false
        case .discard: return true
        }
    }

    func confirmLeaving(_ action: LeaveAction) async -> Bool {
        captureDraft()
        guard session.isDirty || editor.hasMarkedText() else { return true }
        guard !isConfirming, let window else { return false }
        isConfirming = true
        defer { isConfirming = false }
        let response = await makeDiscardAlert(for: action).beginSheetModal(for: window)
        switch response {
        case .alertSecondButtonReturn: return applyDecision(.copy)
        case .alertThirdButtonReturn: return applyDecision(.discard)
        default: return applyDecision(.keepEditing)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClosing { return true }
        guard !isConfirming else { return false }
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
        guard !isConfirming else { return false }
        session.invalidateLoading()
        readingTask?.cancel()
        return await confirmLeaving(.quit)
    }
}
