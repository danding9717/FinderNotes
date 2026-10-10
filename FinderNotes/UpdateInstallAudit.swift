import Foundation
import Darwin

/// Sparkle does not report cleanup failures. Keep unobserved cleanup unknown.
@MainActor
final class UpdateInstallAudit {
    struct FileIdentity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
    }
    struct Version: Codable, Equatable {
        let display: String
        let build: String
    }
    struct CacheBinding: Codable {
        let directoryPath: String
        let directoryIdentity: FileIdentity
        let bundlePath: String
        let extractionIdentity: FileIdentity?

        init(directoryPath: String, directoryIdentity: FileIdentity, bundlePath: String,
             extractionIdentity: FileIdentity? = nil) {
            self.directoryPath = directoryPath
            self.directoryIdentity = directoryIdentity
            self.bundlePath = bundlePath
            self.extractionIdentity = extractionIdentity
        }
    }
    enum Observation: String, Codable { case oldBundlePresent, missing, differentObject, unreadable }
    enum Status: String, Codable { case completed, incomplete, unknown }
    struct Evaluation: Codable {
        let status: Status
        let reason: String
    }
    struct Record: Codable {
        let schema: Int
        let id: UUID
        let bundleID: String
        let createdAt: Date
        let installationPath: String
        let oldVersion: Version
        let targetVersion: Version
        let oldIdentity: FileIdentity?
        let cacheInstallationPath: String
        let binding: CacheBinding?
        var awaitingRestart: Bool
        var evaluation: Evaluation
        var observations: [Observation]
        var checkedAt: Date?
    }

    let bundleID: String
    let installationURL: URL
    let currentVersion: Version
    let resultsDirectory: URL
    let cacheInstallationDirectory: URL
    private let fileManager: FileManager
    private var baseline: Set<String>?
    private var prepared: Record?
    private var resumeTask: Task<Void, Never>?

    init(bundle: Bundle = .main, resultsDirectory: URL? = nil,
         cacheInstallationDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        bundleID = bundle.bundleIdentifier ?? "unknown"
        installationURL = bundle.bundleURL.standardizedFileURL
        currentVersion = Version(display: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                 build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.resultsDirectory = resultsDirectory ?? support.appendingPathComponent(bundleID).appendingPathComponent("UpdateResults")
        let cache = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheInstallationDirectory = cacheInstallationDirectory ?? cache.appendingPathComponent(bundleID)
            .appendingPathComponent("org.sparkle-project.Sparkle").appendingPathComponent("Installation")
    }

    func beginCheck() {
        // A cancelled quit leaves this same Sparkle installation available for retry.
        guard prepared == nil else { return }
        baseline = try? Set(directChildren(cacheInstallationDirectory).map(\.lastPathComponent))
        if case .missing = fileState(cacheInstallationDirectory) { baseline = [] }
    }

    func prepare(targetVersion: Version) {
        prepared = Record(schema: 1, id: UUID(), bundleID: bundleID, createdAt: Date(),
                          installationPath: installationURL.path, oldVersion: currentVersion,
                          targetVersion: targetVersion, oldIdentity: identity(installationURL),
                          cacheInstallationPath: cacheInstallationDirectory.path,
                          binding: bindCacheDirectory(targetVersion: targetVersion),
                          awaitingRestart: false, evaluation: Evaluation(status: .unknown, reason: "awaiting-termination"),
                          observations: [], checkedAt: nil)
    }

    func recordBeforeTermination() {
        guard var record = prepared else { return }
        record.awaitingRestart = true
        record.evaluation = Evaluation(status: .unknown, reason: "awaiting-restart-and-cleanup-check")
        prepared = record
        persist(record)
    }

    func recordCancelledTermination() {
        guard var record = prepared else { return }
        record.awaitingRestart = false
        record.evaluation = Evaluation(status: .unknown, reason: "termination-cancelled")
        record.checkedAt = Date()
        prepared = record
        persist(record)
    }

    func resumePendingResults() {
        guard resumeTask == nil else { return }
        let records: [Record]
        do {
            records = try directChildren(resultsDirectory).filter { $0.pathExtension == "json" }.compactMap { url in
                guard let data = try? readRegularFile(url),
                      let record = try? JSONDecoder().decode(Record.self, from: data),
                      record.schema == 1, record.bundleID == bundleID, record.awaitingRestart,
                      url.lastPathComponent == record.id.uuidString + ".json" else { return nil }
                return record
            }
        } catch { return }
        resumeTask = Task { [weak self] in
            guard let self else { return }
            for var record in records {
                let targetMatches = record.installationPath == installationURL.path && record.targetVersion == currentVersion
                if targetMatches, record.binding != nil, record.oldIdentity != nil {
                    // Relaunch can precede cleanup. Observe immediately, then retry
                    // for a bounded interval without blocking the UI.
                    for delay in [0.0, 0.2, 1.0, 2.0, 4.0, 8.0] {
                        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                        guard !Task.isCancelled else { return }
                        record.observations.append(observe(record))
                        if Self.evaluate(binding: record.binding, targetMatches: true,
                                         observations: record.observations).status == .completed { break }
                    }
                }
                record.evaluation = Self.evaluate(binding: record.binding, targetMatches: targetMatches,
                                                  observations: record.observations)
                record.awaitingRestart = false
                record.checkedAt = Date()
                persist(record)
            }
            resumeTask = nil
        }
    }

    /// A vanished cache alone cannot prove cleanup: Sparkle can fall back to an
    /// OS replacement directory. Require observing our old inode here first.
    static func evaluate(binding: CacheBinding?, targetMatches: Bool, observations: [Observation]) -> Evaluation {
        guard targetMatches else { return Evaluation(status: .unknown, reason: "target-version-or-installation-path-not-running") }
        guard binding != nil else { return Evaluation(status: .unknown, reason: "current-installation-cache-not-uniquely-bound") }
        if observations.last == .oldBundlePresent {
            return Evaluation(status: .incomplete, reason: "observed-old-bundle-still-present")
        }
        if let lastOld = observations.lastIndex(of: .oldBundlePresent), observations.last == .missing,
           observations[lastOld...].allSatisfy({ $0 == .oldBundlePresent || $0 == .missing }) {
            return Evaluation(status: .completed, reason: "observed-old-bundle-then-removed")
        }
        return Evaluation(status: .unknown, reason: "old-bundle-cleanup-not-observed")
    }

    private func bindCacheDirectory(targetVersion: Version) -> CacheBinding? {
        guard let baseline, let directories = try? directChildren(cacheInstallationDirectory) else { return nil }
        var matches: [CacheBinding] = []
        for directory in directories where !baseline.contains(directory.lastPathComponent) {
            guard let directoryIdentity = identity(directory),
                  let extractions = try? directChildren(directory) else { continue }
            for extraction in extractions {
                guard let extractionIdentity = identity(extraction), let bundles = try? directChildren(extraction) else { continue }
                for app in bundles where app.pathExtension == "app" {
                    let infoURL = app.appendingPathComponent("Contents/Info.plist")
                    guard identity(app) != nil, identity(infoURL) != nil,
                          let data = try? readRegularFile(infoURL),
                          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          info["CFBundleIdentifier"] as? String == bundleID,
                          info["CFBundleVersion"] as? String == targetVersion.build,
                          info["CFBundleShortVersionString"] as? String == targetVersion.display else { continue }
                    matches.append(CacheBinding(directoryPath: directory.path, directoryIdentity: directoryIdentity,
                                                bundlePath: app.path, extractionIdentity: extractionIdentity))
                }
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func observe(_ record: Record) -> Observation {
        guard let binding = record.binding, let oldIdentity = record.oldIdentity,
              URL(fileURLWithPath: record.cacheInstallationPath).standardizedFileURL.path == cacheInstallationDirectory.standardizedFileURL.path else { return .unreadable }
        let directory = URL(fileURLWithPath: binding.directoryPath).standardizedFileURL
        let app = URL(fileURLWithPath: binding.bundlePath).standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL.path == cacheInstallationDirectory.standardizedFileURL.path,
              app.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == directory.path else { return .unreadable }
        switch fileState(directory) {
        case .missing: return .missing
        case .present(let value) where value == binding.directoryIdentity: break
        case .present: return .differentObject
        case .unreadable: return .unreadable
        }
        guard let extractionIdentity = binding.extractionIdentity else { return .unreadable }
        switch fileState(app.deletingLastPathComponent()) {
        case .missing: return .missing
        case .present(let value) where value == extractionIdentity: break
        case .present: return .differentObject
        case .unreadable: return .unreadable
        }
        switch fileState(app) {
        case .missing: return .missing
        case .present(let value): return value == oldIdentity ? .oldBundlePresent : .differentObject
        case .unreadable: return .unreadable
        }
    }

    private enum FileState { case present(FileIdentity), missing, unreadable }

    private func fileState(_ url: URL) -> FileState {
        // Reject symlink ancestors rather than following paths elsewhere.
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { return .unreadable }
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return errno == ENOENT ? .missing : .unreadable }
        guard value.st_mode & S_IFMT != S_IFLNK else { return .unreadable }
        return .present(FileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino)))
    }

    private func identity(_ url: URL) -> FileIdentity? {
        if case .present(let value) = fileState(url) { return value }
        return nil
    }

    private func readRegularFile(_ url: URL, maximumSize: Int = 65_536) throws -> Data {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var expected = stat()
        guard lstat(url.path, &expected) == 0, expected.st_mode & S_IFMT == S_IFREG,
              expected.st_nlink == 1, expected.st_size >= 0, expected.st_size <= Int64(maximumSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Nonblocking prevents even a concurrently substituted FIFO from hanging
        // the UI. fstat then requires the exact ordinary file inspected above.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_dev == expected.st_dev, before.st_ino == expected.st_ino,
              before.st_size == expected.st_size else { throw CocoaError(.fileReadCorruptFile) }
        let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
        var after = stat()
        var current = stat()
        guard data.count == Int(before.st_size), fstat(descriptor, &after) == 0,
              lstat(url.path, &current) == 0, current.st_dev == before.st_dev, current.st_ino == before.st_ino,
              after.st_nlink == 1, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private func directChildren(_ directory: URL) throws -> [URL] {
        guard identity(directory) != nil else { throw CocoaError(.fileReadNoSuchFile) }
        let children = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // Shallow, bounded reads; never traverse other app caches.
        guard children.count <= 128 else { throw CocoaError(.fileReadTooLarge) }
        return children
    }

    private func persist(_ record: Record) {
        do {
            guard resultsDirectory.standardizedFileURL.path == resultsDirectory.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try fileManager.createDirectory(at: resultsDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            var directory = stat()
            guard lstat(resultsDirectory.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
                  directory.st_uid == geteuid(), directory.st_mode & 0o777 == 0o700 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let destination = resultsDirectory.appendingPathComponent(record.id.uuidString + ".json")
            var existing = stat()
            if lstat(destination.path, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1,
                      existing.st_uid == geteuid(), existing.st_mode & 0o777 == 0o600,
                      let previous = try? JSONDecoder().decode(Record.self, from: readRegularFile(destination)),
                      previous.schema == record.schema, previous.id == record.id,
                      previous.bundleID == record.bundleID else { throw CocoaError(.fileWriteInvalidFileName) }
            } else if errno != ENOENT {
                throw CocoaError(.fileWriteNoPermission)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: destination, options: .atomic)
            // Do not follow a substituted link while setting receipt permissions.
            let descriptor = open(destination.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            defer { close(descriptor) }
            var written = stat()
            guard fstat(descriptor, &written) == 0, written.st_mode & S_IFMT == S_IFREG,
                  written.st_nlink == 1, written.st_uid == geteuid(), fchmod(descriptor, 0o600) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } catch {
            NSLog("FinderNotes update cleanup audit could not be recorded; result remains unknown: %@", String(describing: error))
        }
    }
}
