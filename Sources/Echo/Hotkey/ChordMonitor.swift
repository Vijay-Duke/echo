import AppKit
import CoreGraphics

/// Two-stage chord monitor:
///   - Modifier (⌥) down → onModifierDown
///   - Trigger (`) down while ⌥ held → onTriggerDown (start utterance)
///   - Trigger up → onTriggerUp (end utterance → AI responds)
///   - Modifier up → onModifierUp (kill audio + teardown)
///
/// Uses a `CGEventTap` on the HID stream so the chord fires from any focused
/// app. Requires Accessibility permission (already granted for ⌘V paste).
/// Trigger keyDown/keyUp events are SWALLOWED while the modifier is held so
/// the focused app doesn't receive a stray backtick.
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

    private static let kKeyCodeDefault = "chord.keyCode.v1"
    private static let kModifierDefault = "chord.modifier.v1"
    private static func loadKeyCode() -> Int64 {
        let v = UserDefaults.standard.integer(forKey: kKeyCodeDefault)
        return v == 0 ? 50 : Int64(v)
    }
    private static func loadModifier() -> CGEventFlags {
        let raw = UserDefaults.standard.integer(forKey: kModifierDefault)
        return raw == 0 ? .maskAlternate : CGEventFlags(rawValue: UInt64(raw))
    }
    func saveBinding() {
        UserDefaults.standard.set(Int(triggerKeyCode), forKey: Self.kKeyCodeDefault)
        UserDefaults.standard.set(Int(modifierMask.rawValue), forKey: Self.kModifierDefault)
    }

    private var tap: CFMachPort?
    private var runLoopSrc: CFRunLoopSource?
    private var modifierIsDown = false
    private var triggerIsDown = false

    func start() {
        guard tap == nil else { return }
        // Trigger Accessibility prompt up-front so the user grants permission
        // before the first chord press (otherwise the tap silently no-ops).
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
            NSLog("[Chord] tapCreate failed — Accessibility permission missing?")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSrc = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[Chord] event tap started")
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
            return false
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
