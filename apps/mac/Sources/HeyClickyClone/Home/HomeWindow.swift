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

    init(app: AppDelegate) {
        self.app = app
        _auth = ObservedObject(wrappedValue: app.auth)
        _permissions = ObservedObject(wrappedValue: app.permissions)
        _notch = ObservedObject(wrappedValue: app.notch.model)
        _computerUse = ObservedObject(wrappedValue: app.computerUse)
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
