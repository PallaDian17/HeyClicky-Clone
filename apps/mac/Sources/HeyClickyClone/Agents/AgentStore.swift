import Foundation

/// A named, persistent helper. Lives in its own folder with a persona file.
struct Agent: Codable, Identifiable, Equatable {
    var id: UUID
    var slug: String
    var name: String
    var purpose: String
    var createdAt: Date
    var sessionID: String?        // Claude Code session to resume
    var lastActivity: Date?

    var initial: String { String(name.prefix(1)).uppercased() }
}

struct TranscriptEntry: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant, command, status, error }
    var id: UUID = UUID()
    var role: Role
    var text: String
    var detail: String?          // command output, error detail
    var timestamp: Date = Date()
    var streaming = false
}

/// Roster + folders on disk under Application Support/HeyClickyClone/agents/.
@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [Agent] = []

    let root: URL
    private var rosterURL: URL { root.appendingPathComponent("roster.json") }

    init() {
        root = AppConfig.appSupportDirectory.appendingPathComponent("agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func folder(for agent: Agent) -> URL { root.appendingPathComponent(agent.slug, isDirectory: true) }

    func agent(id: UUID) -> Agent? { agents.first { $0.id == id } }

    @discardableResult
    func create(name: String, purpose: String) throws -> Agent {
        let slug = Self.uniqueSlug(for: name, taken: Set(agents.map(\.slug)))
        let agent = Agent(id: UUID(), slug: slug, name: name, purpose: purpose, createdAt: Date())
        let dir = folder(for: agent)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("output"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        try Self.persona(for: agent).write(to: dir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        agents.append(agent)
        try save()
        Log.agents.info("created agent \(agent.slug, privacy: .public) at \(dir.path, privacy: .public)")
        return agent
    }

    func update(_ agent: Agent) {
        guard let i = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[i] = agent
        try? save()
    }

    func delete(_ agent: Agent) {
        agents.removeAll { $0.id == agent.id }
        try? FileManager.default.removeItem(at: folder(for: agent))
        try? save()
    }

    /// Copies the bundled cua-driver skill into the agent's project skills so
    /// Claude Code lists it natively (`.claude/skills/cua-driver/SKILL.md`).
    func installComputerUseSkill(for agent: Agent, from source: URL?) {
        guard let source, FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else { return }
        let dest = folder(for: agent).appendingPathComponent(".claude/skills/cua-driver", isDirectory: true)
        let fm = FileManager.default
        let stamp = dest.appendingPathComponent(".version")
        let version = (try? String(contentsOf: source.appendingPathComponent("VERSION"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        if let existing = try? String(contentsOf: stamp, encoding: .utf8), existing == version { return }
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for file in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "md" {
            let target = dest.appendingPathComponent(file.lastPathComponent)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: file, to: target)
        }
        try? version.write(to: stamp, atomically: true, encoding: .utf8)
        Log.computerUse.info("installed cua-driver skill \(version, privacy: .public) for \(agent.slug, privacy: .public)")
    }

    // MARK: - Transcript persistence

    func loadTranscript(for agent: Agent) -> [TranscriptEntry] {
        let url = folder(for: agent).appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([TranscriptEntry].self, from: data)) ?? []
    }

    func saveTranscript(_ entries: [TranscriptEntry], for agent: Agent) {
        let url = folder(for: agent).appendingPathComponent("transcript.json")
        let kept = entries.suffix(400).map { e -> TranscriptEntry in var e = e; e.streaming = false; return e }
        if let data = try? Self.encoder.encode(Array(kept)) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: rosterURL),
              let list = try? Self.decoder.decode([Agent].self, from: data) else { return }
        agents = list.filter { FileManager.default.fileExists(atPath: folder(for: $0).path) }
        // Agents founded before the Claude runtime have AGENTS.md but no CLAUDE.md.
        for agent in agents {
            let persona = folder(for: agent).appendingPathComponent("CLAUDE.md")
            if !FileManager.default.fileExists(atPath: persona.path) {
                try? Self.persona(for: agent).write(to: persona, atomically: true, encoding: .utf8)
            }
        }
    }

    private func save() throws {
        try Self.encoder.encode(agents).write(to: rosterURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private static func uniqueSlug(for name: String, taken: Set<String>) -> String {
        let base = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let root = base.isEmpty ? "clicky" : base
        var candidate = root
        var n = 2
        while taken.contains(candidate) { candidate = "\(root)-\(n)"; n += 1 }
        return candidate
    }

    /// The persona file Claude Code loads from the working directory at the start of every turn.
    static func persona(for agent: Agent) -> String {
        let date = ISO8601DateFormatter().string(from: agent.createdAt).prefix(10)
        return """
        # \(agent.name)

        You are \(agent.name), a helper that lives on this person's Mac and works in this folder.
        Your job: \(agent.purpose)

        ## How you work
        - This folder is yours. Finished work goes in `output/`; scratch files go in `tmp/`. When you are done, `output/` holds only what was asked for.
        - Do what was asked, then stop. Ask only when the answer genuinely depends on something only the person knows, and bundle your questions.
        - Never claim something happened unless it did. Never invent facts, files or links.
        - Confirm before deleting data, sending anything, or spending money.
        - Lead your final message with the result. Keep it short, plain and warm. Say what didn't work.

        ## Notes
        Durable facts you learn about this job, newest first, each with a date. Never store passwords, tokens or other secrets here.

        - \(date): founded for: \(agent.purpose)

        """
    }
}
