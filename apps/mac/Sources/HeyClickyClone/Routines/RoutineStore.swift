import Foundation

/// A task a Clicky repeats on a cadence: "every morning, check X and tell me
/// what changed." Stored as JSON next to the agent roster.
struct Routine: Codable, Identifiable, Equatable {
    var id: UUID
    var agentID: UUID
    var title: String
    var task: String
    var everyMinutes: Int
    var paused = false
    var createdAt: Date
    var lastRun: Date?
    var nextRun: Date
    var lastSummary: String?
    var runCount = 0

    var cadenceLabel: String {
        switch everyMinutes {
        case ..<60: return "every \(everyMinutes) min"
        case 60: return "hourly"
        case ..<1440: return everyMinutes % 60 == 0 ? "every \(everyMinutes / 60) h" : "every \(everyMinutes) min"
        case 1440: return "daily"
        case 10080: return "weekly"
        default: return everyMinutes % 1440 == 0 ? "every \(everyMinutes / 1440) days" : "every \(everyMinutes / 60) h"
        }
    }

    func isDue(at now: Date = Date()) -> Bool { !paused && nextRun <= now }
}

/// What an agent emits to propose a routine mid-turn:
/// `<ROUTINE>{"title":"…","task":"…","every_minutes":1440}</ROUTINE>`
struct RoutineProposal: Decodable, Equatable {
    var title: String
    var task: String
    var every_minutes: Int

    static let openTag = "<ROUTINE>"
    static let closeTag = "</ROUTINE>"

    /// Pulls every proposal out of a message and returns the message with the tags removed.
    static func extract(from text: String) -> (proposals: [RoutineProposal], stripped: String) {
        var proposals: [RoutineProposal] = []
        var remaining = text
        var out = ""
        while let open = remaining.range(of: openTag), let close = remaining.range(of: closeTag, range: open.upperBound..<remaining.endIndex) {
            out += remaining[remaining.startIndex..<open.lowerBound]
            let json = remaining[open.upperBound..<close.lowerBound]
            if let p = try? JSONDecoder().decode(RoutineProposal.self, from: Data(json.utf8)), p.every_minutes >= 5, !p.task.isEmpty {
                proposals.append(p)
            }
            remaining = String(remaining[close.upperBound...])
        }
        out += remaining
        return (proposals, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@MainActor
final class RoutineStore: ObservableObject {
    @Published private(set) var routines: [Routine] = []
    private let fileURL: URL

    init() {
        fileURL = AppConfig.appSupportDirectory.appendingPathComponent("routines.json")
        load()
    }

    func routine(id: UUID) -> Routine? { routines.first { $0.id == id } }
    func routines(for agentID: UUID) -> [Routine] { routines.filter { $0.agentID == agentID } }

    /// Routines whose next run has passed, oldest first.
    func due(at now: Date = Date()) -> [Routine] {
        routines.filter { $0.isDue(at: now) }.sorted { $0.nextRun < $1.nextRun }
    }

    @discardableResult
    func add(agentID: UUID, title: String, task: String, everyMinutes: Int, firstRun: Date? = nil) -> Routine {
        let every = max(5, everyMinutes)
        let routine = Routine(id: UUID(), agentID: agentID, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                              task: task.trimmingCharacters(in: .whitespacesAndNewlines), everyMinutes: every,
                              createdAt: Date(), nextRun: firstRun ?? Date().addingTimeInterval(TimeInterval(every) * 60))
        routines.append(routine)
        save()
        Log.agents.info("routine added '\(routine.title, privacy: .public)' \(routine.cadenceLabel, privacy: .public)")
        return routine
    }

    func update(_ routine: Routine) {
        guard let i = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        routines[i] = routine
        save()
    }

    func remove(_ id: UUID) {
        routines.removeAll { $0.id == id }
        save()
    }

    func removeAll(for agentID: UUID) {
        routines.removeAll { $0.agentID == agentID }
        save()
    }

    func setPaused(_ id: UUID, _ paused: Bool) {
        guard var r = routine(id: id) else { return }
        r.paused = paused
        if !paused, r.nextRun < Date() { r.nextRun = Date() }
        update(r)
    }

    /// Pulls the next run forward so the scheduler picks it up on its next tick.
    func runNow(_ id: UUID) {
        guard var r = routine(id: id) else { return }
        r.nextRun = Date()
        r.paused = false
        update(r)
    }

    func markRan(_ id: UUID, summary: String?) {
        guard var r = routine(id: id) else { return }
        let now = Date()
        r.lastRun = now
        r.runCount += 1
        r.lastSummary = summary.map { String($0.prefix(300)) }
        // Keep the cadence anchored to the schedule, not to when the run finished.
        var next = r.nextRun.addingTimeInterval(TimeInterval(r.everyMinutes) * 60)
        while next <= now { next = next.addingTimeInterval(TimeInterval(r.everyMinutes) * 60) }
        r.nextRun = next
        update(r)
    }

    /// A run failed to start (agent busy / offline): nudge instead of skipping the slot.
    func postpone(_ id: UUID, by seconds: TimeInterval) {
        guard var r = routine(id: id) else { return }
        r.nextRun = Date().addingTimeInterval(seconds)
        update(r)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        routines = (try? decoder.decode([Routine].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(routines) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
