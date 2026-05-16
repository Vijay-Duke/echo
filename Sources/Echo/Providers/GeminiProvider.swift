import Foundation
import os.log

private let plog = OSLog(subsystem: "com.echo.session", category: "gemini")
@inline(__always) private func slog(_ msg: String) {
    os_log("%{public}@", log: plog, type: .info, msg)
}

/// VoiceProvider for Gemini Live API.
///
/// Connects directly to `wss://generativelanguage.googleapis.com/...` with
/// the API key as a query param (safe on-device since the key is local).
///
/// Concurrency model: all outbound WebSocket frames are pre-serialized to
/// JSON strings synchronously at enqueue time and pushed onto a single
/// `AsyncStream`. One `sendLoop` task drains that stream and awaits each
/// `task.send`. Because `AsyncStream.Continuation.yield` is thread-safe and
/// FIFO, audio frames and `activityStart`/`activityEnd` markers always reach
/// the server in the exact order the capture queue produced them — no
/// per-frame `Task` races. All mutable cross-task state is `stateLock`-guarded.
final class GeminiProvider: NSObject, VoiceProvider, @unchecked Sendable {
    let kind: ProviderKind = .gemini

    let events: AsyncStream<TranscriptEvent>
    private let yielder: AsyncStream<TranscriptEvent>.Continuation

    /// Outbound frame queue. Elements are fully-serialized JSON strings.
    private let outbound: AsyncStream<String>
    private let outboundYield: AsyncStream<String>.Continuation

    private let session: URLSession

    // MARK: cross-task mutable state — every access guarded by `stateLock`.
    private let stateLock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var setupContinuation: CheckedContinuation<Void, Error>?
    private var inputSeconds: Double = 0
    private var outputSeconds: Double = 0
    /// Set when the most recent audio frame is sent. Used to log the
    /// end-of-user-speech -> first-audio-out latency.
    private var lastAudioSentAt: Date?
    private var firstAudioOutLoggedThisTurn = false
    /// Set by `disconnect()`. Suppresses the `.error` the receive loop would
    /// otherwise emit when the socket is cancelled intentionally.
    private var isDisconnecting = false

    private var profile: Profile?

    override init() {
        let (stream, cont) = AsyncStream<TranscriptEvent>.makeStream()
        self.events = stream
        self.yielder = cont
        let (outStream, outCont) = AsyncStream<String>.makeStream()
        self.outbound = outStream
        self.outboundYield = outCont
        self.session = URLSession(configuration: .default)
        super.init()
    }

    // MARK: - Connect

