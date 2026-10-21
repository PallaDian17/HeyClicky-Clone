import AppKit
import ClickyPrivacy

/// Talk mode: hold the hotkey, speak, get an answer read aloud and pointed at.
///
/// Hold begins   -> harvest the accessibility tree, ask the privacy guard, capture
///                  the screen only if allowed; open voice session, stream mic
/// Hold ends     -> commit audio, wait for the transcript
/// Transcript    -> redact codes, POST /v1/chat with screenshot + elements (or a
///                  "screen withheld" note)
/// Answer        -> HUD reply card, pointer overlay, Realtime reads it aloud
@MainActor
final class TalkCoordinator {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    private(set) var phase: Phase = .idle

    private let notch: NotchViewModel
    private let backend: BackendClient
    private let overlay: PointingOverlayManager
    private let privacy: PrivacyMonitor
    private let voice = RealtimeVoiceClient()
    private let audio = VoiceAudioEngine()

    private struct Context {
        var shot: ScreenCapture.Shot?
        var harvest: AXHarvest
        var withheld: PrivacyGuard.Reason?
    }
    private var contextTask: Task<Context, Never>?
    private var transcriptContinuation: CheckedContinuation<String, Error>?
    private var history: [BackendClient.HistoryTurn] = []
    private var turnTask: Task<Void, Never>?

    /// Routes a hand-off to an agent. Receives the task, the named helper if any,
    /// and the screenshot (nil when withheld). Returns the agent's name, or nil if none took it.
    var onHandoff: ((_ task: String, _ agentHint: String?, _ screenshotJPEG: Data?) -> String?)?

    init(notch: NotchViewModel, backend: BackendClient, overlay: PointingOverlayManager, privacy: PrivacyMonitor) {
        self.notch = notch
        self.backend = backend
        self.overlay = overlay
        self.privacy = privacy
        wireVoice()
    }

    // MARK: - Hotkey entry points

    func beginHold() {
        if phase != .idle { cancel() }
        phase = .listening
        notch.set(.listening)
        overlay.hide()
        contextTask = Task { await self.captureContext() }

        Task { @MainActor in
            do {
                try await ensureVoice()
                guard phase == .listening else { return }
                voice.clearInput()
                try audio.startCapture { [weak self] chunk in
                    Task { @MainActor in self?.voice.appendAudio(chunk) }
                }
            } catch {
                Log.app.error("voice start failed: \(String(describing: error), privacy: .public)")
                phase = .idle
                notch.set(.notice(Self.friendly(error)), autoDismissAfter: 5)
            }
        }
    }

    func endHold() {
        guard phase == .listening else { return }
        audio.stopCapture()
        phase = .thinking
        notch.set(.thinking)
        guard voice.isConnected else {
            phase = .idle
            notch.set(.notice("Voice is not connected. Try again."), autoDismissAfter: 4)
            return
        }
        voice.commitInput()
        turnTask = Task { @MainActor in
            do {
                let transcript = try await waitForTranscript(timeout: 10)
                guard !transcript.isEmpty else {
                    phase = .idle
                    notch.set(.notice("Didn't catch that. Hold ⌃⌃ and try again."), autoDismissAfter: 4)
                    return
                }
                await runTurn(transcript: transcript)
            } catch {
                phase = .idle
                notch.set(.notice(Self.friendly(error)), autoDismissAfter: 5)
            }
        }
    }

    /// Typed question from the HUD prompt box or the debug URL.
    func ask(_ text: String) {
        if phase != .idle { cancel() }
        phase = .thinking
        notch.set(.thinking)
        contextTask = Task { await self.captureContext() }
        turnTask = Task { @MainActor in await runTurn(transcript: text) }
    }

    func cancel() {
        turnTask?.cancel()
        turnTask = nil
        transcriptContinuation?.resume(throwing: CancellationError())
        transcriptContinuation = nil
        audio.stopCapture()
        audio.stopPlayback()
        if voice.isConnected { voice.cancelResponse() }
        overlay.hide()
        phase = .idle
    }

    // MARK: - The turn

