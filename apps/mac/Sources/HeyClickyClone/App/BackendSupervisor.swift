import AppKit
import Foundation

/// Owns the local backend so talk never depends on a terminal being open.
/// At launch it probes `/healthz`; if nothing answers it starts
/// `apps/backend` from the repo next to the bundle (tsx, no watch), keeps the
/// log in Application Support, restarts it with backoff when it exits, and
/// reports its state to Setup and the notch. If something else already serves
/// the port (a dev terminal), it just watches that.
@MainActor
final class BackendSupervisor: ObservableObject {
    enum State: Equatable {
        case unknown, external, starting, running(pid: Int32), stopped(String)
        var label: String {
            switch self {
            case .unknown: return "Checking…"
            case .external: return "Running (started outside the app)"
            case .starting: return "Starting…"
            case .running(let pid): return "Running (pid \(pid), managed by the app)"
            case .stopped(let why): return "Stopped: \(why)"
            }
        }
        var isUp: Bool { if case .running = self { return true }; return self == .external }
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var lastHealthy: Date?
    @Published private(set) var restarts = 0

    let baseURL: URL
    private var process: Process?
    private var healthTimer: Timer?
    private var restartTimes: [Date] = []
    private var stopping = false
    var logURL: URL { AppConfig.appSupportDirectory.appendingPathComponent("backend.log") }

    /// Where the backend's source lives (dev builds): the repo next to the bundle.
    static var backendDirectory: URL? {
        guard let repo = AppConfig.repoURL else { return nil }
        let dir = repo.appendingPathComponent("apps/backend", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("src/index.ts").path) ? dir : nil
    }

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    var canManage: Bool { Self.isLocal(baseURL) && Self.backendDirectory != nil }

    func start() {
        Task { await ensureRunning(reason: "launch") }
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.ensureRunning(reason: "health check") }
        }
    }

    func stop() {
        stopping = true
        healthTimer?.invalidate()
        healthTimer = nil
        if let process, process.isRunning {
            process.terminate()
            Log.app.info("backend: stopped managed process pid=\(process.processIdentifier)")
        }
        process = nil
    }

    func restart() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        restartTimes = []
        Task { await ensureRunning(reason: "manual restart") }
    }

    /// Probes the port; starts the backend when nothing answers and we can.
    func ensureRunning(reason: String) async {
        if await isHealthy() {
            lastHealthy = Date()
            if let process, process.isRunning { state = .running(pid: process.processIdentifier) } else { state = .external }
            return
        }
        guard canManage else {
            state = .stopped(Self.isLocal(baseURL) ? "no backend source next to the app" : "remote backend \(baseURL.host ?? "") is not answering")
            return
        }
        if let process, process.isRunning {
            // Started but not answering yet (tsx needs a few seconds).
            state = .starting
            return
        }
        // Backoff: at most 5 starts in 2 minutes.
        restartTimes = restartTimes.filter { Date().timeIntervalSince($0) < 120 }
        guard restartTimes.count < 5 else {
            state = .stopped("kept exiting; see backend.log")
            return
        }
        restartTimes.append(Date())
        launch(reason: reason)
    }

    private func launch(reason: String) {
        guard let dir = Self.backendDirectory else { return }
        let tsx = dir.appendingPathComponent("node_modules/.bin/tsx")
        guard FileManager.default.isExecutableFile(atPath: tsx.path) else {
            state = .stopped("apps/backend/node_modules missing; run pnpm install")
            return
        }
        let p = Process()
        p.executableURL = tsx
        p.arguments = ["src/index.ts"]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + (env["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        env["PORT"] = String(baseURL.port ?? 8787)
        p.environment = env
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data("\n== \(Date().formatted()) start (\(reason))\n".utf8))
            p.standardOutput = handle
            p.standardError = handle
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, !self.stopping else { return }
                self.restarts += 1
                self.state = .stopped("exited with status \(proc.terminationStatus)")
                Log.app.error("backend: exited status=\(proc.terminationStatus); restarting")
                try? await Task.sleep(for: .seconds(2))
                await self.ensureRunning(reason: "crash restart")
            }
        }
        do {
            try p.run()
            process = p
            state = .starting
            Log.app.info("backend: started pid=\(p.processIdentifier) (\(reason, privacy: .public)) log=\(self.logURL.path, privacy: .public)")
            Task { [weak self] in
                // Give tsx a few seconds, then confirm.
                for _ in 0..<15 {
                    try? await Task.sleep(for: .seconds(1))
                    if await self?.isHealthy() == true { break }
                }
                guard let self else { return }
                if await self.isHealthy() { self.lastHealthy = Date(); self.state = .running(pid: p.processIdentifier) }
            }
        } catch {
            state = .stopped("couldn't start: \(error.localizedDescription)")
            Log.app.error("backend: start failed \(String(describing: error), privacy: .public)")
        }
    }

    func isHealthy() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        req.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func isLocal(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }

    /// Kills computer-use daemons left behind by earlier app instances.
    static func reapOrphanDaemons() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "cua-driver serve --embedded"]
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0 { Log.computerUse.info("reaped orphan cua-driver daemon(s)") }
    }
}
