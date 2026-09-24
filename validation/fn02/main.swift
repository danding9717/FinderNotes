import AppKit
import Darwin
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    let config: Config
    let session: Session
    var window: NSWindow!
    let editor = NSTextView()
    let fileLabel = NSTextField(wrappingLabelWithString: "从 Finder 选择临时副本，运行“FinderNotes FN02 验证笔记”服务。")
    let resultLabel = NSTextField(wrappingLabelWithString: "等待系统服务；草稿仅保留在本次运行期间。")
    let launched = Date()
    var deliveries = 0
    init(_ config: Config) { self.config = config; session = Session(config); super.init() }
    func log(_ event: String, _ details: [String: Any] = [:]) {
        var row = details
        row["event"] = event; row["time"] = ISO8601DateFormatter().string(from: Date())
        row["pid"] = ProcessInfo.processInfo.processIdentifier
        row["bundle_id"] = Bundle.main.bundleIdentifier ?? "missing"
        row["draft_bytes"] = session.draft.utf8.count
        row["draft_sha256"] = sha256(Data(session.draft.utf8))
        if let target = session.target { row["path"] = target.path; row["identity"] = target.id }
        guard var bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        bytes.append(10)
        let path = config.root + "/events.jsonl"
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 { bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress, bytes.count) }; close(fd) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupUI()
        log("launch", ["executable": Bundle.main.executablePath ?? "", "uid": getuid(), "arguments": CommandLine.arguments])
        if CommandLine.arguments.contains("--self-test") {
            do { try selfTest(); log("self_test_complete", ["ok": true]) }
            catch { log("self_test_complete", ["ok": false, "error": String(describing: error)]) }
            NSApp.terminate(nil)
        } else {
            NSApp.servicesProvider = self
            NSUpdateDynamicServices()
            show()
        }
    }
    func setupUI() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出验证应用", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.title = "编辑"; menu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 440), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FinderNotes FN02 · 入口与权限验证"
        window.delegate = self; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18)])
        stack.addArrangedSubview(fileLabel)
        editor.isRichText = false; editor.allowsUndo = true; editor.font = .systemFont(ofSize: 16); editor.delegate = self
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityIdentifier("fn02-draft")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = editor
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let buttons = NSStackView(); buttons.spacing = 12
        for (title, selector) in [("保存并回读", #selector(save)), ("复制草稿", #selector(copyDraft)), ("结束当前会话", #selector(endSession))] {
            buttons.addArrangedSubview(NSButton(title: title, target: self, action: selector))
        }
        stack.addArrangedSubview(buttons); stack.addArrangedSubview(resultLabel)
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func textDidChange(_ notification: Notification) { session.draft = editor.string }
    @objc func receiveFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let start = DispatchTime.now().uptimeNanoseconds
        deliveries += 1
        session.draft = editor.string
        // Read only the pasteboard supplied with this service request, never .general.
        let urls: [URL]
        if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        } else {
            urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
        do {
            let message = try session.receive(urls)
            editor.string = session.draft; editor.undoManager?.removeAllActions()
            fileLabel.stringValue = session.target?.path ?? ""
            resultLabel.stringValue = message
            log("service_accepted", ["delivery": deliveries, "received_urls": urls.map(\.absoluteString), "message": message, "handler_ms": Double(DispatchTime.now().uptimeNanoseconds-start)/1e6, "seconds_since_launch": Date().timeIntervalSince(launched)])
        } catch let failure {
            let message = String(describing: failure)
            error.pointee = message as NSString
            resultLabel.stringValue = "拒绝：\(message)。当前草稿保留，可复制。"
            log("service_rejected", ["delivery": deliveries, "received_urls": urls.map(\.absoluteString), "error": message])
        }
        show()
    }
    @objc func save() {
        session.draft = editor.string
        do { try session.save(); resultLabel.stringValue = "已保存并完整回读一致"; log("save_verified") }
        catch { resultLabel.stringValue = "保存失败：\(error)。草稿保留，可复制。"; log("save_failed", ["error": String(describing: error)]) }
    }
    @objc func copyDraft() {
        session.draft = editor.string
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(session.draft, forType: .string)
        resultLabel.stringValue = ok ? "草稿已复制" : "复制失败；草稿仍保留在编辑框"
        log("copy_draft", ["ok": ok])
    }
    func confirmDiscard() -> Bool {
        session.draft = editor.string
        guard session.dirty else { return true }
        let alert = NSAlert(); alert.messageText = "当前草稿尚未保存"
        alert.informativeText = "取消后可复制草稿。明确丢弃会清除本次运行中的文本。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "丢弃草稿")
        return alert.runModal() == .alertSecondButtonReturn
    }
    @objc func endSession() {
        guard confirmDiscard() else { return }
        log("end_session"); session.target = nil; session.draft = ""; editor.string = ""
        fileLabel.stringValue = "等待系统服务"; resultLabel.stringValue = "当前会话已结束"
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        resultLabel.stringValue = "窗口隐藏；本次运行中的草稿保留"
        log("window_hidden"); window.orderOut(nil); return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmDiscard() ? .terminateNow : .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }

    // Launched through LaunchServices inside the same .app. This tests application-process
    // file operations and session guards; it is explicitly not Finder service evidence.
    func selfTest() throws {
        func url(_ name: String) -> URL { URL(fileURLWithPath: config.root + "/work/" + name) }
        func passed(_ name: String, _ extra: [String: Any] = [:]) { var d=extra; d["case"]=name; log("self_test_pass", d) }
        func rejected(_ name: String, _ body: () throws -> Void) throws {
            let before = session.draft
            do { try body() } catch {
                try check(session.draft == before, "草稿被错误修改")
                passed(name, ["expected_error": String(describing: error), "draft_preserved": true]); return
            }
            throw Failure(description: "Expected rejection: \(name)")
        }
        session.draft = "尚未打开文件时的草稿"
        try rejected("unbound-draft-protected") { _ = try session.receive([url("normal.png")]) }
        session.draft = ""
        for ext in ["png", "mov"] {
            session.target = nil; session.draft = ""
            _ = try session.receive([url("normal.\(ext)")])
            session.draft = "FN02 中文🙂\n失败可复制草稿 \(ext)  "
            let draft = session.draft
            _ = try session.receive([url("normal.\(ext)")])
            try check(session.draft == draft, "重复触发丢失草稿"); passed("\(ext):repeat")
            try rejected("\(ext):multi") { _ = try session.receive([url("normal.\(ext)"), url("readonly.\(ext)")]) }
            try rejected("\(ext):dirty-switch") { _ = try session.receive([url("readonly.\(ext)")]) }
            try session.save(); passed("\(ext):write-readback")
            for name in ["symlink", "hard", "unreadable", "invalid"] {
                try rejected("\(ext):\(name)") { _ = try session.receive([url("\(name).\(ext)")]) }
            }
            _ = try session.receive([url("readonly.\(ext)")]); session.draft = draft
            try rejected("\(ext):readonly") { try session.save() }
            // Reset only this test session after verifying retained text, not product recovery.
            session.target = nil; session.draft = ""
            _ = try session.receive([url("disappear.\(ext)")]); session.draft = draft
            guard unlink(url("disappear.\(ext)").path) == 0 else { throw posix("unlink fixture") }
            try rejected("\(ext):disappeared") { try session.save() }
            session.target = nil; session.draft = ""
            _ = try session.receive([url("replace.\(ext)")]); session.draft = draft
            guard rename(url("replacement.\(ext)").path, url("replace.\(ext)").path) == 0 else { throw posix("rename fixture") }
            try rejected("\(ext):replacement") { try session.save() }
            let replacement = try Target(url: url("replace.\(ext)"), config: config)
            try check(replacement.baseline == nil, "误写替换文件"); passed("\(ext):replacement-untouched")
            session.target = nil; session.draft = ""
        }
        try rejected("directory") { _ = try session.receive([url("directory.png")]) }
        try rejected("outside-root") { _ = try session.receive([URL(fileURLWithPath: config.root + "/seed.png")]) }
        try rejected("nonfile-url") { _ = try session.receive([URL(string: "https://example.com/test.png")!]) }
        try rejected("empty-selection") { _ = try session.receive([]) }
    }
}

do {
    let configURL = Bundle.main.url(forResource: "run", withExtension: "json")!
    let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
    let app = NSApplication.shared
    let delegate = AppDelegate(config)
    app.setActivationPolicy(.regular); app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
} catch { fputs("FN02 startup failed: \(error)\n", stderr); exit(1) }
