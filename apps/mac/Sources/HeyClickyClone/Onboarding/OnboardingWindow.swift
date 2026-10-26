import AppKit
import AVFoundation
import SwiftUI

/// First-launch tour: meet the mascot, pick a voice and power-ups, grant
/// permissions, check the mic, learn the three gestures, meet the starter
/// squad. Re-runnable from the menu; progress is not persisted, only the
/// choices it makes (character, voice, skills) and the `ClickyOnboarded` flag.
@MainActor
final class OnboardingWindowController: NSWindowController {
    static let onboardedKey = "ClickyOnboarded"
    let model: OnboardingModel

    init(app: AppDelegate) {
        model = OnboardingModel(app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Hi Dicky"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        super.init(window: window)
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        model.onFinished = { [weak self] in self?.window?.close() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(step: OnboardingModel.Step? = nil) {
        if let step { model.step = step }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, character, voice, skills, permissions, micCheck, tutorial, squad, done }
    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    static let voiceKey = "ClickyVoice"
    static var selectedVoice: String { UserDefaults.standard.string(forKey: voiceKey) ?? "marin" }
    static let languageKey = "ClickyTalkLanguage"
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("hi", "Hindi"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]
    /// English unless changed in Setup; talk mode speaks and transcribes in this language only.
    static var selectedLanguage: String { UserDefaults.standard.string(forKey: languageKey) ?? "en" }
    static func languageName(_ code: String) -> String { languages.first { $0.code == code }?.name ?? "English" }

    @Published var step: Step = .welcome
    @Published var character: ClickyCharacter
    @Published var voice: String = OnboardingModel.selectedVoice
    @Published var previewing: String?
    @Published var previewError: String?
    @Published var selectedSkills: Set<String>
    @Published var micLevel: Double = 0
    @Published var micHeardYou = false
    @Published var tutorialIndex = 0

    let app: AppDelegate
    let skills: [AgentStore.BundledSkill]
    var onFinished: (() -> Void)?
    private var player: AVAudioPlayer?
    private var micEngine: AVAudioEngine?

    init(app: AppDelegate) {
        self.app = app
        character = app.characters.character
        skills = AgentStore.bundledSkills()
        selectedSkills = Set(skills.map(\.name))
    }

    var isLast: Bool { step == .done }
    var canGoBack: Bool { step != .welcome && step != .done }

    func next() {
        commitStep()
        if let n = Step(rawValue: step.rawValue + 1) { step = n } else { finish() }
    }

    func back() {
        if let p = Step(rawValue: step.rawValue - 1) { step = p }
    }

    private func commitStep() {
        switch step {
        case .character:
            app.characters.character = character
        case .voice:
            UserDefaults.standard.set(voice, forKey: Self.voiceKey)
            stopPreview()
        case .micCheck:
            stopMic()
        default: break
        }
    }

    func finish() {
        commitStep()
        for agent in app.agents.store.agents where agent.isStarter {
            for name in selectedSkills { app.agents.store.installSkill(named: name, for: agent) }
        }
        UserDefaults.standard.set(true, forKey: OnboardingWindowController.onboardedKey)
        Log.app.info("onboarding finished voice=\(self.voice, privacy: .public) skills=\(self.selectedSkills.sorted().joined(separator: ","), privacy: .public)")
        onFinished?()
    }

    // MARK: - Voice preview

    func preview(_ name: String) {
        previewing = name
        previewError = nil
        Task {
            do {
                let data = try await app.backend.voicePreview(voice: name)
                guard previewing == name else { return }
                let p = try AVAudioPlayer(data: data, fileTypeHint: "mp3")
                p.volume = 1
                p.prepareToPlay()
                player = p
                let ok = p.play()
                Log.app.info("voice preview \(name, privacy: .public): play=\(ok) duration=\(p.duration, format: .fixed(precision: 1))s device=\(p.currentDevice ?? "default", privacy: .public)")
                if !ok { previewError = "Couldn't start playback. Is an output device selected?" }
            } catch {
                previewError = "Preview unavailable: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
            previewing = nil
        }
    }

    func stopPreview() {
        player?.stop()
        player = nil
        previewing = nil
    }

    // MARK: - Mic check

    var micAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func startMic() {
        guard micEngine == nil else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.app.permissions.refresh()
                    if granted { self.startMic() }
                }
            }
            return
        }
        guard status == .authorized else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let level = min(1, Double(rms) * 12)
            DispatchQueue.main.async {
                self?.micLevel = level
                if level > 0.25 { self?.micHeardYou = true }
            }
        }
        do {
            try engine.start()
            micEngine = engine
            Log.app.info("mic check listening on \(input.inputFormat(forBus: 0).sampleRate)Hz")
        } catch {
            Log.app.error("mic check failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stopMic() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        micLevel = 0
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var permissions: PermissionsModel

    init(model: OnboardingModel) {
        self.model = model
        _permissions = ObservedObject(wrappedValue: model.app.permissions)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 36)
            footer
        }
        .foregroundStyle(.white)
        .frame(width: 760, height: 520)
        .animation(.easeInOut(duration: 0.2), value: model.step)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome:
            VStack(spacing: 18) {
                ClickyCharacterView(character: model.character, mood: .happy, size: 160)
                Text("Hi. I'm your Clicky.").font(.system(size: 30, weight: .bold))
                Text("I live in your menu bar. Hold a key and talk to me about what's on your screen, hand longer jobs to my Clickys, and dictate anywhere. Let's set things up; it takes about a minute.")
                    .font(.title3).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75)).frame(maxWidth: 560)
            }
        case .character:
            VStack(alignment: .leading, spacing: 14) {
                title("Make me yours", "This is how I'll look in the notch, in Home, and in every Clicky's card.")
                CharacterEditorView(character: $model.character)
            }
        case .voice:
            VStack(alignment: .leading, spacing: 14) {
                title("Pick a voice", "The voice you'll hear in talk mode. Tap one to preview it.")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(OnboardingModel.voices, id: \.self) { v in
                        Button {
                            model.voice = v
                            model.preview(v)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: model.previewing == v ? "waveform" : "play.circle").font(.title2)
                                Text(v.capitalized).font(.callout.weight(.medium))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(model.voice == v ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.voice == v ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let err = model.previewError { Text(err).font(.caption).foregroundStyle(.orange) }
            }
        case .skills:
            VStack(alignment: .leading, spacing: 14) {
                title("Power-ups", "Skills your starter Clickys begin with. You can add more later in each Clicky's folder.")
                ForEach(model.skills, id: \.name) { skill in
                    Toggle(isOn: Binding(get: { model.selectedSkills.contains(skill.name) },
                                         set: { on in if on { model.selectedSkills.insert(skill.name) } else { model.selectedSkills.remove(skill.name) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(.callout.weight(.semibold))
                            Text(skill.description).font(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
        case .permissions:
            VStack(alignment: .leading, spacing: 14) {
                title("Permissions", "Each one unlocks a part of me. Allow opens the right pane of System Settings with the app already listed.")
                ForEach(PermissionsModel.Kind.allCases, id: \.self) { kind in
                    permissionRow(kind)
                }
                Button("Re-check") { permissions.refresh() }.controlSize(.small)
            }
        case .micCheck:
            VStack(spacing: 18) {
                title("Say something", "A quick check that I can hear you.")
                if permissions.status(.microphone) == .granted || model.micAuthorized {
                    HStack(spacing: 4) {
                        ForEach(0..<24, id: \.self) { i in
                            let on = Double(i) / 24 < model.micLevel
                            RoundedRectangle(cornerRadius: 2).fill(on ? Color.green : Color.white.opacity(0.12)).frame(width: 14, height: 36)
                        }
                    }
                    Text(model.micHeardYou ? "Heard you loud and clear." : "Listening…").font(.callout).foregroundStyle(model.micHeardYou ? .green : .white.opacity(0.6))
                } else {
                    Text("Microphone isn't allowed yet.").font(.callout).foregroundStyle(.orange)
                    Button("Allow microphone") { permissions.request(.microphone) }
                }
            }
            .onAppear { model.startMic() }
            .onDisappear { model.stopMic() }
            .onChange(of: permissions.status(.microphone)) { _, status in
                if status == .granted { model.startMic() }
            }
        case .tutorial:
            VStack(alignment: .leading, spacing: 16) {
                title("Three gestures", "That's all there is to learn.")
                let steps: [(String, String, String, NotchState)] = [
                    ("⌃ ⌥", "Hold Control + Option", "to talk. Lasso anything on screen while holding; release and I answer out loud and mark what I mean.", .listening),
                    ("⌃ ⌃", "Double-tap Control", "opens a prompt box in the notch for a typed question.", .prompt),
                    ("⌥ hold", "Hold Option", "to dictate into whatever field is focused. Release to paste the cleaned-up text.", .dictating("hello comma this is dictation")),
                ]
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 14) {
                        Text(s.0).font(.system(size: 15, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(model.tutorialIndex == i ? 0.25 : 0.1)))
                            .frame(width: 92)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.1).font(.callout.weight(.semibold))
                            Text(s.2).font(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        Button("Show me") { model.tutorialIndex = i; model.app.demoHUD(s.3) }.controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(model.tutorialIndex == i ? 0.08 : 0.03)))
                }
                Text("Esc always closes the notch.").font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        case .squad:
            VStack(alignment: .leading, spacing: 14) {
                title("Your starter squad", "Two Clickys are ready in Home. Each has its own folder, memory and first asks.")
                HStack(spacing: 14) {
                    ForEach(model.app.agents.store.agents.filter(\.isStarter)) { agent in
                        VStack(spacing: 8) {
                            ClickyCharacterView(character: agent.character ?? .derived(from: agent.slug), mood: .happy, size: 84)
                            Text(agent.name).font(.headline)
                            Text(agent.purpose).font(.caption).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center).lineLimit(4)
                        }
                        .padding(14).frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)))
                    }
                }
                Text("Want a third? Home → New Clicky runs a short interview.").font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        case .done:
            VStack(spacing: 18) {
                ClickyCharacterView(character: model.character, mood: .happy, size: 140)
                Text("All set.").font(.system(size: 30, weight: .bold))
                Text("I'm in your menu bar. Double-tap Control whenever you need me.")
                    .font(.title3).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
            }
        }
    }

    private func permissionRow(_ kind: PermissionsModel.Kind) -> some View {
        let status: PermissionsModel.Status = permissions.status(kind)
        return HStack(spacing: 12) {
            Image(systemName: kind.symbol).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.callout.weight(.medium))
                Text(kind.reason).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Text(status.label).font(.caption).foregroundStyle(status == .granted ? Color.green : Color.orange)
            if status != .granted { Button("Allow") { permissions.request(kind) }.controlSize(.small) }
        }
        .padding(.vertical, 2)
    }

    private func title(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.system(size: 24, weight: .bold))
            Text(sub).font(.callout).foregroundStyle(.white.opacity(0.65))
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { s in
                    Capsule().fill(s == model.step ? Color.white : Color.white.opacity(0.2))
                        .frame(width: s == model.step ? 18 : 6, height: 6)
                }
            }
            Spacer()
            if model.canGoBack { Button("Back") { model.back() }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)) }
            Button(model.isLast ? "Start using Clicky" : (model.step == .welcome ? "Let's go" : "Continue")) { model.next() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(.horizontal, 32).padding(.vertical, 20)
        .background(Color.white.opacity(0.04))
    }
}
