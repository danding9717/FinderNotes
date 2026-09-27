import Foundation

/// The editor owns the live draft; a verified save advances only its storage baseline.
@MainActor
final class EditorSession {
    struct LoadTicket: Equatable { fileprivate let generation: UInt64 }
    struct SaveTicket: Sendable {
        fileprivate let generation: UInt64
        fileprivate let identifier: UInt64
        let draftRevision: UInt64
        let request: NoteSaveRequest
    }
    struct AutosaveTicket: Equatable {
        fileprivate let generation: UInt64
        let draftRevision: UInt64
        let url: URL
        let identity: FileIdentity
    }
    enum Resolution: Equatable { case stale, reused, installed, needsDiscard }
    enum SaveIssue: Equatable {
        case failed(String)
        case unconfirmed(String)

        var message: String {
            switch self {
            case .failed(let detail): return "保存失败：\(detail)"
            case .unconfirmed(let detail): return "写入结果未能确认：\(detail)"
            }
        }
    }

    private(set) var snapshot: NoteSnapshot?
    private(set) var draft = ""
    private(set) var draftRevision: UInt64 = 0
    private(set) var isLoading = false
    private(set) var failure: String?
    private(set) var saveIssue: SaveIssue?
    private(set) var isSaving = false
    private(set) var recoveryIdentifier = UUID()
    private(set) var recoveryNeedsAttention = false
    private(set) var recoveryWriteBlocked = false
    private(set) var recoveryIssue: String?
    private var generation: UInt64 = 0
    private var nextSaveIdentifier: UInt64 = 0
    private var pendingSaveIdentifier: UInt64?
    private var lastSaveStatus: String?

    var isDirty: Bool {
        Data(draft.utf8) != Data((snapshot?.content.text ?? "").utf8)
    }

    var requiresLeaveConfirmation: Bool { isDirty || saveIssue != nil || recoveryNeedsAttention }
    var canBeginSave: Bool { snapshot != nil && !isLoading && !isSaving && !recoveryWriteBlocked }
    var recoveryRecord: DraftRecoveryRecord? {
        guard let snapshot, isDirty || saveIssue != nil || recoveryNeedsAttention else { return nil }
        return DraftRecoveryRecord(id: recoveryIdentifier, baseline: snapshot,
                                   draft: draft, revision: draftRevision)
    }
    var autosaveTicket: AutosaveTicket? {
        guard canBeginSave, isDirty, saveIssue == nil, !recoveryNeedsAttention,
              recoveryIssue == nil, let snapshot else { return nil }
        return AutosaveTicket(generation: generation, draftRevision: draftRevision,
                              url: snapshot.url, identity: snapshot.identity)
    }

    func isCurrent(_ ticket: AutosaveTicket) -> Bool { autosaveTicket == ticket }

