import Foundation

/// Gate for the `mcp__computer-use__*` tools an agent may call.
/// Personal-use defaults: everything is allowed once the user has turned
/// computer use on, except a short denylist of irreversible or escalating
/// actions. The HUD shows every step, and Stop interrupts the turn.
struct ComputerUsePolicy {
    static let toolPrefix = "mcp__\(ComputerUseHost.mcpServerName)__"

    var consentGranted: Bool

    /// Bundle ids an agent may not launch: privilege or settings escalation.
    static let deniedBundleIDs: Set<String> = [
        "com.apple.systempreferences", "com.apple.Terminal", "com.apple.keychainaccess",
        "com.apple.DiskUtility", "com.apple.Passwords",
    ]

    /// Key combos that destroy or send without a further confirmation.
    static let deniedHotkeys: [String] = [
        "cmd+shift+delete",      // Empty Trash
        "cmd+shift+backspace",
        "cmd+delete",            // move to Trash (Finder) / delete message
        "cmd+backspace",
        "cmd+shift+d",           // Send (Mail)
        "cmd+return",            // Send in many chat/mail apps
        "cmd+enter",
        "cmd+q",
    ]

    /// Substrings that mark an irreversible control; matched against the
    /// labels an agent types into or queries for (not against free text).
    static let deniedLabels: [String] = ["empty trash", "delete", "send", "pay", "purchase", "buy now", "erase", "format"]

    static func isComputerUse(_ tool: String) -> Bool { tool.hasPrefix(toolPrefix) }

    func decide(tool: String, input: [String: Any]) -> PermissionPolicy.Decision {
        guard Self.isComputerUse(tool) else { return .allow }
        guard consentGranted else {
            return .deny("Computer use is turned off. The user can enable it in HeyClicky Clone → Setup → Computer use.")
        }
        let name = String(tool.dropFirst(Self.toolPrefix.count))
        switch name {
        case "launch_app":
            if let id = (input["bundle_id"] as? String)?.lowercased(), Self.deniedBundleIDs.contains(where: { $0.lowercased() == id }) {
                return .deny("Launching \(id) is blocked. Ask the user to do that themselves.")
            }
        case "hotkey", "press_key":
            let combo = Self.comboString(input).lowercased()
            if Self.deniedHotkeys.contains(where: { combo.contains($0) }) {
                return .deny("The shortcut \(combo) is blocked because it deletes, sends or quits without confirmation. Ask the user.")
            }
        case "run_steps", "run_script":
            // Inspect nested steps for the same patterns.
            let blob = Self.flatten(input).lowercased()
            if Self.deniedHotkeys.contains(where: { blob.contains("\"\($0)\"") }) {
                return .deny("One of the batched steps uses a blocked shortcut. Run the steps individually and ask the user before deleting or sending.")
            }
        default:
            break
        }
        // Label guard: refuse to target controls whose names mean "irreversible".
        for key in ["label", "query", "name", "title"] {
            if let v = (input[key] as? String)?.lowercased(), Self.deniedLabels.contains(where: { v == $0 || v.hasPrefix($0 + " ") }) {
                return .deny("The control \"\(v)\" is on the never-press list. Ask the user to confirm that step themselves.")
            }
        }
        return .allow
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
