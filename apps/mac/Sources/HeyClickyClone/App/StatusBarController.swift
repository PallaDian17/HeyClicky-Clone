import AppKit

@MainActor
protocol StatusBarActions: AnyObject {
    func openHome()
    func showPermissions()
    func showOnboarding()
    func checkForUpdates()
    func showSignIn()
    func signOut()
    func demoHUD(_ state: NotchState)
    func quit()
}

@MainActor
final class StatusBarController {
    private let item: NSStatusItem
    private weak var actions: StatusBarActions?
    private var authState: AuthManager.State = .loading

    init(actions: StatusBarActions) {
        self.actions = actions
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "HeyClicky Clone")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    func update(authState: AuthManager.State) {
        self.authState = authState
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let accountTitle: String
        switch authState {
        case .signedIn(let email): accountTitle = email
        case .signedOut: accountTitle = "Not signed in"
        case .loading: accountTitle = "Checking session…"
        case .unconfigured: accountTitle = "Supabase not configured"
        }
        let accountItem = NSMenuItem(title: accountTitle, action: nil, keyEquivalent: "")
        accountItem.isEnabled = false
        menu.addItem(accountItem)

        menu.addItem(.separator())
        menu.addItem(makeItem("Open Home", #selector(openHome), key: "h"))
        menu.addItem(makeItem("Permissions…", #selector(showPermissions)))
        menu.addItem(makeItem("Welcome tour…", #selector(showOnboarding)))
        menu.addItem(makeItem("Check for Updates…", #selector(checkForUpdates)))

        let demo = NSMenu()
        demo.addItem(makeItem("Listening", #selector(demoListening)))
        demo.addItem(makeItem("Thinking", #selector(demoThinking)))
        demo.addItem(makeItem("Reply", #selector(demoReply)))
        demo.addItem(makeItem("Agent running", #selector(demoAgent)))
        demo.addItem(makeItem("Prompt box", #selector(demoPrompt)))
        demo.addItem(makeItem("Collapse", #selector(demoCollapse)))
        let demoItem = NSMenuItem(title: "HUD demo", action: nil, keyEquivalent: "")
        demoItem.submenu = demo
        menu.addItem(demoItem)

        menu.addItem(.separator())
        switch authState {
        case .signedIn:
            menu.addItem(makeItem("Sign out", #selector(signOut)))
        case .signedOut:
            menu.addItem(makeItem("Sign in…", #selector(showSignIn)))
        default:
            break
        }
        menu.addItem(makeItem("Quit HeyClicky Clone", #selector(quit), key: "q"))

        item.menu = menu
    }

    private func makeItem(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openHome() { actions?.openHome() }
    @objc private func showPermissions() { actions?.showPermissions() }
    @objc private func showOnboarding() { actions?.showOnboarding() }
    @objc private func checkForUpdates() { actions?.checkForUpdates() }
    @objc private func showSignIn() { actions?.showSignIn() }
    @objc private func signOut() { actions?.signOut() }
    @objc private func quit() { actions?.quit() }
    @objc private func demoListening() { actions?.demoHUD(.listening) }
    @objc private func demoThinking() { actions?.demoHUD(.thinking) }
    @objc private func demoReply() {
        actions?.demoHUD(.reply("The Export menu is under File. Hold the hotkey and ask me to point at it."))
    }
    @objc private func demoAgent() { actions?.demoHUD(.agent(name: "Stripe Radar", step: "Reading last week's refunds")) }
    @objc private func demoPrompt() { actions?.demoHUD(.prompt) }
    @objc private func demoCollapse() { actions?.demoHUD(.idle) }
}
