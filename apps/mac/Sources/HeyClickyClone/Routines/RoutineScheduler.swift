import AppKit
import Network

/// Runs due routines while the Mac is awake. Holds a routine when the agent is
/// already in a turn or the network is down, and tries again on the next tick.
@MainActor
final class RoutineScheduler {
    static let quietReply = "Nothing new."

    let store: RoutineStore
    private let agents: AgentRuntime
    private let notch: NotchViewModel
    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private(set) var isOnline = true
    private var inFlight: [UUID: UUID] = [:]   // routine id -> agent id
    /// Called with the routine and the agent's summary after a run finishes (nil summary when nothing new).
    var onRoutineRan: ((Routine, String?) -> Void)?

    init(store: RoutineStore, agents: AgentRuntime, notch: NotchViewModel) {
        self.store = store
        self.agents = agents
        self.notch = notch
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let online = path.status == .satisfied
                if self?.isOnline != online { Log.agents.info("routines: network \(online ? "online" : "offline", privacy: .public)") }
                self?.isOnline = online
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "routines.network"))

        agents.onRoutineTurnFinished = { [weak self] routineID, summary, isError in
            self?.finished(routineID: routineID, summary: summary, isError: isError)
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Give the network a moment after wake, then catch up on anything missed.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                self?.tick()
            }
        }
        // First pass shortly after launch so an overdue routine is not kept waiting.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            self.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pathMonitor.cancel()
    }

    /// Runs every due routine it can; the rest wait for the next tick.
    func tick(now: Date = Date()) {
        let due = store.due(at: now)
        guard !due.isEmpty else { return }
        guard isOnline else {
            Log.agents.info("routines: \(due.count) due, holding while offline")
            return
        }
        for routine in due where inFlight[routine.id] == nil {
            run(routine)
        }
    }

    /// Starts one routine immediately (used by "Run now" and the due queue).
    @discardableResult
    func run(_ routine: Routine) -> Bool {
        guard let agent = agents.store.agent(id: routine.agentID) else {
            Log.agents.notice("routine '\(routine.title, privacy: .public)' has no agent; removing")
            store.remove(routine.id)
            return false
        }
        guard !agents.isRunning(agent.id), !inFlight.values.contains(agent.id) else {
            Log.agents.info("routine '\(routine.title, privacy: .public)' waiting: \(agent.name, privacy: .public) is busy")
            store.postpone(routine.id, by: 60)
            return false
        }
        inFlight[routine.id] = agent.id
        let message = Self.message(for: routine)
        agents.send(message, to: agent.id, routine: routine)
        Log.agents.info("routine '\(routine.title, privacy: .public)' started on \(agent.name, privacy: .public)")
        return true
    }

    static func message(for routine: Routine) -> String {
        var text = "[Routine: \(routine.title), \(routine.cadenceLabel)] \(routine.task)"
        if let last = routine.lastRun {
            text += "\n\nThis routine last ran \(last.formatted(date: .abbreviated, time: .shortened))."
            if let summary = routine.lastSummary, !summary.isEmpty, summary != quietReply {
                text += " You reported then: \"\(summary)\""
            }
        } else {
            text += "\n\nThis is the first run of this routine."
        }
        return text
    }

    private func finished(routineID: UUID, summary: String, isError: Bool) {
        inFlight[routineID] = nil
        guard let routine = store.routine(id: routineID) else { return }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let quiet = trimmed.isEmpty || trimmed.caseInsensitiveCompare(Self.quietReply) == .orderedSame
            || trimmed.lowercased().hasPrefix("nothing new")
        if isError {
            // Try again in a while rather than burning the slot.
            store.postpone(routineID, by: 15 * 60)
            Log.agents.notice("routine '\(routine.title, privacy: .public)' failed; retry in 15m")
            return
        }
        store.markRan(routineID, summary: quiet ? Self.quietReply : trimmed)
        onRoutineRan?(routine, quiet ? nil : trimmed)
        Log.agents.info("routine '\(routine.title, privacy: .public)' ran; \(quiet ? "nothing new" : "has news", privacy: .public)")
    }
}
