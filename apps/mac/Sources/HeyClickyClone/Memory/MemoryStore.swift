import AppKit
import ClickyPrivacy
import Combine

/// Memory of you: two short notes on disk — PROFILE.md (durable habits and
/// preferences) and VOLATILE.md (what you are working on right now) — learned
/// from talk and agent exchanges and injected into the voice prompt, the chat
/// and every Clicky's turn. Learning is batched: exchanges queue up and a
/// backend rewrite runs a little after the last one.
@MainActor
final class MemoryStore: ObservableObject {
    static let enabledKey = "ClickyMemoryEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    struct Exchange { var source: String; var user: String; var assistant: String }

    @Published private(set) var profile = ""
    @Published private(set) var volatile = ""
    @Published private(set) var learning = false
    @Published private(set) var lastLearned: Date?
    @Published private(set) var lastError: String?

    let directory: URL
    private let backend: BackendClient
    private var queue: [Exchange] = []
    private var flushTask: Task<Void, Never>?

    init(backend: BackendClient, directory: URL = AppConfig.appSupportDirectory.appendingPathComponent("memory", isDirectory: true)) {
        self.backend = backend
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        profile = (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""
        volatile = (try? String(contentsOf: volatileURL, encoding: .utf8)) ?? ""
        if let m = try? profileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { lastLearned = m }
    }

    var profileURL: URL { directory.appendingPathComponent("PROFILE.md") }
    var volatileURL: URL { directory.appendingPathComponent("VOLATILE.md") }
    var isEmpty: Bool { profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && volatile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What gets injected into prompts; nil when off or empty.
    var promptBlock: String? {
        guard Self.isEnabled, !isEmpty else { return nil }
        var parts: [String] = []
        let p = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty { parts.append("About the user:\n\(p)") }
        if !v.isEmpty { parts.append("What they are working on right now:\n\(v)") }
        return PrivacyGuard.redact(parts.joined(separator: "\n\n")).text
    }

    // MARK: - Learning

    /// A finished exchange (talk turn or agent turn). Queued; learned a little later.
    func record(source: String, user: String, assistant: String) {
        guard Self.isEnabled else { return }
        let u = PrivacyGuard.redact(user).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = PrivacyGuard.redact(assistant).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        queue.append(.init(source: source, user: String(u.prefix(1500)), assistant: String(a.prefix(1500))))
        if queue.count > 12 { queue.removeFirst(queue.count - 12) }
        scheduleFlush(after: 20)
    }

    func learnNow() { scheduleFlush(after: 0) }

    private func scheduleFlush(after seconds: TimeInterval) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard let self, !Task.isCancelled else { return }
            await self.flush()
        }
    }

    private func flush() async {
        guard !queue.isEmpty, !learning else { return }
        let batch = queue
        queue = []
        learning = true
        defer { learning = false }
        do {
            let r = try await backend.memoryExtract(.init(profile: profile, volatile: volatile, exchanges: batch.map { .init(source: $0.source, user: $0.user, assistant: $0.assistant) }))
            lastError = nil
            if r.changed {
                save(profile: PrivacyGuard.redact(r.profile).text, volatile: PrivacyGuard.redact(r.volatile).text)
                Log.app.info("memory learned from \(batch.count) exchange(s): profile \(self.profile.count)c volatile \(self.volatile.count)c")
            } else {
                lastLearned = Date()
                Log.app.info("memory: nothing new in \(batch.count) exchange(s)")
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            Log.app.error("memory learn failed: \(String(describing: error).prefix(200), privacy: .public)")
            queue = batch + queue
            if queue.count > 12 { queue.removeFirst(queue.count - 12) }
        }
    }

    // MARK: - Editing

    func save(profile newProfile: String, volatile newVolatile: String) {
        profile = newProfile
        volatile = newVolatile
        try? profile.write(to: profileURL, atomically: true, encoding: .utf8)
        try? volatile.write(to: volatileURL, atomically: true, encoding: .utf8)
        lastLearned = Date()
    }

    func forget() {
        flushTask?.cancel()
        queue = []
        save(profile: "", volatile: "")
        lastLearned = nil
        Log.app.info("memory forgotten")
    }
}
