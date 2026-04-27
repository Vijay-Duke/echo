import Foundation
import OnnxRuntimeBindings

/// Client-side voice activity detector that gates audio frames before they
/// are forwarded to the realtime provider. Uses the official Silero VAD ONNX
/// model executed via Microsoft's onnxruntime Objective-C bindings.
///
/// Inference contract (Silero VAD v5):
///   - Input "input"  : Float32, shape [1, 512]   (32 ms @ 16 kHz)
///   - Input "state"  : Float32, shape [2, 1, 128] (LSTM state, init zeros)
///   - Input "sr"     : Int64,   shape []          (sample rate, 16000)
///   - Output "output": Float32, shape [1, 1]      (speech probability)
///   - Output "stateN": Float32, shape [2, 1, 128] (next LSTM state)
///
/// Hysteresis: speech starts when prob > positiveThreshold, ends after
/// `redemptionFrames` consecutive frames with prob < negativeThreshold.
final class VadGate: @unchecked Sendable {
    enum Event { case speechStart, speechEnd }

    var onEvent: ((Event) -> Void)?

    // Tunables.
    private let positiveThreshold: Float = 0.5
    private let negativeThreshold: Float = 0.35
    private let redemptionFrames: Int = 8       // ~256 ms before declaring end
    private let frameSize: Int = 512            // Silero v5 fixed window @ 16 kHz
    private let contextSize: Int = 64           // v5 prepends last 64 samples of prior frame
    private let modelRate: Double = 16000

    // Speaking state (atomic via lock).
    private let lock = NSLock()
    private var _isSpeaking: Bool = false
    private var silenceCounter: Int = 0
    private var pending: [Float] = []           // 16 kHz samples awaiting inference
    /// Sliding 64-sample context — last 64 samples of the previous (context+frame)
    /// window. Required by Silero v5; without it prob stays ~0.
    private var context: [Float] = []

    // ONNX runtime resources.
    private var env: ORTEnv?
    private var session: ORTSession?
    private var state: [Float]                  // [2,1,128] flat
    private let stateShape: [NSNumber] = [2, 1, 128]
    private let inputShape: [NSNumber] = [1, NSNumber(value: 512 + 64)]
    private let srShape: [NSNumber] = []        // scalar

