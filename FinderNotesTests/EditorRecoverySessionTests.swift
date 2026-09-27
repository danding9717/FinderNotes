import XCTest
@testable import FinderNotes

@MainActor
final class EditorRecoverySessionTests: XCTestCase {
    private func note(_ name: String = "recovery.png", inode: UInt64 = 7,
                      content: NoteContent = .present(Data("打开时正文".utf8))) -> NoteSnapshot {
        NoteSnapshot(url: URL(fileURLWithPath: "/private/tmp/" + name),
                     identity: FileIdentity(device: 1, inode: inode, birthSeconds: 100,
                                            birthNanoseconds: 200), content: content)
    }

    private func record(baseline: NoteSnapshot? = nil, draft: String = "未保存草稿🙂\n",
                        revision: UInt64 = 42) -> DraftRecoveryRecord {
        DraftRecoveryRecord(id: UUID(), baseline: baseline ?? note(), draft: draft, revision: revision)
    }

    private func saved(_ ticket: EditorSession.SaveTicket) -> NoteSnapshot {
        NoteSnapshot(url: ticket.request.baseline.url, identity: ticket.request.baseline.identity,
                     content: ticket.request.desiredContent)
    }

    func testCleanTargetsHaveNoRecoveryRecordAndInstallChangesIdentifier() throws {
        let session = EditorSession()
        XCTAssertNil(session.recoveryRecord)
        let emptyIdentifier = session.recoveryIdentifier
        _ = session.resolve(note(), ticket: session.beginLoading())
        let firstIdentifier = session.recoveryIdentifier
        XCTAssertNotEqual(firstIdentifier, emptyIdentifier)
        XCTAssertNil(session.recoveryRecord)
        session.updateDraft("改动")
        let first = try XCTUnwrap(session.recoveryRecord)
        XCTAssertEqual(first.id, firstIdentifier)
        XCTAssertEqual(first.snapshot.content, note().content)
        XCTAssertEqual(first.draft, "改动")
        XCTAssertEqual(first.revision, session.draftRevision)
        session.updateDraft(note().content.text)
        XCTAssertNil(session.recoveryRecord)
        _ = session.resolve(note("second.png", inode: 8), ticket: session.beginLoading())
        XCTAssertNotEqual(session.recoveryIdentifier, firstIdentifier)
        let secondIdentifier = session.recoveryIdentifier
        session.close()
        XCTAssertNotEqual(session.recoveryIdentifier, secondIdentifier)
        XCTAssertNil(session.recoveryRecord)
    }

    func testRestoringKeepsOpeningBaselineAndPausesAutosaveUntilManualSaveSucceeds() throws {
        let session = EditorSession()
        let recovery = record()
        XCTAssertTrue(session.restoreRecovery(record: recovery, current: note()))
        XCTAssertEqual(session.recoveryIdentifier, recovery.id)
        XCTAssertEqual(session.draftRevision, recovery.revision)
        XCTAssertEqual(session.draft, recovery.draft)
        XCTAssertEqual(session.snapshot?.content, recovery.snapshot.content)
        XCTAssertTrue(session.recoveryNeedsAttention)
        XCTAssertTrue(session.requiresLeaveConfirmation)
        XCTAssertFalse(session.recoveryWriteBlocked)
        XCTAssertTrue(session.canBeginSave)
        XCTAssertNil(session.autosaveTicket)
        session.updateDraft("恢复后继续编辑")
        XCTAssertNil(session.autosaveTicket)
        let ticket = try XCTUnwrap(session.beginSaving())
        XCTAssertEqual(ticket.request.baseline.content, recovery.snapshot.content)
        XCTAssertTrue(session.completeSaving(saved(ticket), ticket: ticket))
        XCTAssertFalse(session.recoveryNeedsAttention)
        XCTAssertNil(session.recoveryRecord)
        session.updateDraft("下一版")
        XCTAssertNotNil(session.autosaveTicket)
    }

