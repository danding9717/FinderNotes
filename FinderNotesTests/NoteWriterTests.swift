import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import FinderNotes

final class NoteWriterTests: XCTestCase {
    private var root: URL!
    private let reader = NoteReader()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("findernotes-fn05-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testMissingToPresentEmptyAndActiveClearing() throws {
        for name in ["image.png", "movie.mov"] {
            let url = try media(name)
            let initial = try reader.read(urls: [url])
            XCTAssertEqual(initial.content, .missing)
            let empty = try NoteWriter().save(request(initial, ""))
            XCTAssertEqual(empty.content, .present(Data()))
            XCTAssertEqual(try reader.read(urls: [url]).content, .present(Data()))

            let filled = try NoteWriter().save(request(empty, "文字"))
            let cleared = try NoteWriter().save(request(filled, ""))
            XCTAssertEqual(cleared.content, .present(Data()))
            XCTAssertEqual(try attribute(url, NoteReader.attributeName), Data())
        }
    }

    func testExactUTF8MediaAndUnrelatedAttributesSurviveWrites() throws {
        for name in ["image.png", "movie.mov"] {
            let url = try media(name)
            try Self.setAttribute(url, "com.findernotes.fn05.unrelated", Data([0, 1, 254, 255]))
            let mediaDigest = SHA256.hash(data: try Data(contentsOf: url))
            let unrelated = try attribute(url, "com.findernotes.fn05.unrelated")
            var baseline = try reader.read(urls: [url])
            let texts = ["  中文🙂👩🏽‍🚀\n第二段\n\n末尾空白  \n",
                         "e\u{301} 与 é 不归一化",
                         String(repeating: "航", count: 2_000),
                         "首🙂\n" + String(repeating: "x", count: 16_384 - Data("首🙂\n".utf8).count)]
            for text in texts {
                baseline = try NoteWriter().save(request(baseline, text))
                let expected = Data(text.utf8)
                XCTAssertEqual(baseline.content, .present(expected))
                XCTAssertEqual(try reader.read(urls: [url]).content, .present(expected))
                XCTAssertEqual(try attribute(url, NoteReader.attributeName), expected)
                XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: url)), mediaDigest)
                XCTAssertEqual(try attribute(url, "com.findernotes.fn05.unrelated"), unrelated)
            }
        }
    }

    func testAnotherProcessReadsTheCompleteWrittenBytes() throws {
        let url = try media("image.png")
        let text = " 前后空白🙂\n换行\n" + String(repeating: "航", count: 2_000)
        let snapshot = try reader.read(urls: [url])
        _ = try NoteWriter().save(request(snapshot, text))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-p", "-x", NoteReader.attributeName, url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let hex = String(decoding: raw, as: UTF8.self).filter { !$0.isWhitespace }
        let expected = Data(text.utf8).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex.lowercased(), expected)
    }

    func testExternalOwnAttributeChangesConflictButUnrelatedChangeDoesNot() throws {
        let missing = try media("missing.png")
        let missingBaseline = try reader.read(urls: [missing])
        try Self.setAttribute(missing, NoteReader.attributeName, Data("外部".utf8))
        XCTAssertThrowsError(try NoteWriter().save(request(missingBaseline, "草稿"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .conflict)
        }
        XCTAssertEqual(try attribute(missing, NoteReader.attributeName), Data("外部".utf8))

        let url = try media("image.png")
        var baseline = try reader.read(urls: [url])
        baseline = try NoteWriter().save(request(baseline, "原文"))
        try Self.setAttribute(url, NoteReader.attributeName, Data("外改".utf8)) // same byte length
        XCTAssertThrowsError(try NoteWriter().save(request(baseline, "草稿"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .conflict)
        }
        XCTAssertEqual(try attribute(url, NoteReader.attributeName), Data("外改".utf8))

        try removeAttribute(url, NoteReader.attributeName)
        XCTAssertThrowsError(try NoteWriter().save(request(baseline, "草稿"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .conflict)
        }
        XCTAssertNil(try attribute(url, NoteReader.attributeName))

        let fresh = try reader.read(urls: [url])
        try Self.setAttribute(url, "com.findernotes.fn05.unrelated", Data([42]))
        let saved = try NoteWriter().save(request(fresh, "可保存"))
        XCTAssertEqual(saved.content.text, "可保存")
        XCTAssertEqual(try attribute(url, "com.findernotes.fn05.unrelated"), Data([42]))
    }

    func testDisappearanceAndSameNameOrParentReplacementStopBeforeWrite() throws {
        let gone = try media("gone.png")
        let goneBaseline = try reader.read(urls: [gone])
        try FileManager.default.removeItem(at: gone)
        XCTAssertThrowsError(try NoteWriter().save(request(goneBaseline, "草稿"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .identityChanged)
        }

        let replaced = try media("replaced.png")
        let old = try reader.read(urls: [replaced])
        try FileManager.default.moveItem(at: replaced, to: root.appendingPathComponent("retained.png"))
        _ = try media("replaced.png")
        XCTAssertThrowsError(try NoteWriter().save(request(old, "草稿"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .identityChanged)
        }
        XCTAssertNil(try attribute(replaced, NoteReader.attributeName))

        let directory = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let nested = try media("folder/clip.mov")
        let nestedBaseline = try reader.read(urls: [nested])
        try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("old-folder"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try media("folder/clip.mov")
        XCTAssertThrowsError(try NoteWriter().save(request(nestedBaseline, "草稿"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .identityChanged)
        }
        XCTAssertNil(try attribute(nested, NoteReader.attributeName))
    }

    #if DEBUG
    func testLastPrewriteCheckDetectsExternalChange() throws {
        let url = try media("image.png")
        let baseline = try reader.read(urls: [url])
        let writer = NoteWriter(beforeFinalValidation: {
            try Self.setAttribute(url, NoteReader.attributeName, Data("外部".utf8))
        })
        XCTAssertThrowsError(try writer.save(request(baseline, "草稿"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .conflict)
        }
        XCTAssertEqual(try attribute(url, NoteReader.attributeName), Data("外部".utf8))
    }

    func testPostwriteReadbackFailureAndMismatchAreUnconfirmed() throws {
        let url = try media("image.png")
        let baseline = try reader.read(urls: [url])
        enum Injected: Error { case readFailure }
        let failing = NoteWriter(beforeReadback: { throw Injected.readFailure })
        XCTAssertThrowsError(try failing.save(request(baseline, "已写入"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .resultUnconfirmed)
            XCTAssertTrue((error as? NoteWriteError)?.resultWasUnconfirmed == true)
        }
        XCTAssertEqual(try attribute(url, NoteReader.attributeName), Data("已写入".utf8))

        let fresh = try reader.read(urls: [url])
        let racing = NoteWriter(beforeReadback: {
            try Self.setAttribute(url, NoteReader.attributeName, Data("外部覆盖".utf8))
        })
        XCTAssertThrowsError(try racing.save(request(fresh, "新草稿"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .resultUnconfirmed)
        }
        XCTAssertEqual(try attribute(url, NoteReader.attributeName), Data("外部覆盖".utf8))
    }

    func testMovedAfterWriteIsUnconfirmedEvenThoughHeldDescriptorWasWritten() throws {
        let url = try media("image.png")
        let moved = root.appendingPathComponent("moved.png")
        let baseline = try reader.read(urls: [url])
        let writer = NoteWriter(beforeReadback: {
            try FileManager.default.moveItem(at: url, to: moved)
        })
        XCTAssertThrowsError(try writer.save(request(baseline, "草稿"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .resultUnconfirmed)
        }
        XCTAssertEqual(try attribute(moved, NoteReader.attributeName), Data("草稿".utf8))
    }
    #endif

    func testPermissionFailureIsWriteFailureAndDoesNotPresentSuccess() throws {
        try XCTSkipIf(geteuid() == 0, "root bypasses file permissions")
        let url = try media("image.png")
        let baseline = try reader.read(urls: [url])
        XCTAssertEqual(chmod(url.path, 0o400), 0)
        defer { _ = chmod(url.path, 0o600) }
        XCTAssertThrowsError(try NoteWriter().save(request(baseline, "草稿"))) { error in
            guard case .writeFailed(_, let code) = error as? NoteWriteError else {
                return XCTFail("Expected write failure, got \(error)")
            }
            XCTAssertEqual(code, EACCES)
        }
        XCTAssertNil(try attribute(url, NoteReader.attributeName))
    }

    func testCopyGetsIndependentIdentityAndSession() throws {
        let original = try media("original.png")
        let first = try reader.read(urls: [original])
        _ = try NoteWriter().save(request(first, "原件"))
        let copy = root.appendingPathComponent("copy.png")
        try FileManager.default.copyItem(at: original, to: copy)
        let originalSnapshot = try reader.read(urls: [original])
        let copySnapshot = try reader.read(urls: [copy])
        XCTAssertNotEqual(originalSnapshot.identity, copySnapshot.identity)
        _ = try NoteWriter().save(request(copySnapshot, "副本"))
        XCTAssertEqual(try reader.read(urls: [original]).content.text, "原件")
        XCTAssertEqual(try reader.read(urls: [copy]).content.text, "副本")
    }

    func testUnchangedManualSaveVerifiesReadOnlyFileWithoutWritingAgain() throws {
        try XCTSkipIf(geteuid() == 0, "root bypasses file permissions")
        let url = try media("unchanged.png")
        let baseline = try NoteWriter().save(request(try reader.read(urls: [url]), "不变的中文🙂"))
        XCTAssertEqual(chmod(url.path, 0o400), 0)
        defer { _ = chmod(url.path, 0o600) }
        let verified = try NoteWriter().save(request(baseline, "不变的中文🙂"))
        XCTAssertEqual(verified.content, baseline.content)
        XCTAssertEqual(verified.identity, baseline.identity)
        XCTAssertThrowsError(try NoteWriter().save(request(baseline, "真的改动")))
        XCTAssertEqual(try attribute(url, NoteReader.attributeName), Data("不变的中文🙂".utf8))
    }

    func testUnchangedManualSaveStillRejectsChangedBodyAndIdentity() throws {
        let url = try media("unchanged.png")
        let baseline = try NoteWriter().save(request(try reader.read(urls: [url]), "原文"))
        try Self.setAttribute(url, NoteReader.attributeName, Data("外改".utf8))
        XCTAssertThrowsError(try NoteWriter().save(request(baseline, "原文"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .conflict)
        }
        XCTAssertEqual(try attribute(url, NoteReader.attributeName), Data("外改".utf8))
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("retained.png"))
        _ = try media("unchanged.png")
        XCTAssertThrowsError(try NoteWriter().save(request(baseline, "原文"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .identityChanged)
        }
        XCTAssertNil(try attribute(url, NoteReader.attributeName))
    }

    #if DEBUG
    func testUnchangedManualSaveDoesNotEnterPostwritePhase() throws {
        let url = try media("unchanged.png")
        let baseline = try NoteWriter().save(request(try reader.read(urls: [url]), "原文"))
        enum Unexpected: Error { case wrote }
        let writer = NoteWriter(beforeReadback: { throw Unexpected.wrote })
        let result = try writer.save(request(baseline, "原文"))
        XCTAssertEqual(result.content, baseline.content)
    }

    func testUnconfirmedWriteCannotBeRetriedAgainstOldBaseline() throws {
        let url = try media("unconfirmed.png")
        let baseline = try reader.read(urls: [url])
        enum Injected: Error { case readback }
        let writer = NoteWriter(beforeReadback: { throw Injected.readback })
        XCTAssertThrowsError(try writer.save(request(baseline, "已实际写入"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .resultUnconfirmed)
        }
        XCTAssertThrowsError(try NoteWriter().save(request(baseline, "已实际写入"))) { error in
            XCTAssertEqual(error as? NoteWriteError, .conflict)
        }
        XCTAssertEqual(try attribute(url, NoteReader.attributeName), Data("已实际写入".utf8))
    }
    #endif

    private func request(_ baseline: NoteSnapshot, _ text: String) -> NoteSaveRequest {
        NoteSaveRequest(baseline: baseline, desiredContent: .present(Data(text.utf8)))
    }

    private func media(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let bytes = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=")!
        try bytes.write(to: url, options: .withoutOverwriting)
        return url
    }

    private static func setAttribute(_ url: URL, _ name: String, _ bytes: Data) throws {
        let result = bytes.withUnsafeBytes { rawBytes in
            setxattr(url.path, name, rawBytes.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }

    private func removeAttribute(_ url: URL, _ name: String) throws {
        guard removexattr(url.path, name, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
    }

    private func attribute(_ url: URL, _ name: String) throws -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno)!)
        }
        var bytes = [UInt8](repeating: 0, count: max(1, size))
        let count = getxattr(url.path, name, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        return Data(bytes.prefix(count))
    }
}
