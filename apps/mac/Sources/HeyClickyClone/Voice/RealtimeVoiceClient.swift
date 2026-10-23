import Foundation

/// WebSocket client for the OpenAI Realtime API (GA event names, with the
/// beta names accepted too). Used for two things only: transcribing the user's
/// held-key speech, and reading the backend's answer aloud.
@MainActor
final class RealtimeVoiceClient: NSObject {
    enum Failure: LocalizedError {
        case notConnected, handshakeTimeout, server(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "Voice session is not connected"
            case .handshakeTimeout: return "Voice session did not come up in time"
            case .server(let m): return m
            }
        }
    }

    var onPartialTranscript: ((String) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onSpeechTranscriptDelta: ((String) -> Void)?
    var onResponseDone: (() -> Void)?
    var onError: ((String) -> Void)?

    private(set) var isConnected = false
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var expiresAt: Date = .distantPast
    private var readyContinuation: CheckedContinuation<Void, Error>?

    var isUsable: Bool { isConnected && Date() < expiresAt.addingTimeInterval(-30) }

    func connect(grant: BackendClient.RealtimeGrant) async throws {
        close()
        guard let url = URL(string: grant.url) else { throw Failure.server("bad realtime url") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(grant.clientSecret)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        expiresAt = Date(timeIntervalSince1970: grant.expiresAt)
        task.resume()
        receiveLoop(task)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.readyContinuation = cont
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw Failure.handshakeTimeout
            }
            try await group.next()
            group.cancelAll()
        }
        isConnected = true
        // Belt and braces: the secret was minted with these settings, but restate
        // the ones we depend on so a backend config drift cannot break the turn.
        send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "turn_detection": NSNull(),
                    ],
                    "output": ["format": ["type": "audio/pcm", "rate": 24000]],
                ],
            ],
        ])
        Log.app.info("realtime connected model=\(grant.model, privacy: .public) voice=\(grant.voice, privacy: .public)")
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
        readyContinuation?.resume(throwing: Failure.notConnected)
        readyContinuation = nil
    }

    // MARK: - Client events

    func appendAudio(_ pcm16: Data) {
        send(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }

    func commitInput() {
        send(["type": "input_audio_buffer.commit"])
    }

    func clearInput() {
        send(["type": "input_audio_buffer.clear"])
    }

    /// Reads `text` aloud, out of band so it never answers the conversation itself.
    /// Spoken language for every response; the session is minted with the same language.
    var language = "English"

    func speak(_ text: String) {
        send([
            "type": "response.create",
            "response": [
                "conversation": "none",
                "output_modalities": ["audio"],
                "instructions": "Speak in \(language) only; do not translate or switch languages. Read the following aloud exactly as written, nothing more:\n\n\(text)",
            ],
        ])
    }

    func cancelResponse() {
        send(["type": "response.cancel"])
    }

    private func send(_ event: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { error in
            if let error { Log.app.error("realtime send failed: \(String(describing: error), privacy: .public)") }
        }
    }

    // MARK: - Server events

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Task { @MainActor in
                    guard self.task === task else { return }
                    self.isConnected = false
                    self.readyContinuation?.resume(throwing: error)
                    self.readyContinuation = nil
                    self.onError?("voice connection dropped: \(error.localizedDescription)")
                }
            case .success(let message):
                if case .string(let text) = message, let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Task { @MainActor in self.handle(json) }
                }
                self.receiveLoop(task)
            }
        }
    }

    private func handle(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        switch type {
        case "session.created", "session.updated":
            readyContinuation?.resume()
            readyContinuation = nil
        case "conversation.item.input_audio_transcription.delta":
            if let delta = event["delta"] as? String { onPartialTranscript?(delta) }
        case "conversation.item.input_audio_transcription.completed":
            onTranscript?((event["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        case "conversation.item.input_audio_transcription.failed":
            onError?("transcription failed")
        case "response.output_audio.delta", "response.audio.delta":
            if let b64 = event["delta"] as? String, let data = Data(base64Encoded: b64) { onAudio?(data) }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            if let delta = event["delta"] as? String { onSpeechTranscriptDelta?(delta) }
        case "response.done":
            onResponseDone?()
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? "unknown realtime error"
            Log.app.error("realtime error: \(message, privacy: .public)")
            readyContinuation?.resume(throwing: Failure.server(message))
            readyContinuation = nil
            onError?(message)
        default:
            break
        }
    }
}

extension RealtimeVoiceClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let why = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        Log.app.info("realtime closed code=\(closeCode.rawValue) \(why, privacy: .public)")
        Task { @MainActor in self.isConnected = false }
    }
}
