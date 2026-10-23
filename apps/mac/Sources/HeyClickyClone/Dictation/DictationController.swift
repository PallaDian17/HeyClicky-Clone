import AppKit
import AVFoundation
import ClickyPrivacy
import Speech

/// Hold Option: capture speech, clean it up for the focused field, paste it,
/// verify it landed, then watch for corrections to learn new words.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable { case idle, listening, cleaning, inserting }
    static let localeKey = "ClickyDictationLocale"
    static var availableLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
    }
    static var chosenLocale: Locale {
        let id = UserDefaults.standard.string(forKey: localeKey) ?? ""
        return id.isEmpty ? .current : Locale(identifier: id)
    }

    @Published private(set) var phase: Phase = .idle
    let dictionary = DictationDictionary()

    private let notch: NotchViewModel
    private let backend: BackendClient
    private let privacy: PrivacyMonitor
    private var transcriber: DictationTranscriber?
    private var field = FocusedField()
    private var learnTask: Task<Void, Never>?

    init(notch: NotchViewModel, backend: BackendClient, privacy: PrivacyMonitor) {
        self.notch = notch
        self.backend = backend
        self.privacy = privacy
    }

    // MARK: - Gesture entry points

    func begin() {
        guard phase == .idle else { return }
        learnTask?.cancel()
        field = FocusedField.current()

        // Never dictate into a password field or a protected app.
        if field.isSecure || PrivacyMonitor.secureInputActive {
            notch.set(.notice("Not dictating into a password field"), autoDismissAfter: 3)
            return
        }
        if case .withhold(let reason) = privacy.guardian.assess(.init(bundleID: field.bundleID, appName: field.appName, windowTitle: field.title)) {
            notch.set(.notice("Not dictating here: \(reason.label)"), autoDismissAfter: 3)
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            notch.set(.notice("Microphone permission is needed to dictate"), autoDismissAfter: 4)
            return
        }

        phase = .listening
        notch.set(.dictating(""))
        Task { await startTranscriber() }
    }

    func end() {
        guard phase == .listening, let transcriber else { return }
        phase = .cleaning
        Task {
            let raw = await transcriber.finish()
            self.transcriber = nil
            await self.deliver(raw: raw)
        }
    }

    func cancel() {
        transcriber?.cancel()
        transcriber = nil
        learnTask?.cancel()
        phase = .idle
    }

    /// Debug path: skip the microphone and run cleanup + insertion on given text.
    func deliverSynthetic(_ text: String) {
        guard phase == .idle else { return }
        field = FocusedField.current()
        phase = .cleaning
        notch.set(.dictating(text))
        Task { await deliver(raw: text) }
    }

    // MARK: - Pipeline

    private func startTranscriber() async {
        do {
            let t = try await makeTranscriber()
            t.onPartial = { [weak self] text in
                guard let self, self.phase == .listening else { return }
                self.notch.set(.dictating(text))
            }
            try t.start()
            transcriber = t
        } catch {
            Log.app.error("dictation start failed: \(String(describing: error), privacy: .public)")
            phase = .idle
            notch.set(.notice(Self.friendly(error)), autoDismissAfter: 4)
        }
    }

    private func makeTranscriber() async throws -> DictationTranscriber {
        if let grant = try? await backend.dictationToken(), grant.provider == "deepgram", let key = grant.key, let url = grant.url {
            return try DeepgramTranscriber(url: url, key: key)
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { _ in cont.resume() } }
        }
        return AppleSpeechTranscriber(locale: Self.chosenLocale)
    }

    private func deliver(raw: String) async {
        let redacted = PrivacyGuard.redact(raw)
        let transcript = redacted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            phase = .idle
            notch.set(.notice("Didn't catch that"), autoDismissAfter: 2.5)
            return
        }
        phase = .cleaning
        notch.set(.dictating(transcript))

        var text = transcript
        do {
            text = try await backend.dictationCleanup(
                transcript: transcript,
                context: .init(appName: field.appName, fieldRole: field.role, fieldTitle: field.title, before: field.valueBefore.map { String($0.suffix(200)) }),
                dictionary: dictionary.words
            )
        } catch {
            Log.app.notice("dictation cleanup unavailable, inserting raw: \(String(describing: error), privacy: .public)")
        }
        text = PrivacyGuard.redact(text).text

        phase = .inserting
        // The field read at gesture start is the target; re-read if focus moved.
        if field.element == nil { field = FocusedField.current() }
        let outcome = await TextInsertion.insert(text, into: field)
        phase = .idle
        switch outcome {
        case .pasted, .setDirectly, .unverified:
            notch.set(.dictated(text), autoDismissAfter: 4)
            Log.app.info("dictation inserted \(text.count) chars (\(String(describing: outcome), privacy: .public))")
            watchForCorrections(inserted: text)
        case .failed(let why):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            notch.set(.notice("Couldn't insert (\(why)). Copied to clipboard."), autoDismissAfter: 5)
        }
    }

    /// Eight seconds after an insertion, compare the field to what was inserted.
    private func watchForCorrections(inserted: String) {
        learnTask?.cancel()
        let snapshot = field
        learnTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, let now = snapshot.currentValue() else { return }
            let before = snapshot.valueBefore ?? ""
            let added = now.hasPrefix(before) ? String(now.dropFirst(before.count)) : now
            let learned = DictationDictionary.learnedWords(inserted: inserted, edited: added)
            guard !learned.isEmpty else { return }
            learned.forEach { self.dictionary.add($0) }
            self.notch.set(.notice("Learned: \(learned.joined(separator: ", "))"), autoDismissAfter: 4)
            Log.app.info("dictation learned \(learned.count) word(s)")
        }
    }

    private static func friendly(_ error: Error) -> String {
        if let e = error as? AppleSpeechTranscriber.Failure {
            switch e {
            case .notAuthorized: return "Speech Recognition permission is needed to dictate"
            case .unavailable: return "Speech recognition is not available right now"
            }
        }
        return "Couldn't start dictation"
    }
}
