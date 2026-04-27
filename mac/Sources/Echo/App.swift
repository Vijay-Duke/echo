import SwiftUI
import AppKit
import Combine

// MARK: - App

@main
struct EchoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Echo", systemImage: appDelegate.controller.state.symbolName) {
            menuContent
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var menuContent: some View {
        Text(appDelegate.controller.menuStatus)
            .font(.system(size: 12, weight: .medium))

        if let p = appDelegate.controller.activeProfile {
            Text("\(p.name) · \(p.provider.displayName)")
                .font(.system(size: 11))
        }

        Divider()

        Button("Open Settings…") {
            NSLog("[VG] menu Open Settings clicked")
            AppDelegate.openSettings()
        }

        Divider()

        Button("Quit Echo") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static let showDockIconKey = "showDockIcon.v1"

    /// Strong owner of the controller. Created eagerly at init so it's never nil
    /// when the dock click handler runs. (Previously `AppController.shared` was
    /// weak + lazily set from a SwiftUI @StateObject; if the scene hadn't been
    /// realized the dock click silently no-op'd.)
    let controller: AppController

    /// Weak self pointer so static helpers (called from class-level menu actions)
    /// can find the live delegate without searching `NSApp.delegate`.
    fileprivate static weak var instance: AppDelegate?

    private var controllerSub: AnyCancellable?

    override init() {
        self.controller = AppController()
        super.init()
        AppDelegate.instance = self
        // Forward controller state changes so SwiftUI scenes that observe
        // `appDelegate` re-evaluate when the controller publishes.
        controllerSub = controller.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.showDockIconKey) == nil {
            defaults.set(true, forKey: Self.showDockIconKey)
        }
        NSApp.setActivationPolicy(defaults.bool(forKey: Self.showDockIconKey) ? .regular : .accessory)

        DispatchQueue.global(qos: .userInitiated).async {
            KeychainStore.preloadAll()
        }

        // Auto-open Settings on first launch so the user can configure things.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.openSettings()
        }
    }

    /// Dock icon click → open Settings window. Without this handler the dock
    /// icon does nothing because the app has no regular Window scene.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.openSettings()
        return true
    }

    /// Right-click on dock icon → context menu with explicit Settings entry.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let openSettings = NSMenuItem(title: "Open Settings…", action: #selector(handleOpenSettings), keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Echo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc private func handleOpenSettings() {
        Self.openSettings()
    }

    /// Manually-managed Settings window. SwiftUI's `Settings` scene + the
    /// `showSettingsWindow:` selector are unreliable when the app has no
    /// regular Window scene declared, so we own this directly.
    private static var settingsWindow: NSWindow?

    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            return
        }
        guard let controller = AppDelegate.instance?.controller else {
            NSLog("[VG] openSettings: AppDelegate.instance not yet set")
            return
        }
        let view = SettingsView()
            .environmentObject(controller.profiles)
            .environmentObject(controller)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Echo Settings"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 720, height: 520))
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    static func setDockIconVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: showDockIconKey)
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - State helpers

extension ProviderState {
    var tintColor: Color {
        switch self {
        case .idle: return .gray
        case .connecting: return .yellow
        case .listening: return .blue
        case .thinking: return .orange
        case .speaking: return .green
        case .error: return .red
        }
    }

    /// SF Symbol that visually shifts with state — easier to spot than a color tint.
    var symbolName: String {
        switch self {
        case .idle:       return "waveform"
        case .connecting: return "waveform.badge.magnifyingglass"
        case .listening:  return "waveform.and.mic"
        case .thinking:   return "ellipsis.bubble"
        case .speaking:   return "speaker.wave.2.fill"
        case .error:      return "exclamationmark.triangle"
        }
    }

    var menuLabel: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

// MARK: - AppController

/// Central coordinator that owns the audio engine, current voice provider,
/// the global hotkey manager and the HUD. Wires hotkey events to session lifecycle.
@MainActor
final class AppController: ObservableObject {
    static private(set) weak var shared: AppController?

