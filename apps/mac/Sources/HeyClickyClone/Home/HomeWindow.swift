import AppKit
import SwiftUI

@MainActor
final class HomeWindowController {
    let window: NSWindow

    init(app: AppDelegate) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "HeyClicky Clone"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        window.contentView = NSHostingView(rootView: HomeSpaceView(app: app))
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Placeholder for the Home Space. Phase 1 uses it as a control panel to
/// exercise the HUD, permissions and auth.
struct HomeView: View {
    let app: AppDelegate
    @ObservedObject private var auth: AuthManager
    @ObservedObject private var permissions: PermissionsModel
    @ObservedObject private var notch: NotchViewModel
    @ObservedObject private var computerUse: ComputerUseHost
    @ObservedObject private var privacy: PrivacyMonitor
    @ObservedObject private var routines: RoutineStore
    @ObservedObject private var dictionary: DictationDictionary
    @ObservedObject private var integrations: IntegrationsHost
    @State private var newWord = ""
    @State private var newConnectorName = ""
    @State private var newConnectorURL = ""
    @State private var newConnectorAuth: CustomConnector.Auth = .oauth
    @State private var newConnectorToken = ""
    @State private var newProtectedApp = ""

    init(app: AppDelegate) {
        self.app = app
        _auth = ObservedObject(wrappedValue: app.auth)
        _permissions = ObservedObject(wrappedValue: app.permissions)
        _notch = ObservedObject(wrappedValue: app.notch.model)
        _computerUse = ObservedObject(wrappedValue: app.computerUse)
        _privacy = ObservedObject(wrappedValue: app.privacy)
        _routines = ObservedObject(wrappedValue: app.routines)
        _dictionary = ObservedObject(wrappedValue: app.dictation.dictionary)
        _integrations = ObservedObject(wrappedValue: app.integrations)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                EyesView(mood: .awake)
                    .scaleEffect(1.4)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.black))
                VStack(alignment: .leading, spacing: 2) {
                    Text("HeyClicky Clone").font(.title2.weight(.semibold))
                    Text("Phase 1: menubar, notch HUD, hotkey, permissions, sign-in")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            section("Account") {
                HStack {
                    switch auth.state {
                    case .signedIn(let email):
                        Label(email, systemImage: "person.crop.circle.fill")
                        Spacer()
                        Button("Sign out") { app.signOut() }
                    case .signedOut:
                        Label("Not signed in", systemImage: "person.crop.circle")
                        Spacer()
                        Button("Sign in…") { app.showSignIn() }
                    case .loading:
                        ProgressView().controlSize(.small)
                        Text("Restoring session…")
                    case .unconfigured:
                        Label("Supabase not configured", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("Set SUPABASE_URL / SUPABASE_ANON_KEY in .env and rebuild")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            section("Permissions") {
                HStack {
                    let granted = PermissionsModel.Kind.allCases.filter { permissions.status($0) == .granted }.count
                    Label("\(granted) of \(PermissionsModel.Kind.allCases.count) granted",
                          systemImage: permissions.allGranted ? "checkmark.shield.fill" : "shield")
                    Spacer()
                    Button("Manage…") { app.showPermissions() }
                }
            }

            section("Hotkey") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Double-tap ⌃ Control to open the prompt box. Double-tap and hold to talk.")
                        Spacer()
                        let ready = app.hotkey.isRunning && permissions.status(.accessibility) == .granted
                        Circle()
                            .fill(ready ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(ready ? "hotkey ready" : "needs Accessibility")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            section("Dictation") {
                Text("Hold ⌥ Option, speak, release: the text is cleaned up for the field you are in and pasted there. Never into password fields or protected apps. Words you correct right after are learned.")
                    .font(.callout)
                HStack(spacing: 8) {
                    TextField("Add a name or term speech-to-text gets wrong", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addWord)
                    Button("Add", action: addWord)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !dictionary.words.isEmpty {
                    FlowChips(items: dictionary.words) { word in dictionary.words.removeAll { $0 == word } }
                }
            }

            section("Routines") {
                if routines.routines.isEmpty {
                    Text("None yet. Ask a Clicky to do something every morning or every hour and it becomes a routine here; the morning cards in the notch can add them too.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(routines.routines) { routine in
                        RoutineRow(routine: routine, agentName: app.agents.store.agent(id: routine.agentID)?.name ?? "?",
                                   onRun: { routines.runNow(routine.id); app.scheduler.tick() },
                                   onPause: { routines.setPaused(routine.id, !routine.paused) },
                                   onDelete: { routines.remove(routine.id) })
                    }
                }
            }

            section("Integrations") {
                if integrations.composioConfigured {
                    Text("Online accounts through Composio. Connect one and every Clicky can use it.").font(.callout)
                    ForEach(integrations.toolkits) { toolkit in
                        HStack {
                            Text(toolkit.name).font(.callout)
                            Text(toolkit.connected ? "connected" : "not connected").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if toolkit.connected {
                                Button("Disconnect") { Task { await integrations.disconnectComposio(toolkit.slug) } }.controlSize(.small)
                            } else {
                                Button("Connect") { Task { await integrations.connectComposio(toolkit.slug) } }.controlSize(.small)
                            }
                        }
                    }
                    Toggle("Allow Composio tools that send, delete or pay", isOn: $integrations.composioAllowSensitive).font(.caption)
                } else {
                    Text("Composio is not configured on the backend (set COMPOSIO_API_KEY to offer Gmail, Notion, Slack and friends). Custom connectors below work without it.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 2)
                Text("Custom connectors: any remote MCP server, signed in through its own OAuth or an access token.").font(.callout)
                ForEach(integrations.connectors) { connector in
                    ConnectorRow(connector: connector, host: integrations)
                }
                HStack(spacing: 8) {
                    TextField("Name", text: $newConnectorName).textFieldStyle(.roundedBorder).frame(width: 140)
                    TextField("https://host/mcp", text: $newConnectorURL).textFieldStyle(.roundedBorder)
                    Picker("", selection: $newConnectorAuth) {
                        ForEach(CustomConnector.Auth.allCases) { Text($0.label).tag($0) }
                    }.frame(width: 150)
                    if newConnectorAuth == .bearer {
                        SecureField("token", text: $newConnectorToken).textFieldStyle(.roundedBorder).frame(width: 140)
                    }
                    Button("Add", action: addConnector)
                        .disabled(newConnectorName.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: newConnectorURL)?.host == nil)
                }
                if let msg = integrations.lastMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            section("Computer use") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Let Clickys click and type in your apps, in the background, without stealing focus.")
                        Text(computerUseStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { computerUse.isEnabled }, set: { computerUse.isEnabled = $0 }))
                        .toggleStyle(.switch)
                        .disabled(!computerUse.isAvailable)
                }
            }

            section("Privacy guard") {
                Text("Always on. Nothing is captured while a password field is active, in password managers, banking or wallet apps, or on payment, sign-in and verification pages. One-time codes and card numbers are redacted from anything sent or stored. Agents never read the clipboard.")
                    .font(.callout)
                HStack(spacing: 8) {
                    TextField("Add an app name or bundle id to protect", text: $newProtectedApp)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addProtectedApp)
                    Button("Add", action: addProtectedApp)
                        .disabled(newProtectedApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !privacy.userProtectedApps.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(privacy.userProtectedApps, id: \.self) { app in
                            HStack(spacing: 4) {
                                Text(app).font(.caption)
                                Button { privacy.userProtectedApps.removeAll { $0 == app } } label: {
                                    Image(systemName: "xmark").font(.caption2)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }
                }
                if let last = privacy.lastWithheld {
                    Text("Last withheld: \(last.reason.label), \(last.at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            section("HUD") {
                HStack(spacing: 8) {
                    Button("Listening") { app.demoHUD(.listening) }
                    Button("Thinking") { app.demoHUD(.thinking) }
                    Button("Reply") { app.demoHUD(.reply("Here's the thing you asked about. Hold the hotkey and I'll point at it.")) }
                    Button("Agent") { app.demoHUD(.agent(name: "Stripe Radar", step: "Reading last week's refunds")) }
                    Button("Prompt") { app.demoHUD(.prompt) }
                    Spacer()
                    Button("Collapse") { app.demoHUD(.idle) }
                }
                Text("Current: \(String(describing: notch.state))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()
        }
        .padding(24)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func addProtectedApp() {
        let value = newProtectedApp.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !privacy.userProtectedApps.contains(value) else { return }
        privacy.userProtectedApps.append(value)
        newProtectedApp = ""
    }

    private var computerUseStatus: String {
        guard computerUse.isAvailable else { return "cua-driver is not bundled in this build." }
        let grants = (permissions.status(.accessibility) == .granted && permissions.status(.screenRecording) == .granted)
        switch computerUse.state {
        case .off: return computerUse.isEnabled ? "Starting…" : (grants ? "Off." : "Off. Needs Accessibility and Screen Recording.")
        case .starting: return "Starting the driver…"
        case .running: return grants ? "On. Agents get the computer-use tools on their next turn." : "Driver running, but Accessibility or Screen Recording is missing, so actions will fail."
        case .failed(let m): return m
        }
    }

    private func addConnector() {
        let c = integrations.add(name: newConnectorName, url: newConnectorURL, auth: newConnectorAuth, token: newConnectorToken)
        newConnectorName = ""; newConnectorURL = ""; newConnectorToken = ""
        Task {
            if c.auth == .oauth { await integrations.signIn(c.id) } else { await integrations.test(c.id) }
        }
    }

    private func addWord() {
        dictionary.add(newWord)
        newWord = ""
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}


// MARK: - Routines + dictionary rows

struct RoutineRow: View {
    let routine: Routine
    let agentName: String
    let onRun: () -> Void
    let onPause: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(routine.title).font(.callout.weight(.semibold))
                    Text("· \(agentName) · \(routine.cadenceLabel)").font(.caption).foregroundStyle(.secondary)
                    if routine.paused { Text("paused").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.orange.opacity(0.25))) }
                }
                Text(routine.task).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(statusLine).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Button("Run now", action: onRun).controlSize(.small)
            Button(routine.paused ? "Resume" : "Pause", action: onPause).controlSize(.small)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.controlSize(.small)
        }
    }

    private var statusLine: String {
        var parts: [String] = []
        if let last = routine.lastRun { parts.append("last \(last.formatted(date: .abbreviated, time: .shortened))") }
        parts.append(routine.paused ? "not scheduled" : "next \(routine.nextRun.formatted(date: .abbreviated, time: .shortened))")
        if let s = routine.lastSummary, !s.isEmpty { parts.append(s) }
        return parts.joined(separator: " · ")
    }
}

struct FlowChips: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item).font(.caption).lineLimit(1)
                    Button { onRemove(item) } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
        }
    }
}


struct ConnectorRow: View {
    let connector: CustomConnector
    @ObservedObject var host: IntegrationsHost

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connector.name).font(.callout.weight(.semibold))
                    Text(connector.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(host.status(for: connector)).font(.caption).foregroundStyle(connector.lastError == nil ? .secondary : Color.orange).lineLimit(2)
                HStack(spacing: 12) {
                    Toggle("On", isOn: Binding(get: { connector.enabled }, set: { var c = connector; c.enabled = $0; host.update(c) })).font(.caption)
                    Toggle("Allow send & delete", isOn: Binding(get: { connector.allowSensitiveActions }, set: { var c = connector; c.allowSensitiveActions = $0; host.update(c) })).font(.caption)
                }
            }
            Spacer()
            if host.busy.contains(connector.id) { ProgressView().controlSize(.small) }
            if connector.auth == .oauth {
                if host.tokens(for: connector.id) == nil {
                    Button("Sign in") { Task { await host.signIn(connector.id) } }.controlSize(.small)
                } else {
                    Button("Sign out") { host.signOut(connector.id) }.controlSize(.small)
                }
            }
            Button("Test") { Task { await host.test(connector.id) } }.controlSize(.small)
            Button(role: .destructive) { host.remove(connector.id) } label: { Image(systemName: "trash") }.controlSize(.small)
        }
    }
}