    var isSpeaking: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isSpeaking
    }

    init?() {
        self.state = [Float](repeating: 0, count: 2 * 1 * 128)
        self.context = [Float](repeating: 0, count: 64)
        guard let url = Bundle.module.url(forResource: "silero_vad", withExtension: "onnx") else {
            NSLog("[VadGate] silero_vad.onnx missing from bundle")
            return nil
        }
        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let opts = try ORTSessionOptions()
            try opts.setIntraOpNumThreads(1)
            self.env = env
            self.session = try ORTSession(env: env,
                                          modelPath: url.path,
                                          sessionOptions: opts)
            NSLog("[VadGate] init OK, model=%@", url.lastPathComponent)
        } catch {
            NSLog("[VadGate] failed to load Silero ONNX: \(error)")
            return nil
        }
    }

    private static var feedCounter: Int = 0

    func reset() {
        lock.lock()
        _isSpeaking = false
        silenceCounter = 0
        pending.removeAll(keepingCapacity: true)
        for i in 0..<state.count { state[i] = 0 }
        for i in 0..<context.count { context[i] = 0 }
        lock.unlock()
    }

    /// Feed a chunk of mono Float32 samples captured at `rate`. The gate will
    /// downsample to 16 kHz, accumulate 512-sample windows, and run inference.
    func feed(_ frame: [Float], rate: Double) {
        Self.feedCounter += 1
        if Self.feedCounter == 1 || Self.feedCounter % 50 == 0 {
            NSLog("[VadGate] feed x%d frame=%d rate=%.0f", Self.feedCounter, frame.count, rate)
        }
        guard !frame.isEmpty else { return }
        let resampled: [Float]
        if abs(rate - modelRate) < 0.5 {
            resampled = frame
        } else {
            resampled = PCMConverter.downsample(frame, from: rate, to: modelRate)
        }
        lock.lock()
        pending.append(contentsOf: resampled)
        var windowsToRun: [[Float]] = []
        while pending.count >= frameSize {
            windowsToRun.append(Array(pending.prefix(frameSize)))
            pending.removeFirst(frameSize)
        }
        lock.unlock()

        for window in windowsToRun {
            runInference(window: window)
        }
    }

    // MARK: - Internal

    private static var inferCounter: Int = 0

    private func runInference(window: [Float]) {
        guard let session = session else {
            NSLog("[VadGate] runInference: session nil")
            return
        }
        Self.inferCounter += 1
        if Self.inferCounter == 1 { NSLog("[VadGate] first inference") }
        do {
            // Silero v5 input is [1, context(64) + frame(512)] = [1, 576].
            // Without the context prefix the model returns prob~0 always.
            let total = contextSize + frameSize
            var combined = [Float](repeating: 0, count: total)
            for i in 0..<contextSize { combined[i] = context[i] }
            for i in 0..<frameSize { combined[contextSize + i] = window[i] }

            let inputData = NSMutableData(length: total * MemoryLayout<Float>.size)!
            combined.withUnsafeBufferPointer { src in
                inputData.replaceBytes(in: NSRange(location: 0, length: inputData.length),
                                       withBytes: src.baseAddress!)
            }
            let inputTensor = try ORTValue(tensorData: inputData,
                                           elementType: .float,
                                           shape: inputShape)

            // Update context for next call: last 64 samples of this combined window.
            for i in 0..<contextSize { context[i] = combined[total - contextSize + i] }

            // state tensor [2,1,128]
            let stateData = NSMutableData(length: state.count * MemoryLayout<Float>.size)!
            state.withUnsafeBufferPointer { src in
                stateData.replaceBytes(in: NSRange(location: 0, length: stateData.length),
                                       withBytes: src.baseAddress!)
            }
            let stateTensor = try ORTValue(tensorData: stateData,
                                           elementType: .float,
                                           shape: stateShape)

            // sr scalar int64
            var sr: Int64 = 16000
            let srData = NSMutableData(bytes: &sr, length: MemoryLayout<Int64>.size)
            let srTensor = try ORTValue(tensorData: srData,
                                        elementType: .int64,
                                        shape: srShape)

            let outputs = try session.run(
                withInputs: [
                    "input": inputTensor,
                    "state": stateTensor,
                    "sr": srTensor,
                ],
                outputNames: ["output", "stateN"],
                runOptions: nil
            )
            if Self.inferCounter == 1 {
                NSLog("[VadGate] session.run returned %d outputs", outputs.count)
            }

            if Self.inferCounter == 1 {
                NSLog("[VadGate] output keys: %@", outputs.keys.joined(separator: ","))
            }
            guard let outVal = outputs["output"],
                  let stateOut = outputs["stateN"] else {
                if Self.inferCounter <= 3 {
                    NSLog("[VadGate] missing output/stateN keys: %@", outputs.keys.joined(separator: ","))
                }
                return
            }

            let outData = try outVal.tensorData() as Data
            var prob: Float = 0
            outData.withUnsafeBytes { raw in
                if let p = raw.bindMemory(to: Float.self).baseAddress {
                    prob = p.pointee
                }
            }

            // Persist next LSTM state.
            let nextStateData = try stateOut.tensorData() as Data
            nextStateData.withUnsafeBytes { raw in
                if let p = raw.bindMemory(to: Float.self).baseAddress {
                    let count = min(state.count, nextStateData.count / MemoryLayout<Float>.size)
                    for i in 0..<count { state[i] = p[i] }
                }
            }

            applyHysteresis(prob: prob)
        } catch {
            NSLog("[VadGate] inference error: \(error)")
        }
    }

    private static var hysteresisLogCounter: Int = 0

    private func applyHysteresis(prob: Float) {
        Self.hysteresisLogCounter += 1
        if Self.hysteresisLogCounter == 1 || Self.hysteresisLogCounter % 30 == 0 {
            NSLog("[VadGate] prob=%.3f speaking=%d", prob, _isSpeaking ? 1 : 0)
        }
        lock.lock()
        let wasSpeaking = _isSpeaking
        var fireStart = false
        var fireEnd = false

        if prob > positiveThreshold {
            silenceCounter = 0
            if !_isSpeaking {
                _isSpeaking = true
                fireStart = true
            }
        } else if prob < negativeThreshold {
            if _isSpeaking {
                silenceCounter += 1
                if silenceCounter >= redemptionFrames {
                    _isSpeaking = false
                    silenceCounter = 0
                    fireEnd = true
                }
            }
        } else {
            // Between thresholds: if speaking, treat as ambiguous (no counter bump).
            if !_isSpeaking { silenceCounter = 0 }
        }
        _ = wasSpeaking
        lock.unlock()

        if fireStart { onEvent?(.speechStart) }
        if fireEnd { onEvent?(.speechEnd) }
    }
}
