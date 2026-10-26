import AppKit
import SwiftUI

// The notch panel as the app's main surface, as recorded: a greeting, a
// corkboard of Clicky cards, the talk thread, and settings, all dropping
// from the menu bar. The Home window stays as the pop-out.

/// Header shared by the expanded panel pages: home · chat on the left,
/// "Update app" · pop-out · gear on the right.
struct PanelHeader: View {
    @ObservedObject var model: NotchViewModel
    var title: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Button { model.set(.home) } label: {
                ClickyCharacterView(character: model.character, mood: .awake, size: 22, animated: false)
            }
            .buttonStyle(.plain).help("Home")
            Button { model.openConversation() } label: { Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Talk thread")
            if let title { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8)) }
            Spacer()
            if let app = model.app, app.updates.lastResult.hasPrefix("Update available") {
                Button { app.checkForUpdates() } label: {
                    Text("Update app").font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange))
                }
                .buttonStyle(.plain)
            }
            Button { model.app?.openHome(); model.collapse() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Open the full window")
            Button { model.set(.settings) } label: { Image(systemName: "gearshape.fill").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Settings")
        }
    }
}

/// Greeting + corkboard + footer.
struct HomePanelView: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(model: model)
            VStack(spacing: 2) {
                Text(Self.greeting).font(.system(size: 17, weight: .bold))
                Text("Hold ⌃ Control + ⌥ Option and tell me what to take off your plate.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            if let app = model.app {
                CorkboardView(model: model, runtime: app.agents, store: app.agents.store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button { model.app?.openHome(); model.collapse(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .homeSpaceNewClicky, object: nil) } } label: {
                    Label("New Clicky", systemImage: "plus").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                Spacer()
                Button { model.app?.openHome(); model.collapse(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .homeSpaceSetup, object: nil) } } label: {
                    Label("Apps", systemImage: "square.grid.2x2").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Night" : hour < 12 ? "Morning" : hour < 17 ? "Afternoon" : "Evening"
        let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? "\(part)." : "\(part), \(name)."
    }
}

/// The selected Clicky's card in the middle, the others as sticky notes.
struct CorkboardView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var runtime: AgentRuntime
    @ObservedObject var store: AgentStore

    private var selected: Agent? {
        if let id = model.selectedAgentID, let a = store.agent(id: id) { return a }
        return store.agents.first
    }

    var body: some View {
        let others = store.agents.filter { $0.id != selected?.id }
        ZStack {
            // Sticky notes behind, fanned to the sides.
            ForEach(Array(others.prefix(6).enumerated()), id: \.element.id) { i, agent in
                StickyNote(agent: agent, card: runtime.card(for: agent), tint: Self.noteColors[i % Self.noteColors.count])
                    .rotationEffect(.degrees(Double(i % 2 == 0 ? -6 : 5) + Double(i) * 1.5))
                    .offset(x: i % 2 == 0 ? -185 + CGFloat(i / 2) * 12 : 185 - CGFloat(i / 2) * 12,
                            y: -70 + CGFloat(i / 2) * 68)
                    .onTapGesture { model.selectedAgentID = agent.id }
                    .zIndex(0)
            }
            if let agent = selected {
                AgentCard(agent: agent, card: runtime.card(for: agent), latestOutput: Self.latestOutput(for: agent, store: store), model: model)
                    .frame(width: 330)
                    .zIndex(1)
            } else {
                Text("No Clickys yet. Press New Clicky to found one.").font(.callout).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static let noteColors: [Color] = [
        Color(red: 1.0, green: 0.95, blue: 0.72), Color(red: 1.0, green: 0.82, blue: 0.9),
        Color(red: 0.8, green: 0.93, blue: 1.0), Color(red: 0.84, green: 0.98, blue: 0.84),
        Color(red: 1.0, green: 0.88, blue: 0.78), Color(red: 0.9, green: 0.86, blue: 1.0),
    ]

    /// Newest file in output/ written within 20 minutes of the Clicky's last activity.
    static func latestOutput(for agent: Agent, store: AgentStore) -> URL? {
        guard let last = agent.lastActivity else { return nil }
        let files = store.outputFiles(for: agent)
        return files.first { url in
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return abs(m.timeIntervalSince(last)) < 20 * 60
        }
    }
}

struct AgentCard: View {
    let agent: Agent
    let card: AgentRuntime.Card
    let latestOutput: URL?
    @ObservedObject var model: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(card.tag == .needsYou ? Color.red : card.tag == .working ? Color.green : Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                Spacer()
                Text(card.tag.label).font(.system(size: 10, weight: .bold)).foregroundStyle(card.tag.color)
                Spacer()
                ClickyCharacterView(character: agent.look, mood: card.tag == .working ? .thinking : .awake, size: 20, animated: false)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.black.opacity(0.05))
            VStack(alignment: .leading, spacing: 6) {
                Text(agent.name).font(.system(size: 15, weight: .bold))
                Text(card.line).font(.system(size: 12)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DotPaper())
            HStack(spacing: 8) {
                if let file = latestOutput {
                    Button { NSWorkspace.shared.open(file) } label: {
                        Label("Open \(file.pathExtension.uppercased().isEmpty ? "file" : file.pathExtension.uppercased())", systemImage: "doc")
                    }
                    .controlSize(.small)
                }
                Button {
                    model.app?.openHome(); model.collapse()
                    let id = agent.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .homeSpaceSelectAgent, object: id) }
                } label: { Label("Full report", systemImage: "doc.text") }
                .controlSize(.small)
                Spacer()
                if card.tag == .working {
                    Button("Stop") { model.app?.agents.stop(agent.id) }.controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.black.opacity(0.06))
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.97, green: 0.97, blue: 0.99)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.4)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

struct StickyNote: View {
    let agent: Agent
    let card: AgentRuntime.Card
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(card.tag.label).font(.system(size: 8, weight: .bold)).foregroundStyle(card.tag.color)
            Text(agent.name).font(.system(size: 11, weight: .bold))
            Text(card.line).font(.system(size: 9)).lineLimit(2)
        }
        .foregroundStyle(Color.black.opacity(0.8))
        .padding(8)
        .frame(width: 118, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(tint))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
        .help("Click to bring \(agent.name) forward")
    }
}

