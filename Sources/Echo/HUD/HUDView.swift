import SwiftUI

/// Notch-engulfing HUD pill. Solid black rectangle that sits BEHIND the physical
/// notch — the notch hardware (also black) blends with the pill so visually
/// they appear continuous. Uses `NotchShape` for the slight inward top-corner
/// curls + rounded bottom corners that make the side wings look organic.
struct HUDView: View {
    let state: ProviderState
    let profile: Profile?
    let level: Double
    let costUSD: Double
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(topCornerRadius: 6, bottomCornerRadius: 16)
                .fill(Color.black)

            // Content sits below the notch height. Above the cutout would
            // collide with the physical notch. Side margins keep content
            // inside the wings, not under the notch hardware.
            HStack(spacing: 8) {
                WaveBars(level: level, color: stateColor)
                    .frame(width: 40, height: 14)

                Text(stateLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if costUSD > 0 {
                    Text(String(format: "$%.4f", costUSD))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, notchHeight + 4)
            .padding(.bottom, 4)
        }
    }

    private var stateLabel: String {
        switch state {
        case .idle:        return "Idle"
        case .connecting:  return "Connecting"
        case .listening:   return "Listening"
        case .thinking:    return "Thinking"
        case .speaking:    return "Speaking"
        case .error(let msg):
            let trimmed = msg.replacingOccurrences(of: "\n", with: " ")
            return "Error: \(String(trimmed.prefix(80)))"
        }
    }

    private var stateColor: Color {
        switch state {
        case .idle:        return .gray
        case .connecting:  return .yellow
        case .listening:   return .blue
        case .thinking:    return .orange
        case .speaking:    return .green
        case .error:       return .red
        }
    }
}

/// VoiceInk's NotchShape: rectangle with small inward top-corner curls (so the
/// pill blends seamlessly with the notch hardware) and rounded bottom corners.
private struct NotchShape: Shape {
    var topCornerRadius: CGFloat = 6
    var bottomCornerRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

private struct WaveBars: View {
    let level: Double
    let color: Color
    private let bars: Int = 7

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: heightFor(index: i, total: geo.size.height))
                        .opacity(opacityFor(index: i))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func heightFor(index: Int, total: CGFloat) -> CGFloat {
        let mid = Double(bars - 1) / 2.0
        let dist = abs(Double(index) - mid) / mid
        let envelope = max(0.3, 1.0 - dist * 0.7)
        let amp = max(0.2, min(1.0, level)) * envelope
        return total * CGFloat(amp)
    }

    private func opacityFor(index: Int) -> Double {
        let mid = Double(bars - 1) / 2.0
        let dist = abs(Double(index) - mid) / mid
        return 0.55 + 0.45 * (1.0 - dist)
    }
}
