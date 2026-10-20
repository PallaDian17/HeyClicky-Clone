import Foundation

/// Runs one agent turn as a headless `claude` process (Claude Code's stream-json
/// mode, the transport the Claude Agent SDK uses). Authenticates with the user's
/// own Claude login; no API key is involved anywhere.
///
/// Each turn is its own process; continuity comes from `--resume <session>`.
/// Permission prompts arrive on stdout as `control_request` events and are
/// answered on stdin by `PermissionPolicy`.
final class ClaudeCodeRunner {
    struct Options {
        var cwd: URL
        var sessionID: String?            // resume this Claude Code session
        var newSessionID: String          // used when sessionID is nil
        var model: String?                // nil = Claude Code's default
        var appendSystemPrompt: String?
        var mcpConfigJSON: String?        // --mcp-config, e.g. the computer-use server
    }

    enum Event {
        case started(sessionID: String, model: String)
        case textDelta(String)
        case assistantText(String)                       // a complete text block
        case toolStarted(id: String, name: String, summary: String)
        case toolFinished(id: String, output: String, isError: Bool)
        case permissionDecided(tool: String, allowed: Bool, reason: String?)
        case finished(text: String, isError: Bool, sessionID: String?, costUSD: Double?, durationMs: Int?)
        case failed(String)
    }

    enum Failure: LocalizedError {
        case binaryMissing
        var errorDescription: String? { "Claude Code is not installed. Install it and run `claude auth login`." }
    }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var buffer = Data()
    private var onEvent: ((Event) -> Void)?
    private let policy: PermissionPolicy
    private var streamingText = ""

    init(policy: PermissionPolicy) {
        self.policy = policy
    }

    static var binary: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    var isRunning: Bool { process.isRunning }

    func start(prompt: String, options: Options, onEvent: @escaping (Event) -> Void) throws {
        guard let binary = Self.binary else { throw Failure.binaryMissing }
        self.onEvent = onEvent

        var args = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", "default",
            // Routes can_use_tool prompts to our stdin/stdout as control_request events.
            "--permission-prompt-tool", "stdio",
            // The agent is a product, not the user's dev setup: ignore personal
            // hooks, plugins and (notably) any apiKeyHelper in ~/.claude/settings.json.
            "--setting-sources", "project",
        ]
        if let id = options.sessionID { args += ["--resume", id] } else { args += ["--session-id", options.newSessionID] }
        if let model = options.model { args += ["--model", model] }
        if let sys = options.appendSystemPrompt { args += ["--append-system-prompt", sys] }
        if let mcp = options.mcpConfigJSON { args += ["--mcp-config", mcp, "--strict-mcp-config"] } else { args += ["--strict-mcp-config"] }

        process.executableURL = binary
        process.arguments = args
        process.currentDirectoryURL = options.cwd
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = [
            "HOME": home,
            "USER": NSUserName(),
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TERM": "dumb",
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        process.terminationHandler = { [weak self] p in
            self?.stdout.fileHandleForReading.readabilityHandler = nil
            if p.terminationStatus != 0 {
                self?.emit(.failed("claude exited with status \(p.terminationStatus)"))
            }
        }
        try process.run()
        send(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": prompt]]]])
        Log.agents.info("claude turn started cwd=\(options.cwd.lastPathComponent, privacy: .public) resume=\(options.sessionID ?? "new", privacy: .public)")
    }

    func interrupt() {
        guard process.isRunning else { return }
        process.interrupt()   // SIGINT; claude ends the turn and emits a result
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.process.isRunning == true { self?.process.terminate() }
        }
    }

