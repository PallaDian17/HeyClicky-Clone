import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = AppConfig.load()
    private(set) lazy var auth = AuthManager(config: config)
    let permissions = PermissionsModel()
    let notch = NotchWindowManager()
    let hotkey = HotkeyMonitor()
    let overlay = PointingOverlayManager()
    private(set) lazy var backend: BackendClient = {
        let client = BackendClient(baseURL: config.backendURL)
        client.tokenProvider = { [weak self] in await self?.auth.accessToken() }
        return client
    }()
    let privacy = PrivacyMonitor()
    private(set) lazy var talk = TalkCoordinator(notch: notch.model, backend: backend, overlay: overlay, privacy: privacy)
    let computerUse = ComputerUseHost()
    private(set) lazy var agents = AgentRuntime(store: AgentStore(), computerUse: computerUse, privacy: privacy, notch: notch.model, model: config.agentModel)
    private(set) lazy var dictation = DictationController(notch: notch.model, backend: backend, privacy: privacy)
    private(set) lazy var integrations = IntegrationsHost(backend: backend)
    let characters = CharacterStore()
    private(set) lazy var updates = UpdateController()
    private var onboardingWindow: OnboardingWindowController?
    let routines = RoutineStore()
    private(set) lazy var scheduler = RoutineScheduler(store: routines, agents: agents, notch: notch.model)
    private(set) lazy var suggestions = MorningSuggestions(backend: backend, agents: agents, routines: routines, scheduler: scheduler, notch: notch.model)

    private var statusBar: StatusBarController!
    private var homeWindow: HomeWindowController?
    private var permissionsWindow: PermissionsWindowController?
    private var signInWindow: SignInWindowController?
    private var hotkeyRetryTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashReporter.install()
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
        computerUse.startIfEnabled()
        agents.store.foundStarters()
        wireHandoff()
        wireRoutines()
        scheduler.start()
        suggestions.start()
        agents.integrations = integrations
        Task { await integrations.refreshComposio() }

        auth.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.authStateChanged(state) }
            .store(in: &cancellables)

        _ = updates
        NotificationCenter.default.addObserver(forName: .clickyCharacterChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.notch.model.character = ClickyCharacter.loadUser() }
        }

        if !UserDefaults.standard.bool(forKey: OnboardingWindowController.onboardedKey) {
            showOnboarding()
        } else if !permissions.allRequiredGranted {
            showPermissions()
        }
        let crashes = CrashReporter.unseenReports()
        if !crashes.isEmpty {
            notch.model.set(.notice("Clicky crashed last time (\(crashes.count) report\(crashes.count == 1 ? "" : "s") in Setup)"), autoDismissAfter: 8)
            Log.app.notice("unseen crash reports: \(crashes.map(\.lastPathComponent).joined(separator: ","), privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        scheduler.stop()
        dictation.cancel()
        agents.shutdown()
        computerUse.stop()
    }

    // MARK: - Wiring

    private func wireNotch() {
        notch.model.onPromptSubmitted = { [weak self] text in
            self?.talk.ask(text)
        }
    }

    /// Talk mode asked for work to be done: pick the named Clicky (or the first
    /// starter), drop the screenshot into its tmp/ so it can look, and start the turn.
    private func wireHandoff() {
        talk.onHandoff = { [weak self] task, hint, screenshot in
            guard let self else { return nil }
            let store = self.agents.store
            let agent: Agent? = {
                if let hint, !hint.isEmpty {
                    let h = hint.lowercased()
                    if let match = store.agents.first(where: { $0.name.lowercased() == h || $0.slug == h || $0.name.lowercased().hasPrefix(h) }) {
                        return match
                    }
                }
                return store.agents.first(where: { $0.isStarter && $0.slug == "desk" }) ?? store.agents.first
            }()
            guard let agent else { return nil }
            var message = task
            if let screenshot {
                let dir = store.folder(for: agent).appendingPathComponent("tmp/handoffs", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let name = "screen-\(Int(Date().timeIntervalSince1970)).jpg"
                if (try? screenshot.write(to: dir.appendingPathComponent(name))) != nil {
                    message += "\n\nA screenshot of what the user was looking at when they asked is at tmp/handoffs/\(name) in this folder; read it if the task refers to what is on screen."
                }
            }
            message = "[Handed off from talk mode] " + message
            self.agents.send(message, to: agent.id)
            NotificationCenter.default.post(name: .homeSpaceSelectAgent, object: agent.id)
            return agent.name
        }
    }

    /// Agents can propose routines in their replies; the scheduler reports runs with news.
    private func wireRoutines() {
        agents.onRoutineProposed = { [weak self] agent, proposal in
            guard let self else { return }
            let routine = self.routines.add(agentID: agent.id, title: proposal.title, task: proposal.task, everyMinutes: proposal.every_minutes)
            self.notch.model.set(.notice("\(agent.name) will run “\(routine.title)” \(routine.cadenceLabel)"), autoDismissAfter: 6)
        }
        scheduler.onRoutineRan = { routine, summary in
            Log.agents.info("routine report '\(routine.title, privacy: .public)': \(summary ?? "nothing new", privacy: .public)")
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
            talk.beginHold()
        case .holdEnded:
            talk.endHold()
        case .doubleTap:
            if talk.phase != .idle { talk.cancel() }
            notch.model.toggle(.prompt)
        case .escape:
            talk.cancel()
            dictation.cancel()
            notch.model.collapse()
        case .dictationBegan:
            guard talk.phase == .idle else { return }
            dictation.begin()
        case .dictationEnded:
            dictation.end()
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
        case "onboarding":
            // `heyclickyclone://onboarding` · `/reset` (forget the flag) · `/step?n=3`
            if url.lastPathComponent == "reset" { UserDefaults.standard.removeObject(forKey: OnboardingWindowController.onboardedKey) }
            let n = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "n" })?.value.flatMap(Int.init)
            showOnboarding(step: n.flatMap(OnboardingModel.Step.init(rawValue:)))
        case "updates":
            // `heyclickyclone://updates/check` (Sparkle UI) · `/background` (log only)
            url.lastPathComponent == "background" ? updates.checkInBackground() : updates.checkForUpdates()
        case "crash":
            // `heyclickyclone://crash/test?kind=exception|signal` · `/seen`
            if url.lastPathComponent == "seen" { CrashReporter.markSeen() } else {
                let kind = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "kind" })?.value ?? "exception"
                Log.app.notice("simulating crash kind=\(kind, privacy: .public)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CrashReporter.simulate(kind) }
            }
        case "home":
            // `heyclickyclone://home` · `heyclickyclone://home/setup`
            openHome()
            if url.lastPathComponent == "setup" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .homeSpaceSetup, object: nil) }
            }
        case "permissions":
            showPermissions()
        case "snapshot":
            handleWindowSnapshotURL(url)
        case "agent":
            // `heyclickyclone://agent/new?name=Scout&purpose=...` and `heyclickyclone://agent/send?slug=scout&text=...`
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func q(_ n: String) -> String? { items.first(where: { $0.name == n })?.value }
            switch url.lastPathComponent {
            case "new":
                _ = try? agents.store.create(name: q("name") ?? "Scout", purpose: q("purpose") ?? "general help on this Mac")
                openHome()
            case "starters":
                _ = agents.store.foundStarters(force: true)
                openHome()
            case "interview":
                openHome()
                // The Home view may be mounting right now; let it subscribe first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .homeSpaceNewClicky, object: nil)
                }
            case "select":
                if let slug = q("slug"), let agent = agents.store.agents.first(where: { $0.slug == slug }) {
                    openHome()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: .homeSpaceSelectAgent, object: agent.id)
                    }
                }
            case "send":
                if let slug = q("slug"), let agent = agents.store.agents.first(where: { $0.slug == slug }) {
                    agents.send(q("text") ?? "Say hello in one sentence.", to: agent.id)
                    openHome()
                }
            default: break
            }
        case "computer-use":
            // `heyclickyclone://computer-use/on` | `/off` | `/status`
            switch url.lastPathComponent {
            case "on": computerUse.isEnabled = true
            case "off": computerUse.isEnabled = false
            default: break
            }
            Log.computerUse.info("consent=\(self.computerUse.isEnabled) state=\(String(describing: self.computerUse.state), privacy: .public)")
            openHome()
        case "privacy":
            // `heyclickyclone://privacy/status` logs what the guard would decide right now (no model call).
            Task.detached(priority: .userInitiated) {
                let harvest = AccessibilityHarvester.harvestFrontmost()
                await MainActor.run {
                    let front = NSWorkspace.shared.frontmostApplication
                    let verdict = self.privacy.assessFrontmost(windowTitle: harvest.windowTitle, urls: harvest.urls, hasSecureField: harvest.hasSecureField)
                    Log.privacy.info("status front=\(front?.localizedName ?? "?", privacy: .public) bundle=\(front?.bundleIdentifier ?? "?", privacy: .public) trusted=\(AXIsProcessTrusted()) secureInput=\(PrivacyMonitor.secureInputActive) title=\(harvest.windowTitle ?? "-", privacy: .public) urls=\(harvest.urls.count) secureField=\(harvest.hasSecureField) elements=\(harvest.elements.count) verdict=\(String(describing: verdict), privacy: .public)")
                }
            }
        case "talk":
            // `open "heyclickyclone://talk?text=what%20is%20this"` runs a full typed turn.
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "text" })?.value ?? "What am I looking at?"
            talk.ask(text)
        case "integrations":
            handleIntegrationsURL(url)
        case "dictate":
            // `heyclickyclone://dictate?text=…` runs cleanup + insertion into the focused field without the microphone.
            // `heyclickyclone://dictate/begin` | `/end` drive the real microphone path.
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value
            switch url.lastPathComponent {
            case "begin": dictation.begin()
            case "end": dictation.end()
            default: dictation.deliverSynthetic(text ?? "hello comma this is a dictation test period")
            }
        case "routine":
            // `heyclickyclone://routine/create?slug=scout&title=…&task=…&every=60` · `/list` · `/run?id=` · `/pause?id=` · `/resume?id=` · `/delete?id=` · `/tick`
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func q(_ n: String) -> String? { items.first(where: { $0.name == n })?.value }
            let id = q("id").flatMap(UUID.init(uuidString:))
            switch url.lastPathComponent {
            case "create":
                if let slug = q("slug"), let agent = agents.store.agents.first(where: { $0.slug == slug }) {
                    let r = routines.add(agentID: agent.id, title: q("title") ?? "Check-in", task: q("task") ?? "Say what time it is.",
                                         everyMinutes: Int(q("every") ?? "") ?? 60, firstRun: q("now") == "1" ? Date() : nil)
                    Log.agents.info("routine/create id=\(r.id.uuidString, privacy: .public) next=\(r.nextRun.formatted(), privacy: .public)")
                    if q("now") == "1" { scheduler.tick() }
                }
            case "list":
                for r in routines.routines {
                    Log.agents.info("routine \(r.id.uuidString, privacy: .public) '\(r.title, privacy: .public)' \(r.cadenceLabel, privacy: .public) paused=\(r.paused) runs=\(r.runCount) next=\(r.nextRun.formatted(), privacy: .public) last=\(r.lastSummary ?? "-", privacy: .public)")
                }
                Log.agents.info("routine/list count=\(self.routines.routines.count)")
            case "run": if let id { routines.runNow(id); scheduler.tick() }
            case "pause": if let id { routines.setPaused(id, true) }
            case "resume": if let id { routines.setPaused(id, false) }
            case "delete": if let id { routines.remove(id) }
            case "tick": scheduler.tick()
            default: break
            }
            openHome()
        case "suggestions":
            // `heyclickyclone://suggestions/show` asks the backend now (ignores the once-a-day guard); `/demo` shows static cards.
            switch url.lastPathComponent {
            case "demo":
                let agent = agents.store.agents.first
                suggestions.present([
                    SuggestionCardModel(title: "Morning inbox sweep", task: "Summarize anything new in output/ since yesterday.", agentSlug: agent?.slug ?? "scout", agentName: agent?.name ?? "Scout", everyMinutes: 1440),
                    SuggestionCardModel(title: "Tidy the Desktop", task: "List the files on my Desktop older than a week and suggest folders for them.", agentSlug: agent?.slug ?? "scout", agentName: agent?.name ?? "Scout", everyMinutes: nil),
                ])
            default:
                Task { await suggestions.show(force: true) }
            }
        default:
            break
        }
    }

    /// OAuth / Composio callbacks plus developer hooks:
    /// `integrations/oauth?code&state` · `integrations/composio?status` ·
    /// `integrations/add?name&url&auth=none|bearer|oauth&token` · `integrations/signin?id[&headless=1]` ·
    /// `integrations/test?id` · `integrations/remove?id` · `integrations/sensitive?id&on=1` · `integrations/list` ·
    /// `integrations/composio/refresh` · `integrations/composio/connect?toolkit=gmail`
    private func handleIntegrationsURL(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first(where: { $0.name == n })?.value }
        let id = q("id").flatMap(UUID.init(uuidString:))
        let path = url.path.split(separator: "/").map(String.init)
        switch path.first {
        case "oauth":
            Task { await integrations.handleOAuthCallback(url); self.openHome() }
        case "composio":
            if path.count > 1 {
                switch path[1] {
                case "refresh": Task { await integrations.refreshComposio() }
                case "connect": if let t = q("toolkit") { Task { await integrations.connectComposio(t) } }
                case "disconnect": if let t = q("toolkit") { Task { await integrations.disconnectComposio(t) } }
                default: break
                }
            } else {
                Task { await integrations.handleComposioCallback(url); self.openHome() }
            }
        case "add":
            let auth = CustomConnector.Auth(rawValue: q("auth") ?? "none") ?? .none
            let c = integrations.add(name: q("name") ?? "Connector", url: q("url") ?? "", auth: auth, token: q("token"))
            Log.integrations.info("integrations/add id=\(c.id.uuidString, privacy: .public) slug=\(c.slug, privacy: .public)")
        case "signin": if let id { Task { await integrations.signIn(id, headless: q("headless") == "1") } }
        case "test": if let id { Task { await integrations.test(id) } }
        case "remove": if let id { integrations.remove(id) }
        case "signout": if let id { integrations.signOut(id) }
        case "sensitive":
            if let id, var c = integrations.connector(id: id) { c.allowSensitiveActions = q("on") == "1"; integrations.update(c) }
        case "list":
            for c in integrations.connectors {
                Log.integrations.info("connector \(c.id.uuidString, privacy: .public) '\(c.name, privacy: .public)' slug=\(c.slug, privacy: .public) auth=\(c.auth.rawValue, privacy: .public) enabled=\(c.enabled) sensitive=\(c.allowSensitiveActions) status=\(self.integrations.status(for: c), privacy: .public) tools=\(c.toolNames.joined(separator: ","), privacy: .public)")
            }
            Log.integrations.info("integrations/list connectors=\(self.integrations.connectors.count) composioConfigured=\(self.integrations.composioConfigured) toolkits=\(self.integrations.toolkits.map { "\($0.slug):\($0.connected)" }.joined(separator: ","), privacy: .public)")
        default: break
        }
        if path.first != "oauth", path.first != "composio" { openHome() }
    }

    /// Developer hook: `open "heyclickyclone://snapshot?window=home&path=/tmp/home.png"`.
    /// Windows: home, permissions, signin (signin renders even when Supabase is unconfigured).
    private func handleWindowSnapshotURL(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let which = items.first(where: { $0.name == "window" })?.value ?? "home"
        let path = items.first(where: { $0.name == "path" })?.value ?? "/tmp/\(which).png"
        let window: NSWindow?
        switch which {
        case "onboarding":
            showOnboarding(); window = onboardingWindow?.window
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
        case "dictating": notch.model.set(.dictating(text ?? ""))
        case "dictated": notch.model.set(.dictated(text ?? "Hello, this is a dictation test."), autoDismissAfter: 5)
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

    func showOnboarding() { showOnboarding(step: nil) }

    func showOnboarding(step: OnboardingModel.Step?) {
        if onboardingWindow == nil { onboardingWindow = OnboardingWindowController(app: self) }
        onboardingWindow?.show(step: step)
    }

    func checkForUpdates() { updates.checkForUpdates() }

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
