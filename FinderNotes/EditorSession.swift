import Foundation

/// The only editable state in FN-04 is this process-local draft. There is no writer.
@MainActor
final class EditorSession {
    struct LoadTicket: Equatable { fileprivate let generation: UInt64 }
    enum Resolution: Equatable { case stale, reused, installed, needsDiscard }

    private(set) var snapshot: NoteSnapshot?
    private(set) var draft = ""
    private(set) var draftRevision: UInt64 = 0
    private(set) var isLoading = false
    private(set) var failure: String?
    private var generation: UInt64 = 0

    var isDirty: Bool {
        Data(draft.utf8) != Data((snapshot?.content.text ?? "").utf8)
    }

    var status: String {
        if let failure { return "读取失败：\(failure)" }
        if isLoading { return "正在读取笔记…" }
        guard let snapshot else { return "从 Finder 选择一份图片或视频，运行“FinderNotes 编辑笔记”服务。" }
        if isDirty { return "草稿有改动 · 尚未保存" }
        switch snapshot.content {
        case .missing: return "尚无笔记 · 可在此编辑草稿"
        case .present(let bytes): return bytes.isEmpty ? "已有空笔记" : "笔记已加载"
        }
    }

    func updateDraft(_ text: String) {
        guard Data(text.utf8) != Data(draft.utf8) else { return }
        draft = text
        draftRevision &+= 1
    }

    func beginLoading() -> LoadTicket {
        generation &+= 1
        failure = nil
        isLoading = true
        return LoadTicket(generation: generation)
    }

    func isCurrent(_ ticket: LoadTicket) -> Bool { ticket.generation == generation }

    func resolve(_ candidate: NoteSnapshot, ticket: LoadTicket, protectsMarkedText: Bool = false) -> Resolution {
        guard isCurrent(ticket) else { return .stale }
        isLoading = false
        failure = nil
        if let snapshot, snapshot.url.path == candidate.url.path, snapshot.identity == candidate.identity {
            // In particular do not replace the baseline with an externally changed note.
            return .reused
        }
        guard !isDirty && !protectsMarkedText else { return .needsDiscard }
        install(candidate)
        return .installed
    }

    func acceptReplacement(_ candidate: NoteSnapshot, ticket: LoadTicket, confirmedRevision: UInt64) -> Bool {
        guard isCurrent(ticket), draftRevision == confirmedRevision else { return false }
        install(candidate)
        return true
    }

    func reject(_ message: String, ticket: LoadTicket) {
        guard isCurrent(ticket) else { return }
        isLoading = false
        failure = message
    }

    func invalidateLoading() {
        generation &+= 1
        isLoading = false
    }

    func close() {
        invalidateLoading()
        snapshot = nil
        draft = ""
        draftRevision &+= 1
        failure = nil
    }

    private func install(_ candidate: NoteSnapshot) {
        snapshot = candidate
        draft = candidate.content.text
        draftRevision &+= 1
        failure = nil
    }
}
