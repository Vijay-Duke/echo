import AppKit
import CoreGraphics

/// Two-stage chord monitor:
///   - Modifier (⌥) down → onModifierDown
///   - Trigger (`) down while ⌥ held → onTriggerDown (start utterance)
///   - Trigger up → onTriggerUp (end utterance → AI responds)
///   - Modifier up → onModifierUp (kill audio + teardown)
///
/// Uses a `CGEventTap` on the HID stream so the chord fires from any focused
/// app. Requires Accessibility permission. Trigger keyDown/keyUp events are
/// SWALLOWED while the modifier is held so the focused app doesn't receive a
/// stray backtick.
///
/// The chord is a single app-wide binding (stored in `UserDefaults`). It is not
/// per-profile — one press activates whichever profile is first-enabled.
final class ChordMonitor {
    var onModifierDown: () -> Void = {}
    var onModifierUp: () -> Void = {}
    var onTriggerDown: () -> Void = {}
    var onTriggerUp: () -> Void = {}

    /// Trigger key (default backtick, kVK_ANSI_Grave = 0x32).
    var triggerKeyCode: Int64 = ChordMonitor.loadKeyCode()
    /// Modifier (default ⌥). Stored as raw UInt64 of CGEventFlags.
    var modifierMask: CGEventFlags = ChordMonitor.loadModifier()

    /// When non-nil, the next "modifier + key" combo observed is captured and
    /// passed to this closure instead of firing the normal callbacks. Used to
    /// rebind the chord from Settings.
    var onCapture: ((CGEventFlags, Int64) -> Void)?

    /// True once the `CGEventTap` is live and receiving events. False when
    /// Accessibility permission is missing — `start()` is safe to retry once
    /// the user grants it (see `AppController` re-arming on app activation).
    private(set) var isRunning = false

    private static let kKeyCodeDefault = "chord.keyCode.v1"
    private static let kModifierDefault = "chord.modifier.v1"
    private static let defaultKeyCode: Int64 = 50              // kVK_ANSI_Grave (`)
    private static let defaultModifier: CGEventFlags = .maskAlternate

    private static func loadKeyCode() -> Int64 {
        // `object(forKey:)` nil-check — keycode 0 is a *valid* key (kVK_ANSI_A),
        // so a stored 0 must not be mistaken for "unset".
        guard let v = UserDefaults.standard.object(forKey: kKeyCodeDefault) as? Int else {
            return defaultKeyCode
        }
        return Int64(v)
    }
    private static func loadModifier() -> CGEventFlags {
        guard let raw = UserDefaults.standard.object(forKey: kModifierDefault) as? Int,
              raw != 0 else {
            return defaultModifier
        }
        return CGEventFlags(rawValue: UInt64(raw))
    }
    func saveBinding() {
        UserDefaults.standard.set(Int(triggerKeyCode), forKey: Self.kKeyCodeDefault)
        UserDefaults.standard.set(Int(modifierMask.rawValue), forKey: Self.kModifierDefault)
    }

    /// Human-readable chord, e.g. "⌥`". Reflects the live binding.
    var displayString: String {
        Self.describe(modifier: modifierMask, keyCode: triggerKeyCode)
    }

    /// Just the modifier portion, e.g. "⌥".
    var modifierString: String {
        var s = ""
        if modifierMask.contains(.maskControl)   { s += "⌃" }
        if modifierMask.contains(.maskAlternate) { s += "⌥" }
        if modifierMask.contains(.maskShift)     { s += "⇧" }
        if modifierMask.contains(.maskCommand)   { s += "⌘" }
        return s
    }

    /// Just the trigger key portion, e.g. "`".
    var triggerString: String { Self.keyName(triggerKeyCode) }

    /// Format a modifier+keycode pair for display.
    static func describe(modifier: CGEventFlags, keyCode: Int64) -> String {
        var s = ""
        if modifier.contains(.maskControl)   { s += "⌃" }
        if modifier.contains(.maskAlternate) { s += "⌥" }
        if modifier.contains(.maskShift)     { s += "⇧" }
        if modifier.contains(.maskCommand)   { s += "⌘" }
        s += keyName(keyCode)
        return s
    }

