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
/// Mirrors the working JS reference at `public/gemini.html`.
final class GeminiProvider: NSObject, VoiceProvider, @unchecked Sendable {
    let kind: ProviderKind = .gemini

    let events: AsyncStream<TranscriptEvent>
    private let yielder: AsyncStream<TranscriptEvent>.Continuation

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var setupContinuation: CheckedContinuation<Void, Error>?

    private var profile: Profile?
    private var inputSeconds: Double = 0
    private var outputSeconds: Double = 0
    /// Set when first audio frame is sent to server (= user speaks). Cleared on
    /// turn complete. Used to log end-of-user-speech -> first-audio-out delta.
    private var lastAudioSentAt: Date?
    private var firstAudioOutLoggedThisTurn: Bool = false
    /// Set by `disconnect()`. Suppresses the .error event the receiveLoop
    /// would otherwise emit when the URLSession task is intentionally cancelled.
    private var isDisconnecting: Bool = false

    override init() {
        let (stream, cont) = AsyncStream<TranscriptEvent>.makeStream()
        self.events = stream
        self.yielder = cont
        self.session = URLSession(configuration: .default)
        super.init()
    }

    // MARK: - Connect

    func connect(profile: Profile, apiKey: String) async throws {
        self.profile = profile
        self.inputSeconds = 0
        self.outputSeconds = 0

        yielder.yield(.stateChange(.connecting))

        var comps = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent")!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = comps.url else {
            throw NSError(domain: "GeminiProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad url"])
        }

        let t0 = Date()
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        slog("connect: WSS resume()")

        // Start receive loop before sending setup so we catch setupComplete.
        receiveTask = Task { [weak self] in await self?.receiveLoop() }

        try await sendSetup(profile: profile)
        slog("connect: setup sent (+\(Int(Date().timeIntervalSince(t0)*1000))ms)")

        // Wait for setupComplete.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.setupContinuation = cont
        }
        slog("connect: setupComplete (+\(Int(Date().timeIntervalSince(t0)*1000))ms)")

        yielder.yield(.stateChange(.listening))
    }

    private func sendSetup(profile: Profile) async throws {
        // PTT-only app: server VAD stays enabled so multi-turn works while the
        // hotkey is held. Release tears the WSS down entirely.
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
                // 2-key PTT: client signals utterance boundaries explicitly via
                // activityStart/activityEnd. Server VAD off = zero silence wait.
                "automaticActivityDetection": ["disabled": true],
                "turnCoverage": "TURN_INCLUDES_ONLY_ACTIVITY",
            ],
            "outputAudioTranscription": [:] as [String: Any],
            "inputAudioTranscription": [:] as [String: Any],
        ]
        if profile.webSearchEnabled == true {
            setupBody["tools"] = [["googleSearch": [:] as [String: Any]]]
        }
        try await sendJSON(["setup": setupBody])
    }

    // MARK: - Audio in / utterance markers

    func sendAudio(_ pcm16: Data) async throws {
        let b64 = pcm16.base64EncodedString()
        inputSeconds += Double(pcm16.count) / 2.0 / 16000.0
        lastAudioSentAt = Date()
        let msg: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "mimeType": "audio/pcm;rate=16000",
                    "data": b64,
                ]
            ]
        ]
        try await sendJSON(msg)
    }

    func startUtterance() async throws {
        slog("activityStart")
        try await sendJSON(["realtimeInput": ["activityStart": [:] as [String: Any]]])
    }

    func endUtterance() async throws {
        slog("activityEnd")
        try await sendJSON(["realtimeInput": ["activityEnd": [:] as [String: Any]]])
    }

    func interrupt() async throws {
        // No-op: Gemini server VAD handles barge-in; manual modes use endUtterance.
        // Main app cuts local playback in response to .stateChange(.listening) or
        // serverContent.interrupted events.
    }

    func disconnect() async {
        isDisconnecting = true
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if let cont = setupContinuation {
            setupContinuation = nil
            cont.resume(throwing: CancellationError())
        }
        yielder.yield(.stateChange(.idle))
        yielder.finish()
    }

    /// Send a WebSocket-level ping. Used to keep a parked (shadow) socket alive
    /// across the documented ~10 minute Gemini Live session lifetime. Returns
    /// when the pong is received; throws on transport failure.
    func sendKeepAlive() async throws {
        guard let task = task else {
            throw NSError(domain: "GeminiProvider", code: -3, userInfo: [NSLocalizedDescriptionKey: "no socket"])
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error = error { cont.resume(throwing: error) }
                else { cont.resume() }
            }
        }
    }

    // MARK: - WS plumbing

    private func sendJSON(_ obj: [String: Any]) async throws {
        guard let task = task else { return }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        guard let str = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "GeminiProvider", code: -2, userInfo: [NSLocalizedDescriptionKey: "encode failed"])
        }
        try await task.send(.string(str))
    }

    private func receiveLoop() async {
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
                let intentional = Task.isCancelled || isDisconnecting
                if !intentional {
                    yielder.yield(.error("ws receive: \(error.localizedDescription)"))
                    yielder.yield(.stateChange(.error(error.localizedDescription)))
                    if let cont = setupContinuation {
                        setupContinuation = nil
                        cont.resume(throwing: error)
                    }
                } else {
                    NSLog("[Gemini] receive loop ended (intentional disconnect)")
                }
                return
            }
        }
    }

    // MARK: - Incoming message dispatch

    private func handleMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if obj["setupComplete"] != nil {
            if let cont = setupContinuation {
                setupContinuation = nil
                cont.resume(returning: ())
            }
            return
        }

        if let sc = obj["serverContent"] as? [String: Any] {
            handleServerContent(sc)
        }

        if let err = obj["error"] {
            yielder.yield(.error("gemini: \(err)"))
        }
        // usageMetadata is the authoritative billing source (server-side token
        // counts). Replaces the local time-based estimate so cost cap is exact.
        if let usage = obj["usageMetadata"] as? [String: Any] {
            // Token counts are split by modality; Gemini Live tokens for audio
            // map ~32 tokens/second of audio in/out. Convert to seconds for the
            // existing rate card. If `responseTokenCount` is split per modality,
            // honor that; otherwise fall back to total.
            var newIn: Double = inputSeconds
            var newOut: Double = outputSeconds
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
            if newIn != inputSeconds || newOut != outputSeconds {
                inputSeconds = newIn
                outputSeconds = newOut
                yielder.yield(.costUpdate(inputSeconds: inputSeconds, outputSeconds: outputSeconds))
            }
        }
        _ = obj["sessionResumptionUpdate"]
    }

    private func handleServerContent(_ sc: [String: Any]) {
        if let interrupted = sc["interrupted"] as? Bool, interrupted {
            // Signal listening so main app can cut local playback.
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
                if !firstAudioOutLoggedThisTurn {
                    firstAudioOutLoggedThisTurn = true
                    if let t = lastAudioSentAt {
                        let ms = Int(Date().timeIntervalSince(t) * 1000)
                        slog("turn: end-of-user-speech -> first-audio-out: \(ms)ms")
                    } else {
                        slog("turn: first-audio-out (no audio-sent timestamp)")
                    }
                }
                // Skip tiny (sub-millisecond) chunks — AVAudio scheduling them on the
                // playback queue can crash the consumer Task silently.
                if bytes.count < 64 { continue }
                let mime = inline["mimeType"] as? String ?? ""
                let rate = parseRate(from: mime) ?? 24000
                outputSeconds += Double(bytes.count) / 2.0 / Double(rate)
                yielder.yield(.audioOut(bytes, rate))
                yielder.yield(.costUpdate(inputSeconds: inputSeconds, outputSeconds: outputSeconds))
                yielder.yield(.stateChange(.speaking))
            }
        }

        if let done = sc["turnComplete"] as? Bool, done {
            slog("turn: complete")
            firstAudioOutLoggedThisTurn = false
            lastAudioSentAt = nil
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
