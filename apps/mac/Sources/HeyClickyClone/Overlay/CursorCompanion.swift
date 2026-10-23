import AppKit
import Combine
import SwiftUI

/// The tracker beside the mouse: a small blue ring that follows the pointer
/// and shows what Clicky is doing: a waveform while listening, a spinner while
/// thinking, the answer in a bubble while it speaks, a mic dot while dictating,
/// and a hint while the circle-to-ask overlay is armed. Click-through, always on
/// top, mirrors the notch's state so there is one source of truth.
@MainActor
final class CursorCompanionManager {
    static let modeKey = "ClickyCursorCompanion"
    enum Mode: String, CaseIterable, Identifiable {
        case talk, always, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .talk: return "While talking or dictating"
            case .always: return "Always"
            case .off: return "Off"
            }
        }
    }
    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .talk }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    let model = CursorCompanionModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var hintTask: Task<Void, Never>?
    private let size = CGSize(width: 360, height: 120)

    func bind(to notch: NotchViewModel) {
        notch.$state.receive(on: DispatchQueue.main).sink { [weak self] state in self?.mirror(state) }.store(in: &cancellables)
        apply(mode: Self.mode)
    }

    func apply(mode: Mode) {
        Self.mode = mode
        if mode == .off { model.state = .hidden; stopFollowing(); return }
        if model.state == .hidden, mode == .always { model.state = .idle }
        if model.state != .hidden { startFollowing() }
    }

    /// Debug/demo: force a state.
    func show(_ state: CursorCompanionModel.State) {
        model.state = state
        startFollowing()
    }

    func snapshot(to url: URL) {
        guard let view = panel?.contentView else { return }
        let ok = DebugSnapshot.write(view: view, background: .clear, appearance: NSAppearance(named: .darkAqua), to: url)
        Log.hud.info("cursor companion snapshot -> \(url.path, privacy: .public) ok=\(ok) state=\(String(describing: self.model.state), privacy: .public)")
    }

    private func mirror(_ state: NotchState) {
        guard Self.mode != .off else { return }
        hintTask?.cancel()
        switch state {
        case .listening:
            model.state = .listening(hint: "Talk, or circle anything to ask about it")
            hintTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3.5))
                guard let self, !Task.isCancelled, case .listening = self.model.state else { return }
                self.model.state = .listening(hint: nil)
            }
        case .thinking:
            model.state = .thinking
        case .reply(let text):
            model.state = .speaking(text)
        case .dictating(let text):
            model.state = .dictating(text)
        case .dictated(let text):
            model.state = .speaking(text)
        case .agent(let name, let step):
            model.state = Self.mode == .always ? .speaking("\(name): \(step)") : .hidden
        case .notice(let text):
            model.state = Self.mode == .always ? .speaking(text) : (model.state == .hidden ? .hidden : .speaking(text))
        case .idle, .prompt, .suggestions:
            model.state = Self.mode == .always ? .idle : .hidden
        }
        model.state == .hidden ? stopFollowing() : startFollowing()
    }

    private func startFollowing() {
        if panel == nil { build() }
        follow()
        panel?.orderFrontRegardless()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.follow() }
        }
    }

    private func stopFollowing() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    /// Places the ring just below-right of the pointer, keeping the bubble on screen.
    private func follow() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        var origin = CGPoint(x: mouse.x + 14 - CursorCompanionView.ringInset, y: mouse.y - size.height + 24)
        let v = screen.visibleFrame
        origin.x = min(origin.x, v.maxX - size.width)
        origin.y = max(origin.y, v.minY)
        if origin.x < v.minX { origin.x = v.minX }
        panel.setFrameOrigin(origin)
    }

    private func build() {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Cursor companion"
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CursorCompanionView(model: model))
        self.panel = panel
    }
}

@MainActor
final class CursorCompanionModel: ObservableObject {
    enum State: Equatable {
        case hidden, idle, listening(hint: String?), thinking, speaking(String), dictating(String)
    }
    @Published var state: State = .hidden
}

struct CursorCompanionView: View {
    static let ringInset: CGFloat = 10
    @ObservedObject var model: CursorCompanionModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ring
                .frame(width: 30, height: 30)
                .padding(.top, 2)
            bubble
            Spacer(minLength: 0)
        }
        .padding(Self.ringInset)
        .frame(width: 360, height: 120, alignment: .topLeading)
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.18), value: model.state)
    }

    @ViewBuilder private var ring: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .idle:
            Circle().stroke(Color(nsColor: .systemBlue), lineWidth: 2.5).frame(width: 14, height: 14)
                .shadow(color: Color(nsColor: .systemBlue).opacity(0.7), radius: 5)
        case .listening:
            ZStack {
                Circle().fill(Color(nsColor: .systemBlue).opacity(0.25))
                Circle().stroke(Color(nsColor: .systemBlue), lineWidth: 2.5)
                WaveformBars().scaleEffect(0.55)
            }
            .shadow(color: Color(nsColor: .systemBlue).opacity(0.8), radius: 7)
        case .thinking:
            ZStack {
                Circle().stroke(Color(nsColor: .systemBlue).opacity(0.3), lineWidth: 2.5)
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
                    Circle().trim(from: 0, to: 0.3).stroke(Color(nsColor: .systemBlue), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(angle))
                }
            }
            .shadow(color: Color(nsColor: .systemBlue).opacity(0.7), radius: 6)
        case .speaking:
            ZStack {
                Circle().fill(Color(nsColor: .systemBlue))
                Image(systemName: "waveform").font(.system(size: 12, weight: .bold))
            }
            .shadow(color: Color(nsColor: .systemBlue).opacity(0.8), radius: 7)
        case .dictating:
            ZStack {
                Circle().fill(Color(nsColor: .systemPurple))
                Image(systemName: "mic.fill").font(.system(size: 12, weight: .bold))
            }
            .shadow(color: Color(nsColor: .systemPurple).opacity(0.8), radius: 7)
        }
    }

    @ViewBuilder private var bubble: some View {
        let text: String? = {
            switch model.state {
            case .listening(let hint): return hint
            case .speaking(let t): return t
            case .dictating(let t): return t.isEmpty ? "Listening…" : t
            default: return nil
            }
        }()
        if let text, !text.isEmpty {
            Text(text)
                .font(.system(size: 12))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.82)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12)))
                .frame(maxWidth: 290, alignment: .leading)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
        }
    }
}
