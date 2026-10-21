import AVFoundation
import Foundation
import Speech

/// A streaming speech-to-text session: start, feed audio (or let it capture
/// itself), get partial and final text.
protocol DictationTranscriber: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    func start() throws
    /// Stops capture and returns the final transcript (empty when nothing was heard).
    func finish() async -> String
    func cancel()
}

// MARK: - Apple Speech (on-device when available)

/// Uses SFSpeechRecognizer with the system microphone. No network when the
/// recognizer supports on-device recognition for the current locale.
final class AppleSpeechTranscriber: DictationTranscriber {
    enum Failure: Error { case unavailable, notAuthorized }

    var onPartial: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finalContinuation: CheckedContinuation<String, Never>?
    private var finished = false

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw Failure.notAuthorized }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        self.request = request
        latest = ""
        finished = false

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latest = result.bestTranscription.formattedString
                self.onPartial?(self.latest)
                if result.isFinal { self.complete() }
            }
            if error != nil { self.complete() }
        }
        Log.app.info("dictation: apple speech started onDevice=\(recognizer.supportsOnDeviceRecognition)")
    }

    func finish() async -> String {
        guard !finished else { return latest }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        // Wait briefly for the final result; whatever we have by then is the answer.
        return await withCheckedContinuation { cont in
            finalContinuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.complete() }
        }
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        task?.cancel()
        request = nil
        task = nil
        finished = true
        finalContinuation?.resume(returning: "")
        finalContinuation = nil
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        task?.finish()
        finalContinuation?.resume(returning: latest)
        finalContinuation = nil
    }
}

// MARK: - Deepgram (when the backend hands out a key)

/// Streams 16 kHz PCM to Deepgram's listen WebSocket with a short-lived key.
final class DeepgramTranscriber: NSObject, DictationTranscriber {
    enum Failure: Error { case badURL }

    var onPartial: ((String) -> Void)?

    private let url: URL
    private let key: String
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var finals: [String] = []
    private var partial = ""
    private var finalContinuation: CheckedContinuation<String, Never>?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    init(url: String, key: String) throws {
        guard let u = URL(string: url) else { throw Failure.badURL }
        self.url = u
        self.key = key
    }

    func start() throws {
        var request = URLRequest(url: url)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()
        receive()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.send(buffer)
        }
        engine.prepare()
        try engine.start()
        Log.app.info("dictation: deepgram started")
    }

    func finish() async -> String {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        socket?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        return await withCheckedContinuation { cont in
            finalContinuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.complete() }
        }
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        socket?.cancel(with: .normalClosure, reason: nil)
        finalContinuation?.resume(returning: "")
        finalContinuation = nil
    }

    private func complete() {
        let text = (finals + [partial]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        socket?.cancel(with: .normalClosure, reason: nil)
        finalContinuation?.resume(returning: text)
        finalContinuation = nil
    }

    private func send(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let data = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        socket?.send(.data(data)) { _ in }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            if case .success(let message) = result, case .string(let text) = message,
               let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
               let channel = obj["channel"] as? [String: Any],
               let alt = (channel["alternatives"] as? [[String: Any]])?.first,
               let transcript = alt["transcript"] as? String {
                if (obj["is_final"] as? Bool) == true {
                    if !transcript.isEmpty { self.finals.append(transcript) }
                    self.partial = ""
                } else {
                    self.partial = transcript
                }
                let shown = (self.finals + [self.partial]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                DispatchQueue.main.async { self.onPartial?(shown) }
            }
            if case .success = result { self.receive() }
        }
    }
}
