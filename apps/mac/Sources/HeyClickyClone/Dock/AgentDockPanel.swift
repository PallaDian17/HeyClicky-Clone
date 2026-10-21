import AppKit
import Combine
import SwiftUI

/// The Clickys on the desktop: a small always-on-top strip in the bottom-right
/// corner of the main screen, one mascot per Clicky. Idle ones blink; a working
/// one bobs with its current step in a bubble; a finished one shows its reply
/// for a while. Click opens the Clicky in Home; hover reveals an ask box.
@MainActor
final class AgentDockPanel {
    static let enabledKey = "ClickyDockEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private let panel: NSPanel
    private let model: AgentDockModel
    private var cancellables = Set<AnyCancellable>()

    init(agents: AgentRuntime, open: @escaping (UUID) -> Void) {
        model = AgentDockModel(agents: agents, open: open)
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: AgentDockView(model: model))

        model.$agentCount.combineLatest(model.$expanded)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.layout() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        layout()
        panel.orderFrontRegardless()
        Log.app.info("dock shown with \(self.model.agentCount) clicky(s)")
    }

    func hide() { panel.orderOut(nil) }

    func setVisible(_ on: Bool) { on ? show() : hide() }

    /// Bottom-right of the main screen's visible area, sized to the row of Clickys.
    private func layout() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let count = max(1, model.agentCount)
        let width = CGFloat(count) * AgentDockView.slot + 24 + (model.expanded != nil ? 180 : 0)
        let height: CGFloat = 150
        let v = screen.visibleFrame
        let frame = NSRect(x: v.maxX - width - 12, y: v.minY + 8, width: width, height: height)
        panel.setFrame(frame, display: true)
    }

    /// Renders the strip to a PNG (debug).
    func snapshot(to url: URL) {
        guard let view = panel.contentView else { return }
        let ok = DebugSnapshot.write(view: view, background: .clear, appearance: NSAppearance(named: .darkAqua), to: url)
        Log.app.info("dock snapshot -> \(url.path, privacy: .public) ok=\(ok)")
    }
}

@MainActor
final class AgentDockModel: ObservableObject {
    @Published private(set) var agentCount = 0
    @Published var expanded: UUID?          // the Clicky whose ask box is open
    @Published var draft = ""
    let agents: AgentRuntime
    let open: (UUID) -> Void
    private var cancellables = Set<AnyCancellable>()

    init(agents: AgentRuntime, open: @escaping (UUID) -> Void) {
        self.agents = agents
        self.open = open
        agentCount = agents.store.agents.count
        agents.store.$agents.map(\.count).receive(on: DispatchQueue.main).assign(to: &$agentCount)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = expanded, !text.isEmpty else { return }
        draft = ""
        expanded = nil
        agents.send(text, to: id)
    }
}

struct AgentDockView: View {
    static let slot: CGFloat = 92
    @ObservedObject var model: AgentDockModel
    @ObservedObject private var store: AgentStore
    @ObservedObject private var runtime: AgentRuntime
    @FocusState private var askFocused: Bool

    init(model: AgentDockModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.agents.store)
        _runtime = ObservedObject(wrappedValue: model.agents)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 0)
            ForEach(store.agents) { agent in
                clicky(agent)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .foregroundStyle(.white)
    }

    private func clicky(_ agent: Agent) -> some View {
        let running = runtime.isRunning(agent.id)
        let activity = runtime.activity[agent.id]
        let isExpanded = model.expanded == agent.id
        return VStack(spacing: 4) {
            if let activity, !activity.isEmpty {
                Text(activity)
                    .font(.system(size: 11))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.78)))
                    .frame(maxWidth: 200)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if isExpanded {
                HStack(spacing: 6) {
                    TextField("Ask \(agent.name)…", text: $model.draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($askFocused)
                        .onSubmit { model.send() }
                    Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(width: 220)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85)))
                .onAppear { askFocused = true }
            }
            Bobbing(active: running) {
                ClickyCharacterView(character: agent.look, mood: running ? .thinking : (activity == nil ? .awake : .happy), size: 64)
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .onTapGesture { model.open(agent.id) }
            .onHover { inside in
                if inside { model.expanded = agent.id } else if model.draft.isEmpty { model.expanded = nil }
            }
            HStack(spacing: 4) {
                Circle().fill(running ? Color.green : Color.white.opacity(0.35)).frame(width: 6, height: 6)
                Text(agent.name).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.7)))
        }
        .frame(width: Self.slot)
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: activity)
    }
}

/// Gentle up-and-down motion while a Clicky works.
struct Bobbing<Content: View>: View {
    var active: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            content().offset(y: active ? CGFloat(sin(t * 5)) * 4 : 0)
        }
    }
}
