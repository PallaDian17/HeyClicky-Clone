import AppKit
import SwiftUI

// The Clicky pages of the notch panel, as recorded: the menu-bar popover list
// of Clickys (avatar, last message, day, unread dot) and a Clicky's own chat
// (list on the left, thread + coloured suggestion cards on the right, the
// mascot peeking over a ledge, push-to-talk straight into this Clicky).

/// What was last said in a Clicky's thread, for the list rows.
struct ClickyRowInfo {
    var line: String
    var day: String
    var unread: Bool

    @MainActor
    static func make(for agent: Agent, runtime: AgentRuntime, model: NotchViewModel) -> ClickyRowInfo {
        let entries = runtime.transcript(for: agent.id)
        let last = entries.last { $0.role == .assistant || $0.role == .user || $0.role == .error }
        let line: String
        if runtime.isRunning(agent.id) { line = runtime.activity[agent.id] ?? "Working…" }
        else if let last { line = (last.role == .user ? "You: " : "") + last.text.replacingOccurrences(of: "\n", with: " ") }
        else { line = agent.purpose }
        let when = last?.timestamp ?? agent.lastActivity
        let day: String
        if let when {
            if Calendar.current.isDateInToday(when) { day = when.formatted(date: .omitted, time: .shortened) }
            else if Calendar.current.isDateInYesterday(when) { day = "Yesterday" }
            else { day = when.formatted(.dateTime.weekday(.wide)) }
        } else { day = "" }
        let unread: Bool = {
            guard let last, last.role != .user else { return false }
            return last.timestamp > (model.seenAt[agent.id] ?? .distantPast)
        }()
        return ClickyRowInfo(line: line, day: day, unread: unread)
    }
}

