import AppKit
import Carbon.HIToolbox
import ClickyPrivacy
import CoreGraphics

/// Collects the live signals the pure `PrivacyGuard` needs, keeps the
/// user's own protected-app list, and remembers the last withheld reason for
/// the Setup screen.
@MainActor
final class PrivacyMonitor: ObservableObject {
    static let userListKey = "ClickyPrivacyProtectedApps"

    @Published private(set) var lastWithheld: (reason: PrivacyGuard.Reason, at: Date)?
    @Published var userProtectedApps: [String] {
        didSet { UserDefaults.standard.set(userProtectedApps, forKey: Self.userListKey) }
    }

    init() {
        userProtectedApps = UserDefaults.standard.stringArray(forKey: Self.userListKey) ?? []
    }

    var guardian: PrivacyGuard { PrivacyGuard(userProtectedApps: userProtectedApps) }

    /// True while any app has a password field focused (system-wide secure keyboard entry).
    nonisolated static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    // MARK: - Verdicts

    /// For talk mode: the frontmost app plus what the accessibility harvest found.
    func assessFrontmost(windowTitle: String?, urls: [String], hasSecureField: Bool) -> PrivacyGuard.Verdict {
        let app = NSWorkspace.shared.frontmostApplication
        let verdict = guardian.assess(.init(
            bundleID: app?.bundleIdentifier, appName: app?.localizedName,
            windowTitle: windowTitle, urls: urls,
            hasSecureField: hasSecureField, secureInputActive: Self.secureInputActive))
        record(verdict)
        return verdict
    }

    /// A closure the computer-use policy can call from any thread.
    func targetAssessor() -> (pid_t?, String?, CGWindowID?) -> PrivacyGuard.Verdict {
        let guardian = self.guardian
        return { pid, bundleID, windowID in
            let verdict = Self.assessTarget(guardian: guardian, pid: pid, bundleID: bundleID, windowID: windowID)
            if case .withhold(let reason) = verdict {
                Task { @MainActor in self.record(.withhold(reason)) }
            }
            return verdict
        }
    }

    /// For computer use: a target process and, when known, a window. With no
    /// target at all, judges the frontmost app. Safe off the main thread.
    nonisolated static func assessTarget(guardian: PrivacyGuard, pid: pid_t?, bundleID: String?, windowID: CGWindowID?) -> PrivacyGuard.Verdict {
        var bundle = bundleID
        var name: String?
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            bundle = bundle ?? app.bundleIdentifier
            name = app.localizedName
        }
        var title: String?
        if let windowID, let info = windowInfo(windowID) {
            title = info.title
            if bundle == nil, let ownerPID = info.ownerPID, let app = NSRunningApplication(processIdentifier: ownerPID) {
                bundle = app.bundleIdentifier
                name = app.localizedName
            }
        }
        if pid == nil, bundleID == nil, windowID == nil, let front = NSWorkspace.shared.frontmostApplication {
            bundle = front.bundleIdentifier
            name = front.localizedName
        }
        return guardian.assess(.init(
            bundleID: bundle, appName: name, windowTitle: title, urls: [],
            hasSecureField: false, secureInputActive: secureInputActive))
    }

    private func record(_ verdict: PrivacyGuard.Verdict) {
        if case .withhold(let reason) = verdict {
            lastWithheld = (reason, Date())
            Log.privacy.info("withheld: \(reason.label, privacy: .public)")
        }
    }

    /// Window title and owner from the window server (needs Screen Recording for titles).
    nonisolated static func windowInfo(_ id: CGWindowID) -> (title: String?, ownerPID: pid_t?)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = list.first else { return nil }
        let title = info[kCGWindowName as String] as? String
        let pid = (info[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.int32Value) }
        return (title, pid)
    }
}
