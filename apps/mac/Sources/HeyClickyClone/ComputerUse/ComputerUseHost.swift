import AppKit
import Combine

/// Owns the embedded cua-driver daemon. Spawned directly by this app so it
/// stays in our TCC responsibility chain and inherits our Accessibility and
/// Screen Recording grants (trycua's embedding contract). Agents reach it
/// through the stdio MCP proxy `cua-driver mcp --embedded --socket <path>`.
@MainActor
final class ComputerUseHost: ObservableObject {
    enum State: Equatable { case off, starting, running, failed(String) }

    @Published private(set) var state: State = .off

    static let hostBundleID = Bundle.main.bundleIdentifier ?? "com.ashish.heyclickyclone"
    static let enabledKey = "ClickyComputerUseEnabled"
    static let mcpServerName = "cua"

    private var process: Process?
    private var generation = 0

    let socketPath: String = {
        // Unix socket paths are limited (~104 bytes); keep it short.
        let dir = NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("heyclickyclone-cua.sock")
    }()

    static var binary: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cua/cua-driver")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var skillDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("cua-skill", isDirectory: true)
    }

    var isAvailable: Bool { Self.binary != nil }
    var isRunning: Bool { state == .running && process?.isRunning == true }

    /// User consent, persisted. Off by default: the agent gets no computer-use tools until this is on.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
            newValue ? start() : stop()
        }
    }

    /// MCP server definition for Claude Code's --mcp-config.
    var mcpConfigJSON: String? {
        guard isRunning, let binary = Self.binary else { return nil }
        // Named "cua": Claude Code silently discards a server called "computer-use".
        let config: [String: Any] = [
            "mcpServers": [
                Self.mcpServerName: [
                    "type": "stdio",
                    "command": binary.path,
                    "args": ["mcp", "--embedded", "--socket", socketPath, "--host-bundle-id", Self.hostBundleID],
                    "env": ["CUA_DRIVER_EMBEDDED": "1", "CUA_DRIVER_HOST_BUNDLE_ID": Self.hostBundleID],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func startIfEnabled() {
        if isEnabled { start() }
    }

    func start() {
        guard !isRunning, let binary = Self.binary else {
            if Self.binary == nil { state = .failed("cua-driver is not bundled; run vendor/fetch-cua-driver.sh and rebuild.") }
            return
        }
        generation += 1
        let gen = generation
        state = .starting
        try? FileManager.default.removeItem(atPath: socketPath)

        let p = Process()
        p.executableURL = binary
        p.arguments = [
            "serve", "--embedded",
            "--socket", socketPath,
            "--host-bundle-id", Self.hostBundleID,
            "--permission-mode", "standard",
        ]
        var env = ProcessInfo.processInfo.environment
        env["CUA_DRIVER_EMBEDDED"] = "1"
        env["CUA_DRIVER_HOST_BUNDLE_ID"] = Self.hostBundleID
        env["CUA_DRIVER_PERMISSION_MODE"] = "standard"
        env["CUA_DRIVER_RS_TELEMETRY_ENABLED"] = "0"
        p.environment = env
        p.standardInput = Pipe()          // the daemon watches stdin for parent liveness
        let stderr = Pipe()
        p.standardError = stderr
        p.standardOutput = FileHandle.nullDevice
        stderr.fileHandleForReading.readabilityHandler = { h in
            let text = String(decoding: h.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { Log.computerUse.debug("\(text.prefix(300), privacy: .public)") }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.process = nil
                self.state = proc.terminationStatus == 0 ? .off : .failed("cua-driver exited with status \(proc.terminationStatus)")
                Log.computerUse.notice("daemon exited status=\(proc.terminationStatus)")
            }
        }
        do {
            try p.run()
        } catch {
            state = .failed("Could not start cua-driver: \(error.localizedDescription)")
            return
        }
        process = p
        Log.computerUse.info("daemon starting pid=\(p.processIdentifier) socket=\(self.socketPath, privacy: .public)")

        Task { @MainActor in
            for _ in 0..<60 {   // up to ~6s for the socket to accept
                try? await Task.sleep(for: .milliseconds(100))
                guard self.generation == gen, p.isRunning else { return }
                if Self.socketAccepts(path: self.socketPath) {
                    self.state = .running
                    Log.computerUse.info("daemon ready")
                    return
                }
            }
            if self.generation == gen, p.isRunning {
                self.state = .failed("cua-driver did not open its socket in time")
                p.terminate()
            }
        }
    }

    func stop() {
        generation += 1
        process?.terminate()
        process = nil
        state = .off
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private static func socketAccepts(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { dest in
                _ = path.withCString { strcpy(dest, $0) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
    }
}