    // Persistence / state.
    @Published var profiles: ProfilesStore
    @Published private(set) var state: ProviderState = .idle
    @Published private(set) var activeProfile: Profile?
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var sessionCostUSD: Double = 0

    // Cost rates per provider (USD per minute audio in / out).
    private struct RateCard { let inPerMin: Double; let outPerMin: Double }
    private func rates(for kind: ProviderKind) -> RateCard {
        switch kind {
        case .gemini: return RateCard(inPerMin: 0.005,  outPerMin: 0.018)  // 3.1 flash live
        case .openai: return RateCard(inPerMin: 0.06,   outPerMin: 0.24)   // realtime-mini
        case .grok:   return RateCard(inPerMin: 0.05,   outPerMin: 0.0)    // flat $0.05/min, output included
        }
    }

    // Subsystems.
    private let hotkeys = HotkeyManager()
    private let hud = HUDPanel()
    private let audio = AudioEngine()

    // Lazily-instantiated per session.
    private var currentProvider: VoiceProvider?
    private var currentSessionTask: Task<Void, Never>?
    private var eventPumpTask: Task<Void, Never>?
    private var currentVAD: VadGate?
    private var vadDidStartUtterance: Bool = false
    /// Tracks whether the user is still holding the hotkey. Used to decide
    /// whether assistant audio finishing should tear down the session.
    private var activeProfileKeyHeld: Bool = false
    /// True once we've observed a `.speaking` state for the current session —
    /// guards the auto-end on `.listening` so we don't tear down the very
    /// first `.listening` event that fires right after `setupComplete`.
    private var sessionHasResponded: Bool = false

    /// Monotonic generation counter. Every `activate` and `forceEndSessionSync`
    /// bumps this. Async closures capture the value at start; if it no longer
    /// matches by the time the closure runs, the work is silently dropped.
    /// This single mechanism kills races from quick re-presses, late connect
    /// completions, in-flight VAD callbacks, and stale sendAudio calls.
    private var sessionGen: UInt64 = 0
    private var isTearingDown: Bool = false

    /// Accumulates assistant text deltas for the current turn. Flushed to the
    /// pasteboard (and optionally posted as ⌘V) on `.assistantTextDone` when
    /// the active profile's output target is .paste or .both.
    fileprivate var currentTranscript: String = ""

    // Energy-based barge-in. When state==.speaking and mic level stays above
    // BARGE_THRESHOLD for BARGE_HOLD_MS, we cut the assistant off.
    private var bargeInLastUnderTime: Date = Date()
    private static let BARGE_THRESHOLD: Double = 0.10
    private static let BARGE_HOLD_MS: Double = 150

    // Profile change observation.
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let store = ProfilesStore()
        self.profiles = store

        // Re-sync hotkey registrations whenever profiles change.
        store.$profiles
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                self?.refreshHotkeys(for: list)
            }
            .store(in: &cancellables)

        refreshHotkeys(for: store.profiles)
        Self.shared = self