    func testExternalChangedBodyIsNotAdoptedAsRestoredBaseline() throws {
        let session = EditorSession()
        let recovery = record()
        let external = note(content: .present(Data("外部新版本".utf8)))
        XCTAssertTrue(session.restoreRecovery(record: recovery, current: external))
        XCTAssertFalse(session.recoveryWriteBlocked)
        XCTAssertEqual(session.snapshot?.content, recovery.snapshot.content)
        XCTAssertTrue(session.saveIssue?.message.contains("正文基线与外部版本不同") ?? false)
        let ticket = try XCTUnwrap(session.beginSaving())
        XCTAssertEqual(ticket.request.baseline.content, recovery.snapshot.content,
                       "NoteWriter must detect external changes against the original baseline")
        XCTAssertTrue(session.failSaving("外部正文冲突", uncertain: false, ticket: ticket))
        XCTAssertEqual(session.draft, recovery.draft)
        XCTAssertNotNil(session.recoveryRecord)
        XCTAssertTrue(session.recoveryNeedsAttention)
        XCTAssertNil(session.autosaveTicket)
    }

    func testMissingReplacedOrCopiedTargetCannotReceiveRestoredDraft() {
        let recovery = record()
        let candidates: [NoteSnapshot?] = [
            nil,
            note(inode: 8),
            note("copy.png", inode: 8),
            note("different-path.png"),
            NoteSnapshot(url: recovery.snapshot.url,
                         identity: FileIdentity(device: 1, inode: 7, birthSeconds: 999,
                                                birthNanoseconds: 200),
                         content: recovery.snapshot.content)
        ]
        for candidate in candidates {
            let session = EditorSession()
            XCTAssertTrue(session.restoreRecovery(record: recovery, current: candidate))
            XCTAssertTrue(session.recoveryWriteBlocked)
            XCTAssertFalse(session.canBeginSave)
            XCTAssertNil(session.beginSaving())
            XCTAssertNil(session.autosaveTicket)
            XCTAssertEqual(session.draft, recovery.draft)
            XCTAssertNotNil(session.recoveryRecord)
            XCTAssertTrue(session.status.contains("禁止写回"))
        }
    }

    func testRestoreInvalidatesOldLoadTicketAndRefusesAnInFlightSave() throws {
        let session = EditorSession()
        let previousLoad = session.beginLoading()
        let recovery = record()
        XCTAssertTrue(session.restoreRecovery(record: recovery, current: note()))
        XCTAssertFalse(session.isLoading)
        XCTAssertEqual(session.resolve(note("old-result.png", inode: 8), ticket: previousLoad), .stale)
        let ticket = try XCTUnwrap(session.beginSaving())
        XCTAssertFalse(session.restoreRecovery(record: record(draft: "另一个恢复稿"), current: note()))
        XCTAssertEqual(session.draft, recovery.draft)
        XCTAssertTrue(session.completeSaving(saved(ticket), ticket: ticket))
    }

    func testEmptyRecoveryRetainsMissingVersusPresentEmptyBaselineAndNeedsExplicitDecision() throws {
        for content in [NoteContent.missing, .present(Data())] {
            let baseline = note(content: content)
            let recovery = record(baseline: baseline, draft: "")
            let session = EditorSession()
            XCTAssertTrue(session.restoreRecovery(record: recovery, current: baseline))
            XCTAssertFalse(session.isDirty)
            XCTAssertTrue(session.requiresLeaveConfirmation)
            XCTAssertEqual(session.recoveryRecord?.snapshot.content, content)
            let ticket = try XCTUnwrap(session.beginSaving())
            XCTAssertEqual(ticket.request.baseline.content, content)
            XCTAssertEqual(ticket.request.desiredContent, .present(Data()))
            XCTAssertTrue(session.completeSaving(saved(ticket), ticket: ticket))
            XCTAssertNil(session.recoveryRecord)
            XCTAssertFalse(session.requiresLeaveConfirmation)
        }
    }

    func testRecoveryWriteFailurePausesAutosaveWithoutPreventingManualSave() throws {
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        session.updateDraft("保留草稿")
        XCTAssertNotNil(session.autosaveTicket)
        session.setRecoveryIssue("测试磁盘失败")
        XCTAssertNil(session.autosaveTicket)
        XCTAssertNotNil(session.recoveryRecord)
        XCTAssertTrue(session.status.contains("恢复文件更新失败"))
        let ticket = try XCTUnwrap(session.beginSaving())
        session.updateDraft("保存时继续编辑")
        XCTAssertTrue(session.completeSaving(saved(ticket), ticket: ticket))
        XCTAssertEqual(session.recoveryIssue, "测试磁盘失败",
                       "An xattr success does not prove recovery storage is working")
        XCTAssertNil(session.autosaveTicket)
        session.setRecoveryIssue(nil)
        XCTAssertNotNil(session.autosaveTicket)
    }

