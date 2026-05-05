import Foundation
import KeyboardShortcuts
import AppKit

extension KeyboardShortcuts.Name {
    init(profileHotkeyName: String) {
        self.init(profileHotkeyName)
    }
}

/// 2-key push-to-talk:
///   - Primary (hotkeyName): hold = WSS session alive. Release = teardown.
///   - Talk (talkHotkeyName): hold = mic active + activity sent. Release =
///     end-of-utterance + barge-in cut.
final class HotkeyManager {
    typealias Handler = () -> Void

    struct Hooks {
        let profileId: UUID
        let onSessionStart: Handler
        let onSessionEnd: Handler
        let onTalkStart: Handler
        let onTalkEnd: Handler
    }

    private var hooks: [UUID: Hooks] = [:]

    func register(profile: Profile,
                  onSessionStart: @escaping Handler,
                  onSessionEnd: @escaping Handler,
                  onTalkStart: @escaping Handler,
                  onTalkEnd: @escaping Handler) {
        unregister(profile: profile)
        hooks[profile.id] = Hooks(profileId: profile.id,
                                  onSessionStart: onSessionStart,
                                  onSessionEnd: onSessionEnd,
                                  onTalkStart: onTalkStart,
                                  onTalkEnd: onTalkEnd)

        let session = KeyboardShortcuts.Name(profileHotkeyName: profile.hotkeyName)
        let talk = KeyboardShortcuts.Name(profileHotkeyName: profile.talkHotkeyName)
        let pid = profile.id

        KeyboardShortcuts.onKeyDown(for: session) { [weak self] in
            self?.hooks[pid]?.onSessionStart()
        }
        KeyboardShortcuts.onKeyUp(for: session) { [weak self] in
            self?.hooks[pid]?.onSessionEnd()
        }
        KeyboardShortcuts.onKeyDown(for: talk) { [weak self] in
            self?.hooks[pid]?.onTalkStart()
        }
        KeyboardShortcuts.onKeyUp(for: talk) { [weak self] in
            self?.hooks[pid]?.onTalkEnd()
        }
    }

    func unregister(profile: Profile) {
        hooks.removeValue(forKey: profile.id)
    }

    func unregisterAll() {
        hooks.removeAll()
        KeyboardShortcuts.removeAllHandlers()
    }
}
