import AppKit
import ClickyPrivacy

/// Drives agents on Claude Code: one headless `claude` process per turn,
/// resumed by session id, with every event mirrored into the transcript and HUD.
@MainActor
final class AgentRuntime: ObservableObject {
    let store: AgentStore
    let computerUse: ComputerUseHost
    let privacy: PrivacyMonitor
    private let notch: NotchViewModel
    private let model: String?

    @Published private(set) var transcripts: [UUID: [TranscriptEntry]] = [:]
    @Published private(set) var modelLabel: String?

    private var runners: [UUID: ClaudeCodeRunner] = [:]
    private var starting: Set<UUID> = []                   // turns gathering their MCP servers
    /// Set by the app: Composio + custom connectors for each turn.
    var integrations: IntegrationsHost?
    private var toolEntries: [String: UUID] = [:]          // tool_use id -> transcript entry
    private var streamingEntry: [UUID: UUID] = [:]         // agent -> streaming assistant entry
    private var routineTurns: [UUID: UUID] = [:]           // agent -> routine driving the current turn
    /// Set by the routine scheduler: (routine id, final text, isError).
    var onRoutineTurnFinished: ((UUID, String, Bool) -> Void)?
    /// Set by the app: an agent proposed a routine in its reply.
    var onRoutineProposed: ((Agent, RoutineProposal) -> Void)?

