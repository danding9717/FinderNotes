import XCTest
@testable import FinderNotes

@MainActor
final class EditorSessionTests: XCTestCase {
    private func note(_ name: String = "one.png", inode: UInt64 = 1, text: String? = "原笔记") -> NoteSnapshot {
        NoteSnapshot(url: URL(fileURLWithPath: "/tmp/" + name),
                     identity: FileIdentity(device: 1, inode: inode),
                     content: text.map { .present(Data($0.utf8)) } ?? .missing)
    }

    func testMissingAndExistingEmptyHaveDifferentStatuses() {
        let session = EditorSession()
        XCTAssertEqual(session.resolve(note(text: nil), ticket: session.beginLoading()), .installed)
        XCTAssertEqual(session.status, "尚无笔记 · 可在此编辑草稿")
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.resolve(note("empty.mov", inode: 2, text: ""), ticket: session.beginLoading()), .installed)
        XCTAssertEqual(session.status, "已有空笔记")
    }

    func testRepeatKeepsDraftAndOriginalBaselineAfterExternalChange() {
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        session.updateDraft("尚未保存🙂")
        let revision = session.draftRevision
        XCTAssertEqual(session.resolve(note(text: "外部正文"), ticket: session.beginLoading()), .reused)
        XCTAssertEqual(session.draft, "尚未保存🙂")
        XCTAssertEqual(session.snapshot?.content.text, "原笔记")
        XCTAssertEqual(session.draftRevision, revision)
    }

    func testReadFailureDoesNotClearCurrentDraftOrEnableEmptyTarget() {
        let empty = EditorSession()
        empty.reject("拒绝访问", ticket: empty.beginLoading())
        XCTAssertNil(empty.snapshot)
        XCTAssertTrue(empty.status.contains("读取失败"))
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        session.updateDraft("草稿")
        session.reject("目标不存在", ticket: session.beginLoading())
        XCTAssertEqual(session.snapshot?.url.lastPathComponent, "one.png")
        XCTAssertEqual(session.draft, "草稿")
        XCTAssertTrue(session.isDirty)
    }

    func testDirtySwitchRequiresExplicitDecisionAndSameNameReplacementIsNewTarget() {
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        session.updateDraft("草稿")
        let replacement = note(inode: 2, text: "新文件")
        let ticket = session.beginLoading()
        XCTAssertEqual(session.resolve(replacement, ticket: ticket), .needsDiscard)
        XCTAssertEqual(session.snapshot?.identity.inode, 1)
        XCTAssertEqual(session.draft, "草稿")
        XCTAssertTrue(session.acceptReplacement(replacement, ticket: ticket, confirmedRevision: session.draftRevision))
        XCTAssertEqual(session.snapshot?.identity.inode, 2)
        XCTAssertEqual(session.draft, "新文件")
        XCTAssertFalse(session.isDirty)
    }

    func testDraftChangesAfterConfirmationCannotBeOverwritten() {
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        session.updateDraft("草稿")
        let ticket = session.beginLoading()
        let next = note("two.mov", inode: 2)
        XCTAssertEqual(session.resolve(next, ticket: ticket), .needsDiscard)
        let confirmedRevision = session.draftRevision
        session.updateDraft("更新的草稿")
        XCTAssertFalse(session.acceptReplacement(next, ticket: ticket, confirmedRevision: confirmedRevision))
        XCTAssertEqual(session.draft, "更新的草稿")
    }

    func testOutOfOrderResultsAndCloseCannotRepopulateWindow() {
        let session = EditorSession()
        let old = session.beginLoading()
        let latest = session.beginLoading()
        XCTAssertEqual(session.resolve(note("two.mov", inode: 2), ticket: latest), .installed)
        XCTAssertEqual(session.resolve(note(), ticket: old), .stale)
        session.reject("旧失败", ticket: old)
        XCTAssertNil(session.failure)
        let pending = session.beginLoading()
        session.close()
        XCTAssertEqual(session.resolve(note(), ticket: pending), .stale)
        XCTAssertNil(session.snapshot)
        XCTAssertEqual(session.draft, "")
    }

    func testEditingDuringReadGetsDiscardProtection() {
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        let ticket = session.beginLoading()
        session.updateDraft("读取时继续写字")
        XCTAssertEqual(session.resolve(note("two.mov", inode: 2), ticket: ticket), .needsDiscard)
        XCTAssertEqual(session.draft, "读取时继续写字")
    }

    func testMarkedTextRequiresProtectionEvenWithEqualDraft() {
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        XCTAssertEqual(session.resolve(note("two.mov", inode: 2), ticket: session.beginLoading(), protectsMarkedText: true), .needsDiscard)
    }

    func testDirtyComparisonPreservesUnicodeBytesAndUndoBackToBaseline() {
        let session = EditorSession()
        _ = session.resolve(note(text: "é"), ticket: session.beginLoading())
        session.updateDraft("e\u{301}")
        XCTAssertTrue(session.isDirty, "Swift canonical string equality must not hide byte changes")
        session.updateDraft("é")
        XCTAssertFalse(session.isDirty)
    }

    func testExplicitEmptySaveTurnsMissingNoteIntoPresentEmptyNote() throws {
        let session = EditorSession()
        _ = session.resolve(note(text: nil), ticket: session.beginLoading())
        XCTAssertFalse(session.isDirty)
        let ticket = try XCTUnwrap(session.beginSaving())
        XCTAssertEqual(ticket.request.baseline.content, .missing)
        XCTAssertEqual(ticket.request.desiredContent, .present(Data()))
        XCTAssertTrue(session.isSaving)
        XCTAssertNil(session.beginSaving(), "Only one write can be pending")
        let saved = NoteSnapshot(url: ticket.request.baseline.url,
                                 identity: ticket.request.baseline.identity,
                                 content: .present(Data()))
        XCTAssertTrue(session.completeSaving(saved, ticket: ticket))
        XCTAssertEqual(session.snapshot?.content, .present(Data()))
        XCTAssertEqual(session.status, "空笔记已保存")
        XCTAssertFalse(session.requiresLeaveConfirmation)
    }

    func testSuccessfulOldSaveAdvancesBaselineWithoutOverwritingNewDraft() throws {
        let session = EditorSession()
        _ = session.resolve(note(text: "原文"), ticket: session.beginLoading())
        session.updateDraft("先保存🙂\n")
        let ticket = try XCTUnwrap(session.beginSaving())
        let captured = Data("先保存🙂\n".utf8)
        XCTAssertEqual(ticket.request.desiredContent, .present(captured))
        session.updateDraft("保存期间的新草稿🙂\n")
        let saved = NoteSnapshot(url: ticket.request.baseline.url,
                                 identity: ticket.request.baseline.identity,
                                 content: .present(captured))
        XCTAssertTrue(session.completeSaving(saved, ticket: ticket))
        XCTAssertEqual(session.snapshot?.content, .present(captured))
        XCTAssertEqual(session.draft, "保存期间的新草稿🙂\n")
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.status, "上一版已保存 · 当前草稿尚未保存")
        XCTAssertFalse(session.completeSaving(saved, ticket: ticket), "A late duplicate result must be ignored")
    }

    func testClearingExistingNoteAndFailureProtection() throws {
        let session = EditorSession()
        _ = session.resolve(note(text: "有正文"), ticket: session.beginLoading())
        session.updateDraft("")
        let ticket = try XCTUnwrap(session.beginSaving())
        let saved = NoteSnapshot(url: ticket.request.baseline.url,
                                 identity: ticket.request.baseline.identity,
                                 content: .present(Data()))
        XCTAssertTrue(session.completeSaving(saved, ticket: ticket))
        XCTAssertEqual(session.status, "笔记已清空并保存")

        let retry = try XCTUnwrap(session.beginSaving())
        XCTAssertTrue(session.failSaving("磁盘拒绝写入", uncertain: false, ticket: retry))
        XCTAssertFalse(session.isDirty)
        XCTAssertTrue(session.requiresLeaveConfirmation, "Even an equal empty draft needs protection after a failed save")
        XCTAssertTrue(session.status.contains("保存失败"))
        let uncertain = try XCTUnwrap(session.beginSaving())
        XCTAssertTrue(session.failSaving("需要重新打开核对", uncertain: true, ticket: uncertain))
        XCTAssertTrue(session.status.contains("写入结果未能确认"))
        XCTAssertTrue(session.requiresLeaveConfirmation)
        XCTAssertEqual(session.resolve(note("other.mov", inode: 9), ticket: session.beginLoading()), .needsDiscard)
    }

    func testSaveResultAfterClosedSessionCannotInstallOldBaseline() throws {
        let session = EditorSession()
        _ = session.resolve(note(), ticket: session.beginLoading())
        session.updateDraft("待保存")
        let ticket = try XCTUnwrap(session.beginSaving())
        let result = NoteSnapshot(url: ticket.request.baseline.url,
                                  identity: ticket.request.baseline.identity,
                                  content: ticket.request.desiredContent)
        session.close()
        XCTAssertFalse(session.completeSaving(result, ticket: ticket))
        XCTAssertNil(session.snapshot)
        XCTAssertEqual(session.draft, "")
    }
}
