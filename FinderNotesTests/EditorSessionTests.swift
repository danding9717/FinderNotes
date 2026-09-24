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
}
