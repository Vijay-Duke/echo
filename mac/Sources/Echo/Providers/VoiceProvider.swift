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

    /// Send 16kHz PCM16 mono frame (~20-40ms).
    func sendAudio(_ pcm16: Data) async throws

    /// Mark beginning of user utterance (manual VAD modes).
    func startUtterance() async throws

    /// Mark end of user utterance — flush + request reply.
    func endUtterance() async throws

    /// Cancel in-flight assistant audio.
    func interrupt() async throws

    /// Close socket + cleanup.
    func disconnect() async
}
