import AppKit
import ApplicationServices
import ClickyPrivacy
import SwiftUI

// Site awareness, as recorded (rec2 125–130 s): on linkedin.com a bar
// appears top-centre — "Connect LinkedIn to HeyClicky? Use HeyClicky to:
// [three chips] · No · Not now · Yes". The app notices the site in the
// frontmost browser, offers the matching integration, and shows three
// things a Clicky could do there.

/// One offer: the site, its integration, and three things to do there.
struct SiteOffer: Equatable {
    var host: String
    var name: String
    var toolkit: String
    var tasks: [String]
    var url: String
    var connected: Bool
}

/// Known sites → integration + three starters.
enum SiteCatalog {
    struct Entry { var suffixes: [String]; var name: String; var toolkit: String; var tasks: [String] }

    static let entries: [Entry] = [
        .init(suffixes: ["linkedin.com"], name: "LinkedIn", toolkit: "linkedin",
              tasks: ["Find company profile details", "Summarize recent post metrics", "Prepare comments to reply with"]),
        .init(suffixes: ["github.com"], name: "GitHub", toolkit: "github",
              tasks: ["Summarize the open pull requests", "Draft a reply to this issue", "Explain what this repo does"]),
        .init(suffixes: ["notion.so", "notion.site"], name: "Notion", toolkit: "notion",
              tasks: ["Summarize this page", "Turn this page into a to-do list", "Find related pages"]),
        .init(suffixes: ["linear.app"], name: "Linear", toolkit: "linear",
              tasks: ["Triage my assigned issues", "Draft an update for this issue", "Summarize the current cycle"]),
        .init(suffixes: ["docs.google.com"], name: "Google Docs", toolkit: "googledocs",
              tasks: ["Summarize this document", "Tighten the wording", "List the action items in it"]),
        .init(suffixes: ["calendar.google.com"], name: "Google Calendar", toolkit: "googlecalendar",
              tasks: ["Summarize my day", "Find a free hour this week", "Draft a reply to the latest invite"]),
        .init(suffixes: ["mail.google.com"], name: "Gmail", toolkit: "gmail",
              tasks: ["Summarize unread mail", "Draft a reply to the open thread", "Find mail that needs a reply"]),
        .init(suffixes: ["slack.com"], name: "Slack", toolkit: "slack",
              tasks: ["Catch me up on this channel", "Draft a reply to the latest thread", "List what I was asked to do"]),
        .init(suffixes: ["youtube.com"], name: "YouTube", toolkit: "youtube",
              tasks: ["Summarize this video from its page", "Pull the key points into notes", "Find similar videos"]),
        .init(suffixes: ["x.com", "twitter.com"], name: "X", toolkit: "twitter",
              tasks: ["Summarize this thread", "Draft a reply", "Find what people say about this"]),
        .init(suffixes: ["figma.com"], name: "Figma", toolkit: "figma",
              tasks: ["Describe this design", "List the screens in this file", "Draft the handoff notes"]),
        .init(suffixes: ["atlassian.net"], name: "Jira", toolkit: "jira",
              tasks: ["Summarize my open tickets", "Draft a comment on this ticket", "Prepare the standup update"]),
        .init(suffixes: ["hubspot.com"], name: "HubSpot", toolkit: "hubspot",
              tasks: ["Summarize this deal", "Draft the follow-up email", "List today's tasks"]),
        .init(suffixes: ["shopify.com"], name: "Shopify", toolkit: "shopify",
              tasks: ["Summarize today's orders", "Draft a product description", "Find low-stock products"]),
        .init(suffixes: ["stripe.com"], name: "Stripe", toolkit: "stripe",
              tasks: ["Summarize this week's payments", "Explain this charge", "List failed payments"]),
    ]

    static func match(host: String) -> Entry? {
        let h = host.lowercased()
        return entries.first { e in e.suffixes.contains { h == $0 || h.hasSuffix("." + $0) } }
    }

    /// The host without a leading "www.".
    static func host(of url: String) -> String? {
        guard let u = URL(string: url), let h = u.host?.lowercased() else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

/// Reads the page URL of the frontmost browser window through accessibility.
enum BrowserURLProbe {
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func isBrowser(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return browsers.contains(id)
    }

    /// The URL shown in the frontmost browser's focused window, if readable.
    static func frontmostPageURL() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication, isBrowser(app) else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = copy(appElement, kAXFocusedWindowAttribute) else { return nil }
        // Safari (and WebKit apps) put the page URL on the window's document.
        if let doc = string(window, kAXDocumentAttribute), doc.hasPrefix("http") { return doc }
        // Chromium exposes it on the web area.
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = 0
        while !queue.isEmpty, seen < 400 {
            let (el, depth) = queue.removeFirst()
            seen += 1
            if string(el, kAXRoleAttribute) == "AXWebArea", let url = string(el, "AXURL"), url.hasPrefix("http") { return url }
            guard depth < 12, let kids = children(el) else { continue }
            for k in kids { queue.append((k, depth + 1)) }
        }
        return nil
    }

    private static func copy(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        return (v as! AXUIElement)
    }
    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        if let s = v as? String { return s }
        if let u = v as? URL { return u.absoluteString }
        return nil
    }
    private static func children(_ el: AXUIElement) -> [AXUIElement]? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return nil }
        return v as? [AXUIElement]
    }
}