    var status: String {
        if let failure { return "读取失败：\(failure)" }
        if isLoading { return "正在读取笔记…" }
        guard let snapshot else { return "从 Finder 选择一份图片或视频，运行本应用的编辑笔记服务。" }
        if isSaving { return "正在保存笔记… 可以继续编辑或导出当前草稿" }
        if recoveryWriteBlocked {
            let detail = [saveIssue?.message, recoveryIssue].compactMap { $0 }.joined(separator: " · ")
            return "草稿的原文件身份无法确认 · 已禁止写回 · 草稿仍保留，可复制或导出" +
                (detail.isEmpty ? "" : " · " + detail)
        }
        if saveIssue != nil || recoveryIssue != nil {
            let recoveryDetail = recoveryIssue.map { "草稿恢复文件更新失败：\($0)" }
            let detail = [saveIssue?.message, recoveryDetail].compactMap { $0 }.joined(separator: " · ")
            return detail + " · 自动保存已暂停 · 草稿仍保留，可复制或导出"
        }
        if recoveryNeedsAttention {
            return "恢复或冲突草稿待确认 · 自动保存已暂停 · 请通过“高级选项 → 核对外部版本”核对后手动保存，或复制、导出草稿"
        }
        if isDirty {
            return lastSaveStatus == nil ? "草稿有改动 · 尚未保存" : "上一版已保存 · 当前草稿尚未保存"
        }
        if let lastSaveStatus { return lastSaveStatus }
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

    func setRecoveryIssue(_ message: String?) {
        recoveryIssue = message
    }

    func pauseForExternalIssue(_ message: String) {
        saveIssue = .failed(message)
        recoveryNeedsAttention = true
    }

    func blockRecoveryWrite(_ message: String) {
        recoveryWriteBlocked = true
        recoveryNeedsAttention = true
        recoveryIssue = message
    }

    /// Restore the original storage baseline, never silently adopt newer external bytes.
    /// The caller must first protect or explicitly discard any currently open draft.
    @discardableResult
    func restoreRecovery(record: DraftRecoveryRecord, current: NoteSnapshot?) -> Bool {
        guard !isSaving else { return false }
        invalidateLoading()
        pendingSaveIdentifier = nil
        snapshot = record.snapshot
        draft = record.draft
        draftRevision = record.revision
        recoveryIdentifier = record.id
        recoveryNeedsAttention = true
        recoveryWriteBlocked = !Self.hasRecoveryIdentity(record.snapshot.identity) ||
            current?.url.path != record.snapshot.url.path ||
            current?.identity != record.snapshot.identity
        recoveryIssue = nil
        failure = nil
        saveIssue = nil
        if !recoveryWriteBlocked, let current, current.content != record.snapshot.content {
            let externalState: String
            switch current.content {
            case .missing: externalState = "外部自定义笔记属性已不存在"
            case .present(let bytes): externalState = bytes.isEmpty ? "外部自定义笔记为空正文" : "外部自定义笔记正文已改变"
            }
            saveIssue = .failed("已落盘草稿的正文基线与外部版本不同；\(externalState)，请先使用“高级选项 → 核对外部版本”。")
        }
        lastSaveStatus = nil
        return true
    }

    /// Only a user-confirmed external snapshot can replace this session's baseline.
    /// Saving still checks that baseline against the xattr; this does not provide a CAS.
    @discardableResult
    func applyExternal(_ candidate: NoteSnapshot, replacingDraft: Bool,
                       confirmedRevision: UInt64) -> Bool {
        guard !isSaving, !isLoading, draftRevision == confirmedRevision,
              let snapshot, candidate.url.path == snapshot.url.path,
              candidate.identity == snapshot.identity,
              !recoveryWriteBlocked || Self.hasRecoveryIdentity(candidate.identity) else { return false }
        generation &+= 1
        if replacingDraft {
            install(candidate)
        } else {
            self.snapshot = candidate
            recoveryNeedsAttention = true
            recoveryWriteBlocked = false
            failure = nil
            saveIssue = nil
            lastSaveStatus = nil
        }
        return true
    }

    func beginSaving() -> SaveTicket? {
        guard canBeginSave, let snapshot else { return nil }
        nextSaveIdentifier &+= 1
        let ticket = SaveTicket(generation: generation,
                                identifier: nextSaveIdentifier,
                                draftRevision: draftRevision,
                                request: NoteSaveRequest(baseline: snapshot,
                                                         desiredContent: .present(Data(draft.utf8))))
        pendingSaveIdentifier = ticket.identifier
        isSaving = true
        failure = nil
        saveIssue = nil
        return ticket
    }

    @discardableResult
    func completeSaving(_ candidate: NoteSnapshot, ticket: SaveTicket) -> Bool {
        guard isCurrent(ticket),
              candidate.url.path == ticket.request.baseline.url.path,
              candidate.identity == ticket.request.baseline.identity,
              case .present(let bytes) = candidate.content,
              candidate.content == ticket.request.desiredContent else { return false }
        pendingSaveIdentifier = nil
        isSaving = false
        snapshot = candidate
        saveIssue = nil
        recoveryNeedsAttention = false
        recoveryWriteBlocked = false
        if bytes.isEmpty {
            if case .present(let previous) = ticket.request.baseline.content, !previous.isEmpty {
                lastSaveStatus = "笔记已清空并保存"
            } else {
                lastSaveStatus = "空笔记已保存"
            }
        } else {
            lastSaveStatus = "笔记已保存"
        }
        return true
    }

    @discardableResult
    func failSaving(_ message: String, uncertain: Bool, ticket: SaveTicket) -> Bool {
        guard isCurrent(ticket) else { return false }
        pendingSaveIdentifier = nil
        isSaving = false
        saveIssue = uncertain ? .unconfirmed(message) : .failed(message)
        return true
    }

    private func isCurrent(_ ticket: SaveTicket) -> Bool {
        isSaving && pendingSaveIdentifier == ticket.identifier && generation == ticket.generation
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
        guard !requiresLeaveConfirmation && !protectsMarkedText else { return .needsDiscard }
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
        pendingSaveIdentifier = nil
        isSaving = false
        snapshot = nil
        draft = ""
        draftRevision &+= 1
        failure = nil
        saveIssue = nil
        lastSaveStatus = nil
        resetRecoveryState()
    }

    private func install(_ candidate: NoteSnapshot) {
        snapshot = candidate
        draft = candidate.content.text
        draftRevision &+= 1
        failure = nil
        saveIssue = nil
        lastSaveStatus = nil
        resetRecoveryState()
    }

    private static func hasRecoveryIdentity(_ identity: FileIdentity) -> Bool {
        identity.inode != 0 && identity.birthSeconds > 0 &&
            (0..<1_000_000_000).contains(identity.birthNanoseconds)
    }

    private func resetRecoveryState() {
        recoveryIdentifier = UUID()
        recoveryNeedsAttention = false
        recoveryWriteBlocked = false
        recoveryIssue = nil
    }
}
