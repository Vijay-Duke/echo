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
}

struct Profile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var modelName: String
    var voiceName: String
    var systemPrompt: String
    /// Primary hotkey: hold to keep WSS session alive. Release = teardown.
    var hotkeyName: String
    /// Secondary hotkey: hold to talk (mic active). Release = end-of-utterance,
    /// triggers server response. Releasing while assistant is replying = barge-in.
    var talkHotkeyName: String
    var output: OutputTarget
    var injectClipboard: Bool
    var costCapUSD: Double?
    var enabled: Bool
    var webSearchEnabled: Bool?

    // Compatibility shims for older persisted profiles. We intentionally drop
    // `provider`, `mode`, `vad` from the model — every session is Gemini with
    // a 2-key push-to-talk now — but JSONDecoder must not crash on legacy keys
    // and missing `talkHotkeyName` should default sanely.
    private enum CodingKeys: String, CodingKey {
        case id, name, modelName, voiceName, systemPrompt, hotkeyName,
             talkHotkeyName, output, injectClipboard, costCapUSD, enabled,
             webSearchEnabled
    }

    init(id: UUID = UUID(), name: String, modelName: String, voiceName: String,
         systemPrompt: String, hotkeyName: String, talkHotkeyName: String,
         output: OutputTarget, injectClipboard: Bool, costCapUSD: Double?,
         enabled: Bool, webSearchEnabled: Bool?) {
        self.id = id
        self.name = name
        self.modelName = modelName
        self.voiceName = voiceName
        self.systemPrompt = systemPrompt
        self.hotkeyName = hotkeyName
        self.talkHotkeyName = talkHotkeyName
        self.output = output
        self.injectClipboard = injectClipboard
        self.costCapUSD = costCapUSD
        self.enabled = enabled
        self.webSearchEnabled = webSearchEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        let name = (try? c.decode(String.self, forKey: .name)) ?? "Quick Assistant"
        let hotkey = (try? c.decode(String.self, forKey: .hotkeyName)) ?? "profile-\(id.uuidString.prefix(8))"
        self.id = id
        self.name = name
        self.modelName = (try? c.decode(String.self, forKey: .modelName)) ?? "models/gemini-3.1-flash-live-preview"
        self.voiceName = (try? c.decode(String.self, forKey: .voiceName)) ?? "Aoede"
        self.systemPrompt = (try? c.decode(String.self, forKey: .systemPrompt)) ?? "You are a witty, brief voice assistant. Keep replies short and conversational."
        self.hotkeyName = hotkey
        self.talkHotkeyName = (try? c.decode(String.self, forKey: .talkHotkeyName)) ?? "\(hotkey)-talk"
        self.output = (try? c.decode(OutputTarget.self, forKey: .output)) ?? .speak
        self.injectClipboard = (try? c.decode(Bool.self, forKey: .injectClipboard)) ?? false
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
            hotkeyName: "profile-quick",
            talkHotkeyName: "profile-quick-talk",
            output: .speak,
            injectClipboard: false,
            costCapUSD: 0.50,
            enabled: true,
            webSearchEnabled: false
        )
    }
}
