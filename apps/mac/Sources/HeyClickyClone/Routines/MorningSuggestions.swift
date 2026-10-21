import AppKit

/// Once a day, in the morning, ask the backend what the Clickys could do today
/// and show the cards in the notch. Yes on a repeating card makes a routine;
/// yes on a one-off sends the task.
@MainActor
final class MorningSuggestions {
    static let shownOnKey = "ClickySuggestionsShownOn"
    static let morningHours = 5..<12

    private let backend: BackendClient
    private let agents: AgentRuntime
    private let routines: RoutineStore
    private let scheduler: RoutineScheduler
    private let notch: NotchViewModel
    private var cards: [SuggestionCardModel] = []

    init(backend: BackendClient, agents: AgentRuntime, routines: RoutineStore, scheduler: RoutineScheduler, notch: NotchViewModel) {
        self.backend = backend
        self.agents = agents
        self.routines = routines
        self.scheduler = scheduler
        self.notch = notch
        notch.onSuggestion = { [weak self] card, accepted in self?.answer(card, accepted: accepted) }
    }

    func start() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            self.showIfMorning()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                self?.showIfMorning()
            }
        }
    }

    private static var todayKey: String { Date().formatted(.iso8601.year().month().day()) }

    func showIfMorning() {
        let hour = Calendar.current.component(.hour, from: Date())
        guard Self.morningHours.contains(hour) else { return }
        guard UserDefaults.standard.string(forKey: Self.shownOnKey) != Self.todayKey else { return }
        guard notch.state == .idle, !agents.store.agents.isEmpty else { return }
        Task { await show(force: false) }
    }

    /// Fetches suggestions and shows them. `force` ignores the once-a-day guard.
    func show(force: Bool) async {
        if !force, UserDefaults.standard.string(forKey: Self.shownOnKey) == Self.todayKey { return }
        let payload = agents.store.agents.map { agent in
            let recent = agents.transcript(for: agent.id)
                .filter { $0.role == .user && !$0.text.hasPrefix("[Routine:") }
                .suffix(6).map { String($0.text.prefix(300)) }
            return BackendClient.SuggestionAgent(slug: agent.slug, name: agent.name, purpose: agent.purpose,
                                                 recent: Array(recent),
                                                 routines: routines.routines(for: agent.id).map { "\($0.title) (\($0.cadenceLabel))" })
        }
        guard !payload.isEmpty else { return }
        do {
            let result = try await backend.suggestions(agents: payload)
            UserDefaults.standard.set(Self.todayKey, forKey: Self.shownOnKey)
            let models = result.compactMap { card -> SuggestionCardModel? in
                guard let agent = agents.store.agents.first(where: { $0.slug == card.agent_slug }) else { return nil }
                return SuggestionCardModel(title: card.title, task: card.task, agentSlug: agent.slug, agentName: agent.name, everyMinutes: card.every_minutes)
            }
            Log.agents.info("morning suggestions: \(models.count) card(s)")
            guard !models.isEmpty else { return }
            present(models)
        } catch {
            Log.agents.notice("morning suggestions unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Shows given cards (debug + tests).
    func present(_ models: [SuggestionCardModel]) {
        cards = models
        notch.set(.suggestions(cards))
    }

    private func answer(_ card: SuggestionCardModel, accepted: Bool) {
        cards.removeAll { $0.id == card.id }
        if accepted, let agent = agents.store.agents.first(where: { $0.slug == card.agentSlug }) {
            if let every = card.everyMinutes, every >= 5 {
                let routine = routines.add(agentID: agent.id, title: card.title, task: card.task, everyMinutes: every, firstRun: Date())
                scheduler.run(routine)
                Log.agents.info("suggestion accepted as routine '\(card.title, privacy: .public)'")
            } else {
                agents.send(card.task, to: agent.id)
                Log.agents.info("suggestion accepted as one-off for \(agent.name, privacy: .public)")
            }
            NotificationCenter.default.post(name: .homeSpaceSelectAgent, object: agent.id)
        }
        if cards.isEmpty {
            // A started turn already replaced the HUD state; only collapse if the cards are still up.
            if case .suggestions = notch.state { notch.collapse() }
        } else if case .suggestions = notch.state {
            notch.set(.suggestions(cards))
        }
    }
}
