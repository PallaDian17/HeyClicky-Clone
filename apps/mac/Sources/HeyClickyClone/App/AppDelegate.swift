import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = AppConfig.load()
    private(set) lazy var auth = AuthManager(config: config)
    let permissions = PermissionsModel()
    let notch = NotchWindowManager()
    let hotkey = HotkeyMonitor()

    private var statusBar: StatusBarController!
    private var homeWindow: HomeWindowController?
    private var permissionsWindow: PermissionsWindowController?
    private var signInWindow: SignInWindowController?
    private var hotkeyRetryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Launched \(Bundle.main.bundleIdentifier ?? "unbundled", privacy: .public)")

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:with:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        statusBar = StatusBarController(actions: self)
        notch.show()
        wireNotch()
        wireHotkey()
        startHotkeyWhenPermitted()

        permissions.refresh()
        auth.start()

        auth.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.authStateChanged(state) }
            .store(in: &cancellables)

        if !permissions.allRequiredGranted {
            showPermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
    }

    // MARK: - Wiring

    private func wireNotch() {
        notch.model.onPromptSubmitted = { [weak self] text in
            self?.answerPrompt(text)
        }
    }

    private func wireHotkey() {
        hotkey.onEvent = { [weak self] event in
            self?.handleHotkey(event)
        }
    }

    private func startHotkeyWhenPermitted() {
        if (try? hotkey.start()) != nil {
            Log.hotkey.info("Event tap running")
            return
        }
        Log.hotkey.notice("Event tap unavailable (needs Accessibility or Input Monitoring); retrying")
        hotkeyRetryTimer?.invalidate()
        hotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if (try? self.hotkey.start()) != nil {
                    Log.hotkey.info("Event tap running after permission grant")
                    timer.invalidate()
                    self.permissions.refresh()
                }
            }
        }
    }

    private func handleHotkey(_ event: HotkeyMonitor.Event) {
        switch event {
        case .holdBegan:
            notch.model.set(.listening)
        case .holdEnded:
            guard notch.model.state == .listening else { return }
            notch.model.set(.thinking)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))
                guard self.notch.model.state == .thinking else { return }
                self.notch.model.set(.reply("Heard you. Voice and screen capture land in phase 2; the hotkey, HUD and permissions are wired."), autoDismissAfter: 7)
            }
        case .doubleTap:
            notch.model.toggle(.prompt)
        case .escape:
            notch.model.collapse()
        }
    }

    private func answerPrompt(_ text: String) {
        notch.model.set(.thinking)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            guard self.notch.model.state == .thinking else { return }
            self.notch.model.set(.reply("You asked: “\(text)”. The model call arrives with the backend in phase 2."), autoDismissAfter: 8)
        }
    }

    private func authStateChanged(_ state: AuthManager.State) {
        statusBar.update(authState: state)
        switch state {
        case .signedOut:
            showSignIn()
        case .signedIn:
            signInWindow?.close()
        case .loading, .unconfigured:
            break
        }
    }

    // MARK: - URL scheme (heyclickyclone://auth/callback?...)

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, with reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: raw) else { return }
        Log.app.info("Received URL \(url.scheme ?? "", privacy: .public)://\(url.host ?? "", privacy: .public)\(url.path, privacy: .public)")
        switch url.host {
        case "auth":
            auth.handle(callbackURL: url)
        case "hud":
            handleDebugHUDURL(url)
        case "home":
            openHome()
        case "permissions":
            showPermissions()
        case "snapshot":
            handleWindowSnapshotURL(url)
        default:
            break
        }
    }

    /// Developer hook: `open "heyclickyclone://snapshot?window=home&path=/tmp/home.png"`.
    /// Windows: home, permissions, signin (signin renders even when Supabase is unconfigured).
    private func handleWindowSnapshotURL(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let which = items.first(where: { $0.name == "window" })?.value ?? "home"
        let path = items.first(where: { $0.name == "path" })?.value ?? "/tmp/\(which).png"
        let window: NSWindow?
        switch which {
        case "permissions":
            showPermissions(); window = permissionsWindow?.window
        case "signin":
            if signInWindow == nil { signInWindow = SignInWindowController(auth: auth) }
            signInWindow?.show(); window = signInWindow?.window
        default:
            openHome(); window = homeWindow?.window
        }
        guard let window else { return }
        // Give a freshly created window one layout pass before capturing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let view = window.contentView else { return }
            // The window chrome paints the background, not the content view, so add it back.
            let ok = DebugSnapshot.write(view: view, background: window.backgroundColor,
                                         appearance: window.effectiveAppearance, to: URL(fileURLWithPath: path))
            Log.app.info("window snapshot \(which, privacy: .public) -> \(path, privacy: .public) ok=\(ok)")
        }
    }

    /// Developer hook: `open "heyclickyclone://hud/listening"` drives the HUD
    /// from a terminal. Paths: idle, listening, thinking, prompt, reply, agent, notice.
    private func handleDebugHUDURL(_ url: URL) {
        let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "text" })?.value
        switch url.lastPathComponent {
        case "idle": notch.model.collapse()
        case "listening": notch.model.set(.listening)
        case "thinking": notch.model.set(.thinking)
        case "prompt": notch.model.set(.prompt)
        case "reply": notch.model.set(.reply(text ?? "Here's the thing you asked about. Hold the hotkey and I'll point at it."), autoDismissAfter: 8)
        case "agent": notch.model.set(.agent(name: text ?? "Stripe Radar", step: "Reading last week's refunds"))
        case "notice": notch.model.set(.notice(text ?? "Update installed. Clicky restarted."), autoDismissAfter: 5)
        case "snapshot":
            // Renders the HUD's own content to a PNG (no Screen Recording needed).
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value ?? "/tmp/hud.png"
            notch.snapshot(to: URL(fileURLWithPath: path))
        default: break
        }
    }
}

// MARK: - Window openers

extension AppDelegate: StatusBarActions {
    func openHome() {
        if homeWindow == nil { homeWindow = HomeWindowController(app: self) }
        homeWindow?.show()
    }

    func showPermissions() {
        if permissionsWindow == nil { permissionsWindow = PermissionsWindowController(model: permissions) }
        permissionsWindow?.show()
    }

    func showSignIn() {
        guard auth.isConfigured else {
            openHome()
            return
        }
        if signInWindow == nil { signInWindow = SignInWindowController(auth: auth) }
        signInWindow?.show()
    }

    func signOut() {
        Task { await auth.signOut() }
    }

    func demoHUD(_ state: NotchState) {
        notch.model.set(state, autoDismissAfter: state == .idle ? nil : 6)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
