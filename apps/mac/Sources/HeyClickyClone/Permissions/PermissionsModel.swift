import AppKit
import AVFoundation
import Speech
import IOKit.hid
import ApplicationServices

@MainActor
final class PermissionsModel: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case accessibility, inputMonitoring, screenRecording, microphone, speech
        var id: String { rawValue }

        var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            case .screenRecording: return "Screen Recording"
            case .microphone: return "Microphone"
            case .speech: return "Speech Recognition"
            }
        }

        var reason: String {
            switch self {
            case .accessibility: return "Hotkey gestures and pointing at things on screen."
            case .inputMonitoring: return "Required: without it macOS switches the hotkey listener off within seconds, and ⌃⌥ does nothing."
            case .screenRecording: return "Seeing your screen when you press the hotkey. Never in the background."
            case .microphone: return "Talking to it."
            case .speech: return "On-device transcription fallback."
            }
        }

        var symbol: String {
            switch self {
            case .accessibility: return "hand.raised.fill"
            case .inputMonitoring: return "keyboard"
            case .screenRecording: return "rectangle.dashed.badge.record"
            case .microphone: return "mic.fill"
            case .speech: return "waveform"
            }
        }

        /// Needed for phase 1 to function; the rest can wait.
        var required: Bool { self == .accessibility }

        var settingsPane: String {
            switch self {
            case .accessibility: return "Privacy_Accessibility"
            case .inputMonitoring: return "Privacy_ListenEvent"
            case .screenRecording: return "Privacy_ScreenCapture"
            case .microphone: return "Privacy_Microphone"
            case .speech: return "Privacy_SpeechRecognition"
            }
        }
    }

    enum Status: Equatable {
        case granted, denied, notDetermined
        var label: String {
            switch self {
            case .granted: return "Granted"
            case .denied: return "Not granted"
            case .notDetermined: return "Not asked yet"
            }
        }
    }

    @Published private(set) var statuses: [Kind: Status] = [:]

    var allRequiredGranted: Bool {
        Kind.allCases.filter(\.required).allSatisfy { statuses[$0] == .granted }
    }

    var allGranted: Bool {
        Kind.allCases.allSatisfy { statuses[$0] == .granted }
    }

    func status(_ kind: Kind) -> Status { statuses[kind] ?? .notDetermined }

    func refresh() {
        var next: [Kind: Status] = [:]
        next[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: next[.inputMonitoring] = .granted
        case kIOHIDAccessTypeDenied: next[.inputMonitoring] = .denied
        default: next[.inputMonitoring] = .notDetermined
        }
        next[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .denied
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: next[.microphone] = .granted
        case .notDetermined: next[.microphone] = .notDetermined
        default: next[.microphone] = .denied
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: next[.speech] = .granted
        case .notDetermined: next[.speech] = .notDetermined
        default: next[.speech] = .denied
        }
        if next != statuses {
            statuses = next
            Log.permissions.info("\(next.map { "\($0.key.rawValue)=\($0.value.label)" }.sorted().joined(separator: " "), privacy: .public)")
        }
    }

    /// Triggers the system prompt where macOS offers one; otherwise opens System Settings.
    func request(_ kind: Kind) {
        switch kind {
        case .accessibility:
            // Registers this app (with its current code signature) in TCC and shows the
            // system prompt; the Settings pane then lists the right entry to switch on.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            if IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) == false { openSettings(kind) }
        case .screenRecording:
            // Registers the app and prompts once; a later call just returns false, so fall back to Settings.
            if !CGRequestScreenCaptureAccess() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, self.status(.screenRecording) != .granted else { return }
                    self.openSettings(kind)
                }
            }
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        case .speech:
            SFSpeechRecognizer.requestAuthorization { _ in
                Task { @MainActor in self.refresh() }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            self.refresh()
        }
    }

    func openSettings(_ kind: Kind) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsPane)")!
        NSWorkspace.shared.open(url)
    }
}
