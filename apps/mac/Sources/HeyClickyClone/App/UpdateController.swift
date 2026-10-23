import AppKit
import Sparkle

/// Sparkle 2 wrapper. The feed URL and EdDSA public key come from Info.plist
/// (SUFeedURL / SUPublicEDKey, filled in by scripts/build-app.sh). Checks run
/// automatically once a day; "Check for Updates…" is in the menu and Setup.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var lastResult: String = "Not checked yet"
    @Published private(set) var isChecking = false
    /// Dev builds: what `git` says about the repo this bundle came from.
    @Published private(set) var repoStatus: String = ""
    @Published private(set) var repoIsAhead = false
    @Published private(set) var isUpdating = false

    var stamp: String {
        let when = AppConfig.buildDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown time"
        return "v\(AppConfig.version) build \(AppConfig.build) · \(AppConfig.gitCommit) · \(AppConfig.buildConfiguration) · built \(when)"
    }

    /// Compares the bundle's commit with the repo's HEAD (after a fetch) without touching the tree.
    func checkRepo() {
        guard let repo = AppConfig.repoURL else { repoStatus = ""; return }
        let built = AppConfig.gitCommit.replacingOccurrences(of: "+local", with: "")
        Task.detached { [weak self] in
            func git(_ args: [String]) -> String {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", repo.path] + args
                let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
                return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            _ = git(["fetch", "-q", "origin", "main"])
            let head = git(["rev-parse", "--short=9", "HEAD"])
            let remote = git(["rev-parse", "--short=9", "origin/main"])
            let behindRemote = Int(git(["rev-list", "--count", "HEAD..origin/main"])) ?? 0
            let builtBehindHead = Int(git(["rev-list", "--count", "\(built)..HEAD"])) ?? -1
            let dirty = !git(["status", "--porcelain"]).isEmpty
            var parts: [String] = []
            var ahead = false
            if builtBehindHead == 0 && !AppConfig.gitCommit.hasSuffix("+local") { parts.append("This build is the repo's latest commit (\(head))") }
            else if builtBehindHead > 0 { parts.append("Repo is \(builtBehindHead) commit\(builtBehindHead == 1 ? "" : "s") ahead of this build (HEAD \(head))"); ahead = true }
            else if AppConfig.gitCommit.hasSuffix("+local") { parts.append("Built from uncommitted changes on \(built)") }
            else { parts.append("Built from \(built), repo HEAD \(head)") }
            if behindRemote > 0 { parts.append("origin/main is \(behindRemote) commit\(behindRemote == 1 ? "" : "s") ahead (\(remote)); update to pull it"); ahead = true }
            if dirty { parts.append("working tree has uncommitted changes") }
            let text = parts.joined(separator: " · ")
            await MainActor.run { self?.repoStatus = text; self?.repoIsAhead = ahead }
            Log.app.info("repo check: \(text, privacy: .public)")
        }
    }

    /// Runs scripts/update.sh (pull, build, quit this app, relaunch the new one).
    func updateFromRepo() {
        guard let repo = AppConfig.repoURL, !isUpdating else { return }
        isUpdating = true
        repoStatus = "Updating: pulling, building, relaunching…"
        let script = repo.appendingPathComponent("scripts/update.sh").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script, "--relaunch-pid", String(ProcessInfo.processInfo.processIdentifier)]
        p.currentDirectoryURL = repo
        let log = AppConfig.appSupportDirectory.appendingPathComponent("update.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) { p.standardOutput = handle; p.standardError = handle }
        do {
            try p.run()
            Log.app.info("update.sh started pid=\(p.processIdentifier) log=\(log.path, privacy: .public)")
        } catch {
            isUpdating = false
            repoStatus = "Couldn't start the update script: \(error.localizedDescription)"
        }
    }

    private var controller: SPUStandardUpdaterController!

    var feedURL: String { Bundle.main.infoDictionary?["SUFeedURL"] as? String ?? "" }
    var isConfigured: Bool { !feedURL.isEmpty && !(Bundle.main.infoDictionary?["SUPublicEDKey"] as? String ?? "").isEmpty }
    var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        checkRepo()
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
