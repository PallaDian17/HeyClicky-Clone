import AppKit
import ClickyPrivacy

/// Talk mode, as recorded: hold Control + Option, speak (and lasso anything on
/// screen), release. The answer is read aloud, shown as a thread in the notch
/// with follow-up chips, and annotated on screen with numbered markers and
/// underlines revealed as the explanation goes. A lasso with no words makes
/// the assistant ask what to do with the highlighted section.
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

    private struct Context {
        var shot: ScreenCapture.Shot?
        var harvest: AXHarvest
        var withheld: PrivacyGuard.Reason?
    }
    private var contextTask: Task<Context, Never>?
    private var lastContext: Context?
    private var transcriptContinuation: CheckedContinuation<String, Error>?
    private var history: [BackendClient.HistoryTurn] = []
    private var turnTask: Task<Void, Never>?
    private var thread = ConversationModel()
    private var dismissTask: Task<Void, Never>?

    /// Circle-to-ask: the lasso drawn during the current hold, and the last one for follow-ups.
    private var pendingRegionBox: CGRect?
    private var lastRegion: (box: CGRect, at: Date)?
    private var lastRegionAsk: (question: String, answer: String, appName: String?, crop: Data?)?

    /// Routes a hand-off to an agent. Receives the task, the named helper if any,
    /// and the screenshot (nil when withheld). Returns the agent's name, or nil if none took it.
    var onHandoff: ((_ task: String, _ agentHint: String?, _ screenshotJPEG: Data?) -> String?)?
    /// The model decided the question is a multi-step task: start walkthrough mode with this goal.
    var onWalkthrough: ((String) -> Void)?
    /// Gets every transcript / typed question first; returns true when it consumed it (a running walkthrough).
    var transcriptHook: ((String) -> Bool)?
    /// Memory of the user, injected into the chat and the voice session.
    var memory: (() -> String?)?
    /// A finished talk exchange, for learning.
    var onExchange: ((_ user: String, _ assistant: String) -> Void)?

    init(notch: NotchViewModel, backend: BackendClient, overlay: PointingOverlayManager, privacy: PrivacyMonitor) {
        self.notch = notch
        self.backend = backend
        self.overlay = overlay
        self.privacy = privacy
        wireVoice()
        region.silent = true
        region.onSelected = { [weak self] box in
            guard let self else { return }
            pendingRegionBox = box
            lastRegion = (box, Date())
        }
        notch.onConversationSend = { [weak self] text in self?.send(text) }
        notch.onClearAnnotations = { [weak self] in self?.clearAnnotations() }
        notch.onTellMore = { [weak self] in self?.tellMeMore() }
    }

    // MARK: - Hotkey entry points

    func beginHold() {
        if phase == .speaking || phase == .thinking { cancelTurnKeepThread() }
        guard phase == .idle else { return }
        dismissTask?.cancel()
        phase = .listening
        thread.status = "Listening…"
        notch.set(.listening)
        pendingRegionBox = nil
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
                region.dismiss(notify: false)
                notch.set(.notice(Self.friendly(error)), autoDismissAfter: 5)
            }
        }
    }

    func endHold() {
        guard phase == .listening else { return }
        audio.stopCapture()
        phase = .thinking
        notch.set(.thinking)
        let box = pendingRegionBox
        pendingRegionBox = nil
        if box != nil { region.stopCapturing() } else { region.disarmIfIdle() }

        guard voice.isConnected else {
            if let box {
                turnTask = Task { @MainActor in await runTurn(transcript: "", region: box) }
            } else {
                phase = .idle
                notch.set(.notice("Voice is not connected. Try again."), autoDismissAfter: 4)
            }
            return
        }
        voice.commitInput()
        turnTask = Task { @MainActor in
            var transcript = ""
            do { transcript = try await waitForTranscript(timeout: 10) } catch {
                if box == nil {
                    phase = .idle
                    notch.set(.notice(Self.friendly(error)), autoDismissAfter: 5)
                    return
                }
            }
            if transcript.isEmpty, box == nil {
                phase = .idle
                notch.set(.notice("Didn't catch that. Hold ⌃⌥ and try again."), autoDismissAfter: 4)
                return
            }
            if box == nil, let transcriptHook, transcriptHook(transcript) {
                phase = .idle
                region.dismiss(notify: false)
                return
            }
            await runTurn(transcript: transcript, region: box)
        }
    }

    /// Speak a sentence through the talk voice (walkthrough steps).
    func say(_ text: String) {
        Task { @MainActor in
            do { try await ensureVoice() } catch { return }
            if voice.isUsable { phase = .speaking; voice.cancelResponse(); voice.speak(text) }
        }
    }

    /// Typed question (prompt box, Ask field, chips, debug URL). Reuses a recent lasso.
    func ask(_ text: String) {
        if let transcriptHook, transcriptHook(text) { return }
        if phase != .idle { cancelTurnKeepThread() }
        dismissTask?.cancel()
        phase = .thinking
        notch.set(.thinking)
        contextTask = Task { await self.captureContext() }
        let box = lastRegion.flatMap { Date().timeIntervalSince($0.at) < 90 ? $0.box : nil }
        turnTask = Task { @MainActor in await runTurn(transcript: text, region: box) }
    }

    /// Chips and the Ask field send through here; the thread stays on screen.
    func send(_ text: String) { ask(text) }

    func cancel() {
        cancelTurnKeepThread()
        overlay.hide()
        region.dismiss(notify: false)
        lastRegion = nil
        thread.canClear = false
        phase = .idle
    }

    private func cancelTurnKeepThread() {
        turnTask?.cancel()
        turnTask = nil
        transcriptContinuation?.resume(throwing: CancellationError())
        transcriptContinuation = nil
        audio.stopCapture()
        audio.stopPlayback()
        if voice.isConnected { voice.cancelResponse() }
        thread.status = nil
        phase = .idle
    }

    /// The "✕ Clear" chip: annotations and the lasso go away, the thread stays.
    func clearAnnotations() {
        overlay.clear()
        region.dismiss(notify: false)
        thread.canClear = false
        showThread()
    }

    // MARK: - The turn

    private func runTurn(transcript rawTranscript: String, region box: CGRect? = nil) async {
        let redaction = PrivacyGuard.redact(rawTranscript)
        let transcript = redaction.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if redaction.wasRedacted { Log.privacy.info("redacted \(redaction.count) item(s) from the question") }

        let context = await contextTask?.value ?? lastContext ?? Context(shot: nil, harvest: .empty, withheld: nil)
        lastContext = context
        guard !Task.isCancelled else { return }
        if let reason = context.withheld {
            notch.set(.notice("Not looking: \(reason.label)"), autoDismissAfter: 2.5)
            try? await Task.sleep(for: .seconds(1.2))
        }
        if !transcript.isEmpty { thread.messages.append(.init(role: .user, text: transcript)) }
        thread.status = "Thinking…"
        thread.chips = []
        showThread()

        let crop = box.flatMap { context.withheld == nil ? context.shot?.crop(normalized: $0) : nil }
        if let box { Log.app.info("region ask box=\(NSStringFromRect(box), privacy: .public) words=\(transcript.count) crop=\(crop?.data.count ?? 0) bytes") }
        let request = BackendClient.ChatRequest(
            transcript: transcript.isEmpty ? "(no words)" : transcript,
            screenshot: context.shot?.jpegBase64,
            appName: context.harvest.appName,
            elements: context.harvest.elements,
            history: Array(history.suffix(8)),
            screenWithheld: context.withheld?.label,
            region: box.map { .init(x: $0.minX, y: $0.minY, w: $0.width, h: $0.height) },
            regionCrop: crop?.jpegBase64,
            memory: memory?()
        )
        do {
            let reply = try await backend.chat(request)
            guard !Task.isCancelled else { return }
            let replyText = PrivacyGuard.redact(reply.text).text
            if !transcript.isEmpty { history.append(.init(role: "user", text: transcript)) }
            history.append(.init(role: "assistant", text: replyText))
            if !transcript.isEmpty, reply.clarify != true { onExchange?(transcript, replyText) }

            if let handoff = reply.handoff, let onHandoff, reply.clarify != true {
                let task = PrivacyGuard.redact(handoff.task).text
                let shot = context.withheld == nil ? context.shot.flatMap { Data(base64Encoded: $0.jpegBase64) } : nil
                if let name = onHandoff(task, handoff.agent_hint, shot) {
                    Log.app.info("handoff to \(name, privacy: .public) (\(task.count) chars, screenshot=\(shot != nil))")
                    thread.messages.append(.init(role: .assistant, text: "Handing that to \(name)."))
                    thread.status = nil
                    showThread(dismissAfter: 8)
                    if voice.isUsable { phase = .speaking; voice.speak("Handing that to \(name).") } else { phase = .idle }
                    return
                }
            }

            if let goal = reply.walkthrough?.goal, reply.clarify != true, let onWalkthrough {
                Log.app.info("walkthrough requested: \(goal.prefix(100), privacy: .public)")
                thread.messages.append(.init(role: .assistant, text: replyText))
                thread.status = nil
                phase = .idle
                onWalkthrough(goal)
                return
            }
            thread.messages.append(.init(role: .assistant, text: replyText))
            thread.chips = reply.follow_ups ?? []
            if let box, context.withheld == nil {
                lastRegionAsk = (transcript.isEmpty ? "What is this?" : transcript, replyText, context.harvest.appName, crop?.data)
                notch.tellMoreAvailable = reply.clarify != true
            } else {
                notch.tellMoreAvailable = false
            }

            // Annotate while speaking: numbered targets in speaking order.
            let targets = annotationTargets(from: reply, context: context)
            if !targets.isEmpty, context.withheld == nil {
                let words = Double(replyText.split(separator: " ").count)
                overlay.showTargets(targets, over: max(2, words / 2.6))
                thread.canClear = true
            } else if context.withheld == nil {
                point(reply, context: context)
                thread.canClear = false
            }
            thread.status = voice.isUsable ? "Speaking…" : nil
            showThread(dismissAfter: voice.isUsable ? nil : 25)
            Log.app.info("talk reply: \(replyText.count) chars targets=\(targets.count) chips=\(self.thread.chips.count) clarify=\(reply.clarify ?? false)")

            if voice.isUsable {
                phase = .speaking
                voice.speak(replyText)
            } else {
                phase = .idle
            }
        } catch {
            phase = .idle
            thread.status = nil
            notch.set(.notice(Self.friendly(error)), autoDismissAfter: 6)
        }
    }

    private func showThread(dismissAfter seconds: TimeInterval? = nil) {
        dismissTask?.cancel()
        notch.set(.conversation(thread))
        guard let seconds else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.phase == .idle else { return }
            if case .conversation = self.notch.state { self.notch.collapse() }
        }
    }

    private func annotationTargets(from reply: BackendClient.ChatResponse, context: Context) -> [(rect: CGRect, kind: AnnotationTarget.Kind, label: String?)] {
        guard let targets = reply.targets, !targets.isEmpty else { return [] }
        let screen = context.shot?.screen ?? NSScreen.main
        return targets.compactMap { t in
            let kind = AnnotationTarget.Kind(rawValue: t.kind) ?? .box
            if let id = t.element_id, let element = context.harvest.elements.first(where: { $0.id == id }) {
                return (element.cgRect, kind, t.label)
            }
            if let b = t.box, let screen {
                return (PointingOverlayManager.quartz(normalized: CGRect(x: b.x, y: b.y, width: b.w, height: b.h), on: screen), kind, t.label)
            }
            return nil
        }
    }

    private func point(_ reply: BackendClient.ChatResponse, context: Context) {
        if let id = reply.element_id, let element = context.harvest.elements.first(where: { $0.id == id }) {
            overlay.show(quartzRect: element.cgRect, label: element.title.isEmpty ? nil : element.title)
        } else if let box = reply.box, let screen = context.shot?.screen ?? NSScreen.main {
            overlay.show(normalizedBox: CGRect(x: box.x, y: box.y, width: box.w, height: box.h), on: screen, label: nil)
        }
    }

    // MARK: - Tell me more (hand the circled thing to Scout)

    func tellMeMore() {
        guard let last = lastRegionAsk else { return }
        notch.tellMoreAvailable = false
        let question = last.question == "What is this?" ? "What is this, what does it do here, and how do I use it?" : last.question
        let task = """
        The user circled part of their screen\(last.appName.map { " in \($0)" } ?? "") and asked: "\(question)". The attached image is exactly what they circled. Clicky's quick spoken answer was: "\(last.answer)".
        Go deeper. Explain what it is, what it does in this app, and how to use it step by step, with anything to watch out for and what happens afterwards. If the app or feature is public, check its documentation on the web and cite it. Write the walkthrough to output/ as Markdown and reply with the three sentences that matter most.
        """
        if let name = onHandoff?(task, "Scout", last.crop) {
            thread.messages.append(.init(role: .assistant, text: "Handing that to \(name) for the full story."))
            showThread(dismissAfter: 8)
            if voice.isUsable { phase = .speaking; voice.speak("Handing that to \(name) for the full story.") } else { phase = .idle }
            Log.app.info("tell-me-more handed to \(name, privacy: .public) crop=\(last.crop?.count ?? 0) bytes")
        } else {
            notch.set(.notice("No Clicky took that."), autoDismissAfter: 4)
        }
    }

    /// Debug: run a region ask (or copy / hand-off) for a normalized box without the overlay.
    func debugRegion(box: CGRect, text: String?, action: RegionSelectOverlayManager.Action) {
        if phase != .idle { cancelTurnKeepThread() }
        lastRegion = (box, Date())
        switch action {
        case .ask:
            phase = .thinking
            notch.set(.thinking)
            contextTask = Task { await self.captureContext() }
            turnTask = Task { @MainActor in await runTurn(transcript: text ?? "", region: box) }
        case .handoff(let agentID):
            contextTask = Task { await self.captureContext() }
            turnTask = Task { @MainActor in
                let context = await contextTask?.value ?? Context(shot: nil, harvest: .empty, withheld: nil)
                let crop = context.withheld == nil ? context.shot?.crop(normalized: box)?.data : nil
                let hint = agentID.flatMap { id in region.agentsProvider().first(where: { $0.id == id })?.name }
                let what = (text ?? "").isEmpty ? "Tell me what this is and whether anything about it needs doing." : text!
                if let name = onHandoff?("The user circled a region of their screen; the attached image is that region. \(what)", hint, crop) {
                    notch.set(.reply("Handing that to \(name)."), autoDismissAfter: 5)
                }
            }
        case .copy:
            contextTask = Task { await self.captureContext() }
            turnTask = Task { @MainActor in
                let context = await contextTask?.value ?? Context(shot: nil, harvest: .empty, withheld: nil)
                guard context.withheld == nil, let png = context.shot?.cropPNG(normalized: box) else { notch.set(.notice("Couldn't copy that region."), autoDismissAfter: 3); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
                notch.set(.notice("Copied the circled region."), autoDismissAfter: 3)
                Log.app.info("region copied \(png.count) bytes")
            }
        }
    }

    // MARK: - Context capture (guarded)

    private func captureContext() async -> Context {
        let harvest = await Task.detached(priority: .userInitiated) { AccessibilityHarvester.harvestFrontmost() }.value
        let verdict = privacy.assessFrontmost(windowTitle: harvest.windowTitle, urls: harvest.urls, hasSecureField: harvest.hasSecureField)
        if case .withhold(let reason) = verdict {
            return Context(shot: nil, harvest: harvest.withheld(), withheld: reason)
        }
        var shot: ScreenCapture.Shot?
        do { shot = try await ScreenCapture.capture() } catch {
            Log.app.notice("screenshot skipped: \(String(describing: error), privacy: .public)")
        }
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
            thread.status = nil
            if case .conversation = notch.state { showThread(dismissAfter: 25) }
        }
        voice.onError = { [weak self] message in
            guard let self else { return }
            transcriptContinuation?.resume(throwing: RealtimeVoiceClient.Failure.server(message))
            transcriptContinuation = nil
        }
    }

    private func ensureVoice() async throws {
        if voice.isUsable { return }
        let grant = try await backend.mintRealtimeSession(voice: OnboardingModel.selectedVoice, language: OnboardingModel.selectedLanguage, memory: memory?())
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
        if let f = error as? BackendClient.Failure { return f.status == 0 ? "The backend isn't answering yet. Setup → Backend." : "Backend error \(f.status)." }
        if error is URLError { return "The backend isn't running. Setup → Backend." }
        return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
    }
}
