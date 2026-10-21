import SwiftUI
import UniformTypeIdentifiers

/// The Home Space: agents on the left, a transcript and composer in the middle,
/// the agent's output on the right, and the New Clicky and Setup pages.
struct HomeSpaceView: View {
    let app: AppDelegate
    @ObservedObject private var runtime: AgentRuntime
    @ObservedObject private var store: AgentStore
    @StateObject private var newClicky: NewClickyModel
    @State private var selection: Selection = .setup

    enum Selection: Hashable { case agent(UUID), newClicky, setup }

    init(app: AppDelegate) {
        self.app = app
        _runtime = ObservedObject(wrappedValue: app.agents)
        _store = ObservedObject(wrappedValue: app.agents.store)
        _newClicky = StateObject(wrappedValue: NewClickyModel(backend: app.backend, store: app.agents.store))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 232)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            detail
        }
        .onAppear {
            if case .setup = selection, let first = store.agents.first { selection = .agent(first.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeSpaceSelectAgent)) { note in
            if let id = note.object as? UUID { selection = .agent(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeSpaceNewClicky)) { _ in
            selection = .newClicky
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeSpaceSetup)) { _ in
            selection = .setup
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
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.agents) { agent in
                        sidebarRow(agent)
                    }
                    newClickyRow
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

    private var newClickyRow: some View {
        Button {
            selection = .newClicky
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).foregroundStyle(.secondary)
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                }
                .frame(width: 26, height: 26)
                Text("New Clicky").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selection == .newClicky ? Color.accentColor.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sidebarRow(_ agent: Agent) -> some View {
        let selected = selection == .agent(agent.id)
        let running = runtime.isRunning(agent.id)
        return Button {
            selection = .agent(agent.id)
        } label: {
            HStack(spacing: 10) {
                AgentAvatar(agent: agent, size: 26)
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
        case .newClicky:
            NewClickyPage(model: newClicky, store: store) { agent in
                selection = .agent(agent.id)
                newClicky.reset()
            }
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

extension Notification.Name {
    static let homeSpaceSelectAgent = Notification.Name("HomeSpaceSelectAgent")
    static let homeSpaceNewClicky = Notification.Name("HomeSpaceNewClicky")
    static let homeSpaceSetup = Notification.Name("HomeSpaceSetup")
}

struct AgentAvatar: View {
    let agent: Agent
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(agent.initial).font(.system(size: size * 0.46, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Transcript

struct AgentTranscriptView: View {
    let agent: Agent
    @ObservedObject var runtime: AgentRuntime
    @ObservedObject var store: AgentStore
    @StateObject private var outputs = OutputFolderWatcher()
    @State private var draft = ""
    @State private var attachments: [URL] = []
    @State private var dropHighlight = false
    @FocusState private var composerFocused: Bool

    private var entries: [TranscriptEntry] { runtime.transcript(for: agent.id) }
    private var running: Bool { runtime.isRunning(agent.id) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                transcript
                Divider()
                composer
            }
            Divider()
            OutputColumn(watcher: outputs, folder: store.folder(for: agent))
                .frame(width: 260)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear {
            composerFocused = true
            outputs.watch(agent: agent, store: store)
        }
        .onDisappear { outputs.stop() }
        .onChange(of: running) { _, isRunning in if !isRunning { outputs.refresh() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AgentAvatar(agent: agent, size: 32)
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

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Give \(agent.name) its first job. Its folder, persona and notes live on this Mac, and it remembers across chats.")
                                .foregroundStyle(.secondary)
                            if !agent.firstMessages.isEmpty {
                                FirstMessageCards(agent: agent) { message in
                                    runtime.send(message, to: agent.id)
                                }
                            }
                        }
                        .padding(.top, 20)
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
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(attachments, id: \.self) { file in
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip").font(.caption2)
                            Text(file.lastPathComponent).font(.caption).lineLimit(1)
                            Button { attachments.removeAll { $0 == file } } label: { Image(systemName: "xmark").font(.caption2) }
                                .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask \(agent.name) to do something… (drop files here)", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(dropHighlight ? Color.accentColor : .clear, lineWidth: 2))
                    .focused($composerFocused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) || running)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let copied = store.attach(files: urls, to: agent)
            attachments.append(contentsOf: copied)
            return !copied.isEmpty
        } isTargeted: { dropHighlight = $0 }
    }

    private func send() {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), !running else { return }
        if !attachments.isEmpty {
            let list = attachments.map { "tmp/attachments/\($0.lastPathComponent)" }.joined(separator: ", ")
            text += (text.isEmpty ? "" : "\n\n") + "Attached files (in this folder): \(list)"
        }
        draft = ""
        attachments = []
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
                if entry.text.isEmpty && entry.streaming {
                    Text("…").font(.system(size: 13))
                } else {
                    MarkdownText(text: entry.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
