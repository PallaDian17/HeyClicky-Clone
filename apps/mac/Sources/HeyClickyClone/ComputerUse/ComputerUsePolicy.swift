import Foundation
import ClickyPrivacy
import CoreGraphics

/// Gate for the `mcp__cua__*` tools an agent may call.
/// Personal-use defaults: everything is allowed once the user has turned
/// computer use on, except a short denylist of irreversible or escalating
/// actions, and anything the privacy guard withholds (password fields,
/// protected apps, payment/sign-in pages, the clipboard).
struct ComputerUsePolicy {
    static var toolPrefix: String { "mcp__\(ComputerUseHost.mcpServerName)__" }

    var consentGranted: Bool
    /// Live privacy verdict for a target (pid, bundle id, window id). Injected so the policy stays testable.
    var assessTarget: (pid_t?, String?, CGWindowID?) -> PrivacyGuard.Verdict = { _, _, _ in .allow }
    var secureInputActive: () -> Bool = { false }

    /// Bundle ids an agent may not launch: privilege or settings escalation.
    static let deniedBundleIDs: Set<String> = [
        "com.apple.systempreferences", "com.apple.Terminal", "com.apple.keychainaccess",
        "com.apple.DiskUtility", "com.apple.Passwords",
    ]

    /// Key combos that destroy or send without a further confirmation.
    static let deniedHotkeys: [String] = [
        "cmd+shift+delete", "cmd+shift+backspace", "cmd+delete", "cmd+backspace",
        "cmd+shift+d", "cmd+return", "cmd+enter", "cmd+q",
    ]

    /// Substrings that mark an irreversible control; matched against the
    /// labels an agent types into or queries for (not against free text).
    static let deniedLabels: [String] = ["empty trash", "delete", "send", "pay", "purchase", "buy now", "erase", "format"]

    /// Tools that read the clipboard or record; never available to agents.
    static let alwaysDenied: Set<String> = ["clipboard_read", "start_recording", "replay_trajectory"]

    /// Tools that neither observe nor act on a window, so the privacy guard does not apply.
    static let targetless: Set<String> = [
        "list_apps", "list_windows", "check_permissions", "health_report", "get_config", "set_config",
        "get_screen_size", "get_cursor_position", "get_agent_cursor_state", "set_agent_cursor_enabled",
        "set_agent_cursor_motion", "set_agent_cursor_theme", "start_session", "end_session", "install_ffmpeg",
    ]

    static func isComputerUse(_ tool: String) -> Bool { tool.hasPrefix(toolPrefix) }

    func decide(tool: String, input: [String: Any]) -> PermissionPolicy.Decision {
        guard Self.isComputerUse(tool) else { return .allow }
        guard consentGranted else {
            return .deny("Computer use is turned off. The user can enable it in HeyClicky Clone → Setup → Computer use.")
        }
        let name = String(tool.dropFirst(Self.toolPrefix.count))
        if Self.alwaysDenied.contains(name) {
            return .deny("\(name) is not available to agents for privacy reasons.")
        }

        // Privacy guard: the target window/app, and the global secure-input state.
        if !Self.targetless.contains(name) {
            if secureInputActive() {
                return .deny("A password field is active somewhere, so screen reading and input are paused. Ask the user to finish, then retry.")
            }
            let (pid, bundle, window) = Self.target(in: input)
            if pid != nil || bundle != nil || window != nil {
                if case .withhold(let reason) = assessTarget(pid, bundle, window) {
                    return .deny("That window is protected (\(reason.label)). It cannot be read or operated by an agent.")
                }
            } else if name == "get_desktop_state" || name == "zoom" || name.hasPrefix("browser_") {
                // Desktop-wide captures and browser tools: judge by the frontmost app.
                if case .withhold(let reason) = assessTarget(nil, nil, nil) {
                    return .deny("The screen is protected right now (\(reason.label)).")
                }
            }
        }

        switch name {
        case "launch_app":
            if let id = (input["bundle_id"] as? String)?.lowercased() {
                if Self.deniedBundleIDs.contains(where: { $0.lowercased() == id }) {
                    return .deny("Launching \(id) is blocked. Ask the user to do that themselves.")
                }
                if case .withhold(let reason) = assessTarget(nil, id, nil) {
                    return .deny("Launching \(id) is blocked (\(reason.label)).")
                }
            }
        case "hotkey", "press_key":
            let combo = Self.comboString(input).lowercased()
            if Self.deniedHotkeys.contains(where: { combo.contains($0) }) {
                return .deny("The shortcut \(combo) is blocked because it deletes, sends or quits without confirmation. Ask the user.")
            }
        case "run_steps", "run_script":
            let blob = Self.flatten(input).lowercased()
            if Self.deniedHotkeys.contains(where: { blob.contains("\"\($0)\"") }) {
                return .deny("One of the batched steps uses a blocked shortcut. Run the steps individually and ask the user before deleting or sending.")
            }
            if blob.contains("clipboard_read") {
                return .deny("Batched steps may not read the clipboard.")
            }
        default:
            break
        }
        for key in ["label", "query", "name", "title"] {
            if let v = (input[key] as? String)?.lowercased(), Self.deniedLabels.contains(where: { v == $0 || v.hasPrefix($0 + " ") }) {
                return .deny("The control \"\(v)\" is on the never-press list. Ask the user to confirm that step themselves.")
            }
        }
        return .allow
    }

    /// Finds the first pid / bundle id / window id in the input, including nested `target` and `steps`.
    static func target(in input: [String: Any]) -> (pid_t?, String?, CGWindowID?) {
        var pid: pid_t?
        var bundle: String?
        var window: CGWindowID?
        func scan(_ obj: Any, depth: Int) {
            guard depth < 6 else { return }
            if let dict = obj as? [String: Any] {
                if pid == nil, let p = dict["pid"] { pid = (p as? NSNumber)?.int32Value ?? Int32((p as? String) ?? "") }
                if bundle == nil, let b = dict["bundle_id"] as? String { bundle = b }
                if window == nil, let w = dict["window_id"] { window = (w as? NSNumber).map { CGWindowID($0.uint32Value) } ?? UInt32((w as? String) ?? "") }
                for v in dict.values { scan(v, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for v in arr { scan(v, depth: depth + 1) }
            }
        }
        scan(input, depth: 0)
        return (pid, bundle, window)
    }

    private static func comboString(_ input: [String: Any]) -> String {
        if let s = input["combo"] as? String { return s }
        if let s = input["keys"] as? String { return s }
        if let a = input["keys"] as? [String] { return a.joined(separator: "+") }
        if let k = input["key"] as? String {
            let mods = (input["modifiers"] as? [String] ?? []).joined(separator: "+")
            return mods.isEmpty ? k : "\(mods)+\(k)"
        }
        return ""
    }

    private static func flatten(_ input: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: input) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
