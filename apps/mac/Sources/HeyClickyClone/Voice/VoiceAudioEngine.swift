import AVFoundation

/// Microphone capture and playback for the Realtime session.
/// Both sides use 24 kHz mono: capture emits Int16 PCM chunks, playback accepts them.
final class VoiceAudioEngine {
    static let sampleRate: Double = 24_000

    enum Failure: Error { case noMicrophone, formatUnavailable }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var captureHandler: ((Data) -> Void)?
    private var tapInstalled = false

    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

    var isCapturing: Bool { tapInstalled }

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
    }

    // MARK: - Capture

    func startCapture(onChunk: @escaping (Data) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Failure.noMicrophone }
        if tapInstalled { stopCapture() }
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
            throw Failure.formatUnavailable
        }
        self.converter = converter
        captureHandler = onChunk
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer)
        }
        tapInstalled = true
        try startEngineIfNeeded()
        Log.app.info("mic capture started at \(inputFormat.sampleRate)Hz")
    }

    func stopCapture() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        captureHandler = nil
    }

    private func convertAndEmit(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let handler = captureHandler else { return }
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let data = Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        handler(data)
    }

    // MARK: - Playback

    func enqueuePlayback(pcm16: Data) {
        let frames = pcm16.count / MemoryLayout<Int16>.size
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let out = buffer.floatChannelData![0]
            for i in 0..<frames { out[i] = Float(samples[i]) / 32768 }
        }
        do { try startEngineIfNeeded() } catch { return }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer)
    }

    func stopPlayback() {
        player.stop()
    }

    /// Stops everything so the mic indicator goes away.
    func shutdown() {
        stopCapture()
        player.stop()
        if engine.isRunning { engine.stop() }
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }
}
