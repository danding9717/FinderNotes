import AppKit

/// Runs the product's real Swift sources with a replacement entry point.
/// Hidden windows, no servicesProvider registration, no default recovery directory.
@MainActor
final class ReplyRecordingApplication: NSApplication {
    var terminationReplies: [Bool] = []

    override func reply(toApplicationShouldTerminate shouldTerminate: Bool) {
        terminationReplies.append(shouldTerminate)
    }
}

@MainActor
final class PausedAutosaveScheduler: EditorAutosaveScheduling {
    private(set) var scheduledCount = 0
    private(set) var cancelledCount = 0
    func schedule(_ action: @escaping @MainActor () -> Void) { scheduledCount += 1 }
    func cancel() { cancelledCount += 1 }
}

@main
struct FN12ComponentChecks {
    @MainActor
    static func main() async {
        let app = ReplyRecordingApplication.shared as! ReplyRecordingApplication
        app.setActivationPolicy(.prohibited)
        var passed = 0
        var failed = 0
        func check(_ condition: @autoclosure () -> Bool, _ title: String) {
            if condition() { passed += 1; print("PASS: \(title)") }
            else { failed += 1; print("FAIL: \(title)") }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(120)) }

        let delegate = AppDelegate()
        let modal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let modalSession = app.beginModalSession(for: modal)
        _ = app.runModalSession(modalSession)
        check(app.modalWindow === modal, "real AppKit app-modal session is active")
        check(delegate.applicationShouldTerminate(app) == .terminateCancel,
              "app-modal update alert cancels quit synchronously")
        check(delegate.terminationTask == nil && app.terminationReplies.isEmpty,
              "app-modal quit creates no asynchronous task or reply")
        app.endModalSession(modalSession)
        modal.orderOut(nil)
        check(app.modalWindow == nil, "ending real modal session releases modal window")
        check(delegate.applicationShouldTerminate(app) == .terminateNow,
              "no editor may quit synchronously")
        let coordinator = UpdateCoordinator()
        check(!coordinator.canCheckForUpdates, "standard harness does not connect to personal feed")
        let item = NSMenuItem(title: "检查更新…", action: #selector(UpdateCoordinator.checkForUpdates(_:)), keyEquivalent: "")
        check(!coordinator.validateMenuItem(item), "disabled updater disables Check for Updates menu")
        coordinator.checkForUpdates(nil)
        check(!coordinator.canCheckForUpdates, "disabled action remains harmless")
        delegate.updateCoordinator = coordinator
        delegate.setupMenu()
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        let updateItem = appMenu?.items.first { $0.title == "检查更新…" }
        check(updateItem != nil, "application menu includes Check for Updates")
        check(updateItem?.target === coordinator, "menu targets real update coordinator")
        check(updateItem?.action == #selector(UpdateCoordinator.checkForUpdates(_:)), "menu routes real Sparkle action")
        check(appMenu?.items.first?.title == "关于 FinderNotes", "About remains before update command")

        let session = EditorSession()
        let validationRoot = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = URL(fileURLWithPath: "/FN12-component-fixture.png")
        let baseline = NoteSnapshot(url: sourceURL,
                                    identity: FileIdentity(device: 1, inode: 2, birthSeconds: 1),
                                    content: .present(Data("已保存正文\n".utf8)))
        session.install(baseline)
        let autosaveScheduler = PausedAutosaveScheduler()
        let controller = EditorWindowController(session: session,
                                                autosaveScheduler: autosaveScheduler, recoveryStore: nil)
        controller.editor.string = baseline.content.text
        delegate.controller = controller
        coordinator.interactionStateDidChange = { active in controller.setUpdateInterfaceActive(active) }
        check(controller.window?.isVisible == false, "component editor stays hidden")
        controller.window?.makeFirstResponder(controller.editor)
        controller.editor.setSelectedRange(NSRange(location: 2, length: 3))
        let selectedRange = controller.editor.selectedRange()
        let firstResponder = controller.window?.firstResponder
        let originalRevision = session.draftRevision
        controller.togglePin(nil)
        check(controller.isPinned && controller.window?.level == .floating, "pin preference initially floats editor")
        coordinator.standardUserDriverWillShowModalAlert()
        check(coordinator.isUpdateInterfaceActive && controller.window?.level == .normal,
              "Sparkle interaction temporarily lowers pinned editor")
        check(controller.isPinned && controller.pinButton.state == .on,
              "temporary lowering preserves pin preference and button")
        let pinItem = NSMenuItem(title: "置顶", action: #selector(AppDelegate.togglePin(_:)), keyEquivalent: "")
        check(delegate.validateMenuItem(pinItem) && pinItem.state == .on,
              "temporary lowering preserves pin menu selection")
        controller.togglePin(nil)
        check(!controller.isPinned && controller.window?.level == .normal,
              "unpinning during update changes preference while staying normal")
        controller.togglePin(nil)
        check(controller.isPinned && controller.window?.level == .normal,
              "pinning during update changes preference while staying normal")
        coordinator.standardUserDriverDidShowModalAlert()
        check(!coordinator.isUpdateInterfaceActive && controller.window?.level == .floating,
              "modal completion restores selected floating level")
        coordinator.standardUserDriverWillShowModalAlert()
        coordinator.standardUserDriverWillFinishUpdateSession()
        check(!coordinator.isUpdateInterfaceActive && controller.window?.level == .floating,
              "update session completion restores selected floating level")
        check(controller.editor.string == baseline.content.text && session.draftRevision == originalRevision,
              "update interaction does not alter text or draft revision")
        check(controller.editor.selectedRange() == selectedRange && controller.window?.firstResponder === firstResponder,
              "update interaction preserves component selection and focus")
        let saveTicket = session.beginSaving()!
        let quitDuringSave = await controller.prepareToQuit()
        check(!quitDuringSave, "in-flight save prevents termination")
        check(session.isSaving, "termination never completes or cancels in-flight save")
        _ = session.failSaving("component save paused", uncertain: false, ticket: saveTicket)
        session.install(baseline)
        controller.isExporting = true
        let quitDuringExport = await controller.prepareToQuit()
        check(!quitDuringExport, "in-flight export prevents termination")
        controller.isExporting = false
        controller.isConfirming = true
        let quitDuringConfirmation = await controller.prepareToQuit()
        check(!quitDuringConfirmation, "existing confirmation prevents duplicate termination")
        controller.isConfirming = false

        let draft = "FN12 未保存草稿：中文与 emoji 🙂\n"
        controller.editor.string = draft
        session.updateDraft(draft)
        let revision = session.draftRevision
        coordinator.standardUserDriverWillShowModalAlert()
        check(controller.window?.level == .normal, "install quit starts with editor lowered")
        let firstReply = delegate.applicationShouldTerminate(app)
        let firstTask = delegate.terminationTask
        let repeatedReply = delegate.applicationShouldTerminate(app)
        check(firstReply == .terminateLater && repeatedReply == .terminateLater,
              "repeated quit requests remain asynchronous")
        check(firstTask != nil && delegate.terminationTask != nil,
              "repeated quit uses an existing termination task")
        await settle()
        check(controller.isConfirming, "dirty draft enters existing confirmation flow")
        check(controller.window?.sheets.count == 1, "repeated quit produces exactly one confirmation sheet")
        if let sheet = controller.window?.sheets.first {
            controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        } else {
            check(false, "confirmation sheet available for Return to Editing")
        }
        await settle()
        check(app.terminationReplies == [false], "Return to Editing replies once and cancels quit")
        check(delegate.terminationTask == nil, "cancelled quit releases termination guard")
        check(session.draft == draft && session.draftRevision == revision,
              "Return to Editing preserves exact UTF-8 draft and revision")
        check(!controller.isConfirming, "Return to Editing clears confirmation state")
        check(!coordinator.isUpdateInterfaceActive && controller.isPinned && controller.window?.level == .floating,
              "cancelled quit restores selected floating level")

        controller.editor.setMarkedText("中文shu ru", selectedRange: NSRange(location: 8, length: 0),
                                        replacementRange: NSRange(location: NSNotFound, length: 0))
        check(controller.editor.hasMarkedText(), "programmatic marked-text fixture exists")
        let markedString = controller.editor.string
        let markedRange = controller.editor.markedRange()
        let markedSelection = controller.editor.selectedRange()
        let markedDraft = session.draft
        let markedRevision = session.draftRevision
        let markedGeneration = session.generation
        let autosaveGeneration = controller.autosaveGeneration
        let autosaveCounts = (autosaveScheduler.scheduledCount, autosaveScheduler.cancelledCount)
        let recoveryOperation = controller.recoveryOperation
        let markedFocus = controller.window?.firstResponder
        _ = delegate.applicationShouldTerminate(app)
        await settle()
        check(!controller.isConfirming && controller.window?.sheets.isEmpty == true,
              "marked text rejects quit without opening a draft confirmation sheet")
        check(app.terminationReplies == [false, false] && delegate.terminationTask == nil,
              "marked text finishes asynchronous quit with one cancellation reply")
        check(controller.statusLabel.stringValue == "请先完成中文输入，再退出。",
              "marked text quit explains that composition must finish first")
        check(controller.editor.hasMarkedText() && controller.editor.string == markedString &&
              controller.editor.markedRange() == markedRange,
              "marked text quit preserves native marked range and exact composition bytes")
        check(controller.editor.selectedRange() == markedSelection &&
              controller.window?.firstResponder === markedFocus && controller.editor.isEditable,
              "marked text quit preserves selection, focus, and editability")
        check(session.draft == markedDraft && session.draftRevision == markedRevision &&
              session.generation == markedGeneration,
              "marked text quit preserves draft revision and load generation")
        check(controller.autosaveGeneration == autosaveGeneration &&
              autosaveScheduler.scheduledCount == autosaveCounts.0 &&
              autosaveScheduler.cancelledCount == autosaveCounts.1,
              "marked text quit neither schedules nor cancels autosave")
        check(controller.recoveryOperation == recoveryOperation && controller.recoveryIO == nil &&
              controller.savingTask == nil && !session.isSaving,
              "marked text quit queues no recovery or save operation")
        // If this regresses to opening a sheet, let the harness report failures and
        // continue instead of hanging forever in the original confirmation flow.
        if let sheet = controller.window?.sheets.first {
            controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            await settle()
        }
        controller.editor.unmarkText()
        check(!controller.editor.hasMarkedText() && session.draft == markedString,
              "committing composition resumes normal draft capture")

        let committedRevision = session.draftRevision
        _ = delegate.applicationShouldTerminate(app)
        await settle()
        check(controller.isConfirming && controller.window?.sheets.count == 1,
              "committed dirty input uses the normal draft confirmation flow")
        if let sheet = controller.window?.sheets.first {
            controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        }
        await settle()
        check(app.terminationReplies == [false, false, false] &&
              session.draft == markedString && session.draftRevision == committedRevision,
              "Return to Editing after composition preserves committed draft and revision")

        _ = delegate.applicationShouldTerminate(app)
        await settle()
        check(controller.window?.sheets.count == 1, "cancelled quit can be retried")
        if let sheet = controller.window?.sheets.first {
            controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        await settle()
        check(app.terminationReplies == [false, false, false, true], "explicit discard permits one final quit reply")
        check(delegate.terminationTask == nil, "successful preparation releases termination guard")
        controller.window?.orderOut(nil)
        controller.preview.close()
        do {
            // A real recovery store in this validation output makes unintended
            // discard/persistence observable. The injected writer confirms only
            // controller/session save flow; real xattr/IME proof belongs to UI QA.
            let recoveryDirectory = validationRoot.appendingPathComponent("components/IMERecovery-\(UUID().uuidString)")
            let store = DraftRecoveryStore(directory: recoveryDirectory)
            let imeSession = EditorSession()
            imeSession.install(baseline)
            let imeScheduler = PausedAutosaveScheduler()
            let imeController = EditorWindowController(session: imeSession, save: { request in
                NoteSnapshot(url: request.baseline.url, identity: request.baseline.identity,
                             content: request.desiredContent)
            }, autosaveScheduler: imeScheduler, recoveryStore: store)
            imeController.editor.string = "已完成输入与保留的恢复草稿\n"
            imeController.captureDraft()
            let recovery = imeSession.recoveryRecord!
            try await store.put(recovery)
            let recoveryFile = recoveryDirectory.appendingPathComponent(recovery.id.uuidString + ".json")
            let recoveryBytes = try Data(contentsOf: recoveryFile)
            imeController.editor.setSelectedRange(NSRange(location: (imeController.editor.string as NSString).length,
                                                           length: 0))
            imeController.editor.setMarkedText("中文shu ru", selectedRange: NSRange(location: 8, length: 0),
                                               replacementRange: NSRange(location: NSNotFound, length: 0))
            check(imeController.editor.hasMarkedText(), "recovery fixture uses native NSTextView marked state")
            let imeString = imeController.editor.string
            let imeRevision = imeSession.draftRevision
            var directQuitResult: Bool?
            let directQuit = Task { directQuitResult = await imeController.prepareToQuit() }
            await settle()
            check(directQuitResult == false && !imeController.isConfirming &&
                  imeController.window?.sheets.isEmpty == true,
                  "direct prepareToQuit resolves marked text without awaiting confirmation")
            check(imeController.editor.hasMarkedText() && imeController.editor.string == imeString &&
                  imeSession.draftRevision == imeRevision,
                  "direct marked text guard preserves composition and draft revision")
            let recoveryAfterQuit = try Data(contentsOf: recoveryFile)
            check(recoveryAfterQuit == recoveryBytes,
                  "marked text quit leaves real recovery JSON byte-for-byte unchanged")
            let remainingRecords = try await store.records()
            check(remainingRecords == [recovery] && imeController.recoveryIO == nil &&
                  imeController.recoveryOperation == 0,
                  "marked text quit neither removes recovery nor queues recovery IO")
            if let sheet = imeController.window?.sheets.first {
                imeController.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            }
            _ = await directQuit.value
            imeController.editor.unmarkText()
            let committedText = imeController.editor.string
            check(!imeController.editor.hasMarkedText() && imeSession.draft == committedText && imeSession.isDirty,
                  "committed input remains dirty and eligible for normal manual save")
            imeController.saveNote(nil)
            _ = await imeController.savingTask?.value
            _ = await imeController.recoveryIO?.value
            check(!imeSession.isSaving && !imeSession.isDirty &&
                  imeSession.snapshot?.content.text == committedText,
                  "injected successful manual save confirms exact committed input")
            let savedRecords = try await store.records()
            check(savedRecords.isEmpty, "confirmed save removes the isolated recovery record")
            let savedCanQuit = await imeController.prepareToQuit()
            check(savedCanQuit && imeController.window?.sheets.isEmpty == true,
                  "saved committed input may quit through the normal clean flow")
            imeController.recoveryTimer?.cancel()
            imeController.window?.orderOut(nil)
            imeController.preview.close()
        } catch {
            check(false, "IME recovery fixture execution: \(error)")
        }
        do {
            try await FN12AuditChecks.run(root: validationRoot) { condition, title in check(condition, title) }
        } catch {
            check(false, "audit fixture execution: \(error)")
        }
        print("RESULT: \(passed) passed / \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