    // MARK: - Wire

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        stdin.fileHandleForWriting.write(data)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func emit(_ event: Event) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }

    private func handle(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "system":
            if o["subtype"] as? String == "init" {
                emit(.started(sessionID: o["session_id"] as? String ?? "", model: o["model"] as? String ?? ""))
            }
        case "stream_event":
            guard let ev = o["event"] as? [String: Any] else { return }
            if ev["type"] as? String == "content_block_delta",
               let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                streamingText += text
                emit(.textDelta(text))
            }
        case "assistant":
            guard let message = o["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    streamingText = ""
                    emit(.assistantText(block["text"] as? String ?? ""))
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    emit(.toolStarted(id: block["id"] as? String ?? UUID().uuidString, name: name, summary: Self.summarize(tool: name, input: input)))
                default: break
                }
            }
        case "user":
            guard let message = o["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_result" {
                let output: String
                if let s = block["content"] as? String { output = s }
                else if let parts = block["content"] as? [[String: Any]] { output = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                else { output = "" }
                emit(.toolFinished(id: block["tool_use_id"] as? String ?? "", output: output, isError: block["is_error"] as? Bool ?? false))
            }
        case "control_request":
            guard let request = o["request"] as? [String: Any], let requestID = o["request_id"] as? String else { return }
            answer(requestID: requestID, request: request)
        case "result":
            let isError = o["is_error"] as? Bool ?? false
            var text = o["result"] as? String ?? ""
            if text.isEmpty, let errors = o["errors"] as? [String] { text = errors.joined(separator: "\n") }
            emit(.finished(text: text, isError: isError, sessionID: o["session_id"] as? String,
                           costUSD: o["total_cost_usd"] as? Double, durationMs: o["duration_ms"] as? Int))
            stdin.fileHandleForWriting.closeFile()
        default:
            break
        }
    }

    private func answer(requestID: String, request: [String: Any]) {
        guard request["subtype"] as? String == "can_use_tool" else {
            send(["type": "control_response", "response": ["subtype": "error", "request_id": requestID, "error": "unsupported request"]])
            return
        }
        let tool = request["tool_name"] as? String ?? ""
        let input = request["input"] as? [String: Any] ?? [:]
        let decision = policy.decide(tool: tool, input: input)
        var inner: [String: Any]
        switch decision {
        case .allow:
            inner = ["behavior": "allow", "updatedInput": input]
        case .deny(let reason):
            inner = ["behavior": "deny", "message": reason]
        }
        send(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": inner]])
        if case .deny(let reason) = decision {
            emit(.permissionDecided(tool: tool, allowed: false, reason: reason))
        } else {
            emit(.permissionDecided(tool: tool, allowed: true, reason: nil))
        }
    }

    static func summarize(tool: String, input: [String: Any]) -> String {
        func path(_ key: String) -> String? { (input[key] as? String).map { ($0 as NSString).lastPathComponent } }
        switch tool {
        case "Bash": return (input["description"] as? String) ?? (input["command"] as? String ?? "Running a command")
        case "Read": return "Reading \(path("file_path") ?? "a file")"
        case "Edit", "MultiEdit": return "Editing \(path("file_path") ?? "a file")"
        case "Write": return "Writing \(path("file_path") ?? "a file")"
        case "Glob", "Grep": return "Searching \(input["pattern"] as? String ?? "files")"
        case "WebSearch": return "Searching the web: \(input["query"] as? String ?? "")"
        case "WebFetch": return "Reading \(input["url"] as? String ?? "a page")"
        case "TodoWrite": return "Planning…"
        default:
            if tool.hasPrefix(ComputerUsePolicy.toolPrefix) {
                return summarizeComputerUse(String(tool.dropFirst(ComputerUsePolicy.toolPrefix.count)), input: input)
            }
            return "Using \(tool)"
        }
    }

    private static func summarizeComputerUse(_ name: String, input: [String: Any]) -> String {
        let app = (input["app"] as? String) ?? (input["bundle_id"] as? String).map { ($0.split(separator: ".").last).map(String.init) ?? $0 }
        let inApp = app.map { " in \($0)" } ?? ""
        switch name {
        case "launch_app": return "Opening \(app ?? "an app")"
        case "list_apps", "list_windows": return "Looking at open windows"
        case "get_window_state", "get_app_state", "get_desktop_state": return "Reading the screen\(inApp)"
        case "click", "double_click", "right_click": return "Clicking\(inApp)"
        case "type_text", "set_value": return "Typing\(inApp)"
        case "press_key", "hotkey": return "Pressing keys\(inApp)"
        case "scroll": return "Scrolling\(inApp)"
        case "run_steps": return "Working\(inApp)"
        case "run_script": return "Running a scripted sequence\(inApp)"
        case "verify_state": return "Checking the result\(inApp)"
        case "check_permissions", "health_report": return "Checking computer-use access"
        default: return "Using the computer (\(name))"
        }
    }
}

/// Decides tool permissions without asking the user. Personal-use defaults:
/// everything inside the agent's own folder is allowed; file writes elsewhere
/// and a short list of destructive shell patterns are denied.
struct PermissionPolicy {
    enum Decision { case allow, deny(String) }

    let workspace: URL
    var computerUse = ComputerUsePolicy(consentGranted: false)

    static let deniedShellPatterns: [String] = [
        "rm -rf /", "rm -rf ~", "rm -rf $HOME", "sudo ", "mkfs", "diskutil erase", "> /dev/", ":(){", "shutdown", "reboot",
        "launchctl unload", "killall ", "osascript", "defaults write", "git push --force",
    ]

    func decide(tool: String, input: [String: Any]) -> Decision {
        if ComputerUsePolicy.isComputerUse(tool) { return computerUse.decide(tool: tool, input: input) }
        switch tool {
        case "Bash":
            let cmd = (input["command"] as? String ?? "").lowercased()
            if let hit = Self.deniedShellPatterns.first(where: { cmd.contains($0.lowercased()) }) {
                return .deny("That command is blocked for safety (\(hit.trimmingCharacters(in: .whitespaces))). Use a narrower command or ask the user.")
            }
            // The driver may only be reached through the gated MCP tools, never its CLI.
            if cmd.contains("cua-driver") || cmd.contains("helpers/cua") {
                return .deny(computerUse.consentGranted
                    ? "Use the mcp__cua__* tools for screen actions; running the driver from the shell is blocked."
                    : "Computer use is turned off; the user can enable it in Setup. Running the driver from the shell is blocked.")
            }
            return .allow
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            guard let path = input["file_path"] as? String ?? input["notebook_path"] as? String else { return .allow }
            let target = URL(fileURLWithPath: path).standardizedFileURL.path
            let root = workspace.standardizedFileURL.path
            if target.hasPrefix(root + "/") || target == root { return .allow }
            return .deny("Writes are only allowed inside your own folder (\(workspace.lastPathComponent)). Put files in output/ or tmp/.")
        default:
            return .allow
        }
    }
}
