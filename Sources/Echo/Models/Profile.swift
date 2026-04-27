import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case gemini, openai, grok
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .gemini: "Gemini Live"
        case .openai: "OpenAI Realtime"
        case .grok:   "Grok Voice"
        }
    }
}

enum ActivationMode: String, Codable, CaseIterable, Identifiable {
    case ptt, toggle, hybrid, doubleTap
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ptt:       "Push to talk"
        case .toggle:    "Toggle"
        case .hybrid:    "Hybrid (tap=toggle, hold=PTT)"
        case .doubleTap: "Double tap"
        }
    }
}

enum VADKind: String, Codable, CaseIterable, Identifiable {
    case server, silero, off
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .server: "Server VAD"
        case .silero: "Silero (client)"
        case .off:    "Off (manual)"
        }
    }
}

enum OutputTarget: String, Codable, CaseIterable, Identifiable {
    case speak, paste, both, none
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .speak: "Speak only"
        case .paste: "Paste at cursor"
        case .both:  "Speak + paste"
        case .none:  "Silent (status only)"
        }
    }
}

struct Profile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var provider: ProviderKind
    var modelName: String
    var voiceName: String
    var systemPrompt: String
    var hotkeyName: String                    // KeyboardShortcuts.Name raw key
    var mode: ActivationMode
    var vad: VADKind
    var output: OutputTarget
    var injectClipboard: Bool
    var costCapUSD: Double?
    var enabled: Bool

    static func defaultGemini() -> Profile {
        Profile(
            name: "Quick Assistant",
            provider: .gemini,
            modelName: "models/gemini-3.1-flash-live-preview",
            voiceName: "Aoede",
            systemPrompt: "You are a witty, brief voice assistant. Keep replies short and conversational.",
            hotkeyName: "profile-quick",
            mode: .hybrid,
            vad: .server,
            output: .speak,
            injectClipboard: false,
            costCapUSD: 0.50,
            enabled: true
        )
    }
}
