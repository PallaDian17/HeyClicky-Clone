import AppKit

/// Talk mode: hold the hotkey, speak, get an answer read aloud and pointed at.
///
/// Hold begins   -> capture screen + accessibility tree, open voice session, stream mic
/// Hold ends     -> commit audio, wait for the transcript
/// Transcript    -> POST /v1/chat with screenshot + elements
/// Answer        -> HUD reply card, pointer overlay, Realtime reads it aloud
@MainActor
final class TalkCoordinator {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    private(set) var phase: Phase = .idle

    private let notch: NotchViewModel
    private let backend: BackendClient
    private let overlay: PointingOverlayManager
    private let voice = RealtimeVoiceClient()
    private let audio = VoiceAudioEngine()

    private struct Context {
        var shot: ScreenCapture.Shot?
        var harvest: AXHarvest
    }
    private var contextTask: Task<Context, Never>?
    private var transcriptContinuation: CheckedContinuation<String, Error>?
    private var history: [BackendClient.HistoryTurn] = []
    private var turnTask: Task<Void, Never>?

    init(notch: NotchViewModel, backend: BackendClient, overlay: PointingOverlayManager) {
        self.notch = notch
        self.backend = backend
        self.overlay = overlay
        wireVoice()
    }

    // MARK: - Hotkey entry points

    func beginHold() {
        if phase != .idle { cancel() }
        phase = .listening
        notch.set(.listening)
        overlay.hide()
        contextTask = Task { await Self.captureContext() }

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
        contextTask = Task { await Self.captureContext() }
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

    private func runTurn(transcript: String) async {
        let context = await contextTask?.value ?? Context(shot: nil, harvest: .empty)
        guard !Task.isCancelled else { return }
        notch.set(.thinking)
        let request = BackendClient.ChatRequest(
            transcript: transcript,
            screenshot: context.shot?.jpegBase64,
            appName: context.harvest.appName,
            elements: context.harvest.elements,
            history: Array(history.suffix(8))
        )
        do {
            let reply = try await backend.chat(request)
            guard !Task.isCancelled else { return }
            history.append(.init(role: "user", text: transcript))
            history.append(.init(role: "assistant", text: reply.text))

            notch.set(.reply(reply.text), autoDismissAfter: 12)
            point(reply, context: context)

            if voice.isUsable {
                phase = .speaking
                voice.speak(reply.text)
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

    // MARK: - Context capture

    private static func captureContext() async -> Context {
        async let shot: ScreenCapture.Shot? = {
            do { return try await ScreenCapture.capture() } catch {
                Log.app.notice("screenshot skipped: \(String(describing: error), privacy: .public)")
                return nil
            }
        }()
        let harvest = await Task.detached(priority: .userInitiated) { AccessibilityHarvester.harvestFrontmost() }.value
        return Context(shot: await shot, harvest: harvest)
    }

    // MARK: - Voice plumbing

    private func wireVoice() {
        voice.onTranscript = { [weak self] text in
            guard let self else { return }
            Log.app.info("transcript: \(text, privacy: .public)")
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
        let grant = try await backend.mintRealtimeSession()
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
