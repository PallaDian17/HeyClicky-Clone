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
    case conversation(ConversationModel)       // the talk thread (recorded layout)
}

/// The talk as a thread: assistant and user bubbles, suggestion chips, and the
/// hold-to-talk pill + Ask field underneath.
struct ConversationModel: Equatable {
    struct Message: Equatable, Identifiable {
        enum Role { case user, assistant }
        var id = UUID()
        var role: Role
        var text: String
    }
    var messages: [Message] = []
    var chips: [String] = []
    var status: String?            // "Listening…", "Thinking…", "Speaking…"
    var canClear = false           // annotations on screen
    var hint = "Hold ⌃ Control + ⌥ Option to talk"
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
    @Published var character: ClickyCharacter = ClickyCharacter.loadUser()
    /// Shown on the reply card after a circle-to-ask: hands the same crop + question + answer to a Clicky.
    @Published var tellMoreAvailable = false
    var onTellMore: (() -> Void)?

    private var dismissTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    /// Provided by the window: is the pointer over the panel right now?
    var isMouseInside: (() -> Bool)?
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
        case .conversation(let c):
            let shown = c.messages.suffix(3)
            let textHeight = shown.reduce(CGFloat(0)) { $0 + 30 + CGFloat(min(6, $1.text.count / 48)) * 17 }
            let chips: CGFloat = c.chips.isEmpty ? 0 : 36
            return CGSize(width: 520, height: n.height + 24 + max(40, textHeight) + chips + 62)
        }
    }

    /// Set by the app: a chip or the Ask field sent text; the Clear chip was pressed.
    var onConversationSend: ((String) -> Void)?
    var onClearAnnotations: (() -> Void)?
    @Published var askText = ""

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

    /// SwiftUI reports a hover exit the moment the pill resizes under the pointer,
    /// which used to collapse and re-expand it in a loop. An exit only counts
    /// once the pointer is really outside the panel.
    func setHovering(_ inside: Bool) {
        hoverTask?.cancel()
        if inside {
            hovering = true
            return
        }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            while self.isMouseInside?() == true {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            self.hovering = false
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
