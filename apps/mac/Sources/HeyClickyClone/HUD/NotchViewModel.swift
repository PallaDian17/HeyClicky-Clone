import SwiftUI
import Combine

enum NotchState: Equatable {
    case idle
    case listening
    case thinking
    case prompt
    case reply(String)
    case agent(name: String, step: String)
    case notice(String)
    case dictating(String)                     // live transcript while Option is held
    case dictated(String)                      // what was inserted
    case suggestions([SuggestionCardModel])    // morning cards
}

struct SuggestionCardModel: Equatable, Identifiable {
    var id: String { title + agentSlug }
    var title: String
    var task: String
    var agentSlug: String
    var agentName: String
    var everyMinutes: Int?
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var state: NotchState = .idle
    @Published var hovering = false
    @Published var promptText = ""

    let geometry: NotchGeometry
    var onPromptSubmitted: ((String) -> Void)?

    private var dismissTask: Task<Void, Never>?
    private var generation = 0

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    var isExpanded: Bool { state != .idle || hovering }

    /// Body size (ears excluded) for the current state.
    var size: CGSize {
        let n = geometry.notchSize
        switch state {
        case .idle:
            if hovering { return CGSize(width: n.width + 150, height: n.height + 36) }
            // Under a real notch only a 2pt lip shows; without one, a small pill with eyes.
            return geometry.hasNotch
                ? CGSize(width: n.width, height: n.height + 2)
                : CGSize(width: 96, height: n.height)
        case .listening, .thinking:
            return CGSize(width: max(n.width + 140, 320), height: n.height + 46)
        case .prompt:
            return CGSize(width: 480, height: n.height + 58)
        case .reply(let text):
            let lines = max(1, min(4, (text.count / 58) + 1))
            return CGSize(width: 480, height: n.height + 54 + CGFloat(lines) * 19)
        case .agent:
            return CGSize(width: 440, height: n.height + 60)
        case .notice:
            return CGSize(width: 420, height: n.height + 46)
        case .dictating(let text):
            let lines = max(1, min(3, (text.count / 56) + 1))
            return CGSize(width: 480, height: n.height + 40 + CGFloat(lines) * 18)
        case .dictated(let text):
            let lines = max(1, min(3, (text.count / 56) + 1))
            return CGSize(width: 480, height: n.height + 40 + CGFloat(lines) * 18)
        case .suggestions(let cards):
            return CGSize(width: 520, height: n.height + 52 + CGFloat(max(1, cards.count)) * 58)
        }
    }

    /// Set by the app: what to do when a suggestion card is accepted or dismissed.
    var onSuggestion: ((SuggestionCardModel, Bool) -> Void)?

    func set(_ newState: NotchState, autoDismissAfter seconds: TimeInterval? = nil) {
        dismissTask?.cancel()
        generation += 1
        state = newState
        Log.hud.debug("state -> \(String(describing: newState), privacy: .public)")
        guard let seconds else { return }
        let gen = generation
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.collapse()
        }
    }

    func collapse() {
        dismissTask?.cancel()
        generation += 1
        state = .idle
        hovering = false
    }

    func toggle(_ target: NotchState) {
        state == target ? collapse() : set(target)
    }

    func submitPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        promptText = ""
        onPromptSubmitted?(text)
    }
}
