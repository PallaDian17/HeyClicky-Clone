import Foundation

/// Runtime configuration. Resolution order for each value:
/// 1. environment variable (handy when launching from a terminal),
/// 2. Info.plist key baked in by scripts/build-app.sh from .env,
/// 3. ~/Library/Application Support/HeyClickyClone/config.json.
struct AppConfig {
    var supabaseURL: URL?
    var supabaseAnonKey: String?
    var backendURL = URL(string: "http://localhost:8787")!

    static let appName = "HeyClickyClone"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    /// Short commit the running bundle was built from ("+local" when the tree was dirty).
    static var gitCommit: String { Bundle.main.infoDictionary?["GitCommit"] as? String ?? "unknown" }
    static var buildDate: Date? {
        (Bundle.main.infoDictionary?["BuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }
    static var buildConfiguration: String { Bundle.main.infoDictionary?["BuildConfiguration"] as? String ?? "?" }
    /// Repo the app was built from, when it still exists on this Mac (dev builds).
    static var repoURL: URL? {
        let candidates = [Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent(),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("github/HeyClicky-Clone")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("scripts/update.sh").path) }
    }
    /// Optional `--model` for agent turns; nil lets Claude Code pick its default.
    var agentModel: String?

    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load() -> AppConfig {
        let env = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        let json = loadJSON()

        func value(env envKey: String, plist plistKey: String, json jsonKey: String) -> String? {
            let candidates = [env[envKey], info[plistKey] as? String, json[jsonKey] as? String]
            for c in candidates {
                if let c, !c.isEmpty, !c.hasPrefix("__") { return c }
            }
            return nil
        }

        var config = AppConfig()
        if let raw = value(env: "SUPABASE_URL", plist: "SupabaseURL", json: "supabaseURL") {
            config.supabaseURL = URL(string: raw)
        }
        config.supabaseAnonKey = value(env: "SUPABASE_ANON_KEY", plist: "SupabaseAnonKey", json: "supabaseAnonKey")
        if let raw = value(env: "BACKEND_URL", plist: "BackendURL", json: "backendURL"), let url = URL(string: raw) {
            config.backendURL = url
        }
        if let model = value(env: "AGENT_MODEL", plist: "AgentModel", json: "agentModel") {
            config.agentModel = model
        }
        return config
    }

    private static func loadJSON() -> [String: Any] {
        let url = appSupportDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}
