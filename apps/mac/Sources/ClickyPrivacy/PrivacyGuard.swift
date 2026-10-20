import Foundation

/// The one gate every screen- or voice-observing path consults.
///
/// Pure and deterministic: callers collect the live signals (frontmost app,
/// window title, URLs, secure-field flags) and ask for a verdict; text paths
/// ask for redaction. No AppKit here so the rules can be unit-tested.
public struct PrivacyGuard: Sendable {
    public struct Context: Sendable {
        public var bundleID: String?
        public var appName: String?
        public var windowTitle: String?
        public var urls: [String]
        public var hasSecureField: Bool
        public var secureInputActive: Bool

        public init(bundleID: String? = nil, appName: String? = nil, windowTitle: String? = nil,
                    urls: [String] = [], hasSecureField: Bool = false, secureInputActive: Bool = false) {
            self.bundleID = bundleID
            self.appName = appName
            self.windowTitle = windowTitle
            self.urls = urls
            self.hasSecureField = hasSecureField
            self.secureInputActive = secureInputActive
        }
    }

    public enum Reason: Equatable, Sendable {
        case passwordField
        case protectedApp(String)
        case protectedPage(String)

        /// Short, user-facing.
        public var label: String {
            switch self {
            case .passwordField: return "a password field is active"
            case .protectedApp(let name): return "\(name) is protected"
            case .protectedPage(let kind): return "this looks like a \(kind) page"
            }
        }
    }

    public enum Verdict: Equatable, Sendable {
        case allow
        case withhold(Reason)
        public var isWithheld: Bool { if case .withhold = self { return true } else { return false } }
    }

    /// Extra apps the user added (bundle ids or name fragments, case-insensitive).
    public var userProtectedApps: [String]

    public init(userProtectedApps: [String] = []) {
        self.userProtectedApps = userProtectedApps
    }

    // MARK: - Fixed lists

