import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import FinderNotes

final class NoteReaderTests: XCTestCase {
    private var root: URL!
    private let reader = NoteReader()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("findernotes-fn04-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testMissingAndPresentEmptyAreDistinct() throws {
        let url = try media()
        XCTAssertEqual(try reader.read(urls: [url]).content, .missing)
        try setAttribute(url, NoteReader.attributeName, Data())
        let snapshot = try reader.read(urls: [url])
        XCTAssertEqual(snapshot.content, .present(Data()))
        XCTAssertEqual(snapshot.content.text, "")
    }

    func testExactUTF8RoundTripsWithoutChangingMediaOrAnyAttribute() throws {
        let url = try media()
        try setAttribute(url, "com.findernotes.fn04.fixture", Data([0, 1, 254, 255]))
        // This native Finder comment is an unrelated binary plist; it must never become the note.
        let finderComment = try PropertyListSerialization.data(fromPropertyList: "原生 Finder 注释",
                                                               format: .binary, options: 0)
        try setAttribute(url, "com.apple.metadata:kMDItemFinderComment", finderComment)
        let texts = ["  中文🙂👩🏽‍🚀\n第二段\n\n末尾空白  \n", String(repeating: "航", count: 2_000),
                     "首🙂\n" + String(repeating: "x", count: 16_384 - Data("首🙂\n".utf8).count), "\0"]
        for text in texts {
            let bytes = Data(text.utf8)
            try setAttribute(url, NoteReader.attributeName, bytes)
            let before = try fingerprint(url)
            let snapshot = try reader.read(urls: [url])
            XCTAssertEqual(snapshot.content, .present(bytes))
            XCTAssertEqual(snapshot.content.text, text)
            XCTAssertEqual(try fingerprint(url), before, "Reading must not write media or any xattr")
        }
    }

    func testNativeCommentDoesNotStandInForAbsentNote() throws {
        let url = try media()
        try setAttribute(url, "com.apple.metadata:kMDItemFinderComment", Data("原生注释".utf8))
        let before = try fingerprint(url)
        XCTAssertEqual(try reader.read(urls: [url]).content, .missing)
        XCTAssertEqual(try fingerprint(url), before)
    }

    func testMalformedUTF8IsFailureAndRetainsOriginalBytes() throws {
        let url = try media()
        for bytes in [Data([0xC3, 0x28]), Data([0xFF]), Data([0xED, 0xA0, 0x80])] {
            try setAttribute(url, NoteReader.attributeName, bytes)
            let before = try fingerprint(url)
            XCTAssertThrowsError(try reader.read(urls: [url])) { error in
                XCTAssertEqual(error as? NoteReadError, .invalidUTF8)
            }
            XCTAssertEqual(try fingerprint(url), before)
        }
    }

    func testOnlyOneLocalFileURLIsAccepted() throws {
        let url = try media()
        for urls in [[], [url, url]] {
            XCTAssertThrowsError(try reader.read(urls: urls)) { error in
                XCTAssertEqual(error as? NoteReadError, .selectionCount)
            }
        }
        for remote in [URL(string: "https://example.invalid/file.png")!,
                       URL(string: "file://server.invalid/share/file.png")!] {
            XCTAssertThrowsError(try reader.read(urls: [remote])) { error in
                XCTAssertEqual(error as? NoteReadError, .localFileRequired)
            }
        }
    }

    func testImageAndMovieTypesAreAcceptedAndTextIsRejected() throws {
        for name in ["image.png", "image.jpg", "movie.mov"] {
            XCTAssertEqual(try reader.read(urls: [try media(name)]).content, .missing)
        }
        XCTAssertThrowsError(try reader.read(urls: [try media("text.txt")])) { error in
            XCTAssertEqual(error as? NoteReadError, .unsupportedType)
        }
    }

    func testRejectsDirectoryFinalSymlinkParentSymlinkAndHardLink() throws {
        let url = try media()
        let symlink = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: url)
        let directory = root.appendingPathComponent("directory.png", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let directoryLink = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        for rejected in [directory, symlink, directoryLink.appendingPathComponent(url.lastPathComponent)] {
            XCTAssertThrowsError(try reader.read(urls: [rejected]))
        }
        let hardLink = root.appendingPathComponent("hard-link.png")
        try FileManager.default.linkItem(at: url, to: hardLink)
        for rejected in [url, hardLink] {
            XCTAssertThrowsError(try reader.read(urls: [rejected])) { error in
                XCTAssertEqual(error as? NoteReadError, .hardLink)
            }
        }
    }

