import AVFoundation
import ClickyPrivacy
import Speech

/// Push-to-talk straight into a Clicky, as recorded ("Speaking ‖‖ · Release to
/// send"): while a Clicky's page is open, the talk chord records with the
/// on-device recogniser, shows the words in the pill, and on release sends
/// the redacted transcript to that Clicky as a turn.
@MainActor
final class ClickyPushToTalk {
    private let notch: NotchViewModel
    private let runtime: AgentRuntime
    private var transcriber: DictationTranscriber?
    private(set) var agentID: UUID?

    init(notch: NotchViewModel, runtime: AgentRuntime) {
        self.notch = notch
        self.runtime = runtime
    }

    var isActive: Bool { agentID != nil }

    func begin(agentID: UUID) {
        guard self.agentID == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            notch.set(.notice("Microphone permission is needed to talk to a Clicky"), autoDismissAfter: 4)
            return
        }
        self.agentID = agentID
        notch.pushToTalk = .init(agentID: agentID, text: "")
        Task { @MainActor in
            do {
                if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                    await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { _ in cont.resume() } }
                }
                let t = AppleSpeechTranscriber(locale: DictationController.chosenLocale)
                t.onPartial = { [weak self] text in
                    Task { @MainActor in
                        guard let self, let id = self.agentID else { return }
                        self.notch.pushToTalk = .init(agentID: id, text: text)
                    }
                }
                guard self.agentID == agentID else { return }
                try t.start()
                transcriber = t
            } catch {
                Log.app.error("clicky push-to-talk start failed: \(String(describing: error), privacy: .public)")
                self.agentID = nil
                notch.pushToTalk = nil
                notch.set(.notice("Couldn't start listening: \(error.localizedDescription)"), autoDismissAfter: 4)
            }
        }
    }

    func end() {
        guard let agentID else { return }
        let transcriber = self.transcriber
        self.transcriber = nil
        self.agentID = nil
        Task { @MainActor in
            let raw = await transcriber?.finish() ?? ""
            deliver(raw, to: agentID)
        }
    }

    func cancel() {
        transcriber?.cancel()
        transcriber = nil
        agentID = nil
        notch.pushToTalk = nil
    }

    /// Debug path: no microphone, just the words.
    func deliverSynthetic(_ text: String, to agentID: UUID) { deliver(text, to: agentID) }

    private func deliver(_ raw: String, to agentID: UUID) {
        notch.pushToTalk = nil
        let text = PrivacyGuard.redact(raw).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            notch.set(.notice("Didn't catch that. Hold ⌃⌥ and try again."), autoDismissAfter: 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.notch.openClicky(agentID) }
            return
        }
        Log.app.info("clicky push-to-talk -> \(agentID.uuidString, privacy: .public): \(text.count) chars")
        runtime.send(text, to: agentID)
        notch.openClicky(agentID)
    }
}
