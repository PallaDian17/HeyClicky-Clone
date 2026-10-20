import SwiftUI

/// The Home Space: agents on the left, a transcript and composer in the middle,
/// and the phase-1 setup panel reachable from the rail.
struct HomeSpaceView: View {
    let app: AppDelegate
    @ObservedObject private var runtime: AgentRuntime
    @ObservedObject private var store: AgentStore
    @State private var selection: Selection = .setup
    @State private var showNewAgent = false

    enum Selection: Hashable { case agent(UUID), setup }

    init(app: AppDelegate) {
        self.app = app
        _runtime = ObservedObject(wrappedValue: app.agents)
        _store = ObservedObject(wrappedValue: app.agents.store)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            detail
        }
        .onAppear {
            if case .setup = selection, let first = store.agents.first { selection = .agent(first.id) }
        }
        .sheet(isPresented: $showNewAgent) {
            NewAgentSheet { name, purpose in
                if let agent = try? store.create(name: name, purpose: purpose) {
                    selection = .agent(agent.id)
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                EyesView(mood: .awake).scaleEffect(1.1).padding(6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.black))
                Text("Clickys").font(.headline)
                Spacer()
                Button { showNewAgent = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New Clicky")
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.agents) { agent in
                        sidebarRow(agent)
                    }
                    if store.agents.isEmpty {
                        Text("No Clickys yet. Make one to give it a job.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
            Divider()
            Button {
                selection = .setup
            } label: {
                Label("Setup", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selection == .setup ? Color.accentColor.opacity(0.18) : .clear))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    private func sidebarRow(_ agent: Agent) -> some View {
        let selected = selection == .agent(agent.id)
        let running = runtime.isRunning(agent.id)
        return Button {
            selection = .agent(agent.id)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(agent.initial).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(running ? "Working…" : agent.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if running { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.folder(for: agent)]) }
            Button("Delete Clicky", role: .destructive) {
                runtime.stop(agent.id)
                store.delete(agent)
                if selection == .agent(agent.id) { selection = .setup }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .setup:
            HomeView(app: app)
        case .agent(let id):
            if let agent = store.agent(id: id) {
                AgentTranscriptView(agent: agent, runtime: runtime, store: store)
                    .id(agent.id)
            } else {
                Text("Pick a Clicky").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Transcript

struct AgentTranscriptView: View {
    let agent: Agent
    @ObservedObject var runtime: AgentRuntime
    @ObservedObject var store: AgentStore
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var entries: [TranscriptEntry] { runtime.transcript(for: agent.id) }
    private var running: Bool { runtime.isRunning(agent.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if entries.isEmpty {
                            Text("Give \(agent.name) its first job below. Its folder, persona and notes live on this Mac.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(entries) { entry in
                            TranscriptRow(entry: entry, agentName: agent.name)
                                .id(entry.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: entries.last?.text) { _, _ in
                    if let last = entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            composer
        }
        .onAppear { composerFocused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(agent.initial).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).font(.headline)
                Text(agent.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if running {
                Button("Stop") { runtime.stop(agent.id) }
            }
            if let model = runtime.modelLabel {
                Text(model).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask \(agent.name) to do something…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .focused($composerFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || running)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        draft = ""
        runtime.send(text, to: agent.id)
    }
}

struct TranscriptRow: View {
    let entry: TranscriptEntry
    let agentName: String

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(entry.text)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.25)))
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text(agentName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(entry.text.isEmpty && entry.streaming ? "…" : entry.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .command:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.caption)
                    Text(entry.text).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                    if entry.streaming { ProgressView().controlSize(.mini) }
                }
                .foregroundStyle(.secondary)
                if let out = entry.detail, !out.isEmpty {
                    Text(out.suffix(1200))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        .textSelection(.enabled)
                }
            }
        case .status:
            Label(entry.text, systemImage: "circle.dotted").font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - New agent

struct NewAgentSheet: View {
    var onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var purpose = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Clicky").font(.title3.weight(.semibold))
            Text("Give it a name and a job. It gets its own folder, persona and notes, and remembers across chats.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name (e.g. Stripe Radar)", text: $name).textFieldStyle(.roundedBorder)
            TextField("What it does (e.g. digs through refunds and finds churn)", text: $purpose, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(name.trimmingCharacters(in: .whitespaces), purpose.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || purpose.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}