/// The dotted-paper background of the centre card.
struct DotPaper: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 9
            var y: CGFloat = 4
            while y < size.height {
                var x: CGFloat = 4
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(.black.opacity(0.12)))
                    x += step
                }
                y += step
            }
        }
    }
}

/// Settings inside the panel: the Setup page with a sidebar of jump points.
struct SettingsPanelView: View {
    @ObservedObject var model: NotchViewModel
    static let sections: [(String, String)] = [
        ("Backend", "server.rack"), ("Talk", "waveform"), ("Permissions", "hand.raised"), ("Character", "face.smiling"),
        ("Dictation", "text.cursor"), ("Routines", "clock.arrow.2.circlepath"), ("Integrations", "link"),
        ("Computer use", "cursorarrow.click"), ("Privacy guard", "lock.shield"), ("Updates", "arrow.down.circle"), ("Developer", "hammer"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(model: model, title: "Settings")
            if let app = model.app {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Self.sections, id: \.0) { name, symbol in
                            Button { NotificationCenter.default.post(name: .setupScrollTo, object: name) } label: {
                                Label(name, systemImage: symbol).font(.system(size: 11, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Text("Hi Dicky \(AppConfig.version) (\(AppConfig.build))").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).padding(8)
                    }
                    .frame(width: 150)
                    .background(Color.white.opacity(0.04))
                    HomeView(app: app)
                        .colorScheme(.dark)
                        .background(Color.white.opacity(0.03))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.top, 6)
    }
}

extension Notification.Name {
    static let setupScrollTo = Notification.Name("SetupScrollTo")
}
