import AppKit
import Sparkle

/// Sparkle 2 wrapper. The feed URL and EdDSA public key come from Info.plist
/// (SUFeedURL / SUPublicEDKey, filled in by scripts/build-app.sh). Checks run
/// automatically once a day; "Check for Updates…" is in the menu and Setup.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var lastResult: String = "Not checked yet"
    @Published private(set) var isChecking = false

    private var controller: SPUStandardUpdaterController!

    var feedURL: String { Bundle.main.infoDictionary?["SUFeedURL"] as? String ?? "" }
    var isConfigured: Bool { !feedURL.isEmpty && !(Bundle.main.infoDictionary?["SUPublicEDKey"] as? String ?? "").isEmpty }
    var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        if isConfigured {
            controller.startUpdater()
            Log.app.info("updates: feed \(self.feedURL, privacy: .public) auto=\(self.updater.automaticallyChecksForUpdates)")
        } else {
            lastResult = "Updates are not configured in this build"
            Log.app.notice("updates: no SUFeedURL/SUPublicEDKey; Sparkle idle")
        }
    }

    /// Interactive check (shows Sparkle's own window).
    func checkForUpdates() {
        guard isConfigured else { return }
        isChecking = true
        controller.checkForUpdates(nil)
    }

    /// Background check that only reports in the log and Setup (used by the debug route).
    func checkInBackground() {
        guard isConfigured else { return }
        isChecking = true
        updater.checkForUpdateInformation()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let text = "Update available: \(item.displayVersionString) (build \(item.versionString))"
        Task { @MainActor in self.lastResult = text; self.isChecking = false }
        Log.app.info("updates: \(text, privacy: .public)")
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let text = "Up to date (\(AppConfig.version))"
        Task { @MainActor in self.lastResult = text; self.isChecking = false }
        Log.app.info("updates: no update; \(error.localizedDescription, privacy: .public)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let text = "Check failed: \(error.localizedDescription)"
        Task { @MainActor in self.lastResult = text; self.isChecking = false }
        Log.app.error("updates: \(error.localizedDescription, privacy: .public)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Log.app.info("updates: appcast loaded, \(appcast.items.count) item(s)")
    }
}
