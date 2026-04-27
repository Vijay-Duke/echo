import Foundation
import AVFoundation

enum AudioError: Error {
    case micDenied
    case notRunning
    case formatMismatch
    case prewarmFailed
}

final class AudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let tapBus: AVAudioNodeBus = 0
    private let tapBufferSize: AVAudioFrameCount = 1024

    /// Tap-side state. Updated atomically via `stateLock`. The tap reads these
    /// every callback; sessions swap them in/out. With prewarmAll() the engine
    /// is permanently running at app launch — sessions don't pay engine.start
    /// or voice-processing-enable cost on the hot path.
    private let stateLock = NSLock()
    private var targetRate: Double = 16000
    private var captureAcc: [Float] = []
    private var onCapture: (@Sendable (Data) -> Void)?
    private var onFloatFrame: (@Sendable ([Float]) -> Void)?
    private var onLevel: (@Sendable (Double) -> Void)?
    /// Broadcast gate. False when no session is active (or when assistant is
    /// playing back through speakers and we want to suppress mic feedback).
    private var isBroadcasting: Bool = false
    /// Mic mute (separate from broadcast — used for AEC anti-feedback during
    /// playback). Both must be permissive for chunks to flow.
    private var _micMuted: Bool = false

    private var inputSrcRate: Double = 48000

    /// True once the heavy hardware setup has run (VP, tap install, engine.start,
    /// player prime). Subsequent sessions just toggle isBroadcasting + callbacks.
    private(set) var isPrewarmed: Bool = false

    private let captureQueue = DispatchQueue(label: "echo.audio.capture")

    init() {
        engine.attach(playerNode)
        // Connect player → main mixer with MONO float32 format. Provider audio
        // always arrives as mono PCM16 (Gemini/OpenAI/Grok output 24kHz mono).
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 24000,
                                       channels: 1,
                                       interleaved: false)!
        engine.connect(playerNode, to: engine.mainMixerNode, format: monoFormat)
    }

    func setMicMuted(_ muted: Bool) {
        stateLock.lock(); _micMuted = muted; stateLock.unlock()
    }

    /// One-shot heavy setup: request mic permission, enable voice processing,
    /// install the capture tap, start the engine, prime the player with silence.
    /// Call once at app launch (after permissions are likely to be granted).
    /// Subsequent `startSession` calls become near-instant.
    func prewarmAll() async throws {
        if isPrewarmed { return }
        let permStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        NSLog("[Audio] prewarm: mic permission status=%d", permStatus.rawValue)
        try await Self.ensureMicPermission()

        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            NSLog("[Audio] voice processing enabled (AEC on)")
        } catch {
            NSLog("[Audio] voice processing unavailable: %{public}@", String(describing: error))
        }

        let inputFormat = input.outputFormat(forBus: tapBus)
        inputSrcRate = inputFormat.sampleRate
        NSLog("[Audio] input format: rate=%.0f ch=%d", inputSrcRate, inputFormat.channelCount)
        guard inputFormat.channelCount >= 1 else { throw AudioError.formatMismatch }

        var tapFireCount = 0
        input.installTap(onBus: tapBus, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            tapFireCount += 1
            guard let self else { return }
            guard let chData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { return }

            // Read state under lock (cheap — held briefly).
            self.stateLock.lock()
            let broadcasting = self.isBroadcasting
            let muted = self._micMuted
            let targetRate = self.targetRate
            let onCap = self.onCapture
            let onFloat = self.onFloatFrame
            let onLvl = self.onLevel
            let srcRate = self.inputSrcRate
            self.stateLock.unlock()

            // 20ms chunks @ targetRate (shorter = faster server VAD endpointing).
            let flushAt = Int(targetRate / 50)
            if flushAt <= 0 { return }

            // Copy mono channel 0.
            let ptr = chData[0]
            var samples = [Float](repeating: 0, count: frameCount)
            samples.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: ptr, count: frameCount)
            }

            // Downsample to target rate.
            let down = PCMConverter.downsample(samples, from: srcRate, to: targetRate)

            self.captureQueue.async {
                self.captureAcc.append(contentsOf: down)
                while self.captureAcc.count >= flushAt {
                    let chunk = Array(self.captureAcc.prefix(flushAt))
                    self.captureAcc.removeFirst(flushAt)
                    if !broadcasting || muted { continue }
                    if let onCap {
                        let data = PCMConverter.float32ToPCM16LE(chunk)
                        onCap(data)
                    }
                    onFloat?(chunk)
                    if let onLvl {
                        var sumSq: Double = 0
                        for s in chunk { sumSq += Double(s * s) }
                        let rms = (chunk.isEmpty ? 0 : (sumSq / Double(chunk.count)).squareRoot())
                        let normalized = min(1.0, rms * 4.0)
                        onLvl(normalized)
                    }
                }
            }

            if tapFireCount == 1 || tapFireCount % 200 == 0 {
                NSLog("[Audio] tap x%d frames=%d broadcasting=%d", tapFireCount, frameCount, broadcasting ? 1 : 0)
            }
        }

        engine.prepare()
        try engine.start()
        NSLog("[Audio] engine started (prewarm)")

        // Prime the player so first scheduleBuffer doesn't pay cold-start.
        playerNode.play()
        if let primeFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 24000, channels: 1,
                                        interleaved: false),
           let prime = AVAudioPCMBuffer(pcmFormat: primeFmt, frameCapacity: 480) {
            prime.frameLength = 480
            playerNode.scheduleBuffer(prime, completionHandler: nil)
            NSLog("[Audio] player primed")
        }

        isPrewarmed = true
    }

    /// Hot-path session activation. Requires `prewarmAll()` already finished.
    /// Just swaps callbacks + targetRate and flips broadcasting on. Sub-ms cost.
    func startSession(targetRate: Double,
                      onCapture: @escaping @Sendable (Data) -> Void,
                      onFloatFrame: (@Sendable ([Float]) -> Void)? = nil,
                      onLevel: (@Sendable (Double) -> Void)? = nil) {
        stateLock.lock()
        self.targetRate = targetRate
        self.onCapture = onCapture
        self.onFloatFrame = onFloatFrame
        self.onLevel = onLevel
        self.isBroadcasting = true
        // Reset mute. Otherwise a session that ended while muted (e.g. server
        // emitted .speaking but never .listening before we tore down on .idle)
        // would leave the next press silently dropping every chunk.
        self._micMuted = false
        stateLock.unlock()
        captureQueue.async { [weak self] in self?.captureAcc.removeAll(keepingCapacity: true) }
    }

    /// End-of-session: stop forwarding chunks, drop callbacks. Engine stays alive.
    func stopSession() {
        stateLock.lock()
        isBroadcasting = false
        onCapture = nil
        onFloatFrame = nil
        onLevel = nil
        stateLock.unlock()
        captureQueue.async { [weak self] in self?.captureAcc.removeAll(keepingCapacity: true) }
    }

    private static var playCount: Int = 0

    /// Schedule a PCM16LE chunk on the player at the given sample rate.
    func playPCM16(_ data: Data, rate: Int) {
        Self.playCount += 1
        let n = Self.playCount
        let floats = PCMConverter.pcm16LEToFloat32(data)
        guard floats.count >= 32,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(rate),
                                         channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(floats.count))
        else { return }

        buffer.frameLength = AVAudioFrameCount(floats.count)
        if let dst = buffer.floatChannelData?[0] {
            floats.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: floats.count)
            }
        }

        do {
            if !engine.isRunning { try engine.start() }
            if !playerNode.isPlaying { playerNode.play() }
            playerNode.scheduleBuffer(buffer, completionHandler: nil)
            if n == 1 { NSLog("[Audio] playPCM16 first chunk scheduled") }
        } catch {
            NSLog("[Audio] playPCM16 schedule error: %{public}@", String(describing: error))
        }
    }

    /// Flush any queued playback buffers without tearing down the engine.
    func cutPlayback() {
        playerNode.stop()
        playerNode.play()
    }

    /// Fully tear down. Call on app shutdown.
    func shutdown() {
        stopSession()
        engine.inputNode.removeTap(onBus: tapBus)
        playerNode.stop()
        engine.stop()
        engine.detach(playerNode)
        isPrewarmed = false
    }

    // MARK: - Permission

    private static func ensureMicPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw AudioError.micDenied }
        case .denied, .restricted:
            throw AudioError.micDenied
        @unknown default:
            throw AudioError.micDenied
        }
    }
}

/// Bounded ring buffer for audio chunks captured before the WSS is ready.
/// Caps at ~2 seconds of audio to bound memory in case connect hangs.
final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private let maxChunks: Int = 100  // 100 * 20ms = 2s

    func append(_ pcm: Data) {
        lock.lock()
        if chunks.count >= maxChunks { chunks.removeFirst() }
        chunks.append(pcm)
        lock.unlock()
    }

    func drain() -> [Data] {
        lock.lock()
        let out = chunks
        chunks.removeAll(keepingCapacity: false)
        lock.unlock()
        return out
    }
}

/// Tiny atomic-ish boolean for cross-actor readiness signaling.
final class ReadyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