        // Prewarm audio at launch — pays the ~150-300ms voice-processing-enable
        // + engine.start cost off the hot path. Hotkey press becomes near-instant.
        Task { [weak self] in
            do { try await self?.audio.prewarmAll() }
            catch { NSLog("[VG] audio prewarm failed: %{public}@", String(describing: error)) }
        }
    }

    var menuStatus: String { "Status: \(state.menuLabel)" }

    // MARK: - Hotkey wiring

    private func refreshHotkeys(for list: [Profile]) {
        hotkeys.unregisterAll()
        for profile in list where profile.enabled {
            hotkeys.register(
                profile: profile,
                onActivate: { [weak self] in
                    Task { @MainActor in self?.activate(profile: profile) }
                },
                onDeactivate: { [weak self] in
                    Task { @MainActor in self?.deactivate(profile: profile) }
                }
            )
        }
    }

    // MARK: - Session lifecycle

    private func activate(profile: Profile) {
        NSLog("[VG] activate profile=%{public}@ vad=%{public}@ provider=%{public}@", profile.name, profile.vad.rawValue, profile.provider.rawValue)
        if isTearingDown { NSLog("[VG] activate ignored — teardown in progress"); return }
        activeProfileKeyHeld = true

        // Each press = brand new session. Tear down any prior session entirely
        // (cut socket, stop playback, drop conversation memory) before connecting.
        if currentProvider != nil {
            NSLog("[VG] killing prior session for fresh start")
            audio.cutPlayback()
            forceEndSessionSync()
        }

        sessionGen &+= 1
        let myGen = sessionGen
        sessionHasResponded = false
        currentTranscript = ""
        activeProfile = profile
        setState(.connecting)

        guard let apiKey = KeychainStore.apiKey(for: profile.provider), !apiKey.isEmpty else {
            NSLog("[VG] no API key for %{public}@", profile.provider.rawValue)
            setState(.error("No API key for \(profile.provider.displayName). Open Settings."))
            return
        }
        NSLog("[VG] api key present, len=%d", apiKey.count)

        let provider: VoiceProvider
        switch profile.provider {
        case .gemini: provider = GeminiProvider()
        case .openai: provider = OpenAIProvider()
        case .grok:   provider = GrokProvider()
        }
        currentProvider = provider

        // Provider sample rate convention.
        let micRate: Double = (profile.provider == .gemini) ? 16000 : 24000

        // Pump provider events to UI + audio playback.
        eventPumpTask?.cancel()
        let pumpedProvider = provider // capture for stale-event filtering
        eventPumpTask = Task { [weak self] in
            for await event in provider.events {
                guard let self = self else { return }
                // Drop events from a provider that is no longer the active one.
                // This happens during fresh-session-per-press teardown.
                let isCurrent = await MainActor.run { self.currentProvider === pumpedProvider }
                if !isCurrent { continue }
                switch event {
                case .stateChange(let s):
                    NSLog("[VG] state→%{public}@", String(describing: s))
                    await MainActor.run {
                        self.setState(s)
                        // Mic stays open during .speaking so the user (and the
                        // server VAD) can barge-in. Echo from speakers bleeding
                        // into the mic is mitigated by AVAudioEngine voice
                        // processing (AEC) — see AudioEngine.start.
                        if case .speaking = s { self.sessionHasResponded = true }
                        // Auto-end the session only after we've seen at least
                        // one .speaking (i.e. a real response started). Without
                        // this guard the initial post-connect .listening would
                        // tear down the session before the user could speak.
                        if case .listening = s,
                           self.sessionHasResponded,
                           self.activeProfileKeyHeld == false,
                           self.currentProvider != nil {
                            self.endSession()
                        }
                    }
                case .audioOut(let pcm, let rate):
                    NSLog("[VG] audioOut bytes=%d rate=%d", pcm.count, rate)
                    self.audio.playPCM16(pcm, rate: rate)
                case .userText(let t):
                    NSLog("[VG] user: %{public}@", t)
                case .assistantTextDelta(let t):
                    NSLog("[VG] asst delta: %{public}@", t)
                    await MainActor.run { self.currentTranscript += t }
                case .assistantTextDone:
                    NSLog("[VG] asst done")
                    await MainActor.run {
                        let text = self.currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        switch profile.output {
                        case .paste, .both:
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(text, forType: .string)
                            NSLog("[VG] copied %d chars to clipboard", text.count)
                            if profile.output == .paste || profile.output == .both {
                                Self.simulatePasteIfPossible()
                            }
                        case .speak, .none:
                            break
                        }
                    }
                case .error(let msg):
                    NSLog("[VG] provider error: %{public}@", msg)
                    await MainActor.run { self.setState(.error(msg)) }
                case .costUpdate(let inSec, let outSec):
                    let r = self.rates(for: profile.provider)
                    let cost = (inSec / 60.0) * r.inPerMin + (outSec / 60.0) * r.outPerMin
                    await MainActor.run {
                        self.sessionCostUSD = cost
                        self.hud.updateCost(cost)
                        if let cap = profile.costCapUSD, cost >= cap {
                            self.deactivate(profile: profile)
                        }
                    }
                }
            }
        }

        // Build Silero VAD gate when requested. If construction fails (e.g. ONNX
        // model missing), we silently fall back to ungated capture for this
        // session — the alternative would be a hard failure on hotkey activate.
        let vadGate: VadGate?
        if profile.vad == .silero {
            let g = VadGate()
            if g == nil {
                NSLog("[AppController] Silero VAD unavailable; proceeding ungated")
            }
            vadGate = g
        } else {
            vadGate = nil
        }
        self.currentVAD = vadGate
        self.vadDidStartUtterance = false

        // Wire VAD events → provider utterance lifecycle.
        if let gate = vadGate {
            gate.onEvent = { [weak self, weak provider] event in
                guard let self = self, let provider = provider else { return }
                switch event {
                case .speechStart:
                    Task { @MainActor in self.vadDidStartUtterance = true }
                    Task { try? await provider.startUtterance() }
                case .speechEnd:
                    Task { @MainActor in self.vadDidStartUtterance = false }
                    Task { try? await provider.endUtterance() }
                }
            }
        }

        // Start mic capture immediately (engine is prewarmed at app launch — this
        // is sub-ms now) AND kick off WSS connect in parallel. Audio that arrives
        // before connect completes is buffered into a small ring; flushed once
        // connected. Hides ~150-300ms WSS handshake behind the first audio bytes.
        let pendingChunks = AudioRingBuffer()
        let providerReady = ReadyFlag()
        audio.startSession(
            targetRate: micRate,
            onCapture: { [weak provider, weak vadGate] pcm in
                if let g = vadGate, !g.isSpeaking { return }
                if providerReady.value, let provider = provider {
                    Task { try? await provider.sendAudio(pcm) }
                } else {
                    pendingChunks.append(pcm)
                }
            },
            onFloatFrame: vadGate.map { gate in
                { @Sendable (frame: [Float]) in gate.feed(frame, rate: micRate) }
            },
            onLevel: { [weak self] lvl in
                Task { @MainActor in
                    guard let self = self, self.sessionGen == myGen else { return }
                    self.inputLevel = lvl
                    self.hud.updateLevel(lvl)
                    self.maybeBargeIn(level: lvl)
                }
            }
        )

        currentSessionTask?.cancel()
        currentSessionTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                NSLog("[VG] connecting provider...")
                try await provider.connect(profile: profile, apiKey: apiKey)

                let stillCurrent = await MainActor.run { self.sessionGen == myGen }
                if !stillCurrent {
                    NSLog("[VG] connect won race but session is stale — aborting")
                    await provider.disconnect()
                    self.audio.stopSession()
                    return
                }

                // Flush any audio captured while WSS handshake was in flight.
                let buffered = pendingChunks.drain()
                if !buffered.isEmpty {
                    NSLog("[VG] flushing %d buffered chunks", buffered.count)
                    for pcm in buffered { try? await provider.sendAudio(pcm) }
                }
                providerReady.value = true

                if profile.vad != .server && profile.vad != .silero {
                    try await provider.startUtterance()
                }
            } catch {
                let stillCurrent = await MainActor.run { self.sessionGen == myGen }
                if stillCurrent {
                    await MainActor.run { self.setState(.error(String(describing: error))) }
                    self.audio.stopSession()
                }
            }
        }
    }


    /// On hotkey release: stop the mic tap and (in manual VAD modes) tell the
    /// provider the user turn is done. DO NOT disconnect — the assistant's
    /// audio reply streams in *after* this point. Socket stays alive until
    /// `response.done` (turnComplete) is observed, then we fully tear down.
    private func deactivate(profile: Profile) {
        NSLog("[VG] deactivate profile=%{public}@", profile.name)
        activeProfileKeyHeld = false
        guard let active = activeProfile, active.id == profile.id else { return }
        let provider = currentProvider

        let needsManualEnd: Bool
        switch profile.vad {
        case .server: needsManualEnd = false
        case .silero: needsManualEnd = vadDidStartUtterance
        case .off:    needsManualEnd = true
        }

        currentVAD?.onEvent = nil
        currentVAD = nil
        vadDidStartUtterance = false

        audio.stopSession()
        // Cut any in-flight assistant audio + cancel the in-flight response
        // server-side. User releasing the key = "I'm done, kill it."
        audio.cutPlayback()
        Task { try? await provider?.interrupt() }
        // End the session now — fresh next press, no memory.
        endSession()
    }

    /// Full teardown: drops the socket and clears active profile. Called on
    /// `response.done`/`turnComplete` so assistant audio finishes playing.
    private func endSession() {
        NSLog("[VG] endSession")
        if isTearingDown { return }
        isTearingDown = true
        let provider = currentProvider
        sessionGen &+= 1 // invalidate any in-flight closures
        currentSessionTask?.cancel()
        currentSessionTask = nil
        currentProvider = nil
        Task { [weak self] in
            await provider?.disconnect()
            await MainActor.run {
                self?.eventPumpTask?.cancel()
                self?.eventPumpTask = nil
                self?.setState(.idle)
                self?.activeProfile = nil
                self?.isTearingDown = false
            }
        }
    }

    /// Synchronous force-end used when starting a fresh session. Cancels current
    /// pumps + fires off a detached disconnect — does NOT wait. The generation
    /// bump ensures any closures still referencing the prior session become
    /// no-ops as soon as their `sessionGen == myGen` check fails.
    private func forceEndSessionSync() {
        let provider = currentProvider
        sessionGen &+= 1
        currentSessionTask?.cancel()
        currentSessionTask = nil
        eventPumpTask?.cancel()
        eventPumpTask = nil
        currentProvider = nil
        currentVAD?.onEvent = nil
        currentVAD = nil
        vadDidStartUtterance = false
        audio.stopSession()
        Task.detached { await provider?.disconnect() }
    }

    private func setState(_ newState: ProviderState) {
        state = newState
        // Reset barge-in timer when entering a new state.
        if case .speaking = newState { bargeInLastUnderTime = Date() }
        hud.show(state: newState, profile: activeProfile, level: inputLevel, costUSD: sessionCostUSD)
    }

    /// Post a synthetic ⌘V to the focused app so the just-copied transcript
    /// pastes at the cursor. Requires Accessibility permission — without it
    /// CGEvent.post silently no-ops, so the user still has the text on the
    /// clipboard and can paste manually.
    static func simulatePasteIfPossible() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            NSLog("[VG] no Accessibility permission — text on clipboard, not auto-pasting")
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        // 'V' keycode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        NSLog("[VG] posted ⌘V")
    }

    /// Energy-based barge-in. Only active during `.speaking`. With AEC enabled,
    /// the mic level mostly reflects the user (speaker bleed is cancelled), so
    /// sustained level above threshold = user is interrupting → cut assistant.
    private func maybeBargeIn(level: Double) {
        guard case .speaking = state else {
            bargeInLastUnderTime = Date()
            return
        }
        let now = Date()
        if level < Self.BARGE_THRESHOLD {
            bargeInLastUnderTime = now
            return
        }
        let heldMs = now.timeIntervalSince(bargeInLastUnderTime) * 1000
        if heldMs >= Self.BARGE_HOLD_MS {
            NSLog("[VG] barge-in: level=%.3f held=%.0fms — cutting assistant", level, heldMs)
            audio.cutPlayback()
            let provider = currentProvider
            Task { try? await provider?.interrupt() }
            // Reset timer so we don't fire again until level drops.
            bargeInLastUnderTime = Date.distantFuture
        }
    }
}
