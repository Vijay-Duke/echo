import Foundation

// OpenAIProvider — OpenAI Realtime over WSS (gpt-realtime / gpt-realtime-mini).
//
// Audio convention: caller streams 24kHz mono PCM16 frames in; provider emits
// 24kHz mono PCM16 frames out. The Mac AudioEngine is configured for 24kHz on
// both sides, so no resampling is needed. Frames are base64-encoded for the
// JSON wire format.

final class OpenAIProvider: NSObject, VoiceProvider, URLSessionWebSocketDelegate {
    let kind: ProviderKind = .openai
    let events: AsyncStream<TranscriptEvent>
    private let eventsContinuation: AsyncStream<TranscriptEvent>.Continuation

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    private var profile: Profile?
    private var sessionCreated = false
    private var responseActive = false
    private var serverVAD = false

    override init() {
        var cont: AsyncStream<TranscriptEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventsContinuation = cont
        super.init()
    }

    deinit {
        eventsContinuation.finish()
    }

    // MARK: - Connect

    func connect(profile: Profile, apiKey: String) async throws {
        self.profile = profile
        self.serverVAD = (profile.vad == .server)
        self.sessionCreated = false
        self.responseActive = false

        emit(.stateChange(.connecting))

        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(profile.modelName)")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let cfg = URLSessionConfiguration.default
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        let t = s.webSocketTask(with: req)
        self.session = s
        self.task = t
        t.resume()

        try await sendSessionUpdate(profile: profile)

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func sendSessionUpdate(profile: Profile) async throws {
        let turnDetection: Any = serverVAD
            ? ["type": "server_vad"]
            : NSNull()

        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["audio", "text"],
                "instructions": profile.systemPrompt,
                "voice": profile.voiceName,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": ["model": "whisper-1"],
                "turn_detection": turnDetection,
            ],
        ]
        try await sendJSON(payload)
    }

    // MARK: - VoiceProvider

    func sendAudio(_ pcm16: Data) async throws {
        guard task != nil else { return }
        let b64 = pcm16.base64EncodedString()
        try await sendJSON([
            "type": "input_audio_buffer.append",
            "audio": b64,
        ])
    }

    func startUtterance() async throws {
        if !serverVAD {
            try? await sendJSON(["type": "input_audio_buffer.clear"])
        }
    }

    func endUtterance() async throws {
        guard !serverVAD else { return }
        try await sendJSON(["type": "input_audio_buffer.commit"])
        try await sendJSON(["type": "response.create"])
    }

    func interrupt() async throws {
        guard responseActive else { return }
        try? await sendJSON(["type": "response.cancel"])
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        sessionCreated = false
        responseActive = false
        emit(.stateChange(.idle))
    }

    // MARK: - Send / Receive

    private func sendJSON(_ obj: [String: Any]) async throws {
        guard let task else { return }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [])
        guard let str = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(str))
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                switch msg {
                case .string(let s):
                    handleMessage(s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) {
                        handleMessage(s)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    emit(.error("ws: \(error.localizedDescription)"))
                    emit(.stateChange(.error(error.localizedDescription)))
                }
                return
            }
        }
    }

    private func handleMessage(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return }

        switch type {
        case "session.created":
            sessionCreated = true
            emit(.stateChange(.listening))

        case "session.updated":
            break

        case "input_audio_buffer.speech_started":
            guard serverVAD else { break }
            if responseActive {
                Task { try? await self.interrupt() }
            }
            emit(.stateChange(.listening))

        case "input_audio_buffer.speech_stopped":
            emit(.stateChange(.thinking))

        case "conversation.item.input_audio_transcription.completed":
            if let t = obj["transcript"] as? String {
                emit(.userText(t))
            }

        case "response.created":
            responseActive = true
            emit(.stateChange(.thinking))

        case "response.audio.delta":
            if let b64 = obj["delta"] as? String,
               let pcm = Data(base64Encoded: b64) {
                emit(.audioOut(pcm, 24000))
                emit(.stateChange(.speaking))
            }

        case "response.audio_transcript.delta",
             "response.text.delta":
            if let d = obj["delta"] as? String, !d.isEmpty {
                emit(.assistantTextDelta(d))
            }

        case "response.done":
            responseActive = false
            emit(.assistantTextDone)
            emit(.stateChange(.listening))

        case "error":
            let err = (obj["error"] as? [String: Any])?["message"] as? String
                ?? (obj["message"] as? String)
                ?? raw
            emit(.error(err))

        default:
            break
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        // Connected; waiting for session.created before flipping to .listening.
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        emit(.stateChange(.idle))
    }

    // MARK: - Helpers

    private func emit(_ e: TranscriptEvent) {
        eventsContinuation.yield(e)
    }
}
