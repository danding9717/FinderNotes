import AppKit

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    enum LeaveAction { case switchFile, closeWindow, quit }
    enum DraftDecision { case keepEditing, discard }

    let session: EditorSession
    let preview: MediaPreviewController
    let editor = CompositionTextView()
    let filePath = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let saveButton = NSButton(title: "保存", target: nil, action: nil)
    let copyButton = NSButton(title: "复制", target: nil, action: nil)
    let exportButton = NSButton(title: "导出", target: nil, action: nil)
    let previewButton = NSButton(title: "", target: nil, action: nil)
    let advancedButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let recoveryMenuItem = NSMenuItem(title: "恢复草稿…", action: nil, keyEquivalent: "")
    let conflictMenuItem = NSMenuItem(title: "核对外部版本…", action: nil, keyEquivalent: "")
    private let recoveryStore: DraftRecoveryStore?
    private let protectedExportDestination: (@MainActor (URL, String, String) async -> URL?)?
    private var recoveryTimer: Task<Void, Never>?
    private var recoveryIO: Task<Bool, Never>?
    private var lastRecoveryRecord: DraftRecoveryRecord?
    private var recoveryOperation: UInt64 = 0
    private let previewPane = NSView()
    private var previewWidth: NSLayoutConstraint?
    private var collapsedPreviewWidth: NSLayoutConstraint?
    private var previewContentConstraints: [NSLayoutConstraint] = []
    private(set) var isConfirming = false
    private var readingTask: Task<Void, Never>?
    private var savingTask: Task<Void, Never>?
    private var isExporting = false
    private var allowClosing = false
    private var autosaveGeneration: UInt64 = 0
    private let autosaveScheduler: any EditorAutosaveScheduling
    private let read: @Sendable ([URL]) throws -> NoteSnapshot
    private let save: @Sendable (NoteSaveRequest) throws -> NoteSnapshot
    private let export: @Sendable (MarkdownExportRequest) throws -> Void

    init(session: EditorSession = EditorSession(),
         read: @escaping @Sendable ([URL]) throws -> NoteSnapshot = { try NoteReader().read(urls: $0) },
         save: @escaping @Sendable (NoteSaveRequest) throws -> NoteSnapshot = { try NoteWriter().save($0) },
         export: @escaping @Sendable (MarkdownExportRequest) throws -> Void = { try MarkdownExporter().export($0) },
         autosaveScheduler: any EditorAutosaveScheduling = EditorAutosaveScheduler(),
         preview: MediaPreviewController = MediaPreviewController(),
         recoveryStore: DraftRecoveryStore? = nil,
         protectedExportDestination: (@MainActor (URL, String, String) async -> URL?)? = nil) {
        self.protectedExportDestination = protectedExportDestination
        self.recoveryStore = recoveryStore
        self.session = session
        self.preview = preview
        self.read = read
        self.save = save
        self.export = export
        self.autosaveScheduler = autosaveScheduler
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
        editor.inputStateDidChange = { [weak self] in
            self?.captureDraft()
            self?.scheduleRecovery()
            self?.scheduleAutosave()
            self?.renderStatus()
        }
        editor.setAccessibilityIdentifier("fn-note-editor")
        editor.setAccessibilityLabel("笔记正文")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = editor
        previewButton.target = self
        previewButton.action = #selector(togglePreview(_:))
        previewButton.refusesFirstResponder = true
        previewButton.isBordered = false
        previewButton.imagePosition = .imageOnly
        previewButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        previewButton.contentTintColor = .secondaryLabelColor
        previewButton.setAccessibilityIdentifier("fn-toggle-preview")
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        previewPane.addSubview(previewButton)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        previewContentConstraints = [
            preview.view.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            preview.view.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            preview.view.topAnchor.constraint(equalTo: previewPane.topAnchor, constant: 32),
            preview.view.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor)
        ]
        NSLayoutConstraint.activate([
            previewButton.topAnchor.constraint(equalTo: previewPane.topAnchor, constant: 2),
            previewButton.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor, constant: -2),
            previewButton.widthAnchor.constraint(equalToConstant: 28),
            previewButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        let body = NSStackView(views: [previewPane, scroll])
        body.orientation = .horizontal
        body.alignment = .top
        body.distribution = .fill
        body.spacing = 12
        body.detachesHiddenViews = true
        stack.addArrangedSubview(body)
        previewWidth = previewPane.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.4, constant: -4.8)
        collapsedPreviewWidth = previewPane.widthAnchor.constraint(equalToConstant: 32)
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 130),
            scroll.heightAnchor.constraint(equalTo: body.heightAnchor),
            previewPane.heightAnchor.constraint(equalTo: body.heightAnchor)
        ])
        let controls = NSStackView()
        controls.spacing = 6
        saveButton.target = self
        saveButton.action = #selector(saveNote(_:))
        saveButton.setAccessibilityIdentifier("fn-save")
        copyButton.target = self
        copyButton.action = #selector(copyDraft(_:))
        copyButton.toolTip = "复制完整草稿"
        exportButton.target = self
        exportButton.action = #selector(exportMarkdown(_:))
        exportButton.toolTip = "导出 Markdown 快照"
        exportButton.setAccessibilityIdentifier("fn-export-markdown")
        controls.addArrangedSubview(saveButton)
        controls.addArrangedSubview(copyButton)
        controls.addArrangedSubview(exportButton)
        let spacer = NSView()
        controls.addArrangedSubview(spacer)
        controls.setCustomSpacing(0, after: exportButton)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        let advancedMenu = NSMenu()
        // Preserve the same explicit busy-state rules as the original buttons.
        advancedMenu.autoenablesItems = false
        advancedMenu.addItem(withTitle: "高级选项", action: nil, keyEquivalent: "")
        conflictMenuItem.target = self
        conflictMenuItem.action = #selector(resolveConflict(_:))
        conflictMenuItem.setAccessibilityIdentifier("fn-resolve-conflict")
        recoveryMenuItem.target = self
        recoveryMenuItem.action = #selector(showRecovery(_:))
        recoveryMenuItem.setAccessibilityIdentifier("fn-recover-draft")
        advancedMenu.addItem(conflictMenuItem)
        advancedMenu.addItem(recoveryMenuItem)
        advancedButton.menu = advancedMenu
        advancedButton.refusesFirstResponder = true
        advancedButton.setAccessibilityIdentifier("fn-advanced-options")
        controls.addArrangedSubview(advancedButton)
        stack.addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.setAccessibilityIdentifier("fn-status")
        stack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(filePath)
        filePath.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        setPreviewExpanded(preview.isExpanded)
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
        cancelAutosave()
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
                if let current = self.session.snapshot,
                   current.url.path != candidate.url.path || current.identity != candidate.identity,
                   !self.session.requiresLeaveConfirmation, !self.editor.hasMarkedText(),
                   self.lastRecoveryRecord?.id == self.session.recoveryIdentifier {
                    // The user undid the entire draft to its confirmed baseline and is leaving.
                    // Clean up only after the new target was read successfully, never on a
                    // repeated service invocation or a failed open.
                    guard await self.discardRecovery() else {
                        self.session.reject("恢复记录未能清理，已保留当前文件。", ticket: ticket)
                        self.renderStatus()
                        return
                    }
                }
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
            self.scheduleAutosave()
        }
    }

    func captureDraft() {
        if session.snapshot != nil { session.updateDraft(editor.string) }
    }

    func textDidChange(_ notification: Notification) {
        captureDraft()
        scheduleRecovery()
        scheduleAutosave()
        renderStatus()
    }

    private func cancelAutosave() {
        autosaveGeneration &+= 1
        autosaveScheduler.cancel()
    }

    private func scheduleAutosave() {
        cancelAutosave()
        guard !isConfirming, !editor.hasMarkedText(), let ticket = session.autosaveTicket else { return }
        let generation = autosaveGeneration
        autosaveScheduler.schedule { [weak self] in
            guard let self, self.autosaveGeneration == generation else { return }
            self.captureDraft()
            guard !self.isConfirming, !self.editor.hasMarkedText(), self.session.isCurrent(ticket) else { return }
            self.performSave(automatically: true)
        }
    }

    /// Called only after changing the target (never for status changes or repeated services).
    func renderInstalledSnapshot() {
        preview.install(snapshot: session.recoveryWriteBlocked ? nil : session.snapshot)
        if session.snapshot != nil { setPreviewExpanded(true) }
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

    @objc func togglePreview(_ sender: Any?) {
        setPreviewExpanded(!preview.isExpanded)
    }

    private func setPreviewExpanded(_ expanded: Bool) {
        let focusWasInPreview = (window?.firstResponder as? NSView)?.isDescendant(of: preview.view) == true
        // The control stays mounted while hidden preview content leaves the layout entirely.
        // This also keeps the placeholder's minimum width from widening the collapsed rail.
        if expanded {
            collapsedPreviewWidth?.isActive = false
            previewWidth?.isActive = true
            if preview.view.superview == nil {
                previewPane.addSubview(preview.view)
                NSLayoutConstraint.activate(previewContentConstraints)
            }
        } else {
            NSLayoutConstraint.deactivate(previewContentConstraints)
            preview.view.removeFromSuperview()
            previewWidth?.isActive = false
            collapsedPreviewWidth?.isActive = true
        }
        preview.setExpanded(expanded)
        let previewAction = expanded ? "收起预览" : "展开预览"
        previewButton.toolTip = previewAction
        previewButton.setAccessibilityLabel(previewAction)
        if !expanded, focusWasInPreview { window?.makeFirstResponder(editor) }
        // Keep the native editor and its input state intact while only the layout changes.
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func renderStatus() {
        statusLabel.stringValue = session.status
        statusLabel.textColor = session.failure == nil && session.saveIssue == nil ? .secondaryLabelColor : .systemRed
        recoveryMenuItem.isEnabled = recoveryStore != nil && !isConfirming && !session.isSaving && !session.isLoading && !isExporting
        conflictMenuItem.isEnabled = session.snapshot != nil && !isConfirming && !session.isSaving && !session.isLoading && !isExporting
        advancedButton.isEnabled = recoveryMenuItem.isEnabled || conflictMenuItem.isEnabled
        saveButton.isEnabled = session.canBeginSave && !isConfirming
        copyButton.isEnabled = session.snapshot != nil
        exportButton.isEnabled = session.snapshot != nil && !isExporting && !isConfirming
        window?.isDocumentEdited = session.requiresLeaveConfirmation
    }

    var canSaveFromMenu: Bool { session.canBeginSave && !isConfirming }
    var canExportFromMenu: Bool { session.snapshot != nil && !isExporting && !isConfirming }

    private func showActionMessage(_ message: String, isError: Bool = false) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    @objc func saveNote(_ sender: Any?) {
        performSave(automatically: false)
    }

    private func performSave(automatically: Bool) {
        guard !isConfirming else { return }
        guard !editor.hasMarkedText() else {
            cancelAutosave()
            if !automatically { showActionMessage("请先完成中文输入，再保存笔记。") }
            return
        }
        captureDraft()
        if automatically, session.autosaveTicket == nil { return }
        cancelAutosave()
        guard let ticket = session.beginSaving() else {
            if !automatically { NSSound.beep() }
            return
        }
        renderStatus()
        let save = self.save
        // Enqueue before the xattr write. Even if the process exits during saving, the prior
        // baseline is retained; recovery always rechecks it and never silently resumes autosave.
        let recovery = queueCurrentRecovery()
        savingTask = Task { [weak self] in
            let protected = await recovery?.value ?? true
            if automatically, !protected {
                guard let self else { return }
                _ = self.session.failSaving("草稿恢复文件未能更新，请手动保存或导出。", uncertain: false, ticket: ticket)
                self.savingTask = nil
                self.renderStatus()
                return
            }
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
                var message = error.localizedDescription
                if case .conflict? = error as? NoteWriteError {
                    message += " 请使用“高级选项 → 核对外部版本”。"
                }
                _ = self.session.failSaving(message, uncertain: uncertain, ticket: ticket)
            }
            self.savingTask = nil
            self.captureDraft()
            if self.session.saveIssue == nil, !self.session.isDirty, !self.editor.hasMarkedText() {
                _ = self.queueRecoveryRemoval(id: self.session.recoveryIdentifier)
            } else if !self.editor.hasMarkedText() {
                _ = self.queueCurrentRecovery()
            }
            self.renderStatus()
            self.scheduleAutosave()
        }
    }

    @objc func exportMarkdown(_ sender: Any?) {
        guard session.snapshot != nil, !isExporting, !isConfirming else { return }
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
        cancelAutosave()
        captureDraft()
        guard session.requiresLeaveConfirmation || editor.hasMarkedText() else {
            return await discardRecovery()
        }
        guard !isConfirming, let window else { return false }
        isConfirming = true
        renderStatus()
        defer {
            isConfirming = false
            renderStatus()
        }
        let response = await makeDiscardAlert(for: action).beginSheetModal(for: window)
        switch response {
        case .alertSecondButtonReturn:
            let revision = session.draftRevision
            guard await discardRecovery(), session.draftRevision == revision else { return false }
            return applyDecision(.discard)
        default:
            // Returning to editing starts a fresh quiet period, without flushing on leave.
            isConfirming = false
            scheduleAutosave()
            return applyDecision(.keepEditing)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClosing { return true }
        guard !isConfirming, !session.isSaving, !isExporting else { return false }
        cancelAutosave()
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
        cancelAutosave()
        session.invalidateLoading()
        readingTask?.cancel()
        let canQuit = await confirmLeaving(.quit)
        if canQuit { preview.close() }
        return canQuit
    }
}

extension EditorWindowController {
    // Only completed input is persisted. A cancelled timer does not cancel a write already
    // queued: all puts/removals join the preceding operation, including explicit discard.
    private func scheduleRecovery() {
        recoveryTimer?.cancel()
        guard recoveryStore != nil, !editor.hasMarkedText(), session.snapshot != nil else { return }
        let revision = session.draftRevision
        let id = session.recoveryIdentifier
        recoveryTimer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled, !self.editor.hasMarkedText(),
                  self.session.recoveryIdentifier == id, self.session.draftRevision == revision else { return }
            _ = self.queueCurrentRecovery()
        }
    }

    @discardableResult
    func queueCurrentRecovery() -> Task<Bool, Never>? {
        recoveryTimer?.cancel()
        guard let store = recoveryStore, !editor.hasMarkedText(), let snapshot = session.snapshot else { return nil }
        // Persist undo-to-baseline as the newest draft too, rather than leaving a stale earlier
        // edit on disk. Removal is reserved for confirmed save or an explicit leave/discard.
        guard session.recoveryRecord != nil || lastRecoveryRecord?.id == session.recoveryIdentifier else { return nil }
        let record = DraftRecoveryRecord(id: session.recoveryIdentifier, baseline: snapshot,
                                         draft: session.draft, revision: session.draftRevision)
        if let previous = lastRecoveryRecord,
           previous.id == record.id, previous.revision == record.revision,
           previous.snapshot.content == record.snapshot.content, session.recoveryIssue == nil {
            return recoveryIO
        }
        lastRecoveryRecord = record
        let preceding = recoveryIO
        recoveryOperation &+= 1
        let operation = recoveryOperation
        let task = Task { [weak self] () -> Bool in
            _ = await preceding?.value
            do {
                try await store.put(record)
                if let self, self.recoveryOperation == operation,
                   self.session.recoveryIdentifier == record.id {
                    self.session.setRecoveryIssue(nil)
                    self.renderStatus()
                }
                return true
            } catch {
                if let self, self.session.recoveryIdentifier == record.id {
                    self.session.setRecoveryIssue(error.localizedDescription)
                    self.cancelAutosave()
                    self.renderStatus()
                }
                return false
            }
        }
        recoveryIO = task
        return task
    }

    @discardableResult
    private func queueRecoveryRemoval(id: UUID) -> Task<Bool, Never>? {
        recoveryTimer?.cancel()
        guard let store = recoveryStore else { return nil }
        // A never-edited empty/clean window owns no record. Closing it must not acquire
        // another instance's recovery lock or fail merely because that directory is busy.
        guard lastRecoveryRecord?.id == id || session.recoveryRecord != nil else { return nil }
        let preceding = recoveryIO
        recoveryOperation &+= 1
        let operation = recoveryOperation
        let task = Task { [weak self] () -> Bool in
            _ = await preceding?.value
            do {
                try await store.remove(id: id)
                if let self, self.recoveryOperation == operation {
                    self.lastRecoveryRecord = nil
                    if self.session.recoveryIdentifier == id { self.session.setRecoveryIssue(nil) }
                    self.renderStatus()
                }
                return true
            } catch {
                if let self, self.session.recoveryIdentifier == id {
                    self.session.setRecoveryIssue("恢复文件清理失败：" + error.localizedDescription)
                    self.cancelAutosave()
                    self.renderStatus()
                }
                return false
            }
        }
        recoveryIO = task
        return task
    }

    func discardRecovery() async -> Bool {
        recoveryTimer?.cancel()
        let revision = session.draftRevision
        let editable = editor.isEditable
        editor.isEditable = false
        defer { editor.isEditable = editable }
        let result = queueRecoveryRemoval(id: session.recoveryIdentifier)
        let removed = await result?.value ?? true
        guard session.draftRevision == revision else {
            _ = await queueCurrentRecovery()?.value
            return false
        }
        return removed
    }

    func refreshRecoveryAvailability() {
        guard let store = recoveryStore else { return }
        Task { [weak self] in
            do {
                let records = try await store.records()
                self?.recoveryMenuItem.title = records.isEmpty ? "恢复草稿…" : "恢复草稿（\(records.count)）…"
            } catch {
                self?.showActionMessage("恢复目录暂不可用：" + error.localizedDescription, isError: true)
            }
        }
    }

    @objc func showRecovery(_ sender: Any?) {
        guard let store = recoveryStore, !isConfirming, !session.isSaving, !session.isLoading,
              !isExporting, !editor.hasMarkedText(), let window else { return }
        cancelAutosave()
        isConfirming = true
        renderStatus()
        Task {
            defer { isConfirming = false; renderStatus(); scheduleAutosave() }
            do {
                _ = await recoveryIO?.value
                let records = try await store.records().filter { $0.id != session.recoveryIdentifier }
                guard !records.isEmpty else {
                    let alert = NSAlert()
                    alert.messageText = "没有已落盘的待恢复草稿"
                    alert.informativeText = "恢复文件只保护未保存的草稿；尚未落盘的最后输入不在保证范围内。"
                    alert.addButton(withTitle: "返回编辑")
                    _ = await alert.beginSheetModal(for: window)
                    return
                }
                let chooser = NSAlert()
                chooser.messageText = "选择已落盘的草稿"
                chooser.informativeText = "恢复后暂停自动保存。将重新核对原文件身份及正文基线；原件消失或被替换时，只保留和导出草稿。"
                let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 28))
                for record in records {
                    popup.addItem(withTitle: "\(record.snapshot.url.path) · \(record.updatedAt.formatted()) · \(record.id.uuidString.prefix(8))")
                }
                chooser.accessoryView = popup
                chooser.addButton(withTitle: "返回编辑")
                chooser.addButton(withTitle: "恢复所选草稿")
                guard await chooser.beginSheetModal(for: window) == .alertSecondButtonReturn else { return }
                let record = records[popup.indexOfSelectedItem]
                let read = self.read
                let current = await Task.detached { try? read([record.snapshot.url]) }.value
                // Choosing/cancelling the list never discards the active draft. Only after a
                // record is selected do we ask to leave, then immediately install the record.
                isConfirming = false
                guard await confirmLeaving(.switchFile) else { return }
                if session.restoreRecovery(record: record, current: current) {
                    lastRecoveryRecord = record
                    renderInstalledSnapshot()
                }
            } catch {
                session.setRecoveryIssue(error.localizedDescription)
            }
        }
    }

    func makeConflictAlert(external: NoteSnapshot) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "核对文件中的笔记"
        let state: String
        switch external.content {
        case .missing: state = "外部自定义笔记属性已不存在。"
        case .present(let bytes): state = bytes.isEmpty ? "外部自定义笔记是空正文。" : "已读取外部自定义笔记正文。"
        }
        alert.informativeText = state + "\n载入外部版前先导出本地草稿；覆盖前先导出外部版，再确认写入。取消或导出失败会保留当前草稿。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "导出草稿并载入外部版…")
        alert.addButton(withTitle: "备份外部版并覆盖…")
        alert.addButton(withTitle: "仅导出本地草稿…")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[2].hasDestructiveAction = true
        return alert
    }

    @objc func resolveConflict(_ sender: Any?) {
        guard !isConfirming, !session.isSaving, !session.isLoading, !isExporting,
              !editor.hasMarkedText(), let baseline = session.snapshot, let window else { return }
        cancelAutosave()
        captureDraft()
        let revision = session.draftRevision
        let id = session.recoveryIdentifier
        let read = self.read
        isConfirming = true
        renderStatus()
        Task {
            defer { isConfirming = false; renderStatus(); scheduleAutosave() }
            do {
                let external = try await Task.detached { try read([baseline.url]) }.value
                guard session.draftRevision == revision, session.recoveryIdentifier == id else { return }
                guard external.url.path == baseline.url.path, external.identity == baseline.identity else {
                    session.blockRecoveryWrite("原文件身份已变化；当前草稿只能保留或导出，不能写入同名替换文件。")
                    return
                }
                let response = await makeConflictAlert(external: external).beginSheetModal(for: window)
                guard session.draftRevision == revision, session.recoveryIdentifier == id else { return }
                if response == NSApplication.ModalResponse(rawValue: 1003) {
                    _ = await exportProtectedSnapshot(bytes: Data(session.draft.utf8), source: baseline.url, suffix: ".local-draft.note.md", title: "导出本地草稿")
                    return
                }
                guard response == .alertSecondButtonReturn || response == .alertThirdButtonReturn else { return }
                let replacingDraft = response == .alertSecondButtonReturn
                let bytes: Data
                let suffix: String
                if replacingDraft {
                    bytes = Data(session.draft.utf8)
                    suffix = ".local-draft.note.md"
                } else {
                    switch external.content {
                    case .missing:
                        bytes = Data("# 外部笔记状态\n\n自定义属性 com.findernotes.note.v1 不存在（不是空正文）。\n".utf8)
                        suffix = ".external-missing.note.md"
                    case .present(let data): bytes = data; suffix = ".external.note.md"
                    }
                }
                guard await exportProtectedSnapshot(bytes: bytes, source: baseline.url, suffix: suffix,
                    title: replacingDraft ? "载入前导出本地草稿" : "覆盖前备份外部版本") else { return }
                // Re-read after the export sheet: neither a changed target nor a newer external
                // version is covered by the preceding user choice.
                let checked = try await Task.detached { try read([baseline.url]) }.value
                guard session.draftRevision == revision, session.recoveryIdentifier == id,
                      checked.identity == external.identity, checked.url.path == external.url.path,
                      checked.content == external.content else {
                    session.pauseForExternalIssue("确认期间文件或正文发生变化；导出快照已保留，请重新核对。")
                    return
                }
                if replacingDraft {
                    guard await discardRecovery() else { return }
                    guard session.applyExternal(checked, replacingDraft: true, confirmedRevision: revision) else { return }
                    renderInstalledSnapshot()
                } else {
                    let confirm = NSAlert()
                    confirm.messageText = "用本地草稿覆盖外部笔记？"
                    confirm.informativeText = "外部版本已导出。将把当前本地草稿保存到原文件的自定义笔记属性；写前仍会检查文件身份和刚确认的外部基线。"
                    confirm.addButton(withTitle: "继续编辑")
                    confirm.addButton(withTitle: "明确覆盖")
                    confirm.buttons[1].hasDestructiveAction = true
                    guard await confirm.beginSheetModal(for: window) == .alertSecondButtonReturn,
                          session.applyExternal(checked, replacingDraft: false, confirmedRevision: revision) else { return }
                    _ = await queueCurrentRecovery()?.value
                    isConfirming = false
                    performSave(automatically: false)
                }
            } catch {
                session.pauseForExternalIssue("外部版本读取失败；未载入或覆盖：" + error.localizedDescription)
            }
        }
    }

    private func exportProtectedSnapshot(bytes: Data, source: URL, suffix: String, title: String) async -> Bool {
        guard let window else { return false }
        let destination: URL
        if let choose = protectedExportDestination {
            guard let chosen = await choose(source, suffix, title) else { return false }
            destination = chosen
        } else {
            let panel = NSSavePanel()
            panel.title = title
            panel.prompt = "导出并继续"
            panel.nameFieldStringValue = source.lastPathComponent + suffix
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            panel.canCreateDirectories = true
            guard await panel.beginSheetModal(for: window) == .OK, let chosen = panel.url else { return false }
            destination = chosen
        }
        let export = self.export
        do {
            try await Task.detached { try export(MarkdownExportRequest(source: source, destination: destination, bytes: bytes)) }.value
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "导出失败，当前草稿仍保留"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "返回编辑")
            _ = await alert.beginSheetModal(for: window)
            return false
        }
    }
}
