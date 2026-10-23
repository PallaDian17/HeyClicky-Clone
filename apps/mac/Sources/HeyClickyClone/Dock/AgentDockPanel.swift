import AppKit
import Combine
import SwiftUI

/// Borderless panel that can take the keyboard without activating the app, so
/// the ask box under a Clicky accepts typing while another app stays frontmost.
final class DockPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The Clickys on the desktop: an always-on-top strip in the bottom-right
/// corner of the main screen, one mascot per Clicky. Idle ones blink; a working
/// one bobs with its current step in a bubble; a finished one shows its reply
/// for a while. Click a Clicky to open its ask box and type; Return sends (or
/// steers a running turn); Esc closes it; click the name to open it in Home.
@MainActor
final class AgentDockPanel {
    static let enabledKey = "ClickyDockEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private let panel: DockPanelWindow
    let model: AgentDockModel
    private var cancellables = Set<AnyCancellable>()

    init(agents: AgentRuntime, open: @escaping (UUID) -> Void) {
        model = AgentDockModel(agents: agents, open: open)
        panel = DockPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

        // Typing needs the panel to be key; closing the box gives the keyboard back.
        model.$expanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] expanded in
                guard let self else { return }
                if expanded != nil { self.panel.makeKeyAndOrderFront(nil) } else if self.panel.isKeyWindow { self.panel.resignKey() }
            }
            .store(in: &cancellables)
        model.$agentCount.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.layout() }.store(in: &cancellables)
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

    func hide() {
        model.expanded = nil
        panel.orderOut(nil)
    }

    func setVisible(_ on: Bool) { on ? show() : hide() }

    /// Opens the ask box under a Clicky (debug + Home shortcuts).
    func ask(_ agentID: UUID) {
        if !panel.isVisible { show() }
        model.expanded = agentID
    }

    /// Bottom-right of the main screen's visible area. The frame is fixed for a
    /// given Clicky count (the ask box and bubbles fit inside it), so nothing
    /// moves under the pointer when a box opens.
    private func layout() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let count = max(1, model.agentCount)
        let width = CGFloat(count) * AgentDockView.slot + 2 * AgentDockView.margin
        let height = AgentDockView.height
        let v = screen.visibleFrame
        panel.setFrame(NSRect(x: v.maxX - width - 8, y: v.minY + 6, width: width, height: height), display: true)
    }

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

    init(agents: AgentRuntime, open: @escaping (UUID) -> Void) {
        self.agents = agents
        self.open = open
        agentCount = agents.store.agents.count
        agents.store.$agents.map(\.count).receive(on: DispatchQueue.main).assign(to: &$agentCount)
    }

    func toggle(_ id: UUID) {
        if expanded == id { expanded = nil; draft = "" } else { expanded = id }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = expanded, !text.isEmpty else { return }
        draft = ""
        expanded = nil
        agents.send(text, to: id)      // steers when the Clicky is mid-turn
        Log.app.info("dock ask sent to \(self.agents.store.agent(id: id)?.slug ?? "?", privacy: .public) (\(text.count) chars)")
    }

    func cancel() {
        draft = ""
        expanded = nil
    }
}

struct AgentDockView: View {
    static let slot: CGFloat = 96
    static let margin: CGFloat = 120     // room for the ask box / bubble to overhang the slots
    static let height: CGFloat = 200
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
        .padding(.horizontal, Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .foregroundStyle(.white)
        .onExitCommand { model.cancel() }
    }

    private func clicky(_ agent: Agent) -> some View {
        let running = runtime.isRunning(agent.id)
        let activity = runtime.activity[agent.id]
        let isExpanded = model.expanded == agent.id
        return VStack(spacing: 5) {
            if isExpanded {
                HStack(spacing: 6) {
                    TextField(running ? "Add to what \(agent.name) is doing…" : "Ask \(agent.name)…", text: $model.draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($askFocused)
                        .onSubmit { model.send() }
                    Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 16)) }
                        .buttonStyle(.plain)
                        .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(width: 260)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.88)))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.15)))
                .onAppear { DispatchQueue.main.async { askFocused = true } }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let activity, !activity.isEmpty {
                Text(activity)
                    .font(.system(size: 11))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.78)))
                    .frame(maxWidth: 220)
                    .transition(.opacity)
            }
            Bobbing(active: running) {
                ClickyCharacterView(character: agent.look, mood: running ? .thinking : (isExpanded ? .listening : (activity == nil ? .awake : .happy)), size: 64)
            }
            .scaleEffect(isExpanded ? 1.06 : 1)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .contentShape(Rectangle())
            .onTapGesture { model.toggle(agent.id) }
            .help(isExpanded ? "Esc closes" : "Click to ask \(agent.name) something")
            Button { model.open(agent.id) } label: {
                HStack(spacing: 4) {
                    Circle().fill(running ? Color.green : Color.white.opacity(0.35)).frame(width: 6, height: 6)
                    Text(agent.name).font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .help("Open \(agent.name) in Home")
        }
        .frame(width: Self.slot)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.18), value: activity)
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
