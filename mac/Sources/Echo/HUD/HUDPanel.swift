import AppKit
import SwiftUI

/// Notch-style HUD ported from VoiceInk's NotchRecorderPanel pattern.
///
/// Trick: render a solid black rectangle positioned BEHIND the physical notch.
/// The notch hardware itself is opaque black, so it blends with the panel —
/// visually the panel becomes a "halo" that hangs off the notch.
final class HUDPanel: NSPanel {
    private var hosting: NSHostingView<HUDView>?
    private var autoHideTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    private var currentState: ProviderState = .idle
    private var currentProfile: Profile?
    private var currentLevel: Double = 0
    private var currentCost: Double = 0

    init() {
        let metrics = Self.calculateMetrics()
        super.init(
            contentRect: metrics.frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .statusBar + 3
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.ignoresMouseEvents = true
        self.styleMask.remove(.titled)
        self.titleVisibility = .hidden
        self.appearance = NSAppearance(named: .darkAqua)

        let view = HUDView(state: .idle, profile: nil, level: 0, costUSD: 0,
                           notchWidth: metrics.notchWidth, notchHeight: metrics.notchHeight)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: metrics.frame.size)
        self.contentView = host
        self.hosting = host

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.reposition()
            }
        }
    }

    deinit {
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Show / Update / Hide

    func show(state: ProviderState, profile: Profile?, level: Double = 0, costUSD: Double = 0) {
        currentState = state
        currentProfile = profile
        currentLevel = level
        currentCost = costUSD
        rerender()
        reposition()
        if !isVisible {
            orderFrontRegardless()
        }
        scheduleAutoHideIfIdle()
    }

    func updateLevel(_ level: Double) {
        currentLevel = level
        rerender()
    }

    func updateCost(_ cost: Double) {
        currentCost = cost
        rerender()
    }

    func hide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        orderOut(nil)
    }

    // MARK: - Internals

    private func rerender() {
        let m = Self.calculateMetrics()
        let view = HUDView(state: currentState, profile: currentProfile,
                           level: currentLevel, costUSD: currentCost,
                           notchWidth: m.notchWidth, notchHeight: m.notchHeight)
        hosting?.rootView = view
    }

    private func reposition() {
        let metrics = Self.calculateMetrics()
        setFrame(metrics.frame, display: true)
    }

    /// Ported from VoiceInk: derive exact notch dimensions from `safeAreaInsets`
    /// + `auxiliaryTopLeftArea/RightArea`. The panel always anchors flush at
    /// `screen.frame.maxY` so its top edge sits at the very top of the display.
    static func calculateMetrics() -> (frame: NSRect, notchWidth: CGFloat, notchHeight: CGFloat) {
        guard let screen = NSScreen.main else {
            return (NSRect(x: 0, y: 0, width: 460, height: 60), 200, 32)
        }
        let safeInsets = screen.safeAreaInsets
        let notchHeight: CGFloat = safeInsets.top > 0 ? safeInsets.top : NSStatusBar.system.thickness
        let notchWidth: CGFloat = {
            if let left = screen.auxiliaryTopLeftArea?.width,
               let right = screen.auxiliaryTopRightArea?.width {
                return screen.frame.width - left - right
            }
            return 180
        }()
        let sideExpansion: CGFloat = 110
        let totalWidth = notchWidth + sideExpansion * 2
        let totalHeight: CGFloat = notchHeight + 36 // notch + content drop below
        let x = screen.frame.midX - totalWidth / 2
        let y = screen.frame.maxY - totalHeight
        return (NSRect(x: x, y: y, width: totalWidth, height: totalHeight), notchWidth, notchHeight)
    }

    private func scheduleAutoHideIfIdle() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        if case .idle = currentState {
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                self?.hide()
            }
        }
    }
}