/// The menu-bar popover: every Clicky as a row.
struct ClickyListView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var runtime: AgentRuntime
    @ObservedObject var store: AgentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeader(model: model, title: "Clickys")
            VStack(spacing: 2) {
                ForEach(store.agents) { agent in
                    let info = ClickyRowInfo.make(for: agent, runtime: runtime, model: model)
                    Button { model.openClicky(agent.id) } label: {
                        HStack(spacing: 10) {
                            ClickyCharacterView(character: agent.look, mood: runtime.isRunning(agent.id) ? .thinking : .awake, size: 30, animated: false)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(agent.name).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(info.day).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                                }
                                Text(info.line).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                            }
                            if info.unread { Circle().fill(Color.blue).frame(width: 8, height: 8) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if store.agents.isEmpty {
                    Text("No Clickys yet.").font(.callout).foregroundStyle(.white.opacity(0.6)).padding()
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button { model.app?.openHome(); model.collapse(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .homeSpaceSetup, object: nil) } } label: {
                    Label("Apps", systemImage: "plus").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                Spacer()
                Button { model.app?.openHome(); model.collapse(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .homeSpaceNewClicky, object: nil) } } label: {
                    Label("New Clicky", systemImage: "sparkles").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }
}

/// A Clicky's chat inside the panel.
struct ClickyChatView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var runtime: AgentRuntime
    @ObservedObject var store: AgentStore
    let agentID: UUID
    @State private var search = ""
    @State private var draft = ""

    private var agent: Agent? { store.agent(id: agentID) }
    private var filtered: [Agent] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? store.agents : store.agents.filter { $0.name.lowercased().contains(q) || $0.purpose.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PanelHeader(model: model)
            }
            HStack(spacing: 10) {
                sidebar.frame(width: 190)
                if let agent { chat(agent) } else { Text("This Clicky is gone.").foregroundStyle(.white.opacity(0.6)) }
            }
        }
        .padding(.top, 6)
        .onAppear { model.markSeen(agentID) }
        .onChange(of: runtime.transcript(for: agentID).last?.id) { _, _ in model.markSeen(agentID) }
    }

    private var sidebar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    TextField("Search", text: $search).textFieldStyle(.plain).font(.system(size: 11))
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                Button { model.app?.openHome(); model.collapse(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .homeSpaceNewClicky, object: nil) } } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain).help("New Clicky")
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filtered) { a in
                        let info = ClickyRowInfo.make(for: a, runtime: runtime, model: model)
                        Button { model.openClicky(a.id) } label: {
                            HStack(spacing: 8) {
                                ClickyCharacterView(character: a.look, mood: .awake, size: 24, animated: false)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.name).font(.system(size: 12, weight: a.id == agentID ? .bold : .medium))
                                    Text(info.line).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if info.unread { Circle().fill(Color.blue).frame(width: 7, height: 7) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(a.id == agentID ? .white.opacity(0.14) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(NSFullUserName().split(separator: " ").first.map(String.init) ?? "You").font(.system(size: 11, weight: .medium))
                Spacer()
                Button { model.set(.settings) } label: { Image(systemName: "gearshape").font(.system(size: 11)) }.buttonStyle(.plain)
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 6).padding(.top, 4)
        }
    }

    private func chat(_ agent: Agent) -> some View {
        let entries = runtime.transcript(for: agent.id).filter { $0.role == .user || $0.role == .assistant || $0.role == .error }
        let talking = model.pushToTalk?.agentID == agent.id ? model.pushToTalk : nil
        return VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if entries.isEmpty {
                            bubble("Hi, I'm \(agent.name). \(agent.purpose.prefix(1).uppercased() + agent.purpose.dropFirst())", mine: false)
                            if !agent.firstMessages.isEmpty {
                                Text("Suggested: send one and I'll get started").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).padding(.top, 4)
                                HStack(alignment: .top, spacing: 8) {
                                    ForEach(Array(agent.firstMessages.prefix(3).enumerated()), id: \.offset) { i, text in
                                        SuggestionCard(text: text, tint: SuggestionCard.tints[i % SuggestionCard.tints.count]) {
                                            runtime.send(text, to: agent.id)
                                        }
                                    }
                                }
                            }
                        }
                        ForEach(entries.suffix(8)) { e in
                            bubble(e.text, mine: e.role == .user, error: e.role == .error).id(e.id)
                        }
                        if let line = runtime.activity[agent.id], runtime.isRunning(agent.id) {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(line).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
                }
                .onChange(of: entries.last?.text) { _, _ in if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onAppear { if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            // The ledge: mascot peeking over the talk pill + Type field.
            ZStack(alignment: .topLeading) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: talking == nil ? "mic.fill" : "waveform")
                        if let talking {
                            Text(talking.text.isEmpty ? "Speaking…" : talking.text).lineLimit(1).truncationMode(.head)
                            Text("· Release to send").foregroundStyle(.white.opacity(0.8))
                        } else {
                            Text("Hold \(HotkeyMonitor.talkLabel) to talk to \(agent.name)")
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(LinearGradient(colors: talking == nil ? [Color(red: 0.25, green: 0.5, blue: 1), Color(red: 0.15, green: 0.35, blue: 0.9)] : [Color(red: 0.2, green: 0.7, blue: 0.5), Color(red: 0.1, green: 0.55, blue: 0.4)], startPoint: .leading, endPoint: .trailing)))
                    TextField("Type…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(width: 170)
                        .background(Capsule().fill(.white.opacity(0.1)))
                        .onSubmit {
                            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            draft = ""
                            runtime.send(t, to: agent.id)
                        }
                    if runtime.isRunning(agent.id) {
                        Button { runtime.stop(agent.id) } label: { Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 30, height: 30).background(Circle().fill(.white.opacity(0.12))) }
                            .buttonStyle(.plain).help("Stop")
                    }
                }
                .padding(.top, 14)
                ClickyCharacterView(character: agent.look, mood: talking == nil ? (runtime.isRunning(agent.id) ? .thinking : .awake) : .listening, size: 28, animated: true)
                    .offset(x: 12, y: -6)
            }
        }
    }

    private func bubble(_ text: String, mine: Bool, error: Bool = false) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(text.prefix(600) + (text.count > 600 ? "…" : ""))
                .font(.system(size: 12))
                .foregroundStyle(error ? Color.red : .white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(mine ? Color(red: 0.2, green: 0.45, blue: 0.95) : .white.opacity(0.1)))
                .frame(maxWidth: 420, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 40) }
        }
    }
}

/// A coloured starter card with a send arrow.
struct SuggestionCard: View {
    let text: String
    let tint: Color
    let send: () -> Void
    static let tints: [Color] = [
        Color(red: 1.0, green: 0.93, blue: 0.6), Color(red: 1.0, green: 0.8, blue: 0.87), Color(red: 0.76, green: 0.87, blue: 1.0),
    ]

    var body: some View {
        Button(action: send) {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 11, weight: .medium)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Image(systemName: "arrow.up.circle.fill").font(.system(size: 16)) }
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint))
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Send to this Clicky")
    }
}
