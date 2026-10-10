import Foundation
import Darwin

/// Exercise the production default-directory construction while keeping all I/O in .build.
final class AuditFixtureFileManager: FileManager, @unchecked Sendable {
    let fixtureRoot: URL
    init(root: URL) { fixtureRoot = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        if directory == .cachesDirectory { return [fixtureRoot.appendingPathComponent("Caches", isDirectory: true)] }
        if directory == .applicationSupportDirectory { return [fixtureRoot.appendingPathComponent("ApplicationSupport", isDirectory: true)] }
        return super.urls(for: directory, in: domainMask)
    }
}

@MainActor
enum FN12AuditChecks {
    static func run(root: URL, check: (Bool, String) -> Void) async throws {
        typealias Audit = UpdateInstallAudit
        let fm = FileManager.default
        let base = root.appendingPathComponent("audit-components-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let id = "com.findernotes.FinderNotes.FN12AuditChecks"
        let oldVersion = Audit.Version(display: "0.1.1", build: "12")
        let targetVersion = Audit.Version(display: "0.1.2", build: "13")

        func makeBundle(_ path: URL, version: Audit.Version = oldVersion, identity: String? = nil) throws -> Bundle {
            let contents = path.appendingPathComponent("Contents", isDirectory: true)
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": identity ?? id, "CFBundlePackageType": "APPL",
                                      "CFBundleName": "FN12 Audit Fixture", "CFBundleExecutable": "fixture-only-no-executable",
                                      "CFBundleShortVersionString": version.display, "CFBundleVersion": version.build]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return Bundle(url: path)!
        }
        func fixture(_ name: String) throws -> (Audit, URL) {
            let directory = base.appendingPathComponent(name, isDirectory: true)
            let cache = directory.appendingPathComponent("Installation", isDirectory: true)
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            let bundle = try makeBundle(directory.appendingPathComponent("Installed.app", isDirectory: true))
            return (Audit(bundle: bundle, resultsDirectory: directory.appendingPathComponent("Results"),
                          cacheInstallationDirectory: cache), directory)
        }
        func candidate(_ audit: Audit, name: String = "new-download", version: Audit.Version = targetVersion) throws -> URL {
            let app = audit.cacheInstallationDirectory.appendingPathComponent(name + "/extraction/Fixture.app", isDirectory: true)
            _ = try makeBundle(app, version: version)
            return app
        }
        let testIdentity = Audit.FileIdentity(device: 1, inode: 2)
        let binding = Audit.CacheBinding(directoryPath: "/bound", directoryIdentity: testIdentity, bundlePath: "/bound/extraction/Old.app")
        let evaluations: [(Audit.CacheBinding?, Bool, [Audit.Observation], Audit.Status, String)] = [
            (nil, true, [.oldBundlePresent, .missing], .unknown, "missing binding cannot prove cleanup"),
            (binding, false, [.oldBundlePresent, .missing], .unknown, "wrong target cannot prove cleanup"),
            (binding, true, [.oldBundlePresent], .incomplete, "observed old bundle remaining is incomplete"),
            (binding, true, [.oldBundlePresent, .missing], .completed, "observed old bundle then missing is completed"),
            (binding, true, [.missing], .unknown, "missing without old inode observation is unknown"),
            (binding, true, [], .unknown, "empty observations are unknown"),
            (binding, true, [.oldBundlePresent, .differentObject, .missing], .unknown, "substituted object invalidates cleanup proof"),
            (binding, true, [.oldBundlePresent, .unreadable, .missing], .unknown, "unreadable interval invalidates cleanup proof"),
        ]
        for (bound, matches, observations, expected, title) in evaluations {
            check(Audit.evaluate(binding: bound, targetMatches: matches, observations: observations).status == expected, title)
        }

        let (unique, _) = try fixture("unique")
        unique.beginCheck()
        let uniqueApp = try candidate(unique)
        unique.prepare(targetVersion: targetVersion)
        check(unique.prepared?.binding?.bundlePath == uniqueApp.path, "one newly extracted target app binds exactly")
        check(unique.prepared?.binding?.extractionIdentity != nil, "binding records exact extraction inode")
        check(unique.prepared?.oldIdentity != nil, "receipt records original installed app inode")
        unique.recordBeforeTermination()
        let uniqueReceipt = unique.resultsDirectory.appendingPathComponent(unique.prepared!.id.uuidString + ".json")
        let before = try JSONDecoder().decode(Audit.Record.self, from: Data(contentsOf: uniqueReceipt))
        check(before.awaitingRestart && before.evaluation.reason == "awaiting-restart-and-cleanup-check",
              "pre-termination JSON records pending restart")
        let attrs = try fm.attributesOfItem(atPath: uniqueReceipt.path)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "receipt is private mode 600")
        unique.recordCancelledTermination()
        let cancelled = try JSONDecoder().decode(Audit.Record.self, from: Data(contentsOf: uniqueReceipt))
        check(!cancelled.awaitingRestart && cancelled.evaluation.reason == "termination-cancelled",
              "cancelled termination persists without claiming completion")

