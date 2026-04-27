import Foundation

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

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        // Start receive loop before sending setup so we catch setupComplete.
        receiveTask = Task { [weak self] in await self?.receiveLoop() }

        try await sendSetup(profile: profile)

        // Wait for setupComplete.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.setupContinuation = cont
        }

        yielder.yield(.stateChange(.listening))
    }

    private func sendSetup(profile: Profile) async throws {
        let disabled: Bool = (profile.vad != .server)
        let setup: [String: Any] = [
            "setup": [
                "model": profile.modelName,
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": [
                            "prebuiltVoiceConfig": ["voiceName": profile.voiceName]
                        ],
                        "languageCode": "en-US",
                    ],
                ],
                "systemInstruction": [
                    "parts": [["text": profile.systemPrompt]]
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": ["disabled": disabled]
                ],
                "outputAudioTranscription": [:] as [String: Any],
                "inputAudioTranscription": [:] as [String: Any],
            ]
        ]
        try await sendJSON(setup)
    }

    // MARK: - Audio in / utterance markers

    func sendAudio(_ pcm16: Data) async throws {
        let b64 = pcm16.base64EncodedString()
        inputSeconds += Double(pcm16.count) / 2.0 / 16000.0
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
        guard let p = profile, p.vad != .server else { return }
        try await sendJSON(["realtimeInput": ["activityStart": [:] as [String: Any]]])
    }

    func endUtterance() async throws {
        guard let p = profile, p.vad != .server else { return }
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
            NSLog("[Gemini] modelTurn parts=%d", parts.count)
            for (i, part) in parts.enumerated() {
                NSLog("[Gemini] part[%d] keys=%{public}@", i, part.keys.joined(separator: ","))
                guard let inline = part["inlineData"] as? [String: Any] else { continue }
                NSLog("[Gemini] inlineData keys=%{public}@ mime=%{public}@", inline.keys.joined(separator: ","), (inline["mimeType"] as? String) ?? "?")
                guard let b64 = inline["data"] as? String else { continue }
                NSLog("[Gemini] inline data b64.count=%d", b64.count)
                guard let bytes = Data(base64Encoded: b64) else { continue }
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
