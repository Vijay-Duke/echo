import SwiftUI
import AppKit

/// First-launch walkthrough. Shown the first time the app runs (or any time the
/// user re-runs from menu bar → Show Onboarding). Three pages:
///   1. What it is + how the hotkey works
///   2. Permissions you'll be asked for and why
///   3. API keys: paste-once, stored in Keychain
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page: Int = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            symbol: "waveform.and.mic",
            title: "Hold the hotkey, talk, release.",
            body: """
            Echo is a push-to-talk voice agent that streams your microphone to a
            realtime model (Gemini Live, OpenAI Realtime, or Grok) and plays the
            spoken reply back.

            Default hotkey is the backtick key (\u{0060}). You can change it
            per-profile in Settings.

            A small pill behind your MacBook notch shows live state — listening,
            thinking, speaking — and the running cost of the session.
            """
        ),
        OnboardingPage(
            symbol: "lock.shield",
            title: "Two permissions, plain reasons.",
            body: """
            • Microphone — to capture what you say. macOS will prompt the first
              time you use Echo. Required.

            • Accessibility — only if a profile uses the “Paste at cursor”
              output mode. Echo posts a synthetic ⌘V into the focused app so
              the spoken reply lands as text. Without it, the reply still goes
              to your clipboard and you can paste it manually. Optional.

            No data leaves your Mac except the audio frames you send, on the
            socket you opened, to the provider whose API key you pasted.
            """
        ),
        OnboardingPage(
            symbol: "key.fill",
            title: "Paste your API key.",
            body: """
            You bring your own key. Echo stores it in the macOS Keychain — never
            on disk in plaintext, never sent anywhere except the provider's
            realtime endpoint.

            Get one from:
              • Gemini Live — https://aistudio.google.com/apikey
              • OpenAI Realtime — https://platform.openai.com/api-keys
              • xAI Grok Voice — https://console.x.ai

            Open Settings (menu bar icon → Open Settings…) to paste it.
            """
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Hero block.
            VStack(spacing: 16) {
                Image(systemName: pages[page].symbol)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.top, 32)

                Text(pages[page].title)
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Text(pages[page].body)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .frame(maxWidth: 460, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 4)

                Spacer(minLength: 12)
            }

            Divider()

            // Footer: dot indicator + back/next.
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 {
                    Button("Back") { page -= 1 }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                if page < pages.count - 1 {
                    Button("Next") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open Settings") {
                        onFinish()
                        AppDelegate.openSettings()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 480)
    }
}

private struct OnboardingPage {
    let symbol: String
    let title: String
    let body: String
}