    func connect(profile: Profile, apiKey: String) async throws {
        self.profile = profile
        stateLock.withLock {
            inputSeconds = 0
            outputSeconds = 0
        }

        yielder.yield(.stateChange(.connecting))

        var comps = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent")!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = comps.url else {
            throw NSError(domain: "GeminiProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad url"])
        }

        let t0 = Date()
        let task = session.webSocketTask(with: url)
        stateLock.withLock { self.task = task }
        task.resume()
        slog("connect: WSS resume()")

        // Receive loop must be live before setup so we catch setupComplete.
        let recv = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        let send = Task { [weak self] in
            guard let self else { return }
            await self.sendLoop()
        }
        stateLock.withLock { receiveTask = recv; sendTask = send }

        // Setup is enqueued first, so it is the first frame the sendLoop drains.
        enqueueJSON(["setup": setupBody(profile: profile)])
        slog("connect: setup enqueued (+\(Int(Date().timeIntervalSince(t0)*1000))ms)")

        // Wait for setupComplete.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stateLock.withLock { self.setupContinuation = cont }
        }
        slog("connect: setupComplete (+\(Int(Date().timeIntervalSince(t0)*1000))ms)")

        yielder.yield(.stateChange(.listening))
    }

    private func setupBody(profile: Profile) -> [String: Any] {
        // PTT-only app: client signals utterance boundaries explicitly via
        // activityStart/activityEnd. Server VAD off = zero silence wait.
        var setupBody: [String: Any] = [
            "model": profile.modelName,
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": ["voiceName": profile.voiceName]
                    ],
                    "languageCode": "en-US",
                ],
                "thinkingConfig": ["thinkingBudget": 0],
            ],
            "systemInstruction": [
                "parts": [["text": profile.systemPrompt]]
            ],
            "realtimeInputConfig": [
                "automaticActivityDetection": ["disabled": true],
                "turnCoverage": "TURN_INCLUDES_ONLY_ACTIVITY",
            ],
            "outputAudioTranscription": [:] as [String: Any],
            "inputAudioTranscription": [:] as [String: Any],
        ]
        if profile.webSearchEnabled == true {
            setupBody["tools"] = [["googleSearch": [:] as [String: Any]]]
        }
        return setupBody
    }

    // MARK: - Audio in / utterance markers (synchronous, FIFO enqueue)

    func sendAudio(_ pcm16: Data) {
        let b64 = pcm16.base64EncodedString()
        stateLock.lock()
        inputSeconds += Double(pcm16.count) / 2.0 / 16000.0
        lastAudioSentAt = Date()
        stateLock.unlock()
        enqueueJSON([
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": b64,
                ]
            ]
        ])
    }

    func startUtterance() {
        slog("activityStart")
        enqueueJSON(["realtimeInput": ["activityStart": [:] as [String: Any]]])
    }

    func endUtterance() {
        slog("activityEnd")
        enqueueJSON(["realtimeInput": ["activityEnd": [:] as [String: Any]]])
    }

    func interrupt() {
        // No-op: Gemini server handles barge-in; the app cuts local playback
        // directly. Kept for protocol conformance / future providers.
    }

    func disconnect() async {
        let (task, recv, send, cont):
            (URLSessionWebSocketTask?, Task<Void, Never>?, Task<Void, Never>?,
             CheckedContinuation<Void, Error>?) = stateLock.withLock {
            isDisconnecting = true
            let t = self.task; self.task = nil
            let r = receiveTask; receiveTask = nil
            let s = sendTask; sendTask = nil
            let c = setupContinuation; setupContinuation = nil
            return (t, r, s, c)
        }

        outboundYield.finish()      // ends the sendLoop
        recv?.cancel()
        send?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        cont?.resume(throwing: CancellationError())
        yielder.yield(.stateChange(.idle))
        yielder.finish()
    }

    /// Send a WebSocket-level ping to keep a parked (shadow) socket alive.
    /// Returns when the pong is received; throws on transport failure.
    func sendKeepAlive() async throws {
        let task = stateLock.withLock { self.task }
        guard let task = task else {
            throw NSError(domain: "GeminiProvider", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "no socket"])
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error = error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }
    }

    // MARK: - WS plumbing

    /// Serialize a JSON object and push it onto the outbound queue. Thread-safe
    /// and FIFO. A no-op after `disconnect()` (the stream is finished).
    private func enqueueJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let str = String(data: data, encoding: .utf8) else {
            NSLog("[Gemini] enqueue: JSON encode failed")
            return
        }
        outboundYield.yield(str)
    }

    /// Single consumer: drains the outbound queue and sends each frame in
    /// order. The only place `task.send` is ever called.
    private func sendLoop() async {
        for await str in outbound {
            let task = stateLock.withLock { self.task }
            guard let task = task else { continue }
            do {
                try await task.send(.string(str))
            } catch {
                let intentional = stateLock.withLock { isDisconnecting }
                if !intentional && !Task.isCancelled {
                    NSLog("[Gemini] send failed: %{public}@", String(describing: error))
                    yielder.yield(.error("ws send: \(error.localizedDescription)"))
                }
                return
            }
        }
    }

    private func receiveLoop() async {
        let task = stateLock.withLock { self.task }
        guard let task = task else { return }
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let s):
                    handleMessage(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { handleMessage(s) }
                @unknown default:
                    break
                }
            } catch {
                let intentional = stateLock.withLock { isDisconnecting }
                if !intentional && !Task.isCancelled {
                    yielder.yield(.error("ws receive: \(error.localizedDescription)"))
                    yielder.yield(.stateChange(.error(error.localizedDescription)))
                    resumeSetup(throwing: error)
                } else {
                    NSLog("[Gemini] receive loop ended (intentional disconnect)")
                }
                return
            }
        }
    }

    /// Resume the connect() continuation exactly once, under lock.
    private func resumeSetup(returning value: Void) {
        stateLock.lock()
        let cont = setupContinuation
        setupContinuation = nil
        stateLock.unlock()
        cont?.resume(returning: ())
    }
    private func resumeSetup(throwing error: Error) {
        stateLock.lock()
        let cont = setupContinuation
        setupContinuation = nil
        stateLock.unlock()
        cont?.resume(throwing: error)
    }

    // MARK: - Incoming message dispatch

    private func handleMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if obj["setupComplete"] != nil {
            resumeSetup(returning: ())
            return
        }

        if let sc = obj["serverContent"] as? [String: Any] {
            handleServerContent(sc)
        }

        if let err = obj["error"] {
            yielder.yield(.error("gemini: \(err)"))
        }
        // usageMetadata is the authoritative billing source (server-side token
        // counts). Replaces the local time-based estimate so the cost cap is
        // exact. Audio tokens map ~32 tokens/second of audio.
        if let usage = obj["usageMetadata"] as? [String: Any] {
            stateLock.lock()
            var newIn = inputSeconds
            var newOut = outputSeconds
            if let promptDetails = usage["promptTokensDetails"] as? [[String: Any]] {
                for d in promptDetails where (d["modality"] as? String) == "AUDIO" {
                    if let n = d["tokenCount"] as? Int { newIn = Double(n) / 32.0 }
                }
            }
            if let respDetails = usage["responseTokensDetails"] as? [[String: Any]] {
                for d in respDetails where (d["modality"] as? String) == "AUDIO" {
                    if let n = d["tokenCount"] as? Int { newOut = Double(n) / 32.0 }
                }
            }
            let changed = newIn != inputSeconds || newOut != outputSeconds
            inputSeconds = newIn
            outputSeconds = newOut
            stateLock.unlock()
            if changed {
                yielder.yield(.costUpdate(inputSeconds: newIn, outputSeconds: newOut))
            }
        }
        _ = obj["sessionResumptionUpdate"]
    }

    private func handleServerContent(_ sc: [String: Any]) {
        if let interrupted = sc["interrupted"] as? Bool, interrupted {
            // Signal listening so the app can cut local playback.
            yielder.yield(.stateChange(.listening))
        }

        if let input = sc["inputTranscription"] as? [String: Any],
           let text = input["text"] as? String, !text.isEmpty {
            yielder.yield(.userText(text))
        }

        if let output = sc["outputTranscription"] as? [String: Any],
           let text = output["text"] as? String, !text.isEmpty {
            yielder.yield(.assistantTextDelta(text))
        }

        if let modelTurn = sc["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any] else { continue }
                guard let b64 = inline["data"] as? String else { continue }
                guard let bytes = Data(base64Encoded: b64) else { continue }
                stateLock.lock()
                let firstOfTurn = !firstAudioOutLoggedThisTurn
                if firstOfTurn { firstAudioOutLoggedThisTurn = true }
                let sentAt = lastAudioSentAt
                stateLock.unlock()
                if firstOfTurn {
                    if let t = sentAt {
                        slog("turn: end-of-user-speech -> first-audio-out: \(Int(Date().timeIntervalSince(t) * 1000))ms")
                    } else {
                        slog("turn: first-audio-out (no audio-sent timestamp)")
                    }
                }
                // Skip tiny (sub-millisecond) chunks — AVAudio scheduling them
                // on the playback queue can crash the consumer Task silently.
                if bytes.count < 64 { continue }
                let mime = inline["mimeType"] as? String ?? ""
                let rate = parseRate(from: mime) ?? 24000
                stateLock.lock()
                outputSeconds += Double(bytes.count) / 2.0 / Double(rate)
                let inSec = inputSeconds, outSec = outputSeconds
                stateLock.unlock()
                yielder.yield(.audioOut(bytes, rate))
                yielder.yield(.costUpdate(inputSeconds: inSec, outputSeconds: outSec))
                yielder.yield(.stateChange(.speaking))
            }
        }

        if let done = sc["turnComplete"] as? Bool, done {
            slog("turn: complete")
            stateLock.lock()
            firstAudioOutLoggedThisTurn = false
            lastAudioSentAt = nil
            stateLock.unlock()
            yielder.yield(.assistantTextDone)
            yielder.yield(.stateChange(.listening))
        }
    }

    private func parseRate(from mime: String) -> Int? {
        // mimeType like "audio/pcm;rate=24000"
        guard let range = mime.range(of: "rate=") else { return nil }
        let tail = mime[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }
}
