import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case gemini
    var id: String { rawValue }
    var displayName: String { "Gemini Live" }
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
    /// Whether assistant audio should play through the speakers.
    var playsAudio: Bool {
        switch self {
        case .speak, .both: return true
        case .paste, .none: return false
        }
    }
    /// Whether the assistant transcript should be copied + pasted at the cursor.
    var pastesText: Bool {
        switch self {
        case .paste, .both: return true
        case .speak, .none: return false
        }
    }
}

struct Profile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var modelName: String
    var voiceName: String
    var systemPrompt: String
    var output: OutputTarget
    var costCapUSD: Double?
    var enabled: Bool
    var webSearchEnabled: Bool?

    // Compatibility shims for older persisted profiles. We intentionally drop
    // `provider`, `mode`, `vad`, `hotkeyName`, `talkHotkeyName`, and
    // `injectClipboard` from the model — every session is Gemini with a single
    // app-wide 2-key push-to-talk chord now — but JSONDecoder must not crash on
    // those legacy keys.
    private enum CodingKeys: String, CodingKey {
        case id, name, modelName, voiceName, systemPrompt,
             output, costCapUSD, enabled, webSearchEnabled
    }

    init(id: UUID = UUID(), name: String, modelName: String, voiceName: String,
         systemPrompt: String, output: OutputTarget, costCapUSD: Double?,
         enabled: Bool, webSearchEnabled: Bool?) {
        self.id = id
        self.name = name
        self.modelName = modelName
        self.voiceName = voiceName
        self.systemPrompt = systemPrompt
        self.output = output
        self.costCapUSD = costCapUSD
        self.enabled = enabled
        self.webSearchEnabled = webSearchEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "Quick Assistant"
        self.modelName = (try? c.decode(String.self, forKey: .modelName)) ?? "models/gemini-3.1-flash-live-preview"
        self.voiceName = (try? c.decode(String.self, forKey: .voiceName)) ?? "Aoede"
        self.systemPrompt = (try? c.decode(String.self, forKey: .systemPrompt)) ?? "You are a witty, brief voice assistant. Keep replies short and conversational."
        self.output = (try? c.decode(OutputTarget.self, forKey: .output)) ?? .speak
        self.costCapUSD = try? c.decodeIfPresent(Double.self, forKey: .costCapUSD)
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        self.webSearchEnabled = try? c.decodeIfPresent(Bool.self, forKey: .webSearchEnabled)
    }

    var provider: ProviderKind { .gemini }

    static func defaultGemini() -> Profile {
        Profile(
            name: "Quick Assistant",
            modelName: "models/gemini-3.1-flash-live-preview",
            voiceName: "Aoede",
            systemPrompt: "You are a witty, brief voice assistant. Keep replies short and conversational.",
            output: .speak,
            costCapUSD: 0.50,
            enabled: true,
            webSearchEnabled: false
        )
    }
}