    /// Password managers, authenticators, keychains, wallets and banking apps.
    public static let protectedBundleIDs: [String] = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.Dashlane", "in.sinew.Enpass-Desktop",
        "org.keepassxc.keepassxc", "com.keepassium.KeePassium", "com.nordpass.macos", "com.roboform.RoboForm",
        "com.apple.Passwords", "com.apple.keychainaccess", "com.apple.systempreferences",
        "com.authy.desktop", "com.twilio.authy", "com.raivo-otp", "com.beyondidentity.authenticator",
        "com.apple.Wallet", "com.apple.PassbookUIService", "com.paypal.PayPalDesktop", "com.revolut.app",
        "com.monzo.Monzo", "com.wise.wise", "net.whatsapp.WhatsApp.payments",
    ]

    /// Name fragments for apps whose bundle id we may not know.
    public static let protectedNameFragments: [String] = [
        "1password", "bitwarden", "lastpass", "dashlane", "keepass", "enpass", "nordpass", "authenticator",
        "authy", "keychain", "passwords", "wallet", "bank", "banking", "paypal", "revolut", "monzo", "wise",
    ]

    /// URL host/path fragments that mark a page as sensitive.
    public static let protectedURLFragments: [String] = [
        "checkout", "payment", "payments", "/pay", "billing", "bank", "banking", "netbanking", "paypal.com",
        "stripe.com", "razorpay", "upi", "wallet", "/login", "/signin", "/sign-in", "/sign_in", "/auth",
        "oauth", "password", "passwd", "2fa", "mfa", "otp", "/verify", "verification", "account/security",
        "accounts.google.com", "appleid.apple.com", "account.apple.com", "icloud.com/settings",
        "login.microsoftonline", "myaccount.google.com/security", "id.atlassian.com", "/reset",
    ]

    /// Window-title fragments (page titles, dialog titles) that mark a sensitive screen.
    public static let protectedTitleFragments: [String] = [
        "sign in", "log in", "login", "password", "passcode", "checkout", "payment", "pay now", "verify",
        "verification code", "two-factor", "two factor", "2-step", "2fa", "one-time", "otp", "bank",
        "wallet", "security code", "card details", "billing", "authenticator", "keychain",
    ]

    // MARK: - Verdict

    public func assess(_ c: Context) -> Verdict {
        if c.secureInputActive || c.hasSecureField { return .withhold(.passwordField) }
        if let bundle = c.bundleID?.lowercased() {
            if Self.protectedBundleIDs.contains(where: { $0.lowercased() == bundle }) {
                return .withhold(.protectedApp(c.appName ?? bundle))
            }
            if userProtectedApps.contains(where: { !$0.isEmpty && bundle.contains($0.lowercased()) }) {
                return .withhold(.protectedApp(c.appName ?? bundle))
            }
        }
        if let name = c.appName?.lowercased() {
            if Self.protectedNameFragments.contains(where: { name.contains($0) }) {
                return .withhold(.protectedApp(c.appName ?? name))
            }
            if userProtectedApps.contains(where: { !$0.isEmpty && name.contains($0.lowercased()) }) {
                return .withhold(.protectedApp(c.appName ?? name))
            }
        }
        for url in c.urls {
            let u = url.lowercased()
            if let hit = Self.protectedURLFragments.first(where: { u.contains($0) }) {
                return .withhold(.protectedPage(Self.pageKind(for: hit)))
            }
        }
        if let title = c.windowTitle?.lowercased() {
            if let hit = Self.protectedTitleFragments.first(where: { title.contains($0) }) {
                return .withhold(.protectedPage(Self.pageKind(for: hit)))
            }
        }
        return .allow
    }

    private static func pageKind(for fragment: String) -> String {
        let f = fragment.lowercased()
        if ["checkout", "payment", "payments", "/pay", "pay now", "billing", "card details", "stripe.com", "razorpay", "paypal.com", "upi"].contains(where: { f.contains($0) }) { return "payment" }
        if ["bank", "banking", "netbanking", "wallet"].contains(where: { f.contains($0) }) { return "banking" }
        if ["2fa", "mfa", "otp", "verify", "verification", "two-factor", "two factor", "2-step", "one-time", "security code", "authenticator"].contains(where: { f.contains($0) }) { return "verification"}
        return "sign-in"
    }

    // MARK: - Redaction

    public struct Redaction: Equatable, Sendable {
        public var text: String
        public var count: Int
        public var wasRedacted: Bool { count > 0 }
    }

    private static let codeContext = try! NSRegularExpression(
        pattern: #"(?i)\b(code|otp|one[- ]time|passcode|pass code|verification|verify|pin|token|2fa|mfa|tan|cvv|cvc)\b"#)
    private static let digitRun = try! NSRegularExpression(pattern: #"(?<![\d-])\d{4,8}(?![\d-])"#)
    private static let spacedCode = try! NSRegularExpression(pattern: #"\b\d{3}[ -]\d{3}\b"#)
    private static let cardLike = try! NSRegularExpression(pattern: #"\b(?:\d[ -]?){13,19}\b"#)
    private static let secretAssignment = try! NSRegularExpression(
        pattern: #"(?i)\b(password|passwd|pwd|passcode|pin|secret|api[_ -]?key|token|cvv|cvc)\b\s*(?:is|was|:|=|-|–)?\s*["'`]?([^\s"'`,;]{3,64})"#)

    /// Replaces one-time codes, card numbers and spelled-out secrets with `[redacted]`.
    public static func redact(_ input: String) -> Redaction {
        var text = input
        var count = 0
        let ns = { (s: String) in NSRange(s.startIndex..<s.endIndex, in: s) }

        // 1. Card numbers (Luhn-valid runs of 13–19 digits).
        let cards = cardLike.matches(in: text, range: ns(text)).reversed()
        for m in cards {
            guard let r = Range(m.range, in: text) else { continue }
            let digits = text[r].filter(\.isNumber)
            if luhnValid(digits) {
                text.replaceSubrange(r, with: "[redacted card]")
                count += 1
            }
        }

        // 2. Explicit secrets: "password: hunter2", "PIN is 4321".
        let assigns = secretAssignment.matches(in: text, range: ns(text)).reversed()
        for m in assigns {
            guard m.numberOfRanges > 2, let r = Range(m.range(at: 2), in: text) else { continue }
            text.replaceSubrange(r, with: "[redacted]")
            count += 1
        }

        // 3. One-time codes: 4–8 digit runs (or 123-456 / 123 456) near a code word, or
        //    standalone in short SMS-style text.
        let contextHits = codeContext.matches(in: text, range: ns(text)).map { $0.range.location }
        let smsLike = input.count < 240 && !contextHits.isEmpty
        var ranges: [NSRange] = spacedCode.matches(in: text, range: ns(text)).map(\.range)
        ranges += digitRun.matches(in: text, range: ns(text)).map(\.range)
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            guard let r = Range(range, in: text) else { continue }
            let near = contextHits.contains { abs($0 - range.location) <= 48 }
            let isYear = range.length == 4 && (text[r].hasPrefix("19") || text[r].hasPrefix("20"))
            if (near || smsLike) && !(isYear && !near) {
                text.replaceSubrange(r, with: "[redacted code]")
                count += 1
            }
        }
        return Redaction(text: text, count: count)
    }

    public static func luhnValid(_ digits: String) -> Bool {
        let nums = digits.compactMap { $0.wholeNumberValue }
        guard nums.count >= 13, nums.count <= 19 else { return false }
        var sum = 0
        for (i, n) in nums.reversed().enumerated() {
            if i % 2 == 1 {
                let d = n * 2
                sum += d > 9 ? d - 9 : d
            } else {
                sum += n
            }
        }
        return sum % 10 == 0
    }
}
