import ClickyPrivacy
import Foundation

// Minimal assertion harness: prints each check, exits 1 if any fails.
var failures = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if condition() {
        print("  ok   \(name)")
    } else {
        failures += 1
        let d = detail()
        print("  FAIL \(name)\(d.isEmpty ? "" : " — \(d)")")
    }
}

let guardian = PrivacyGuard(userProtectedApps: ["MyBankApp"])
typealias C = PrivacyGuard.Context

print("Verdicts")
check("ordinary window allowed", guardian.assess(C(bundleID: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "notes.txt")) == .allow)
check("secure input withholds", guardian.assess(C(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Docs", secureInputActive: true)) == .withhold(.passwordField))
check("secure field in tree withholds", guardian.assess(C(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Some App", hasSecureField: true)) == .withhold(.passwordField))
check("password manager bundle withholds", guardian.assess(C(bundleID: "com.1password.1password", appName: "1Password")) == .withhold(.protectedApp("1Password")))
check("protected name fragment withholds", guardian.assess(C(bundleID: "com.example.vault", appName: "Acme Authenticator")) == .withhold(.protectedApp("Acme Authenticator")))
check("user list withholds", guardian.assess(C(bundleID: "com.example.mybankapp", appName: "MyBankApp")) == .withhold(.protectedApp("MyBankApp")))
check("System Settings withholds", guardian.assess(C(bundleID: "com.apple.systempreferences", appName: "System Settings")) == .withhold(.protectedApp("System Settings")))
check("checkout URL -> payment", guardian.assess(C(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Shop", urls: ["https://shop.example.com/checkout/step2"])) == .withhold(.protectedPage("payment")))
check("google sign-in URL -> sign-in", guardian.assess(C(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Google", urls: ["https://accounts.google.com/v3/signin/identifier"])) == .withhold(.protectedPage("sign-in")))
check("verification title -> verification", guardian.assess(C(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Enter your verification code")) == .withhold(.protectedPage("verification")))
check("bank title -> banking", guardian.assess(C(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "HDFC Bank NetBanking")) == .withhold(.protectedPage("banking")))
check("ordinary URL allowed", guardian.assess(C(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Swift Forums", urls: ["https://forums.swift.org/t/some-thread/1234"])) == .allow)

print("Redaction")
let sms = PrivacyGuard.redact("Your verification code is 482913. It expires in 10 minutes.")
check("sms code redacted", sms.wasRedacted && !sms.text.contains("482913") && sms.text.contains("[redacted code]"), sms.text)
let spaced = PrivacyGuard.redact("G-123 456 is your Google code")
check("spaced code redacted", !spaced.text.contains("123 456"), spaced.text)
let card = PrivacyGuard.redact("Pay with 4111 1111 1111 1111 please")
check("luhn card redacted", card.text.contains("[redacted card]") && !card.text.contains("4111"), card.text)
let order = PrivacyGuard.redact("Order id 1234567890123 shipped")
check("non-luhn long number kept", !order.text.contains("[redacted card]"), order.text)
let pw = PrivacyGuard.redact("my password is hunter2 and the pin: 4321")
check("spelled password and pin redacted", !pw.text.contains("hunter2") && !pw.text.contains("4321"), pw.text)
let prose = PrivacyGuard.redact("In 2026 the team shipped 12 releases. The meeting room is 4120 on floor 3, and the budget was 250000 for the whole year of planning and hiring across the org.")
check("years and plain numbers in prose kept", prose.count == 0 && prose.text.contains("2026"), prose.text)
let phone = PrivacyGuard.redact("Call me at 9876543210 tomorrow about the project timeline and the venue details for Friday")
check("phone number kept", phone.count == 0, phone.text)
check("luhn valid", PrivacyGuard.luhnValid("4111111111111111"))
check("luhn invalid", !PrivacyGuard.luhnValid("4111111111111112") && !PrivacyGuard.luhnValid("1234"))

print(failures == 0 ? "\nAll privacy checks passed." : "\n\(failures) privacy check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
