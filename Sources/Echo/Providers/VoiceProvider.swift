import Foundation

enum ProviderState: Equatable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case error(String)
}

enum TranscriptEvent {
    case userText(String)
    case assistantTextDelta(String)
    case assistantTextDone
    case stateChange(ProviderState)
    case audioOut(Data, Int)              // pcm16 bytes, sample rate
    case costUpdate(inputSeconds: Double, outputSeconds: Double)
    case error(String)
}

protocol VoiceProvider: AnyObject {
    var kind: ProviderKind { get }
    var events: AsyncStream<TranscriptEvent> { get }

    /// Open WSS, configure session per profile.
    func connect(profile: Profile, apiKey: String) async throws

    /// Enqueue a 16kHz PCM16 mono frame (~20-40ms). Synchronous + FIFO: callers
    /// on a serial producer (the audio capture queue) get ordered delivery, so
    /// audio frames and utterance markers never reach the server out of order.
    func sendAudio(_ pcm16: Data)

    /// Enqueue an utterance-start marker (manual VAD modes).
    func startUtterance()

    /// Enqueue an utterance-end marker — flush + request reply.
    func endUtterance()

    /// Cancel in-flight assistant audio.
    func interrupt()

    /// Close socket + cleanup.
    func disconnect() async
}
