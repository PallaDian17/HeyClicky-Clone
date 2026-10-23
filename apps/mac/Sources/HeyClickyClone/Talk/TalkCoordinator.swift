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
    let region = RegionSelectOverlayManager()
    /// Circle-to-ask bookkeeping: the action chosen before the key came up, and the words once they arrived.
    private var pendingRegion: (action: RegionSelectOverlayManager.Action, box: CGRect)?
    private var pendingTranscript: String?
    private var awaitingRegionWords = false
    /// The last circle-to-ask, kept for "Tell me more".
    private var lastRegionAsk: (question: String, answer: String, appName: String?, crop: Data?)?

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
        region.onAction = { [weak self] action, box in self?.regionChosen(action, box: box) }
        notch.onTellMore = { [weak self] in self?.tellMeMore() }
        region.onDismiss = { [weak self] in
            guard let self else { return }
            pendingRegion = nil
            pendingTranscript = nil
            awaitingRegionWords = false
            if phase == .thinking { phase = .idle; notch.collapse() }
        }
    }

    // MARK: - Hotkey entry points

    func beginHold() {
        if phase != .idle { cancel() }
        phase = .listening
        notch.set(.listening)
        overlay.hide()
        pendingRegion = nil
        pendingTranscript = nil
        awaitingRegionWords = false
        region.arm(on: NSScreen.main)
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
        let circling = region.hasSelection || pendingRegion != nil
        if !circling { region.disarmIfIdle() }
        guard voice.isConnected else {
            if circling {
                // No words possible; the region still works on its own.
                pendingTranscript = ""
                awaitingRegionWords = false
                notch.set(.notice("Circle something, then choose Ask, Hand to, or Copy."), autoDismissAfter: 4)
                if let p = pendingRegion { pendingRegion = nil; regionChosen(p.action, box: p.box) }
                return
            }
            phase = .idle
            notch.set(.notice("Voice is not connected. Try again."), autoDismissAfter: 4)
            return
        }
        voice.commitInput()
        awaitingRegionWords = circling
        turnTask = Task { @MainActor in
            do {
                let transcript = try await waitForTranscript(timeout: 10)
                if circling || region.hasSelection {
                    pendingTranscript = transcript
                    awaitingRegionWords = false
                    if let p = pendingRegion { pendingRegion = nil; regionChosen(p.action, box: p.box) }
                    else { notch.set(.notice(transcript.isEmpty ? "Choose Ask, Hand to, or Copy for what you circled." : "Got it: \"\(transcript.prefix(60))\". Choose Ask, Hand to, or Copy."), autoDismissAfter: 6) }
                    return
                }
                guard !transcript.isEmpty else {
                    phase = .idle
                    notch.set(.notice("Didn't catch that. Hold ⌃⌃ and try again."), autoDismissAfter: 4)
                    return
                }
                await runTurn(transcript: transcript)
            } catch {
                if circling { pendingTranscript = ""; awaitingRegionWords = false; if let p = pendingRegion { pendingRegion = nil; regionChosen(p.action, box: p.box) }; return }
                phase = .idle
                notch.set(.notice(Self.friendly(error)), autoDismissAfter: 5)
            }
        }
    }

    // MARK: - Circle-to-ask

    /// The user picked Ask / Hand to / Copy for a circled region.
    private func regionChosen(_ action: RegionSelectOverlayManager.Action, box: CGRect) {
        // Words still on their way (key not yet released, or transcript pending): remember the choice.
        if phase == .listening || awaitingRegionWords {
            pendingRegion = (action, box)
            if phase == .listening { notch.set(.notice("Let go of the key when you're done talking."), autoDismissAfter: 3) }
            return
        }
        let words = (pendingTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTranscript = nil
        switch action {
        case .ask:
            phase = .thinking
            notch.set(.thinking)
            if contextTask == nil { contextTask = Task { await self.captureContext() } }
            turnTask = Task { @MainActor in await runTurn(transcript: words.isEmpty ? "What is this?" : words, region: box) }
        case .handoff(let agentID):
            phase = .thinking
            notch.set(.thinking)
            turnTask = Task { @MainActor in await handoffRegion(box: box, words: words, agentID: agentID) }
        case .copy:
            Task { @MainActor in await copyRegion(box: box) }
        }
    }

    private func handoffRegion(box: CGRect, words: String, agentID: UUID?) async {
        let context = await contextTask?.value ?? Context(shot: nil, harvest: .empty, withheld: nil)
        if let reason = context.withheld {
            phase = .idle
            notch.set(.notice("Not looking: \(reason.label)"), autoDismissAfter: 3)
            return
        }
        let crop = context.shot?.crop(normalized: box)?.data
        let what = words.isEmpty ? "Tell me what this is and whether anything about it needs doing." : words
        let task = "The user circled a region of their screen\(context.harvest.appName.map { " in \($0)" } ?? ""); the attached image is that region. \(what)"
        let hint = agentID.flatMap { id in region.agentsProvider().first(where: { $0.id == id })?.name }
        if let name = onHandoff?(task, hint, crop) {
            notch.set(.reply("Handing that to \(name)."), autoDismissAfter: 5)
            if voice.isUsable { phase = .speaking; voice.speak("Handing that to \(name).") } else { phase = .idle }
            Log.app.info("region handoff to \(name, privacy: .public) crop=\(crop?.count ?? 0) bytes")
        } else {
            phase = .idle
            notch.set(.notice("No Clicky took that."), autoDismissAfter: 4)
        }
    }

    private func copyRegion(box: CGRect) async {
        let context = await contextTask?.value ?? Context(shot: nil, harvest: .empty, withheld: nil)
        phase = .idle
        if let reason = context.withheld {
            notch.set(.notice("Not copying: \(reason.label)"), autoDismissAfter: 3)
            return
        }
        guard let png = context.shot?.cropPNG(normalized: box) else {
            notch.set(.notice("Couldn't copy that region."), autoDismissAfter: 3)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        notch.set(.notice("Copied the circled region."), autoDismissAfter: 3)
        Log.app.info("region copied \(png.count) bytes")
    }

    /// "Tell me more" on a circle-to-ask reply: the crop, the question and Clicky's answer go to Scout
    /// (or the first Clicky) for a researched walkthrough in Home.
    func tellMeMore() {
        guard let last = lastRegionAsk else { return }
        notch.tellMoreAvailable = false
        let question = last.question == "What is this?" ? "What is this, what does it do here, and how do I use it?" : last.question
        let task = """
        The user circled part of their screen\(last.appName.map { " in \($0)" } ?? "") and asked: "\(question)". The attached image is exactly what they circled. Clicky's quick spoken answer was: "\(last.answer)".
        Go deeper. Explain what it is, what it does in this app, and how to use it step by step, with anything to watch out for and what happens afterwards. If the app or feature is public, check its documentation on the web and cite it. Write the walkthrough to output/ as Markdown and reply with the three sentences that matter most.
        """
        if let name = onHandoff?(task, "Scout", last.crop) {
            notch.set(.reply("Handing that to \(name) for the full story."), autoDismissAfter: 5)
            if voice.isUsable { phase = .speaking; voice.speak("Handing that to \(name) for the full story.") } else { phase = .idle }
            Log.app.info("tell-me-more handed to \(name, privacy: .public) crop=\(last.crop?.count ?? 0) bytes")
        } else {
            notch.set(.notice("No Clicky took that."), autoDismissAfter: 4)
        }
    }

    /// Debug: run a region action for a given normalized box without the overlay.
    func debugRegion(box: CGRect, text: String?, action: RegionSelectOverlayManager.Action) {
        if phase != .idle { cancel() }
        contextTask = Task { await self.captureContext() }
        pendingTranscript = text ?? ""
        regionChosen(action, box: box)
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
        region.dismiss(notify: false)
        pendingRegion = nil
        pendingTranscript = nil
        awaitingRegionWords = false
        phase = .idle
    }

    // MARK: - The turn

    private func runTurn(transcript rawTranscript: String, region box: CGRect? = nil) async {
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
        let crop = box.flatMap { context.withheld == nil ? context.shot?.crop(normalized: $0) : nil }
        if let box { Log.app.info("region ask box=\(NSStringFromRect(box), privacy: .public) crop=\(crop?.data.count ?? 0) bytes") }
        let request = BackendClient.ChatRequest(
            transcript: transcript,
            screenshot: context.shot?.jpegBase64,
            appName: context.harvest.appName,
            elements: context.harvest.elements,
            history: Array(history.suffix(8)),
            screenWithheld: context.withheld?.label,
            region: box.map { .init(x: $0.minX, y: $0.minY, w: $0.width, h: $0.height) },
            regionCrop: crop?.jpegBase64
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

            if let box, context.withheld == nil {
                lastRegionAsk = (transcript, replyText, context.harvest.appName, crop?.data)
                notch.tellMoreAvailable = true
            } else {
                lastRegionAsk = nil
                notch.tellMoreAvailable = false
            }
            notch.set(.reply(replyText), autoDismissAfter: box == nil ? 12 : 20)
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
        let grant = try await backend.mintRealtimeSession(voice: OnboardingModel.selectedVoice, language: OnboardingModel.selectedLanguage)
        voice.language = OnboardingModel.languageName(OnboardingModel.selectedLanguage)
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