    func testRejectsFinderAliasEvenWhenNamedPNG() throws {
        let original = try media()
        let alias = root.appendingPathComponent("alias.png")
        let bookmark = try original.bookmarkData(options: .suitableForBookmarkFile,
                                                  includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        XCTAssertTrue(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
        XCTAssertThrowsError(try reader.read(urls: [alias])) { error in
            XCTAssertEqual(error as? NoteReadError, .finderAlias)
        }
    }

    func testPermissionDeniedIsFailureNotAnEmptyNote() throws {
        try XCTSkipIf(geteuid() == 0, "root bypasses normal file read permissions")
        let url = try media()
        try setAttribute(url, NoteReader.attributeName, Data("不能丢失的正文".utf8))
        XCTAssertEqual(chmod(url.path, 0), 0)
        defer { _ = chmod(url.path, 0o600) }
        XCTAssertThrowsError(try reader.read(urls: [url])) { error in
            guard case .system(_, let code) = error as? NoteReadError else {
                return XCTFail("Expected a permission error, got \(error)")
            }
            XCTAssertEqual(code, EACCES)
        }
    }

    func testMissingFileIsFailure() throws {
        XCTAssertThrowsError(try reader.read(urls: [root.appendingPathComponent("gone.png")]))
    }

    func testSystemVarAliasIsTheSameCanonicalTarget() throws {
        let url = try media()
        guard url.path.hasPrefix("/private/var/") else {
            throw XCTSkip("The current temporary directory is not under /private/var")
        }
        let alias = URL(fileURLWithPath: String(url.path.dropFirst("/private".count)))
        let direct = try reader.read(urls: [url])
        let aliased = try reader.read(urls: [alias])
        XCTAssertEqual(direct.url.path, aliased.url.path)
        XCTAssertEqual(direct.identity, aliased.identity)
    }

    func testReplacingFileAtSamePathChangesIdentityAndContent() throws {
        let url = try media()
        try setAttribute(url, NoteReader.attributeName, Data("first".utf8))
        let first = try reader.read(urls: [url])
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("original.png"))
        _ = try media()
        try setAttribute(url, NoteReader.attributeName, Data("second".utf8))
        let second = try reader.read(urls: [url])
        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertEqual(second.content.text, "second")
    }

    #if DEBUG
    func testDeletionDuringReadCannotPublishSnapshot() throws {
        let url = try media()
        let racingReader = NoteReader(beforeFinalValidation: {
            try FileManager.default.removeItem(at: url)
        })
        XCTAssertThrowsError(try racingReader.read(urls: [url])) { error in
            XCTAssertEqual(error as? NoteReadError, .targetChanged)
        }
    }

    func testReplacementDuringReadCannotPublishOldOrNewSnapshot() throws {
        let url = try media()
        let replacement = try media("replacement.png")
        let retainedOriginal = root.appendingPathComponent("original.png")
        try setAttribute(url, NoteReader.attributeName, Data("original".utf8))
        try setAttribute(replacement, NoteReader.attributeName, Data("replacement".utf8))
        let originalFingerprint = try fingerprint(url)
        let replacementFingerprint = try fingerprint(replacement)
        let racingReader = NoteReader(beforeFinalValidation: {
            try FileManager.default.moveItem(at: url, to: retainedOriginal)
            try FileManager.default.moveItem(at: replacement, to: url)
        })
        XCTAssertThrowsError(try racingReader.read(urls: [url])) { error in
            XCTAssertEqual(error as? NoteReadError, .targetChanged)
        }
        XCTAssertEqual(try fingerprint(retainedOriginal), originalFingerprint)
        XCTAssertEqual(try fingerprint(url), replacementFingerprint)
    }
    #endif

    private func media(_ name: String = "image.png") throws -> URL {
        let url = root.appendingPathComponent(name)
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=")!
        try png.write(to: url, options: .withoutOverwriting)
        return url
    }

    private func setAttribute(_ url: URL, _ name: String, _ bytes: Data) throws {
        let result = bytes.withUnsafeBytes { pointer in
            setxattr(url.path, name, pointer.baseAddress, bytes.count, 0, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }

    private struct Fingerprint: Equatable {
        let mediaSHA256: String
        let attributes: [String: Data]
    }

    private func fingerprint(_ url: URL) throws -> Fingerprint {
        let bytes = try Data(contentsOf: url)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        var names = [CChar](repeating: 0, count: max(1, size))
        let count = listxattr(url.path, &names, names.count, XATTR_NOFOLLOW)
        guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        var attributes: [String: Data] = [:]
        for part in names.prefix(count).split(separator: 0) {
            let name = String(decoding: part.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let valueSize = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard valueSize >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
            var value = [UInt8](repeating: 0, count: max(1, valueSize))
            let valueCount = getxattr(url.path, name, &value, value.count, 0, XATTR_NOFOLLOW)
            guard valueCount >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
            attributes[name] = Data(value.prefix(valueCount))
        }
        return Fingerprint(mediaSHA256: hash, attributes: attributes)
    }
}
