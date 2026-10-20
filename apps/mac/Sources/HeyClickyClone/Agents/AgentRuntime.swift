import AppKit

/// Drives agents on Claude Code: one headless `claude` process per turn,
/// resumed by session id, with every event mirrored into the transcript and HUD.
@MainActor
final class AgentRuntime: ObservableObject {
    let store: AgentStore
    private let notch: NotchViewModel
    private let model: String?

    @Published private(set) var transcripts: [UUID: [TranscriptEntry]] = [:]
    @Published private(set) var modelLabel: String?

    private var runners: [UUID: ClaudeCodeRunner] = [:]
    private var toolEntries: [String: UUID] = [:]          // tool_use id -> transcript entry
    private var streamingEntry: [UUID: UUID] = [:]         // agent -> streaming assistant entry

    init(store: AgentStore, notch: NotchViewModel, model: String?) {
        self.store = store
        self.notch = notch
        self.model = model
    }

    var isAvailable: Bool { ClaudeCodeRunner.binary != nil }

    func transcript(for agentID: UUID) -> [TranscriptEntry] {
        if let t = transcripts[agentID] { return t }
        guard let agent = store.agent(id: agentID) else { return [] }
        let loaded = store.loadTranscript(for: agent)
        transcripts[agentID] = loaded
        return loaded
    }

    func isRunning(_ agentID: UUID) -> Bool { runners[agentID] != nil }

    // MARK: - Turns

    func send(_ text: String, to agentID: UUID) {
        guard let agent = store.agent(id: agentID), !isRunning(agentID) else { return }
        append(.init(role: .user, text: text), to: agentID)
        notch.set(.agent(name: agent.name, step: "Starting…"))

        let runner = ClaudeCodeRunner(policy: PermissionPolicy(workspace: store.folder(for: agent)))
        runners[agentID] = runner
        let options = ClaudeCodeRunner.Options(
            cwd: store.folder(for: agent),
            sessionID: agent.sessionID,
            newSessionID: UUID().uuidString.lowercased(),
            model: model,
            appendSystemPrompt: Self.turnPreamble(for: agent)
        )
        do {
            try runner.start(prompt: text, options: options) { [weak self] event in
                self?.handle(event, agentID: agentID)
            }
        } catch {
            runners[agentID] = nil
            let message = (error as? LocalizedError)?.errorDescription ?? "Could not start the agent."
            append(.init(role: .error, text: message), to: agentID)
            notch.set(.notice(message), autoDismissAfter: 6)
        }
    }

    func stop(_ agentID: UUID) {
        runners[agentID]?.interrupt()
    }

    func shutdown() {
        runners.values.forEach { $0.interrupt() }
    }

    /// Standing rules every turn carries, on top of the persona in the folder's CLAUDE.md.
    private static func turnPreamble(for agent: Agent) -> String {
        """
        You are \(agent.name), a helper running inside HeyClicky Clone on this person's Mac. Your working directory is your own folder; its CLAUDE.md holds your persona and dated notes. Keep finished work in output/ and scratch in tmp/. You cannot ask the user questions mid-turn, so make reasonable choices and say what you assumed. Your final message is shown in a small card and may be read aloud: lead with the result in plain words, keep it short, and say what did not work.
        """
    }

    // MARK: - Events

    private func handle(_ event: ClaudeCodeRunner.Event, agentID: UUID) {
        guard let agent = store.agent(id: agentID) else { return }
        switch event {
        case .started(let sessionID, let model):
            if !model.isEmpty { modelLabel = model }
            if agent.sessionID != sessionID, !sessionID.isEmpty {
                var updated = agent
                updated.sessionID = sessionID
                store.update(updated)
            }
        case .textDelta(let delta):
            if let entryID = streamingEntry[agentID] {
                mutate(agentID, entry: entryID) { $0.text += delta }
            } else {
                let entry = TranscriptEntry(role: .assistant, text: delta, streaming: true)
                streamingEntry[agentID] = entry.id
                append(entry, to: agentID)
                notch.set(.agent(name: agent.name, step: "Writing…"))
            }
        case .assistantText(let text):
            if let entryID = streamingEntry[agentID] {
                mutate(agentID, entry: entryID) { $0.text = text; $0.streaming = false }
                streamingEntry[agentID] = nil
            } else if !text.isEmpty {
                append(.init(role: .assistant, text: text), to: agentID)
            }
        case .toolStarted(let id, let name, let summary):
            streamingEntry[agentID] = nil
            let entry = TranscriptEntry(role: .command, text: summary, detail: "", streaming: true)
            toolEntries[id] = entry.id
            append(entry, to: agentID)
            notch.set(.agent(name: agent.name, step: summary))
            Log.agents.debug("tool \(name, privacy: .public): \(summary, privacy: .public)")
        case .toolFinished(let id, let output, let isError):
            if let entryID = toolEntries[id] {
                mutate(agentID, entry: entryID) {
                    $0.streaming = false
                    $0.detail = output
                    if isError { $0.text += " (failed)" }
                }
            }
        case .permissionDecided(let tool, let allowed, let reason):
            if !allowed { append(.init(role: .status, text: "Blocked \(tool): \(reason ?? "")"), to: agentID) }
        case .finished(let text, let isError, let sessionID, let cost, let durationMs):
            finishTurn(agentID: agentID, agent: agent, finalText: text, isError: isError, sessionID: sessionID)
            Log.agents.info("turn finished agent=\(agent.slug, privacy: .public) error=\(isError) cost=\(cost ?? 0) ms=\(durationMs ?? 0)")
        case .failed(let message):
            guard runners[agentID] != nil else { return }
            finishTurn(agentID: agentID, agent: agent, finalText: message, isError: true, sessionID: nil)
        }
    }

    private func finishTurn(agentID: UUID, agent: Agent, finalText: String, isError: Bool, sessionID: String?) {
        runners[agentID] = nil
        streamingEntry[agentID] = nil
        var t = transcript(for: agentID)
        for i in t.indices where t[i].streaming { t[i].streaming = false }
        // The result text repeats the last assistant message; only add it when it brings something new.
        let lastAssistant = t.last(where: { $0.role == .assistant })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isError {
            t.append(.init(role: .error, text: finalText.isEmpty ? "The turn failed." : finalText))
        } else if !finalText.isEmpty, finalText.trimmingCharacters(in: .whitespacesAndNewlines) != lastAssistant {
            t.append(.init(role: .assistant, text: finalText))
        }
        transcripts[agentID] = t

        var updated = agent
        updated.lastActivity = Date()
        if let sessionID, !sessionID.isEmpty { updated.sessionID = sessionID }
        store.update(updated)
        store.saveTranscript(t, for: updated)

        if isError {
            notch.set(.notice("\(agent.name): \(finalText.prefix(120))"), autoDismissAfter: 8)
        } else {
            let summary = finalText.isEmpty ? (lastAssistant ?? "Done.") : finalText
            notch.set(.reply("\(agent.name): \(summary)"), autoDismissAfter: 12)
        }
    }

    // MARK: - Transcript helpers

    private func append(_ entry: TranscriptEntry, to agentID: UUID) {
        var t = transcript(for: agentID)
        t.append(entry)
        transcripts[agentID] = t
    }

    private func mutate(_ agentID: UUID, entry entryID: UUID, _ change: (inout TranscriptEntry) -> Void) {
        guard var t = transcripts[agentID], let i = t.firstIndex(where: { $0.id == entryID }) else { return }
        change(&t[i])
        transcripts[agentID] = t
    }
}