        let (ambiguous, _) = try fixture("ambiguous")
        ambiguous.beginCheck()
        _ = try candidate(ambiguous, name: "one")
        _ = try candidate(ambiguous, name: "two")
        ambiguous.prepare(targetVersion: targetVersion)
        check(ambiguous.prepared?.binding == nil, "two matching new caches remain unbound")
        let (stale, _) = try fixture("stale")
        _ = try candidate(stale)
        stale.beginCheck()
        stale.prepare(targetVersion: targetVersion)
        check(stale.prepared?.binding == nil, "pre-check cache is excluded from binding")
        let (foreign, _) = try fixture("foreign")
        foreign.beginCheck()
        _ = try candidate(foreign, version: .init(display: "9.0", build: "999"))
        foreign.prepare(targetVersion: targetVersion)
        check(foreign.prepared?.binding == nil, "other version cannot bind")

        let (linked, linkedRoot) = try fixture("symlink")
        linked.beginCheck()
        let outside = linkedRoot.appendingPathComponent("Outside.app", isDirectory: true)
        _ = try makeBundle(outside, version: targetVersion)
        let linkedApp = linked.cacheInstallationDirectory.appendingPathComponent("new/extraction/Fixture.app")
        try fm.createDirectory(at: linkedApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedApp, withDestinationURL: outside)
        linked.prepare(targetVersion: targetVersion)
        check(linked.prepared?.binding == nil, "symlink app outside exact cache cannot bind")
        let (infoLinked, infoRoot) = try fixture("info-symlink")
        infoLinked.beginCheck()
        let infoApp = try candidate(infoLinked)
        let infoPath = infoApp.appendingPathComponent("Contents/Info.plist")
        let escapedInfo = infoRoot.appendingPathComponent("outside-info.plist")
        try fm.moveItem(at: infoPath, to: escapedInfo)
        try fm.createSymbolicLink(at: infoPath, withDestinationURL: escapedInfo)
        infoLinked.prepare(targetVersion: targetVersion)
        check(infoLinked.prepared?.binding == nil, "Info.plist symlink escape cannot bind")

        let (replaced, replacedRoot) = try fixture("replaced-extraction")
        replaced.beginCheck()
        let replacementApp = try candidate(replaced)
        replaced.prepare(targetVersion: targetVersion)
        let exactRecord = replaced.prepared!
        let extraction = replacementApp.deletingLastPathComponent()
        try fm.moveItem(at: extraction, to: replacedRoot.appendingPathComponent("OriginalExtraction"))
        _ = try candidate(replaced)
        check(replaced.observe(exactRecord) == .differentObject, "changed extraction inode invalidates observation")
        let outsideBinding = Audit.CacheBinding(directoryPath: base.path, directoryIdentity: testIdentity,
                                               bundlePath: base.appendingPathComponent("elsewhere/Fixture.app").path)
        var escapedRecord = exactRecord
        escapedRecord = Audit.Record(schema: escapedRecord.schema, id: escapedRecord.id, bundleID: escapedRecord.bundleID,
            createdAt: escapedRecord.createdAt, installationPath: escapedRecord.installationPath, oldVersion: escapedRecord.oldVersion,
            targetVersion: escapedRecord.targetVersion, oldIdentity: escapedRecord.oldIdentity,
            cacheInstallationPath: escapedRecord.cacheInstallationPath, binding: outsideBinding,
            awaitingRestart: true, evaluation: escapedRecord.evaluation, observations: [], checkedAt: nil)
        check(replaced.observe(escapedRecord) == .unreadable, "receipt cannot inspect outside its exact installation cache")

