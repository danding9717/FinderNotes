import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var controller: EditorWindowController?
    private(set) var updateCoordinator: UpdateCoordinator?
    private var pinMenuItem: NSMenuItem?
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateCoordinator = UpdateCoordinator()
        updateCoordinator?.interactionStateDidChange = { [weak self] active in
            self?.controller?.setUpdateInterfaceActive(active)
        }
        setupMenu()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        editorController().showEditor()
    }

    private func editorController() -> EditorWindowController {
        if let controller { return controller }
        let created = EditorWindowController(recoveryStore: DraftRecoveryStore(directory: DraftRecoveryStore.defaultDirectory()))
        created.pinStateDidChange = { [weak self] isPinned in
            self?.pinMenuItem?.state = isPinned ? .on : .off
        }
        created.setUpdateInterfaceActive(updateCoordinator?.isUpdateInterfaceActive ?? false)
        created.refreshRecoveryAvailability()
        controller = created
        return created
    }

    @objc func receiveFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(from: pasteboard)
        guard urls.count == 1 else {
            error.pointee = "只接受一个文件；请在 Finder 中只选择一份图片或视频。" as NSString
            // Route rejection through the same read-only UI, preserving an existing draft.
            editorController().receive(urls)
            return
        }
        editorController().receive(urls)
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        editorController().showEditor()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sparkle's modal alerts run inside a main-queue callback. Waiting for a
        // MainActor task from that nested modal loop can deadlock the quit reply.
        guard sender.modalWindow == nil else { return .terminateCancel }
        guard let controller else { return .terminateNow }
        // Sparkle sends an ordinary quit event and waits for actual termination.
        // A second quit request must not open another sheet or reply twice.
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { [weak self] in
            let canQuit = await controller.prepareToQuit()
            self?.updateCoordinator?.recordApplicationTermination(allowed: canQuit)
            if !canQuit { self?.updateCoordinator?.restoreEditorWindowLevel() }
            self?.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func saveNote(_ sender: Any?) { controller?.saveNote(sender) }
    @objc func exportMarkdown(_ sender: Any?) { controller?.exportMarkdown(sender) }
    @objc func togglePin(_ sender: Any?) { controller?.togglePin(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePin(_:)) {
            menuItem.state = controller?.isPinned == true ? .on : .off
            return controller?.window != nil
        }
        if menuItem.action == #selector(saveNote(_:)) { return controller?.canSaveFromMenu ?? false }
        if menuItem.action == #selector(exportMarkdown(_:)) { return controller?.canExportFromMenu ?? false }
        return true
    }

    func setupMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        let app = submenu("FinderNotes")
        app.addItem(withTitle: "关于 FinderNotes", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let update = app.addItem(withTitle: "检查更新…", action: #selector(UpdateCoordinator.checkForUpdates(_:)), keyEquivalent: "")
        update.target = updateCoordinator
        app.addItem(.separator())
        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "服务")
        app.addItem(services)
        NSApp.servicesMenu = services.submenu
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 FinderNotes", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "退出 FinderNotes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu("文件")
        file.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let save = file.addItem(withTitle: "保存", action: #selector(saveNote(_:)), keyEquivalent: "s")
        save.target = self
        let export = file.addItem(withTitle: "导出 Markdown…", action: #selector(exportMarkdown(_:)), keyEquivalent: "e")
        export.target = self
        let edit = submenu("编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let find = edit.addItem(withTitle: "查找…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let next = edit.addItem(withTitle: "查找下一个", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        let window = submenu("窗口")
        let pin = window.addItem(withTitle: "置顶", action: #selector(togglePin(_:)), keyEquivalent: "")
        pin.target = self
        pinMenuItem = pin
        window.addItem(.separator())
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}