    private func runTurn(transcript rawTranscript: String) async {
        // Spoken or typed text may contain a code the user just read out; never forward it.
        let redaction = PrivacyGuard.redact(rawTranscript)
        let transcript = redaction.text
        if redaction.wasRedacted { Log.privacy.info("redacted \(redaction.count) item(s) from the question") }

        let context = await contextTask?.value ?? Context(shot: nil, harvest: .empty, withheld: nil)
        guard !Task.isCancelled else { return }
        if let reason = context.withheld {
            notch.set(.notice("Not looking: \(reason.label)"), autoDismissAfter: 2.5)
            try? await Task.sleep(for: .seconds(1.2))
        }
        notch.set(.thinking)
        let request = BackendClient.ChatRequest(
            transcript: transcript,
            screenshot: context.shot?.jpegBase64,
            appName: context.harvest.appName,
            elements: context.harvest.elements,
            history: Array(history.suffix(8)),
            screenWithheld: context.withheld?.label
        )
        do {
            let reply = try await backend.chat(request)
            guard !Task.isCancelled else { return }
            let replyText = PrivacyGuard.redact(reply.text).text
            history.append(.init(role: "user", text: transcript))
            history.append(.init(role: "assistant", text: replyText))

            if let handoff = reply.handoff, let onHandoff {
                let task = PrivacyGuard.redact(handoff.task).text
                let shot = context.withheld == nil ? context.shot.flatMap { Data(base64Encoded: $0.jpegBase64) } : nil
                if let name = onHandoff(task, handoff.agent_hint, shot) {
                    Log.app.info("handoff to \(name, privacy: .public) (\(task.count) chars, screenshot=\(shot != nil))")
                    notch.set(.reply("Handing that to \(name)."), autoDismissAfter: 5)
                    if voice.isUsable { phase = .speaking; voice.speak("Handing that to \(name).") } else { phase = .idle }
                    return
                }
            }

            notch.set(.reply(replyText), autoDismissAfter: 12)
            if context.withheld == nil { point(reply, context: context) }

            if voice.isUsable {
                phase = .speaking
                voice.speak(replyText)
            } else {
                phase = .idle
            }
        } catch {
            phase = .idle
            notch.set(.notice(Self.friendly(error)), autoDismissAfter: 6)
        }
    }

    private func point(_ reply: BackendClient.ChatResponse, context: Context) {
        if let id = reply.element_id, let element = context.harvest.elements.first(where: { $0.id == id }) {
            overlay.show(quartzRect: element.cgRect, label: element.title.isEmpty ? nil : element.title)
        } else if let box = reply.box, let screen = context.shot?.screen ?? NSScreen.main {
            overlay.show(normalizedBox: CGRect(x: box.x, y: box.y, width: box.w, height: box.h), on: screen, label: nil)
        }
    }

    // MARK: - Context capture (guarded)

    private func captureContext() async -> Context {
        // 1. Read the accessibility tree first: it is what the guard judges on.
        let harvest = await Task.detached(priority: .userInitiated) { AccessibilityHarvester.harvestFrontmost() }.value
        // 2. Ask the guard before any pixel is captured.
        let verdict = privacy.assessFrontmost(windowTitle: harvest.windowTitle, urls: harvest.urls, hasSecureField: harvest.hasSecureField)
        if case .withhold(let reason) = verdict {
            return Context(shot: nil, harvest: harvest.withheld(), withheld: reason)
        }
        // 3. Only now take the screenshot.
        var shot: ScreenCapture.Shot?
        do { shot = try await ScreenCapture.capture() } catch {
            Log.app.notice("screenshot skipped: \(String(describing: error), privacy: .public)")
        }
        // 4. Re-check secure input after the capture: a password field may have gained focus meanwhile.
        if PrivacyMonitor.secureInputActive {
            return Context(shot: nil, harvest: harvest.withheld(), withheld: .passwordField)
        }
        return Context(shot: shot, harvest: harvest, withheld: nil)
    }

    // MARK: - Voice plumbing

    private func wireVoice() {
        voice.onTranscript = { [weak self] text in
            guard let self else { return }
            Log.app.info("transcript received (\(text.count) chars)")
            transcriptContinuation?.resume(returning: text)
            transcriptContinuation = nil
        }
        voice.onAudio = { [weak self] data in self?.audio.enqueuePlayback(pcm16: data) }
        voice.onResponseDone = { [weak self] in
            guard let self, phase == .speaking else { return }
            phase = .idle
        }
        voice.onError = { [weak self] message in
            guard let self else { return }
            transcriptContinuation?.resume(throwing: RealtimeVoiceClient.Failure.server(message))
            transcriptContinuation = nil
        }
    }

    private func ensureVoice() async throws {
        if voice.isUsable { return }
        let grant = try await backend.mintRealtimeSession(voice: OnboardingModel.selectedVoice)
        try await voice.connect(grant: grant)
    }

    private func waitForTranscript(timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { cont in self.transcriptContinuation = cont }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw RealtimeVoiceClient.Failure.server("No transcript came back in time")
            }
            let first = try await group.next() ?? ""
            group.cancelAll()
            return first
        }
    }

    private static func friendly(_ error: Error) -> String {
        if let f = error as? VoiceAudioEngine.Failure, f == .noMicrophone { return "Microphone permission is needed to talk." }
        if let f = error as? BackendClient.Failure { return f.status == 0 ? "Can't reach the backend. Is it running?" : "Backend error \(f.status)." }
        if error is URLError { return "Can't reach the backend. Is it running?" }
        return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
    }
}
