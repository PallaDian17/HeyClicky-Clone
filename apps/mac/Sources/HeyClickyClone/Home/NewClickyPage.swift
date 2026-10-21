import SwiftUI

/// The New Clicky page: a short interview that ends in a founded agent.
/// Also offers a quick form for people who already know what they want.
@MainActor
final class NewClickyModel: ObservableObject {
    struct Line: Identifiable, Equatable { let id = UUID(); var role: String; var text: String }

    @Published private(set) var lines: [Line] = []
    @Published var draft = ""
    @Published private(set) var busy = false
    @Published private(set) var brief: BackendClient.InterviewBrief?
    @Published var error: String?

    private let backend: BackendClient
    private let store: AgentStore
    private var started = false

    init(backend: BackendClient, store: AgentStore) {
        self.backend = backend
        self.store = store
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await exchange() }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, brief == nil else { return }
        draft = ""
        lines.append(Line(role: "user", text: text))
        Task { await exchange() }
    }

    private func exchange() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let turns = lines.map { BackendClient.InterviewTurn(role: $0.role, text: $0.text) }
            let response = try await backend.interview(turns: turns, existingNames: store.agents.map(\.name))
            lines.append(Line(role: "assistant", text: response.reply))
            if response.done, let brief = response.brief { self.brief = brief }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach the backend."
        }
    }

    /// Founds the agent from the brief and returns it.
    func found() -> Agent? {
        guard let brief else { return nil }
        let notes = brief.notes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return try? store.create(name: brief.name, purpose: brief.purpose, notes: notes, firstMessages: brief.first_messages)
    }

    func reset() {
        lines = []
        brief = nil
        draft = ""
        started = false
        start()
    }
}

struct NewClickyPage: View {
    @ObservedObject var model: NewClickyModel
    let store: AgentStore
    var onFounded: (Agent) -> Void

    @State private var quickName = ""
    @State private var quickPurpose = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                EyesView(mood: .happy).scaleEffect(1.3).padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.black))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Clicky").font(.headline)
                    Text("Tell it what you want help with. A couple of questions, then it's founded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start over") { model.reset() }.disabled(model.lines.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.lines) { line in
                            if line.role == "user" {
                                HStack { Spacer(minLength: 60)
                                    Text(line.text).font(.system(size: 13))
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.25)))
                                }
                            } else {
                                HStack(alignment: .top, spacing: 8) {
                                    EyesView(mood: .awake).scaleEffect(0.8).padding(5)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(.black))
                                    Text(line.text).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        if model.busy { ThinkingDots().padding(.leading, 40).colorInvert() }
                        if let brief = model.brief { briefCard(brief).id("brief") }
                        if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    }
                    .padding(16)
                }
                .onChange(of: model.lines.count) { _, _ in
                    if let last = model.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: model.brief?.name) { _, _ in withAnimation { proxy.scrollTo("brief", anchor: .bottom) } }
            }

            Divider()
            if model.brief == nil {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Answer here…", text: $model.draft, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.plain).font(.system(size: 13)).padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                        .focused($focused)
                        .onSubmit(model.send)
                    Button(action: model.send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)) }
                        .buttonStyle(.plain).disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                }
                .padding(12)
                quickForm
            }
        }
        .onAppear { model.start(); focused = true }
    }

    private func briefCard(_ brief: BackendClient.InterviewBrief) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(String(brief.name.prefix(1))).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                }.frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(brief.name).font(.headline)
                    Text(brief.purpose).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !brief.notes.isEmpty {
                Text(brief.notes).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("FIRST ASKS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(brief.first_messages, id: \.self) { m in
                    Label(m, systemImage: "bubble.left").font(.caption)
                }
            }
            HStack {
                Spacer()
                Button("Found \(brief.name)") {
                    if let agent = model.found() { onFounded(agent) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var quickForm: some View {
        DisclosureGroup("Know exactly what you want? Create it directly") {
            HStack(spacing: 8) {
                TextField("Name", text: $quickName).textFieldStyle(.roundedBorder).frame(width: 160)
                TextField("What it does", text: $quickPurpose).textFieldStyle(.roundedBorder)
                Button("Create") {
                    if let agent = try? store.create(name: quickName.trimmingCharacters(in: .whitespaces), purpose: quickPurpose.trimmingCharacters(in: .whitespaces)) {
                        onFounded(agent)
                    }
                }
                .disabled(quickName.trimmingCharacters(in: .whitespaces).isEmpty || quickPurpose.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 6)
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
}
