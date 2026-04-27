import Foundation
import KeyboardShortcuts
import AppKit

extension KeyboardShortcuts.Name {
    /// Build a Name from a profile's stable hotkey id string.
    init(profileHotkeyName: String) {
        self.init(profileHotkeyName)
    }
}

/// Coordinates global hotkey registration per profile, supporting four activation modes:
/// push-to-talk, toggle, hybrid (tap=toggle / hold=PTT), and double-tap.
final class HotkeyManager {
    typealias Handler = () -> Void

    private struct Hooks {
        let profileId: UUID
        let mode: ActivationMode
        let onActivate: Handler
        let onDeactivate: Handler
        // Mode state.
        var keyDownAt: Date?
        var hybridTimer: Timer?
        var hybridIsActive: Bool = false
        var lastTapAt: Date?
        var toggleActive: Bool = false
    }

    private var hooks: [String: Hooks] = [:] // keyed by hotkeyName

    // Tunables.
    private let hybridHoldThreshold: TimeInterval = 0.300
    private let doubleTapWindow: TimeInterval = 0.400

    // MARK: - Public API

    func register(profile: Profile,
                  onActivate: @escaping Handler,
                  onDeactivate: @escaping Handler) {
        let name = KeyboardShortcuts.Name(profileHotkeyName: profile.hotkeyName)
        // Wipe any prior registration for this name.
        unregister(profile: profile)

        var entry = Hooks(profileId: profile.id,
                          mode: profile.mode,
                          onActivate: onActivate,
                          onDeactivate: onDeactivate)
        hooks[profile.hotkeyName] = entry

        // Capture-only references; we look up state via dictionary on each callback so
        // we always read the latest values.
        let key = profile.hotkeyName

        switch profile.mode {
        case .ptt:
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                self?.hooks[key]?.onActivate()
            }
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                self?.hooks[key]?.onDeactivate()
            }

        case .toggle:
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                guard let self = self, var h = self.hooks[key] else { return }
                h.toggleActive.toggle()
                self.hooks[key] = h
                if h.toggleActive { h.onActivate() } else { h.onDeactivate() }
            }

        case .hybrid:
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                guard let self = self, var h = self.hooks[key] else { return }
                h.keyDownAt = Date()
                h.hybridIsActive = false
                // Schedule a fire after the threshold — if still held, treat as PTT.
                h.hybridTimer?.invalidate()
                h.hybridTimer = Timer.scheduledTimer(withTimeInterval: self.hybridHoldThreshold,
                                                    repeats: false) { [weak self] _ in
                    guard let self = self, var h = self.hooks[key] else { return }
                    h.hybridIsActive = true
                    self.hooks[key] = h
                    h.onActivate()
                }
                self.hooks[key] = h
            }
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                guard let self = self, var h = self.hooks[key] else { return }
                let elapsed = h.keyDownAt.map { Date().timeIntervalSince($0) } ?? 0
                h.hybridTimer?.invalidate()
                h.hybridTimer = nil
                if elapsed < self.hybridHoldThreshold {
                    // Tap → toggle behavior.
                    h.toggleActive.toggle()
                    let nowActive = h.toggleActive
                    self.hooks[key] = h
                    if nowActive { h.onActivate() } else { h.onDeactivate() }
                } else {
                    // Hold released → end PTT.
                    if h.hybridIsActive {
                        h.hybridIsActive = false
                        self.hooks[key] = h
                        h.onDeactivate()
                    } else {
                        self.hooks[key] = h
                    }
                }
            }

        case .doubleTap:
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in
                guard let self = self, var h = self.hooks[key] else { return }
                let now = Date()
                if let last = h.lastTapAt, now.timeIntervalSince(last) <= self.doubleTapWindow {
                    h.lastTapAt = nil
                    h.toggleActive.toggle()
                    let nowActive = h.toggleActive
                    self.hooks[key] = h
                    if nowActive { h.onActivate() } else { h.onDeactivate() }
                } else {
                    h.lastTapAt = now
                    self.hooks[key] = h
                }
            }
        }
    }

    /// Removes the per-profile state. Bound handlers self-gate by looking up
    /// `hooks[key]` and become no-ops once cleared. KeyboardShortcuts 2.x has no
    /// per-name handler removal — use `rebuildAll` for clean re-registration.
    func unregister(profile: Profile) {
        hooks[profile.hotkeyName]?.hybridTimer?.invalidate()
        hooks.removeValue(forKey: profile.hotkeyName)
    }

    func unregisterAll() {
        for (_, h) in hooks { h.hybridTimer?.invalidate() }
        hooks.removeAll()
        KeyboardShortcuts.removeAllHandlers()
    }

    /// Nukes all global handlers and re-registers each enabled profile.
    /// Call this whenever the profile set or any profile's hotkey/mode changes.
    func rebuildAll(profiles: [Profile],
                    onActivate: @escaping (Profile) -> Void,
                    onDeactivate: @escaping (Profile) -> Void) {
        unregisterAll()
        for profile in profiles where profile.enabled {
            register(profile: profile,
                     onActivate: { onActivate(profile) },
                     onDeactivate: { onDeactivate(profile) })
        }
    }
}