    func testSavingOlderRecoveredRevisionKeepsNewerRecoveryWithAdvancedBaseline() throws {
        let session = EditorSession()
        let recovery = record()
        XCTAssertTrue(session.restoreRecovery(record: recovery, current: note()))
        let ticket = try XCTUnwrap(session.beginSaving())
        session.updateDraft("保存期间新的草稿🙂")
        let newestRevision = session.draftRevision
        XCTAssertTrue(session.completeSaving(saved(ticket), ticket: ticket))
        let remaining = try XCTUnwrap(session.recoveryRecord)
        XCTAssertEqual(remaining.id, recovery.id)
        XCTAssertEqual(remaining.revision, newestRevision)
        XCTAssertEqual(remaining.draft, "保存期间新的草稿🙂")
        XCTAssertEqual(remaining.snapshot.content, ticket.request.desiredContent)
        XCTAssertFalse(session.recoveryNeedsAttention)
        XCTAssertTrue(session.isDirty)
    }

    func testApplyExternalCanPreserveDraftForExplicitSaveAndInvalidateOldAutosave() throws {
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        session.updateDraft("本地草稿")
        let oldTicket = try XCTUnwrap(session.autosaveTicket)
        let oldIdentifier = session.recoveryIdentifier
        let revision = session.draftRevision
        let external = note(content: .present(Data("外部正文".utf8)))
        XCTAssertTrue(session.applyExternal(external, replacingDraft: false, confirmedRevision: revision))
        XCTAssertEqual(session.draft, "本地草稿")
        XCTAssertEqual(session.draftRevision, revision)
        XCTAssertEqual(session.recoveryIdentifier, oldIdentifier)
        XCTAssertEqual(session.snapshot?.content, external.content)
        XCTAssertTrue(session.recoveryNeedsAttention)
        XCTAssertNil(session.autosaveTicket)
        XCTAssertFalse(session.isCurrent(oldTicket))
        let ticket = try XCTUnwrap(session.beginSaving())
        XCTAssertEqual(ticket.request.baseline.content, external.content)
        XCTAssertEqual(ticket.request.desiredContent, .present(Data("本地草稿".utf8)))
    }

    func testApplyExternalLoadClearsIssuesAndDistinguishesExternalDeletion() throws {
        let session = EditorSession()
        let recovery = record()
        XCTAssertTrue(session.restoreRecovery(record: recovery, current: nil))
        session.setRecoveryIssue("旧恢复错误")
        let external = note(content: .missing)
        XCTAssertTrue(session.applyExternal(external, replacingDraft: true,
                                            confirmedRevision: session.draftRevision))
        XCTAssertEqual(session.draft, "")
        XCTAssertEqual(session.snapshot?.content, .missing)
        XCTAssertFalse(session.recoveryNeedsAttention)
        XCTAssertFalse(session.recoveryWriteBlocked)
        XCTAssertNil(session.recoveryIssue)
        XCTAssertNil(session.saveIssue)
        XCTAssertNil(session.recoveryRecord)
        XCTAssertNotEqual(session.recoveryIdentifier, recovery.id)
        XCTAssertEqual(session.status, "尚无笔记 · 可在此编辑草稿")
    }

