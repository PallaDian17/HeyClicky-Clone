import AppKit
import ClickyPrivacy

/// Walkthrough mode: the teacher that takes you through a task one step at a
/// time. Each step comes from a fresh look at the screen plus the log of steps
/// already done, is pointed at on screen and spoken, and a click on the
/// highlighted target moves to the next one. Manual steps (typing, reading)
/// wait for "continue" or the Next button. At most 15 steps; Esc stops.
@MainActor
final class WalkthroughCoordinator {
    struct LogEntry { var instruction: String; var outcome: String }
    private struct Context { var shot: ScreenCapture.Shot?; var harvest: AXHarvest; var withheld: PrivacyGuard.Reason? }

    let maxSteps = 15
    private let notch: NotchViewModel
    private let backend: BackendClient
    private let overlay: PointingOverlayManager
    private let privacy: PrivacyMonitor
    /// Set by the app: speak a sentence through the talk voice.
    var speak: ((String) -> Void)?

    private(set) var goal: String?
    private(set) var log: [LogEntry] = []
    private var current: BackendClient.WalkthroughStep?
    private var targetRect: CGRect?          // Quartz (top-left origin) screen points
    private var clickMonitor: Any?
    private var stepTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var calls = 0
    private var busy = false

    var isActive: Bool { goal != nil }

    init(notch: NotchViewModel, backend: BackendClient, overlay: PointingOverlayManager, privacy: PrivacyMonitor) {
        self.notch = notch
        self.backend = backend
        self.overlay = overlay
        self.privacy = privacy
        notch.onWalkthroughNext = { [weak self] in self?.advance(outcome: "done, confirmed with Next") }
        notch.onWalkthroughStop = { [weak self] in self?.stop(say: "Okay, stopping here.") }
    }

    // MARK: - Entry points

    func start(goal: String) {
        reset()
        self.goal = goal
        Log.app.info("walkthrough start: \(goal.prefix(120), privacy: .public)")
        show(instruction: "", status: "Looking at your screen…", needsNext: false)
        requestStep(note: nil)
    }

    /// The talk chord or the Ask field while a walkthrough runs. Returns false when not active.
    func handle(transcript raw: String) -> Bool {
        guard isActive else { return false }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = text.lowercased()
        if t.isEmpty { return true }
        if ["stop", "cancel", "quit", "enough", "never mind", "nevermind"].contains(where: { t.contains($0) }) {
            stop(say: "Okay, stopping here.")
            return true
        }
        let confirmations = ["continue", "next", "done", "did it", "did that", "okay", "ok", "yes", "go on", "ready", "finished"]
        if t.split(separator: " ").count <= 4, confirmations.contains(where: { t.contains($0) }) {
            advance(outcome: "done, confirmed by voice")
            return true
        }
        guard !busy else { return true }
        show(instruction: current?.instruction ?? "", status: "Thinking about that…", needsNext: false)
        requestStep(note: "the user said: \"\(text)\"")
        return true
    }

    func stop(say text: String?) {
        let wasActive = isActive
        let steps = log.count
        reset()
        if wasActive, let text {
            speak?(text)
            notch.set(.notice(text), autoDismissAfter: 3)
        } else if case .walkthrough = notch.state {
            notch.collapse()
        }
        if wasActive { Log.app.info("walkthrough stopped after \(steps) step(s)") }
    }

    /// Debug: pretend the user clicked the target.
    func debugClickTarget() {
        guard let r = targetRect else { return }
        clicked(at: CGPoint(x: r.midX, y: r.midY))
    }

    // MARK: - Steps

    private func requestStep(note: String?) {
        guard let goal else { return }
        stepTask?.cancel()
        calls += 1
        guard calls <= 40 else { stop(say: "That's as far as I can take this one."); return }
        busy = true
        removeMonitor()
        stepTask = Task { @MainActor in
            let ctx = await captureContext()
            guard !Task.isCancelled, self.goal != nil else { return }
            let req = BackendClient.WalkthroughStepRequest(
                goal: goal, appName: ctx.harvest.appName, screenshot: ctx.shot?.jpegBase64,
                elements: ctx.harvest.elements, screenWithheld: ctx.withheld?.label,
                log: log.map { .init(instruction: $0.instruction, outcome: $0.outcome) },
                note: note, maxSteps: maxSteps)
            do {
                var step: BackendClient.WalkthroughStep
                do { step = try await backend.walkthroughStep(req) } catch {
                    // One retry: the model endpoint hiccups now and then.
                    Log.app.notice("walkthrough step retrying: \(String(describing: error).prefix(160), privacy: .public)")
                    try await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, self.goal != nil else { return }
                    step = try await backend.walkthroughStep(req)
                }
                guard !Task.isCancelled, self.goal != nil else { return }
                busy = false
                present(step, context: ctx)
            } catch {
                busy = false
                Log.app.error("walkthrough step failed: \(String(describing: error), privacy: .public)")
                stop(say: nil)
                notch.set(.notice("The walkthrough hit an error. Try again in a moment."), autoDismissAfter: 6)
            }
        }
    }