        let (unsafe, unsafeRoot) = try fixture("unsafe-files")
        let fifo = unsafeRoot.appendingPathComponent("fifo.json")
        check(mkfifo(fifo.path, 0o600) == 0, "FIFO validation fixture created")
        let fifoBegan = Date()
        do { _ = try unsafe.readRegularFile(fifo); check(false, "FIFO receipt rejected") }
        catch { check(Date().timeIntervalSince(fifoBegan) < 1, "FIFO receipt rejected without blocking") }
        let huge = unsafeRoot.appendingPathComponent("large.json")
        try Data(repeating: 65, count: 65_537).write(to: huge)
        do { _ = try unsafe.readRegularFile(huge); check(false, "oversized receipt rejected") }
        catch { check(true, "oversized receipt rejected") }
        let regular = unsafeRoot.appendingPathComponent("ordinary.json")
        try Data("ordinary".utf8).write(to: regular)
        try fm.linkItem(at: regular, to: unsafeRoot.appendingPathComponent("hardlink.json"))
        do { _ = try unsafe.readRegularFile(regular); check(false, "hardlinked receipt rejected") }
        catch { check(true, "hardlinked receipt rejected") }
        let symlink = unsafeRoot.appendingPathComponent("link.json")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: huge)
        do { _ = try unsafe.readRegularFile(symlink); check(false, "symlink receipt rejected") }
        catch { check(true, "symlink receipt rejected") }
        unsafe.beginCheck()
        unsafe.prepare(targetVersion: targetVersion)
        unsafe.recordBeforeTermination()
        let unsafeReceipt = unsafe.resultsDirectory.appendingPathComponent(unsafe.prepared!.id.uuidString + ".json")
        var stranger = unsafe.prepared!
        stranger = Audit.Record(schema: 1, id: stranger.id, bundleID: "another.bundle", createdAt: stranger.createdAt,
            installationPath: stranger.installationPath, oldVersion: stranger.oldVersion, targetVersion: stranger.targetVersion,
            oldIdentity: stranger.oldIdentity, cacheInstallationPath: stranger.cacheInstallationPath,
            binding: nil, awaitingRestart: true, evaluation: stranger.evaluation, observations: [], checkedAt: nil)
        let strangerBytes = try JSONEncoder().encode(stranger)
        try strangerBytes.write(to: unsafeReceipt)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unsafeReceipt.path)
        unsafe.recordCancelledTermination()
        check(try Data(contentsOf: unsafeReceipt) == strangerBytes, "foreign existing receipt is not overwritten")
        try fm.removeItem(at: unsafeReceipt)
        let sentinel = unsafeRoot.appendingPathComponent("sentinel.json")
        let sentinelBytes = Data("do not follow receipt links".utf8)
        try sentinelBytes.write(to: sentinel)
        try fm.createSymbolicLink(at: unsafeReceipt, withDestinationURL: sentinel)
        unsafe.recordBeforeTermination()
        check(try Data(contentsOf: sentinel) == sentinelBytes, "unsafe existing receipt symlink is not followed or overwritten")

        let (unknown, _) = try fixture("resume-unknown")
        unknown.beginCheck()
        unknown.prepare(targetVersion: oldVersion)
        unknown.recordBeforeTermination()
        let unknownReceipt = unknown.resultsDirectory.appendingPathComponent(unknown.prepared!.id.uuidString + ".json")
        unknown.resumePendingResults()
        try? await Task.sleep(for: .milliseconds(120))
        let unknownResult = try JSONDecoder().decode(Audit.Record.self, from: Data(contentsOf: unknownReceipt))
        check(!unknownResult.awaitingRestart && unknownResult.evaluation.status == .unknown,
              "restart without reliable binding persists unknown")
        let (resumed, _) = try fixture("resume-completed")
        resumed.beginCheck()
        let cachedOld = try candidate(resumed, version: oldVersion)
        resumed.prepare(targetVersion: oldVersion)
        var resumedRecord = resumed.prepared!
        resumedRecord = Audit.Record(schema: 1, id: resumedRecord.id, bundleID: resumedRecord.bundleID,
            createdAt: resumedRecord.createdAt, installationPath: resumedRecord.installationPath,
            oldVersion: .init(display: "0.1.0", build: "11"), targetVersion: oldVersion,
            oldIdentity: resumed.identity(cachedOld), cacheInstallationPath: resumedRecord.cacheInstallationPath,
            binding: resumedRecord.binding, awaitingRestart: true,
            evaluation: .init(status: .unknown, reason: "test-pending"), observations: [], checkedAt: nil)
        resumed.persist(resumedRecord)
        let resumedReceipt = resumed.resultsDirectory.appendingPathComponent(resumedRecord.id.uuidString + ".json")
        resumed.resumePendingResults()
        try? await Task.sleep(for: .milliseconds(80))
        try fm.removeItem(at: cachedOld)
        try? await Task.sleep(for: .milliseconds(300))
        let completed = try JSONDecoder().decode(Audit.Record.self, from: Data(contentsOf: resumedReceipt))
        check(!completed.awaitingRestart && completed.evaluation.status == .completed && completed.observations == [.oldBundlePresent, .missing],
              "real scoped restart observation persists old inode then removed")

        let defaultsRoot = base.appendingPathComponent("default-directory-construction", isDirectory: true)
        let defaultsManager = AuditFixtureFileManager(root: defaultsRoot)
        let defaultsBundle = try makeBundle(defaultsRoot.appendingPathComponent("Installed.app", isDirectory: true))
        // Pass neither resultsDirectory nor cacheInstallationDirectory: the real initializer
        // builds the bundle-ID paths exactly as on an installed app, including URL directory bits.
        let defaultsAudit = Audit(bundle: defaultsBundle, fileManager: defaultsManager)
        let expectedCache = defaultsRoot.appendingPathComponent("Caches").appendingPathComponent(id)
            .appendingPathComponent("org.sparkle-project.Sparkle").appendingPathComponent("Installation")
        let expectedResults = defaultsRoot.appendingPathComponent("ApplicationSupport").appendingPathComponent(id)
            .appendingPathComponent("UpdateResults")
        check(defaultsAudit.cacheInstallationDirectory.path == expectedCache.path,
              "default initializer constructs its bundle-ID Sparkle cache path")
        check(defaultsAudit.resultsDirectory.path == expectedResults.path,
              "default initializer constructs its bundle-ID results path")
        defaultsAudit.beginCheck()
        check(defaultsAudit.baseline == [], "missing default installation cache starts with empty baseline")
        let defaultsOld = try candidate(defaultsAudit, version: oldVersion)
        defaultsAudit.prepare(targetVersion: oldVersion)
        let defaultPrepared = defaultsAudit.prepared!
        check(defaultPrepared.binding?.bundlePath == defaultsOld.path,
              "default-constructed cache path binds exactly one new extraction")
        let defaultRecord = Audit.Record(schema: 1, id: defaultPrepared.id, bundleID: defaultPrepared.bundleID,
            createdAt: defaultPrepared.createdAt, installationPath: defaultPrepared.installationPath,
            oldVersion: .init(display: "0.1.0", build: "11"), targetVersion: oldVersion,
            oldIdentity: defaultsAudit.identity(defaultsOld), cacheInstallationPath: defaultPrepared.cacheInstallationPath,
            binding: defaultPrepared.binding, awaitingRestart: true, evaluation: defaultPrepared.evaluation,
            observations: [], checkedAt: nil)
        let oldObservation = defaultsAudit.observe(defaultRecord)
        check(oldObservation == .oldBundlePresent, "default-directory URL bits permit observing exact old inode")
        let bindingPath = defaultRecord.binding!.directoryPath
        try fm.removeItem(at: URL(fileURLWithPath: bindingPath, isDirectory: true))
        let withoutDirectoryBit = URL(fileURLWithPath: bindingPath, isDirectory: false)
        let withDirectoryBit = URL(fileURLWithPath: bindingPath, isDirectory: true)
        check(!withoutDirectoryBit.hasDirectoryPath && withDirectoryBit.hasDirectoryPath &&
              withoutDirectoryBit.standardizedFileURL.path == withDirectoryBit.standardizedFileURL.path,
              "removed binding fixture retains differing URL directory bits with identical paths")
        let removedObservation = defaultsAudit.observe(defaultRecord)
        check(removedObservation == .missing, "removing entire exact binding directory observes missing")
        check(Audit.evaluate(binding: defaultRecord.binding, targetMatches: true,
                             observations: [oldObservation, removedObservation]).status == .completed,
              "observed old inode followed by whole bound-directory removal completes")
        check(Audit.evaluate(binding: defaultRecord.binding, targetMatches: true,
                             observations: [removedObservation]).status == .unknown,
              "whole directory already missing without old-inode observation remains unknown")
        print("Audit fixtures retained at \(base.path)")
    }
}