    func testApplyExternalRejectsStaleRevisionIdentityPathLoadingAndSaving() throws {
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        session.updateDraft("本地草稿")
        let revision = session.draftRevision
        let external = note(content: .present(Data("外部版本".utf8)))
        session.updateDraft("新草稿")
        XCTAssertFalse(session.applyExternal(external, replacingDraft: true, confirmedRevision: revision))
        for candidate in [note(inode: 8), note("copy.png")] {
            XCTAssertFalse(session.applyExternal(candidate, replacingDraft: false,
                                                 confirmedRevision: session.draftRevision))
        }
        _ = session.beginLoading()
        XCTAssertFalse(session.applyExternal(external, replacingDraft: true,
                                             confirmedRevision: session.draftRevision))
        session.invalidateLoading()
        let ticket = try XCTUnwrap(session.beginSaving())
        XCTAssertFalse(session.applyExternal(external, replacingDraft: true,
                                             confirmedRevision: session.draftRevision))
        XCTAssertEqual(session.draft, "新草稿")
        XCTAssertEqual(session.snapshot?.content, note().content)
        XCTAssertTrue(session.failSaving("保留", uncertain: true, ticket: ticket))
        XCTAssertNotNil(session.recoveryRecord)
    }

    func testCloseClearsRecoveryFlagsAndRejectsOldSaveCompletion() throws {
        let session = EditorSession()
        let recovery = record()
        XCTAssertTrue(session.restoreRecovery(record: recovery, current: note()))
        session.setRecoveryIssue("旧错误")
        let ticket = try XCTUnwrap(session.beginSaving())
        session.close()
        XCTAssertFalse(session.completeSaving(saved(ticket), ticket: ticket))
        XCTAssertNil(session.snapshot)
        XCTAssertNil(session.recoveryRecord)
        XCTAssertFalse(session.recoveryNeedsAttention)
        XCTAssertFalse(session.recoveryWriteBlocked)
        XCTAssertNil(session.recoveryIssue)
        XCTAssertNotEqual(session.recoveryIdentifier, recovery.id)
    }

    func testLiveIdentityFailureBlocksAllWritesWithoutLosingEitherFailureDetail() throws {
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        session.updateDraft("本地草稿")
        let ticket = try XCTUnwrap(session.beginSaving())
        XCTAssertTrue(session.failSaving("先前保存未确认", uncertain: true, ticket: ticket))
        session.setRecoveryIssue("恢复目录写入失败")
        XCTAssertTrue(session.status.contains("先前保存未确认"))
        XCTAssertTrue(session.status.contains("恢复目录写入失败"))

        session.blockRecoveryWrite("同名文件身份已替换")
        XCTAssertTrue(session.recoveryWriteBlocked)
        XCTAssertTrue(session.recoveryNeedsAttention)
        XCTAssertEqual(session.recoveryIssue, "同名文件身份已替换")
        XCTAssertFalse(session.canBeginSave)
        XCTAssertNil(session.beginSaving())
        XCTAssertNil(session.autosaveTicket)
        XCTAssertNotNil(session.recoveryRecord)
        XCTAssertTrue(session.status.contains("先前保存未确认"))
        XCTAssertTrue(session.status.contains("同名文件身份已替换"))
        XCTAssertEqual(session.draft, "本地草稿")
    }

    func testRestoreBaselineConflictReportsExternalMissingAndEmptySeparately() {
        for (content, description) in [(NoteContent.missing, "属性已不存在"),
                                        (.present(Data()), "为空正文")] {
            let session = EditorSession()
            let recovery = record()
            XCTAssertTrue(session.restoreRecovery(record: recovery, current: note(content: content)))
            XCTAssertFalse(session.recoveryWriteBlocked)
            XCTAssertTrue(session.saveIssue?.message.contains("正文基线与外部版本不同") ?? false)
            XCTAssertTrue(session.saveIssue?.message.contains(description) ?? false)
            XCTAssertEqual(session.snapshot?.content, recovery.snapshot.content)
            XCTAssertEqual(session.draft, recovery.draft)
            XCTAssertNil(session.autosaveTicket)
        }
    }
    func testRecoveryWithoutUsableBirthIdentityCannotBeReenabledForWriting() {
        let unknown = NoteSnapshot(url: note().url, identity: FileIdentity(device: 1, inode: 7),
                                   content: note().content)
        let session = EditorSession()
        XCTAssertTrue(session.restoreRecovery(record: record(baseline: unknown), current: unknown))
        XCTAssertTrue(session.recoveryWriteBlocked)
        XCTAssertNil(session.beginSaving())
        XCTAssertFalse(session.applyExternal(unknown, replacingDraft: false,
                                              confirmedRevision: session.draftRevision))
        XCTAssertEqual(session.draft, "未保存草稿🙂\n")
    }

}