    private func present(_ step: BackendClient.WalkthroughStep, context: Context) {
        current = step
        let doneText = PrivacyGuard.redact(step.summary ?? step.say).text
        if step.done || log.count >= maxSteps {
            Log.app.info("walkthrough done after \(self.log.count) step(s)")
            overlay.clear()
            targetRect = nil
            notch.set(.walkthrough(.init(goal: goal ?? "", step: log.count, maxSteps: maxSteps, instruction: doneText, status: nil, needsNext: false, done: true)))
            speak?(doneText)
            finishTask?.cancel()
            finishTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                self.reset()
                if case .walkthrough = self.notch.state { self.notch.collapse() }
            }
            return
        }
        targetRect = nil
        if let t = step.target {
            if let id = t.element_id, let el = context.harvest.elements.first(where: { $0.id == id }) {
                targetRect = el.cgRect
            } else if let b = t.box, let screen = context.shot?.screen ?? NSScreen.main {
                targetRect = PointingOverlayManager.quartz(normalized: CGRect(x: b.x, y: b.y, width: b.w, height: b.h), on: screen)
            }
        }
        if let r = targetRect, context.withheld == nil {
            overlay.showTargets([(r, .box, step.target?.label ?? step.instruction)], over: 0.3)
        } else {
            overlay.clear()
        }
        let manual = step.done_when != "click" || targetRect == nil
        show(instruction: step.instruction,
             status: manual ? "When that's done, say \"continue\" or press Next" : "Click the highlighted spot and I'll carry on",
             needsNext: manual)
        speak?(PrivacyGuard.redact(step.say).text)
        Log.app.info("walkthrough step \(self.log.count + 1): \(step.instruction, privacy: .public) when=\(step.done_when, privacy: .public) target=\(self.targetRect.map { NSStringFromRect($0) } ?? "none", privacy: .public)")
        installMonitor()
    }

    private func advance(outcome: String) {
        guard let current, !busy else { return }
        log.append(.init(instruction: current.instruction, outcome: outcome))
        show(instruction: current.instruction, status: "Nice. Looking at what's on screen now…", needsNext: false)
        overlay.clear()
        settleThenRequest(note: nil)
    }

    /// Pages take a moment after a click; look again once things have settled.
    private func settleThenRequest(note: String?) {
        stepTask?.cancel()
        busy = true
        removeMonitor()
        stepTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, self.goal != nil else { return }
            self.busy = false
            self.requestStep(note: note)
        }
    }

    // MARK: - Clicks

    private func installMonitor() {
        removeMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            let p = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, let primary = NSScreen.screens.first else { return }
                self.clicked(at: CGPoint(x: p.x, y: primary.frame.height - p.y))
            }
        }
    }

    private func removeMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func clicked(at q: CGPoint) {
        guard let current, !busy else { return }
        if let r = targetRect, r.insetBy(dx: -10, dy: -10).contains(q) {
            Log.app.info("walkthrough: clicked the target")
            advance(outcome: "clicked \(current.target?.label ?? "the target")")
        } else if current.done_when == "click" {
            Log.app.info("walkthrough: clicked elsewhere")
            show(instruction: current.instruction, status: "That wasn't the spot. Let me look again…", needsNext: false)
            settleThenRequest(note: "the user clicked somewhere else on screen (\(Int(q.x)),\(Int(q.y))), not the highlighted target; they may have done the step another way or gone elsewhere")
        }
    }

    // MARK: - Plumbing

    private func show(instruction: String, status: String?, needsNext: Bool) {
        notch.set(.walkthrough(.init(goal: goal ?? "", step: log.count + 1, maxSteps: maxSteps, instruction: instruction, status: status, needsNext: needsNext, done: false)))
    }

    private func reset() {
        stepTask?.cancel(); stepTask = nil
        finishTask?.cancel(); finishTask = nil
        removeMonitor()
        overlay.clear()
        goal = nil; current = nil; targetRect = nil; log = []; calls = 0; busy = false
    }

    private func captureContext() async -> Context {
        let harvest = await Task.detached(priority: .userInitiated) { AccessibilityHarvester.harvestFrontmost() }.value
        let verdict = privacy.assessFrontmost(windowTitle: harvest.windowTitle, urls: harvest.urls, hasSecureField: harvest.hasSecureField)
        if case .withhold(let reason) = verdict { return Context(shot: nil, harvest: harvest.withheld(), withheld: reason) }
        var shot: ScreenCapture.Shot?
        do { shot = try await ScreenCapture.capture() } catch { Log.app.notice("walkthrough screenshot skipped: \(String(describing: error), privacy: .public)") }
        if PrivacyMonitor.secureInputActive { return Context(shot: nil, harvest: harvest.withheld(), withheld: .passwordField) }
        return Context(shot: shot, harvest: harvest, withheld: nil)
    }
}
