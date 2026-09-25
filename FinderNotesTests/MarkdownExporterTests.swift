import Darwin
import Foundation
import XCTest
@testable import FinderNotes

final class MarkdownExporterTests: XCTestCase {
    private var root: URL!
    private let exporter = MarkdownExporter()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("findernotes-fn05-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testDefaultNameUsesCompleteOriginalFileName() {
        XCTAssertEqual(MarkdownExporter.defaultFileName(for: root.appendingPathComponent("照片.final.PNG")),
                       "照片.final.PNG.note.md")
        XCTAssertEqual(MarkdownExporter.defaultFileName(for: root.appendingPathComponent("clip.mov")),
                       "clip.mov.note.md")
    }

    func testExactUTF8SnapshotAndEmptySnapshot() throws {
        let source = try media("picture.png")
        let original = try Data(contentsOf: source)
        let text = "  中文🙂e\u{301}\n第二段\n\n末尾空白  \n" + String(repeating: "航", count: 2_000)
        let bytes = Data(text.utf8)
        let destination = root.appendingPathComponent(MarkdownExporter.defaultFileName(for: source))
        try exporter.export(.init(source: source, destination: destination, bytes: bytes))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try Data(contentsOf: source), original)

        let movie = try media("clip.mov")
        let empty = root.appendingPathComponent("clip.mov.note.md")
        try exporter.export(.init(source: movie, destination: empty, bytes: Data()))
        XCTAssertEqual(try Data(contentsOf: empty), Data())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: empty.path)[.size] as? Int, 0)
        XCTAssertEqual(try Data(contentsOf: movie), original)
    }

    func testSixteenKiBByteSnapshotIsNotNormalized() throws {
        let source = try media("large.png")
        let prefix = Data("\0首🙂\r\n".utf8)
        let bytes = prefix + Data(repeating: 0x20, count: 16_384 - prefix.count)
        let destination = root.appendingPathComponent("large.png.note.md")
        try exporter.export(.init(source: source, destination: destination, bytes: bytes))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testFrozenBytesCanBeExportedAfterSourceDisappears() throws {
        let source = try media("moved.mov")
        var draft = "先冻结的正文"
        let request = MarkdownExportRequest(source: source,
                                            destination: root.appendingPathComponent("snapshot.md"),
                                            bytes: Data(draft.utf8))
        draft = "后续编辑"
        try FileManager.default.removeItem(at: source)
        try exporter.export(request)
        XCTAssertEqual(try Data(contentsOf: request.destination), Data("先冻结的正文".utf8))
        XCTAssertEqual(draft, "后续编辑")
    }

    func testExistingFileAndSymlinkAreNotOverwritten() throws {
        let source = try media("source.png")
        let existing = root.appendingPathComponent("existing.md")
        let original = Data("先前的文件".utf8)
        try original.write(to: existing, options: .withoutOverwriting)
        XCTAssertThrowsError(try exporter.export(.init(source: source, destination: existing,
                                                        bytes: Data("new".utf8)))) { error in
            XCTAssertEqual(error as? MarkdownExportError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: existing), original)

        let symlink = root.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: existing)
        XCTAssertThrowsError(try exporter.export(.init(source: source, destination: symlink,
                                                        bytes: Data("new".utf8)))) { error in
            XCTAssertEqual(error as? MarkdownExportError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: existing), original)
    }

    func testHardLinkToSourceAndInvalidUTF8AreRejected() throws {
        let source = try media("source.png")
        let hardLink = root.appendingPathComponent("source-copy.md")
        try FileManager.default.linkItem(at: source, to: hardLink)
        let original = try Data(contentsOf: source)
        XCTAssertThrowsError(try exporter.export(.init(source: source, destination: hardLink,
                                                        bytes: Data("note".utf8)))) { error in
            XCTAssertEqual(error as? MarkdownExportError, .sourceDestinationSame)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)

        let destination = root.appendingPathComponent("invalid.md")
        XCTAssertThrowsError(try exporter.export(.init(source: source, destination: destination,
                                                        bytes: Data([0xFF])))) { error in
            XCTAssertEqual(error as? MarkdownExportError, .invalidUTF8)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDestinationRaceNeverOverwritesWinner() throws {
        let source = try media("source.png")
        let destination = root.appendingPathComponent("raced.md")
        let winner = Data("another writer".utf8)
        let racingExporter = MarkdownExporter(beforePublish: {
            try winner.write(to: destination, options: .withoutOverwriting)
        })
        XCTAssertThrowsError(try racingExporter.export(.init(source: source, destination: destination,
                                                              bytes: Data("ours".utf8)))) { error in
            XCTAssertEqual(error as? MarkdownExportError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), winner)
        try assertNoTemporaryFiles()
    }

    func testSourcePathAndParentSymlinkAreRejected() throws {
        let source = try media("source.png")
        XCTAssertThrowsError(try exporter.export(.init(source: source, destination: source,
                                                        bytes: Data("note".utf8)))) { error in
            XCTAssertEqual(error as? MarkdownExportError, .sourceDestinationSame)
        }

        let linkedDirectory = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: root)
        let linkedDestination = linkedDirectory.appendingPathComponent("new.md")
        XCTAssertThrowsError(try exporter.export(.init(source: source, destination: linkedDestination,
                                                        bytes: Data("note".utf8))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.md").path))
        try assertNoTemporaryFiles()
    }

    func testUnwritableDirectoryFailsWithoutPublishing() throws {
        try XCTSkipIf(geteuid() == 0, "root bypasses normal directory permissions")
        let source = try media("source.png")
        let directory = root.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory.path, 0o500), 0)
        defer { _ = chmod(directory.path, 0o700) }
        let destination = directory.appendingPathComponent("new.md")
        XCTAssertThrowsError(try exporter.export(.init(source: source, destination: destination,
                                                        bytes: Data("draft".utf8))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func media(_ name: String) throws -> URL {
        let source = root.appendingPathComponent(name)
        try Data([0, 1, 2, 3, 254, 255]).write(to: source, options: .withoutOverwriting)
        return source
    }

    private func assertNoTemporaryFiles() throws {
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertFalse(entries.contains { $0.lastPathComponent.hasPrefix(".findernotes-export-") })
    }
}
