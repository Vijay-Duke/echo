import SwiftUI
import AppKit
import Combine
import os.log

private let appLog = OSLog(subsystem: "com.echo.session", category: "controller")
@inline(__always) private func slog(_ msg: String) {
    os_log("%{public}@", log: appLog, type: .info, msg)
}

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
            Text(p.name)
                .font(.system(size: 11))
        }

        Text(appDelegate.controller.chordHintText)
            .font(.system(size: 11))

        Divider()

        Button("Open Settings…") {
            NSLog("[VG] menu Open Settings clicked")
            AppDelegate.openSettings()
        }

        Button("Show Walkthrough…") {
            AppDelegate.openOnboarding()
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
    static let onboardingDoneKey = "onboarding.v1.completed"

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

    private static var onboardingWindow: NSWindow?

    static func openOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = onboardingWindow {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = OnboardingView(onFinish: {
            UserDefaults.standard.set(true, forKey: onboardingDoneKey)
            onboardingWindow?.close()
            onboardingWindow = nil
        })
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Welcome to Echo"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 540, height: 480))
        win.center()
        win.isReleasedWhenClosed = false
        onboardingWindow = win
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

    // Cost rates (USD per minute audio in / out) — Gemini 3.1 flash live.
    private struct RateCard { let inPerMin: Double; let outPerMin: Double }
    private let rateCard = RateCard(inPerMin: 0.005, outPerMin: 0.018)

    // Subsystems.
    let chord = ChordMonitor()
    private let hud = HUDPanel()
    private let audio = AudioEngine()

    // Lazily-instantiated per session.
    private var currentProvider: VoiceProvider?
    private var currentSessionTask: Task<Void, Never>?
    private var eventPumpTask: Task<Void, Never>?

    // Shadow WSS — pre-connected, keepalive-pinged spare. Promoted on next press
    // so the user doesn't pay DNS+TLS+WSS+setupComplete (~250-500ms cold start).
    // Invariant: shadow has zero conversation history (no audio ever sent).
    private var shadowProvider: GeminiProvider?
    private var shadowProfileId: UUID?
    private var shadowKeepAliveTask: Task<Void, Never>?
    private var shadowConnectTask: Task<Void, Never>?
    private static let shadowKeepAliveInterval: UInt64 = 30_000_000_000 // 30s
    /// Tracks whether the user is still holding the primary (session) hotkey.
    /// Release ends the WSS session entirely.
    private var activeProfileKeyHeld: Bool = false
    /// Tracks whether the secondary (talk) hotkey is held. While true, mic audio
    /// streams to the provider. Release sends activityEnd + cuts assistant audio.
    private var talkKeyHeld: Bool = false
    /// Thread-safe mirror of `talkKeyHeld`, read from the serial audio capture
    /// queue so the capture callback can gate frames without hopping to the
    /// main actor (which would reorder them).
    private let talkGate = ReadyFlag()

    /// Hotkey instructions for the menu bar, derived from the live chord binding.
    var chordHintText: String {
        "Hold \(chord.displayString) to talk · release \(chord.triggerString) to send · release \(chord.modifierString) to hibernate"
    }
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

        // Shadow refresh is debounced and only fires when setup-relevant fields
        // change (model/voice/prompt/web-search/first-enabled-profile-id).
        store.$profiles
            .map { Self.shadowFingerprint(for: $0) }
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.invalidateShadow()
                self.warmShadowIfPossible()
            }
            .store(in: &cancellables)

        wireChord()
        Self.shared = self

        // Prewarm audio at launch — pays the ~150-300ms voice-processing-enable
        // + engine.start cost off the hot path. Hotkey press becomes near-instant.
        Task { [weak self] in
            do { try await self?.audio.prewarmAll() }
            catch { NSLog("[VG] audio prewarm failed: %{public}@", String(describing: error)) }
        }

        // Warm shadow WSS for the first enabled profile (typically the default
        // Quick Assistant). Skipped if no API key is configured yet — Settings
        // can call refreshShadow() after the user pastes a key.
        warmShadowIfPossible()
    }

    /// Picks the first enabled profile and opens a parked Gemini Live session
    /// for it. No-op if a shadow already exists or there's no API key yet.
    func warmShadowIfPossible() {
        guard shadowProvider == nil, shadowConnectTask == nil else { return }
        guard let profile = profiles.profiles.first(where: { $0.enabled }) else { return }
        guard let apiKey = KeychainStore.apiKey(for: .gemini), !apiKey.isEmpty else {
            slog("shadow: skipped (no Gemini API key)")
            return
        }
        let p = GeminiProvider()
        shadowProvider = p
        shadowProfileId = profile.id
        let warmStart = Date()
        slog("shadow: connecting (\(profile.name))")
        shadowConnectTask = Task { [weak self, weak p] in
            guard let p = p else { return }
            do {
                try await Self.connectWithRetry(provider: p, profile: profile, apiKey: apiKey)
                let elapsedMs = Int(Date().timeIntervalSince(warmStart) * 1000)
                await MainActor.run {
                    guard let self = self, self.shadowProvider === p else { return }
                    slog("shadow: ready (\(elapsedMs)ms)")
                    self.shadowConnectTask = nil
                    self.startShadowKeepAlive(p)
                }
            } catch {
                slog("shadow: connect failed after retries — \(error)")
                await MainActor.run {
                    guard let self = self, self.shadowProvider === p else { return }
                    self.shadowProvider = nil
                    self.shadowProfileId = nil
                    self.shadowConnectTask = nil
                    // Re-warm in 2s — covers transient network drops at launch.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        self?.warmShadowIfPossible()
                    }
                }
            }
        }
    }

    private func startShadowKeepAlive(_ p: GeminiProvider) {
        shadowKeepAliveTask?.cancel()
        shadowKeepAliveTask = Task { [weak self, weak p] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: AppController.shadowKeepAliveInterval)
                if Task.isCancelled { return }
                guard let p = p else { return }
                do {
                    try await p.sendKeepAlive()
                } catch {
                    NSLog("[VG] shadow keepalive failed: %{public}@ — refreshing", String(describing: error))
                    await MainActor.run {
                        guard let self = self else { return }
                        if self.shadowProvider === p {
                            self.shadowProvider = nil
                            self.shadowProfileId = nil
                            self.shadowKeepAliveTask = nil
                            Task.detached { await p.disconnect() }
                            self.warmShadowIfPossible()
                        }
                    }
                    return
                }
            }
        }
    }

    /// Take ownership of the shadow if it matches the requested profile.
    /// Returns nil if shadow not ready or for a different profile.
    private func takeShadow(for profileId: UUID) -> GeminiProvider? {
        guard let p = shadowProvider,
              shadowConnectTask == nil,    // connect already finished
              shadowProfileId == profileId else { return nil }
        shadowProvider = nil
        shadowProfileId = nil
        shadowKeepAliveTask?.cancel()
        shadowKeepAliveTask = nil
        return p
    }

    /// Stable hash of the fields that go into a Gemini Live `setup` payload.
    /// Used to debounce shadow invalidation so per-keystroke profile edits
    /// don't churn the WSS.
    private static func shadowFingerprint(for profiles: [Profile]) -> String {
        guard let p = profiles.first(where: { $0.enabled }) else { return "" }
        return [
            p.id.uuidString,
            p.modelName,
            p.voiceName,
            p.systemPrompt,
            String(p.webSearchEnabled ?? false),
        ].joined(separator: "|")
    }

    /// Drop the current shadow (e.g. profile changed) without taking it.
    private func invalidateShadow() {
        guard shadowProvider != nil || shadowConnectTask != nil else { return }
        NSLog("[VG] invalidating shadow (profile changed)")
        shadowKeepAliveTask?.cancel(); shadowKeepAliveTask = nil
        shadowConnectTask?.cancel(); shadowConnectTask = nil
        let dying = shadowProvider
        shadowProvider = nil
        shadowProfileId = nil
        Task.detached { await dying?.disconnect() }
    }

    var menuStatus: String { "Status: \(state.menuLabel)" }

    // MARK: - Hotkey wiring

    private func wireChord() {
        // ⌥ alone does nothing — shadow is already pre-warmed at app launch
        // and after each release, so the chord still gets a warm WSS.
        chord.onModifierDown = { /* no-op */ }
        // Full chord (⌥ + `) down: activate session (uses warm shadow) + start
        // streaming mic.
        chord.onTriggerDown = { [weak self] in
            Task { @MainActor in
                guard let self = self,
                      let p = self.activeProfile ?? self.profiles.profiles.first(where: { $0.enabled })
                else { return }
                if self.activeProfile == nil { self.activate(profile: p) }
                self.beginTalk(profile: p)
            }
        }
        // ` released (⌥ still held): send activityEnd → AI responds. Session
        // stays alive so user can press ` again for a follow-up turn (history
        // retained on the same WSS).
        chord.onTriggerUp = { [weak self] in
            Task { @MainActor in
                guard let self = self, let p = self.activeProfile else { return }
                self.endTalk(profile: p)
            }
        }
        // ⌥ released: hibernate. Kill audio, tear down WSS, wipe history,
        // re-warm a fresh shadow for the next chord.
        chord.onModifierUp = { [weak self] in
            Task { @MainActor in
                guard let self = self, let p = self.activeProfile else { return }
                self.deactivate(profile: p)
            }
        }
        chord.start()
        // The CGEventTap needs Accessibility permission, which may not be
        // granted at first launch — `start()` then fails silently. Re-arm each
        // time the app becomes active (e.g. returning from System Settings
        // after granting permission) so the chord and the Settings recorder
        // begin working without requiring an app relaunch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.chord.isRunning else { return }
                if self.chord.start() { NSLog("[VG] chord tap armed on activation") }
            }
        }
    }

    // MARK: - Session lifecycle

    private func activate(profile: Profile) {
        NSLog("[VG] activate profile=%{public}@", profile.name)
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

        guard let apiKey = KeychainStore.apiKey(for: .gemini), !apiKey.isEmpty else {
            NSLog("[VG] no API key for gemini")
            setState(.error("No Gemini API key. Open Settings."))
            return
        }
        NSLog("[VG] api key present, len=%d", apiKey.count)

        let warmShadow = takeShadow(for: profile.id)
        let provider: VoiceProvider = warmShadow ?? GeminiProvider()
        let usingShadow = warmShadow != nil
        slog(usingShadow ? "press: WARM shadow used (skip handshake)" : "press: COLD connect (no shadow ready)")
        currentProvider = provider

        let micRate: Double = 16000

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
                        // Mute mic only while assistant is speaking (speaker
                        // bleed would bill as user audio). Any other state
                        // unmutes so the next user turn isn't silently dropped.
                        if case .speaking = s {
                            self.sessionHasResponded = true
                            self.audio.setMicMuted(true)
                        } else {
                            self.audio.setMicMuted(false)
                        }
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
                    // Only route to the speakers for output modes that speak.
                    // `.paste`/`.none` are text-only — playing would leak audio.
                    if profile.output.playsAudio {
                        self.audio.playPCM16(pcm, rate: rate)
                    }
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
                        if profile.output.pastesText {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(text, forType: .string)
                            NSLog("[VG] copied %d chars to clipboard", text.count)
                            Self.simulatePasteIfPossible()
                        }
                    }
                case .error(let msg):
                    NSLog("[VG] provider error: %{public}@", msg)
                    await MainActor.run { self.setState(.error(msg)) }
                case .costUpdate(let inSec, let outSec):
                    let r = self.rateCard
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

        // PTT + server-VAD only — no client VAD gate, no manual utterance markers.
        // Server VAD detects end-of-speech within the hold so multi-turn works
        // while the key is held; release tears the session down entirely.
        let providerReady = ReadyFlag()
        let talkGate = self.talkGate
        audio.startSession(
            targetRate: micRate,
            onCapture: { [weak provider] pcm in
                // Synchronous + FIFO: the capture queue is serial and
                // `sendAudio` enqueues without suspension, so frames reach
                // Gemini in capture order. `talkGate` is the thread-safe
                // mirror of `talkKeyHeld`.
                guard providerReady.value, talkGate.value,
                      let provider = provider else { return }
                provider.sendAudio(pcm)
            },
            onFloatFrame: nil,
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
                if usingShadow {
                    NSLog("[VG] shadow already connected — skipping handshake")
                } else {
                    try await Self.connectWithRetry(provider: provider,
                                                    profile: profile,
                                                    apiKey: apiKey)
                }

                let stillCurrent = await MainActor.run { self.sessionGen == myGen }
                if !stillCurrent {
                    NSLog("[VG] connect won race but session is stale — aborting")
                    await provider.disconnect()
                    self.audio.stopSession()
                    return
                }

                providerReady.value = true
            } catch {
                let stillCurrent = await MainActor.run { self.sessionGen == myGen }
                if stillCurrent {
                    await MainActor.run { self.setState(.error(String(describing: error))) }
                    self.audio.stopSession()
                }
            }
        }
    }

    /// Connect with up to 2 retries and short backoff on transient errors.
    /// Network blips, TLS handshake hiccups, and Gemini Live preview
    /// throttling all manifest as throwing once and succeeding on retry.
    private static func connectWithRetry(provider: VoiceProvider,
                                         profile: Profile,
                                         apiKey: String) async throws {
        var attempts = 0
        let maxAttempts = 3
        let backoffsMs: [UInt64] = [0, 200, 600]
        while true {
            attempts += 1
            do {
                if attempts > 1 {
                    try await Task.sleep(nanoseconds: backoffsMs[attempts - 1] * 1_000_000)
                    NSLog("[VG] connect retry attempt %d", attempts)
                } else {
                    NSLog("[VG] connecting provider…")
                }
                try await provider.connect(profile: profile, apiKey: apiKey)
                if attempts > 1 { NSLog("[VG] connect succeeded on retry %d", attempts) }
                return
            } catch {
                if attempts >= maxAttempts {
                    NSLog("[VG] connect failed after %d attempts: %{public}@",
                          attempts, String(describing: error))
                    throw error
                }
                NSLog("[VG] connect attempt %d failed: %{public}@ — retrying",
                      attempts, String(describing: error))
            }
        }
    }


    /// On hotkey release: kill the session entirely. Fresh-per-press model —
    /// no conversation memory carried over, no lingering open socket.
    private func deactivate(profile: Profile) {
        slog("press: hibernate (modifier up)")
        activeProfileKeyHeld = false
        talkKeyHeld = false
        talkGate.value = false
        guard let active = activeProfile, active.id == profile.id else { return }
        let provider = currentProvider

        // SNAPPY: tear the UI down synchronously so the HUD vanishes the
        // moment the user releases the modifier. Slow async cleanup (WS close,
        // shadow rewarm) runs detached and never blocks visible state.
        audio.cutPlayback()
        audio.stopSession()
        sessionGen &+= 1
        currentSessionTask?.cancel(); currentSessionTask = nil
        eventPumpTask?.cancel(); eventPumpTask = nil
        currentProvider = nil
        currentTranscript = ""
        sessionHasResponded = false
        isTearingDown = false
        setState(.idle)
        activeProfile = nil
        hud.hide()        // skip the 1.2s auto-hide; release should feel instant

        provider?.interrupt()
        // Runs on the main actor but suspends at the `await` — visible state is
        // already torn down above, so this slow cleanup never blocks the UI.
        Task { [weak self] in
            await provider?.disconnect()
            self?.warmShadowIfPossible()
        }
    }

    /// Talk key down: enable mic streaming + send activityStart.
    /// Cuts any in-flight assistant audio (barge-in).
    private func beginTalk(profile: Profile) {
        slog("press: talk-down")
        // Auto-start session if user pressed talk without session key first.
        if activeProfile == nil {
            activate(profile: profile)
        }
        guard let active = activeProfile, active.id == profile.id else { return }
        if talkKeyHeld { return }
        talkKeyHeld = true
        talkGate.value = true
        // Barge-in: cut any in-flight assistant playback.
        audio.cutPlayback()
        currentProvider?.startUtterance()
    }

    /// Talk key up: send activityEnd → server generates response.
    private func endTalk(profile: Profile) {
        slog("press: talk-up")
        guard talkKeyHeld else { return }
        talkKeyHeld = false
        talkGate.value = false
        guard let active = activeProfile, active.id == profile.id else { return }
        currentProvider?.endUtterance()
    }

    /// Full teardown: drops the socket and clears active profile. Called on
    /// `response.done`/`turnComplete` so assistant audio finishes playing.
    private func endSession() {
        NSLog("[VG] endSession")
        if isTearingDown { return }
        isTearingDown = true
        talkKeyHeld = false
        talkGate.value = false
        let provider = currentProvider
        sessionGen &+= 1 // invalidate any in-flight closures
        currentSessionTask?.cancel()
        currentSessionTask = nil
        currentProvider = nil
        Task { [weak self] in
            await provider?.disconnect()
            await MainActor.run {
                guard let self = self else { return }
                self.eventPumpTask?.cancel()
                self.eventPumpTask = nil
                self.setState(.idle)
                self.activeProfile = nil
                self.isTearingDown = false
                // Spin up a fresh shadow for the next press.
                self.warmShadowIfPossible()
            }
        }
    }

    /// Synchronous force-end used when starting a fresh session. Cancels current
    /// pumps + fires off a detached disconnect — does NOT wait. The generation
    /// bump ensures any closures still referencing the prior session become
    /// no-ops as soon as their `sessionGen == myGen` check fails.
    private func forceEndSessionSync() {
        let provider = currentProvider
        talkGate.value = false
        sessionGen &+= 1
        currentSessionTask?.cancel()
        currentSessionTask = nil
        eventPumpTask?.cancel()
        eventPumpTask = nil
        currentProvider = nil
        audio.stopSession()
        Task.detached { await provider?.disconnect() }
        // Don't spawn a new shadow here — activate() is mid-flight and will
        // construct its own provider (cold) since the old shadow was already
        // either taken or is invalid. The next endSession() will re-warm.
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
        // `WithOptions([prompt: true])` triggers the system Accessibility prompt
        // the first time we need it — without that, the check is silent and
        // the user never knows they should grant the permission.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        if !trusted {
            NSLog("[VG] no Accessibility permission yet — text on clipboard, prompt shown")
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
            currentProvider?.interrupt()
            // Reset timer so we don't fire again until level drops.
            bargeInLastUnderTime = Date.distantFuture
        }
    }
}