    init(store: AgentStore, computerUse: ComputerUseHost, privacy: PrivacyMonitor, notch: NotchViewModel, model: String?) {
        self.store = store
        self.computerUse = computerUse
        self.privacy = privacy
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

    func isRunning(_ agentID: UUID) -> Bool { runners[agentID] != nil || starting.contains(agentID) }

    // MARK: - Turns

    func send(_ text: String, to agentID: UUID, routine: Routine? = nil) {
        guard let agent = store.agent(id: agentID), !isRunning(agentID) else { return }
        starting.insert(agentID)
        append(.init(role: .user, text: text), to: agentID)
        routineTurns[agentID] = routine?.id
        notch.set(.agent(name: agent.name, step: routine.map { "Routine: \($0.title)" } ?? "Starting…"))
        Task { @MainActor in
            let turnServers = await integrations?.prepareForTurn() ?? IntegrationsHost.TurnServers()
            starting.remove(agentID)
            start(agent: agent, text: text, routine: routine, integrations: turnServers)
        }
    }

    private func start(agent: Agent, text: String, routine: Routine?, integrations turn: IntegrationsHost.TurnServers) {
        let agentID = agent.id
        let computerUseOn = computerUse.isEnabled && computerUse.isRunning
        var policy = PermissionPolicy(workspace: store.folder(for: agent))
        policy.computerUse = ComputerUsePolicy(
            consentGranted: computerUseOn,
            assessTarget: privacy.targetAssessor(),
            secureInputActive: { PrivacyMonitor.secureInputActive }
        )
        policy.integrations = IntegrationPolicy(sensitiveAllowed: turn.sensitiveAllowed, knownServers: Set(turn.servers.keys))
        let runner = ClaudeCodeRunner(policy: policy)
        runners[agentID] = runner
        if computerUseOn { store.installComputerUseSkill(for: agent, from: ComputerUseHost.skillDirectory) }

        var servers = turn.servers
        if computerUseOn, let entry = computerUse.mcpServerEntry { servers[ComputerUseHost.mcpServerName] = entry }
        let options = ClaudeCodeRunner.Options(
            cwd: store.folder(for: agent),
            sessionID: agent.sessionID,
            newSessionID: UUID().uuidString.lowercased(),
            model: model,
            appendSystemPrompt: Self.turnPreamble(for: agent, computerUse: computerUseOn, routine: routine, integrations: turn),
            mcpConfigJSON: ComputerUseHost.mcpConfigJSON(servers: servers)
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
            if let routineID = routineTurns.removeValue(forKey: agentID) { onRoutineTurnFinished?(routineID, message, true) }
        }
    }

    func stop(_ agentID: UUID) {
        runners[agentID]?.interrupt()
    }

    func shutdown() {
        runners.values.forEach { $0.interrupt() }
    }

    /// Standing rules every turn carries, on top of the persona in the folder's CLAUDE.md.
    private static func turnPreamble(for agent: Agent, computerUse: Bool, routine: Routine? = nil, integrations: IntegrationsHost.TurnServers = .init()) -> String {
        var text = """
        You are \(agent.name), a helper running inside HeyClicky Clone on this person's Mac. Your working directory is your own folder; its CLAUDE.md holds your persona and dated notes. Keep finished work in output/ and scratch in tmp/. You cannot ask the user questions mid-turn, so make reasonable choices and say what you assumed. Your final message is shown in a small card and may be read aloud: lead with the result in plain words, keep it short, and say what did not work.

        You have no scheduler of your own, and you must not build or look for one: launchd, cron, crontab, background scripts, sleep loops, the cron/schedule/loop tools and the "schedule" and "loop" skills are all disabled here on purpose (do not load them; do not say scheduling is unavailable). The app runs repeating work for you, and it works. When the user asks for something to happen repeatedly (every morning, hourly, each Monday) or asks to "set up a routine", do NOT run the task now and do NOT write any script; instead end your reply with exactly one tag on its own line:
        <ROUTINE>{"title":"short name","task":"the exact request to run each time","every_minutes":1440}</ROUTINE>
        Use minutes: hourly = 60, daily = 1440, weekly = 10080. The app registers it and starts you on that cadence; tell the user it is scheduled.
        """
        if let routine {
            text += """


            This turn is the routine "\(routine.title)" (\(routine.cadenceLabel)), started by the app on schedule, not by the user typing. Do the task, keep a dated note of what you saw in tmp/routine-\(routine.id.uuidString.prefix(8)).md so the next run can compare, and report ONLY what is new or changed since the last run. If nothing is new, reply with exactly: \(RoutineScheduler.quietReply)
            """
        }
        if computerUse {
            text += """


            You can operate the user's Mac through the computer-use MCP tools (mcp__cua__*), which click and type in native apps in the background without stealing focus. Use only those tools for the screen: the cua-driver command line is blocked and must not be searched for or run. The cua-driver skill in .claude/skills explains the loop: launch_app or list_windows to find the window, get_window_state to read it, act by element_token, then re-read to verify. Prefer files, the shell and the web; use the screen only when nothing else can do the job. Never press controls that delete, send, pay or empty the trash; stop and tell the user when a step needs that.
            """
        } else {
            text += "\n\nComputer use (clicking in apps) is turned off for you right now; if a task needs it, say so and tell the user it can be enabled in Setup."
        }
        if integrations.summary.isEmpty {
            text += "\n\nNo online accounts are connected; if a task needs Gmail, Notion or another service, say so and tell the user they can connect it in Setup → Integrations."
        } else {
            text += "\n\nConnected integrations, available as MCP tools (mcp__<server>__<tool>): " + integrations.summary.joined(separator: "; ") + ". Use them directly for anything in those services. Tools that send, reply, delete, pay or publish are blocked unless the user allowed them for that server; when one is blocked, prepare everything else and tell the user what you would have sent or removed."
        }
        return text
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
                mutate(agentID, entry: entryID) { $0.text = PrivacyGuard.redact($0.text + delta).text }
            } else {
                let entry = TranscriptEntry(role: .assistant, text: delta, streaming: true)
                streamingEntry[agentID] = entry.id
                append(entry, to: agentID)
                notch.set(.agent(name: agent.name, step: "Writing…"))
            }
        case .assistantText(let raw):
            let text = PrivacyGuard.redact(raw).text
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
        case .toolFinished(let id, let rawOutput, let isError):
            let output = PrivacyGuard.redact(rawOutput).text
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
            finishTurn(agentID: agentID, agent: agent, finalText: PrivacyGuard.redact(text).text, isError: isError, sessionID: sessionID)
            Log.agents.info("turn finished agent=\(agent.slug, privacy: .public) error=\(isError) cost=\(cost ?? 0) ms=\(durationMs ?? 0)")
        case .failed(let message):
            guard runners[agentID] != nil else { return }
            finishTurn(agentID: agentID, agent: agent, finalText: message, isError: true, sessionID: nil)
        }
    }

    private func finishTurn(agentID: UUID, agent: Agent, finalText rawFinal: String, isError: Bool, sessionID: String?) {
        runners[agentID] = nil
        streamingEntry[agentID] = nil
        let routineID = routineTurns.removeValue(forKey: agentID)
        var t = transcript(for: agentID)
        for i in t.indices where t[i].streaming { t[i].streaming = false }
        // An agent may propose a routine; the tag is for the app, not the card.
        let extracted = RoutineProposal.extract(from: rawFinal)
        let finalText = extracted.stripped
        for i in t.indices where t[i].role == .assistant && t[i].text.contains(RoutineProposal.openTag) {
            t[i].text = RoutineProposal.extract(from: t[i].text).stripped
        }
        if !isError { extracted.proposals.forEach { onRoutineProposed?(agent, $0) } }
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

        let summary = finalText.isEmpty ? (lastAssistant ?? "Done.") : finalText
        if let routineID {
            onRoutineTurnFinished?(routineID, isError ? finalText : summary, isError)
            let quiet = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("nothing new")
            if isError {
                notch.set(.notice("\(agent.name): \(finalText.prefix(120))"), autoDismissAfter: 8)
            } else if quiet {
                notch.collapse()   // a routine with nothing to say stays out of the way
            } else {
                notch.set(.reply("\(agent.name): \(summary)"), autoDismissAfter: 15)
            }
            return
        }
        if isError {
            notch.set(.notice("\(agent.name): \(finalText.prefix(120))"), autoDismissAfter: 8)
        } else {
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