    static func keyName(_ kc: Int64) -> String {
        switch kc {
        case 50:  return "`"
        case 49:  return "Space"
        case 36:  return "Return"
        case 53:  return "Esc"
        case 48:  return "Tab"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        default:  return "Key#\(kc)"
        }
    }

    /// AX permission probe that does NOT show the system prompt — for UI status.
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    private var tap: CFMachPort?
    private var runLoopSrc: CFRunLoopSource?
    private var modifierIsDown = false
    private var triggerIsDown = false

    /// Create the event tap. Idempotent and retryable: if Accessibility
    /// permission is missing, `tapCreate` fails, `isRunning` stays false, and a
    /// later call (e.g. after the user grants permission) will succeed.
    /// Returns true once the tap is live.
    @discardableResult
    func start() -> Bool {
        if tap != nil {
            isRunning = true
            return true
        }
        // Trigger the Accessibility prompt up-front so the user grants
        // permission before the first chord press (otherwise the tap silently
        // no-ops). The prompt is shown at most once per app session.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        NSLog("[Chord] AX trusted = %{public}@", trusted ? "yes" : "no — prompted")

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // HID-level tap intercepts events before session dispatch, so swallowed
        // keys never reach focused-app sound feedback or system beep.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: chordTapCallback,
            userInfo: refcon
        ) else {
            NSLog("[Chord] tapCreate failed — Accessibility permission missing. Will retry.")
            isRunning = false
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSrc = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        NSLog("[Chord] event tap started")
        return true
    }

    func stop() {
        if let src = runLoopSrc {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSrc = nil
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        isRunning = false
    }

    /// Returns true if the event should be swallowed (consumed, not delivered
    /// to the focused app). False = pass through.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Capture mode: next keyDown w/ any modifier becomes the new chord.
        if let cb = onCapture, type == .keyDown {
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            let modifierBits: UInt64 =
                CGEventFlags.maskAlternate.rawValue
                | CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskControl.rawValue
                | CGEventFlags.maskShift.rawValue
            let mods = CGEventFlags(rawValue: event.flags.rawValue & modifierBits)
            NSLog("[Chord] capture saw keyDown kc=%lld flags=0x%llx mods=0x%llx",
                  kc, event.flags.rawValue, mods.rawValue)
            if mods.rawValue != 0 {
                triggerKeyCode = kc
                modifierMask = mods
                saveBinding()
                onCapture = nil
                DispatchQueue.main.async { cb(mods, kc) }
                NSLog("[Chord] captured kc=%lld mods=0x%llx", kc, mods.rawValue)
                return true
            }
            // A bare key (no modifier) is not a valid chord — swallow it anyway
            // so the focused app doesn't receive a stray keystroke while the
            // user is mid-capture, and keep waiting for a real chord.
            return true
        }
        switch type {
        case .flagsChanged:
            let down = event.flags.contains(modifierMask)
            if down, !modifierIsDown {
                modifierIsDown = true
                DispatchQueue.main.async { [self] in onModifierDown() }
            } else if !down, modifierIsDown {
                modifierIsDown = false
                if triggerIsDown {
                    triggerIsDown = false
                    DispatchQueue.main.async { [self] in onTriggerUp() }
                }
                DispatchQueue.main.async { [self] in onModifierUp() }
            }
            return false

        case .keyDown:
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if kc == triggerKeyCode, modifierIsDown {
                if !triggerIsDown, !isAutoRepeat {
                    triggerIsDown = true
                    DispatchQueue.main.async { [self] in onTriggerDown() }
                }
                return true   // swallow — don't let the focused app see `
            }
            return false

        case .keyUp:
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            if kc == triggerKeyCode, triggerIsDown {
                triggerIsDown = false
                DispatchQueue.main.async { [self] in onTriggerUp() }
                return true   // swallow
            }
            return false

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // System throttled or user disabled the tap; re-enable.
            if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false

        default:
            return false
        }
    }
}

/// C-callable trampoline. Pulls the ChordMonitor out of the userInfo refcon
/// and dispatches.
private func chordTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon = refcon {
            let monitor = Unmanaged<ChordMonitor>.fromOpaque(refcon).takeUnretainedValue()
            _ = monitor.handle(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ChordMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let swallow = monitor.handle(type: type, event: event)
    return swallow ? nil : Unmanaged.passUnretained(event)
}
