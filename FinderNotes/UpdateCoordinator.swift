import AppKit
import Sparkle

/// Owns the native, user-initiated update flow for this installed application.
@MainActor
final class UpdateCoordinator: NSObject, NSMenuItemValidation, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private var updaterController: SPUStandardUpdaterController?
    private var installAudit: UpdateInstallAudit?
    private(set) var isUpdateInterfaceActive = false
    var interactionStateDidChange: ((Bool) -> Void)?

    init(bundle: Bundle = .main) {
        super.init()
        // Development builds never connect to the personal-installation feed.
        if bundle.object(forInfoDictionaryKey: "FinderNotesUpdatesEnabled") as? Bool == true {
            installAudit = UpdateInstallAudit(bundle: bundle)
            installAudit?.resumePendingResults()
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        }
    }

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates ?? false
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        installAudit?.beginCheck()
        setUpdateInterfaceActive(true)
        updaterController?.checkForUpdates(sender)
    }

    // Sparkle uses ordinary windows for its update and download UI. Temporarily
    // lower our floating editor without changing the user's pin selection.
    private func setUpdateInterfaceActive(_ active: Bool) {
        guard isUpdateInterfaceActive != active else { return }
        isUpdateInterfaceActive = active
        interactionStateDidChange?(active)
    }

    func restoreEditorWindowLevel() {
        setUpdateInterfaceActive(false)
    }

    func recordApplicationTermination(allowed: Bool) {
        if allowed { installAudit?.recordBeforeTermination() }
        else { installAudit?.recordCancelledTermination() }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installAudit?.prepare(targetVersion: .init(display: item.displayVersionString, build: item.versionString))
    }

    func standardUserDriverWillShowModalAlert() {
        setUpdateInterfaceActive(true)
    }

    func standardUserDriverDidShowModalAlert() {
        restoreEditorWindowLevel()
    }

    func standardUserDriverWillFinishUpdateSession() {
        restoreEditorWindowLevel()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        restoreEditorWindowLevel()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canCheckForUpdates
    }
}