/// Watches the frontmost browser and offers the matching site bar.
@MainActor
final class SiteAwarenessMonitor: ObservableObject {
    static let enabledKey = "SiteAwarenessEnabled"
    private static let declinedKey = "SiteOffersDeclined"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private let notch: NotchViewModel
    private let privacy: PrivacyMonitor
    private let integrations: IntegrationsHost
    private let runtime: AgentRuntime
    private var timer: Timer?
    private var observer: Any?
    private var lastHost: String?
    private var shownAt: [String: Date] = [:]
    private var snoozedUntil: [String: Date] = [:]
    @Published private(set) var declined: Set<String> = Set(UserDefaults.standard.stringArray(forKey: declinedKey) ?? [])

    /// Set by the app: open Setup → Integrations.
    var onConnect: ((SiteOffer) -> Void)?

    init(notch: NotchViewModel, privacy: PrivacyMonitor, integrations: IntegrationsHost, runtime: AgentRuntime) {
        self.notch = notch
        self.privacy = privacy
        self.integrations = integrations
        self.runtime = runtime
        notch.onSiteAction = { [weak self] offer, action in self?.handle(offer, action) }
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appChanged() }
        }
        appChanged()
    }

    private func appChanged() {
        timer?.invalidate()
        timer = nil
        guard BrowserURLProbe.isBrowser(NSWorkspace.shared.frontmostApplication) else { lastHost = nil; return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard Self.isEnabled, AXIsProcessTrusted() else { return }
        guard let url = BrowserURLProbe.frontmostPageURL(), let host = SiteCatalog.host(of: url) else { return }
        guard host != lastHost else { return }
        lastHost = host
        consider(url: url, host: host)
    }

    /// Debug + the tick: offer the bar for a URL when the rules allow it.
    func consider(url: String, host: String, force: Bool = false) {
        guard let entry = SiteCatalog.match(host: host) else { return }
        if !force {
            guard notch.state == .idle else { return }
            if declined.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return }
            if let until = snoozedUntil[entry.name], until > Date() { return }
            if let at = shownAt[entry.name], Date().timeIntervalSince(at) < 6 * 3600 { return }
            // Never on a page the privacy guard withholds (banking, checkout, sign-in…).
            let app = NSWorkspace.shared.frontmostApplication
            if privacy.guardian.assess(.init(bundleID: app?.bundleIdentifier, appName: app?.localizedName, urls: [url],
                                             secureInputActive: PrivacyMonitor.secureInputActive)).isWithheld { return }
        }
        shownAt[entry.name] = Date()
        let connected = integrations.toolkits.first { $0.slug == entry.toolkit }?.connected ?? false
        let offer = SiteOffer(host: host, name: entry.name, toolkit: entry.toolkit, tasks: entry.tasks, url: url, connected: connected)
        Log.app.info("site bar: \(entry.name, privacy: .public) connected=\(connected)")
        notch.set(.site(offer), autoDismissAfter: 25)
    }

    enum Action: Equatable { case chip(String), yes, notNow, no }

    private func handle(_ offer: SiteOffer, _ action: Action) {
        switch action {
        case .chip(let task):
            guard let id = notch.selectedAgentID.flatMap({ runtime.store.agent(id: $0)?.id }) ?? runtime.store.agents.first?.id else {
                notch.set(.notice("Found a Clicky first — there are none yet."), autoDismissAfter: 4)
                return
            }
            let browser = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the browser"
            let text = "\(task).\n\nThe page open in \(browser) is \(offer.url) (\(offer.name))."
            runtime.send(text, to: id)
            notch.openClicky(id)
        case .yes:
            snoozedUntil[offer.name] = Date().addingTimeInterval(24 * 3600)
            notch.collapse()
            onConnect?(offer)
        case .notNow:
            snoozedUntil[offer.name] = Date().addingTimeInterval(24 * 3600)
            notch.collapse()
        case .no:
            declined.insert(offer.host)
            UserDefaults.standard.set(Array(declined), forKey: Self.declinedKey)
            notch.collapse()
        }
    }

    func resetDecisions() {
        declined = []
        snoozedUntil = [:]
        shownAt = [:]
        lastHost = nil
        UserDefaults.standard.removeObject(forKey: Self.declinedKey)
    }
}

/// The bar itself.
struct SiteBarView: View {
    @ObservedObject var model: NotchViewModel
    let offer: SiteOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link.circle.fill").font(.system(size: 14)).foregroundStyle(.blue)
                Text(offer.connected ? "Use Hi Dicky on \(offer.name)" : "Connect \(offer.name) to Hi Dicky?")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Button { model.onSiteAction?(offer, .notNow) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 6) {
                Text("Use Hi Dicky to:").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                ForEach(offer.tasks, id: \.self) { task in
                    Button { model.onSiteAction?(offer, .chip(task)) } label: {
                        Text(task).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if !offer.connected {
                HStack(spacing: 14) {
                    Spacer()
                    Button("No") { model.onSiteAction?(offer, .no) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                    Button("Not now") { model.onSiteAction?(offer, .notNow) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.75))
                    Button { model.onSiteAction?(offer, .yes) } label: {
                        Text("Yes").font(.system(size: 11, weight: .bold)).padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Capsule().fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(.top, 4)
    }
}
