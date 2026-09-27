import AppKit
import Darwin
import QuickLookUI

@MainActor
protocol MediaPreviewBackend: AnyObject {
    var view: NSView { get }
    var autostarts: Bool { get set }
    func present(_ url: URL)
    func close()
}

@MainActor
private final class QuickLookPreviewBackend: MediaPreviewBackend {
    private let preview: QLPreviewView
    var view: NSView { preview }
    var autostarts: Bool {
        get { preview.autostarts }
        set { preview.autostarts = newValue }
    }

    init?() {
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else { return nil }
        self.preview = preview
        // The controller closes and discards each instance on collapse, switch, or close.
        preview.shouldCloseWithWindow = false
    }

    func present(_ url: URL) { preview.previewItem = url as NSURL }
    func close() { preview.close() }
}

/// System preview is independent of note loading, editing, and persistence.
@MainActor
final class MediaPreviewController {
    enum State: Equatable {
        case empty
        case checkingAccess
        // This means only that Quick Look accepted an item, not that decoding succeeded.
        case systemPreview
        case unavailable
    }

    let view = NSView()
    private(set) var isExpanded = true
    private(set) var state: State = .empty
    private(set) var target: NoteSnapshot?
    let messageLabel = NSTextField(wrappingLabelWithString: "选择文件后显示预览")
    private let placeholder = NSStackView()
    private let icon = NSImageView()
    private let validate: @Sendable (NoteSnapshot) async throws -> Void
    private let makeBackend: @MainActor () -> (any MediaPreviewBackend)?
    private var backend: (any MediaPreviewBackend)?
    private var validationTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(validate: @escaping @Sendable (NoteSnapshot) async throws -> Void = { snapshot in
        try await Task.detached(priority: .userInitiated) {
            try MediaPreviewController.validateAccess(to: snapshot)
        }.value
    }, makeBackend: @escaping @MainActor () -> (any MediaPreviewBackend)? = { QuickLookPreviewBackend() }) {
        self.validate = validate
        self.makeBackend = makeBackend
        view.setAccessibilityIdentifier("fn-media-preview")
        placeholder.orientation = .vertical
        placeholder.spacing = 8
        placeholder.alignment = .centerX
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        placeholder.addArrangedSubview(icon)
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.setAccessibilityIdentifier("fn-preview-message")
        placeholder.addArrangedSubview(messageLabel)
        view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -24),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    func install(snapshot: NoteSnapshot?) {
        if let target, let snapshot,
           target.url.path == snapshot.url.path, target.identity == snapshot.identity {
            self.target = snapshot
            return
        }
        if target == nil && snapshot == nil { return }
        invalidatePreview()
        target = snapshot
        showPlaceholder(.empty)
        if isExpanded, let snapshot { startValidation(snapshot) }
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        view.isHidden = !expanded
        invalidatePreview()
        showPlaceholder(.empty)
        if expanded, let target { startValidation(target) }
    }

    func close() {
        invalidatePreview()
        target = nil
        showPlaceholder(.empty)
    }

    private func startValidation(_ snapshot: NoteSnapshot) {
        let ticket = generation
        let validate = self.validate
        showPlaceholder(.checkingAccess)
        validationTask = Task { [weak self] in
            let result: Result<Void, Error>
            do {
                try await validate(snapshot)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled,
                  self.generation == ticket, self.isExpanded,
                  self.target?.url.path == snapshot.url.path,
                  self.target?.identity == snapshot.identity else { return }
            self.validationTask = nil
            switch result {
            case .failure(let error):
                self.showPlaceholder(.unavailable, detail: error.localizedDescription)
            case .success:
                guard let backend = self.makeBackend() else {
                    self.showPlaceholder(.unavailable)
                    return
                }
                // Set this before assigning the item; Quick Look loads asynchronously.
                backend.autostarts = false
                self.backend = backend
                let previewView = backend.view
                previewView.translatesAutoresizingMaskIntoConstraints = false
                self.view.addSubview(previewView)
                NSLayoutConstraint.activate([
                    previewView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                    previewView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                    previewView.topAnchor.constraint(equalTo: self.view.topAnchor),
                    previewView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
                ])
                backend.present(snapshot.url)
                self.state = .systemPreview
                self.placeholder.isHidden = true
            }
        }
    }

    private func invalidatePreview() {
        generation &+= 1
        validationTask?.cancel()
        validationTask = nil
        if let backend {
            backend.close()
            backend.view.removeFromSuperview()
            self.backend = nil
        }
    }

    private func showPlaceholder(_ state: State, detail: String? = nil) {
        self.state = state
        placeholder.isHidden = false
        messageLabel.toolTip = detail
        switch state {
        case .empty:
            messageLabel.stringValue = "选择文件后显示预览"
        case .checkingAccess:
            messageLabel.stringValue = "正在准备预览…"
        case .unavailable:
            messageLabel.stringValue = "预览不可用，仍可编辑笔记"
        case .systemPreview:
            break
        }
        icon.image = NSImage(systemSymbolName: state == .unavailable ? "exclamationmark.triangle" : "photo",
                             accessibilityDescription: nil)
    }

    nonisolated static func validateAccess(to snapshot: NoteSnapshot) throws {
        guard snapshot.url.isFileURL else { throw NoteReadError.localFileRequired }
        let path = try NoteReader.localPath(snapshot.url.path)
        let fd = try NoteReader.openPath(path)
        defer { Darwin.close(fd) }
        let status = try NoteReader.regularStatus(fd)
        guard FileIdentity(status) == snapshot.identity else { throw NoteReadError.targetChanged }
        // Quick Look later opens this URL itself. This check does not eliminate that race.
    }
}
