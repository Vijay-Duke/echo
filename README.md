<div align="center">

<img src="assets/icon.png" alt="Echo" width="160" height="160" />

# Echo

**Push-to-talk voice assistant for macOS.**
Hold a hotkey, speak, get an instant spoken reply.

</div>

---

## What it is

Echo is a tiny menu-bar Mac app that streams your microphone over a realtime
WebSocket to **Gemini Live** (or OpenAI Realtime / xAI Grok) and plays back the
assistant's spoken reply in milliseconds. No browser, no server hop, no chat
history piling up — every press is a fresh session.

Built for sub-300ms perceived latency. Engine prewarmed at launch, audio capture
runs in parallel with the WebSocket handshake, mic auto-mutes during playback so
you never bill for speaker bleed.

## Highlights

- **Hold hotkey, talk, release.** Default is `` ` `` (backtick) but configurable
  per-profile (PTT, toggle, hybrid, double-tap).
- **Notch-engulfing HUD** that blends with the MacBook notch hardware
  (VoiceInk-style) showing live waveform, state, and per-session cost.
- **Multiple providers in one app.** Gemini Live (`gemini-3.1-flash-live-preview`),
  OpenAI Realtime, xAI Grok — pick per profile.
- **Server VAD or client-side Silero VAD.** Silero v5 ONNX bundled, runs on
  device, gates audio before it ever leaves your Mac.
- **Tight cost tracking.** Reads `usageMetadata` audio-modality token counts
  from Gemini for authoritative billing, enforces per-profile cost caps.
- **Mic muted during assistant playback** so AEC + cost stay clean.
- **Output options.** Speak only, paste at cursor (auto-⌘V via Accessibility),
  speak+paste, or silent.
- **Keychain-stored API keys.** Never written to disk in plaintext.

## Install

1. Download the latest `Echo.dmg` from
   [Releases](https://github.com/Vijay-Duke/echo/releases/latest).
2. Open it, drag **Echo** → **Applications**.
3. Launch Echo. macOS will prompt for **microphone** permission — accept.
4. Open **Echo Settings** (menu-bar icon → *Open Settings…*) and paste your API
   keys. Or seed them from a `.env` file with `./seed-keys.sh`.
5. Hold the configured hotkey and start talking.

The first time you use a profile with output **Paste at cursor** or
**Speak + paste**, macOS will prompt for **Accessibility** permission so Echo
can post a synthetic ⌘V at the focused app. Without it, the transcript still
lands on your clipboard — paste manually.

## Bring your own API key

Get one of:

- **Gemini Live** — https://aistudio.google.com/apikey (free tier available; the
  Live API needs a billing-enabled project for production use).
- **OpenAI Realtime** — https://platform.openai.com/api-keys
- **xAI Grok Voice** — https://console.x.ai

Paste it into Echo Settings → *General* → API Keys.

## Hotkey shortcuts

Each profile binds its own global hotkey via the
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) library.
macOS Sequoia/Tahoe requires modifiers (`⌘` or `⌃`) on most keys; bare
function keys also work.

## Repo layout

```
Sources/Echo/          SwiftUI app, providers, audio engine, VAD
Resources/             Info.plist, AppIcon.icns
Package.swift          Swift Package manifest
build-app.sh           Builds Echo.app, copies SPM resource bundles, ad-hoc signs
seed-keys.sh           Reads ./.env and seeds keys into Keychain
branding/              Source artwork (icns + PNG sizes)
assets/                Icons used in this README
web-demo/              Browser demos: STT/chat/TTS pipeline, Grok realtime, Gemini Live
                       (server.js + public/, separate from the Mac app)
```

Built artifacts (`Echo.app`, `Echo.dmg`, `.build/`) are gitignored — the .dmg
ships via [GitHub Releases](https://github.com/Vijay-Duke/echo/releases).

## Architecture (very short version)

- **`AudioEngine`** owns a single AVAudioEngine started at app launch with
  voice processing (AEC) on, capture tap installed, player primed with a silent
  buffer. Sessions just toggle `isBroadcasting` + swap callbacks — no
  per-press hardware setup.
- **`AppController`** wires hotkey events → session lifecycle. Each press =
  fresh `VoiceProvider`, fresh WebSocket, fresh transcript. Release = full
  teardown.
- **`GeminiProvider`** speaks the
  [Gemini Live BidiGenerateContent](https://ai.google.dev/gemini-api/docs/live)
  WS protocol directly, streams 16kHz PCM up and 24kHz PCM down.
- **`VadGate`** is the optional client-side Silero v5 ONNX runtime gate
  (skips audio frames before they reach the provider).

## Building from source

Requires macOS 14+, Xcode 15+ command-line tools, Swift 5.10.

```bash
swift build                 # SPM build
./build-app.sh              # bundles Echo.app + ad-hoc codesign
open Echo.app
```

To rebuild the .dmg:

```bash
STAGE=$(mktemp -d)
cp -R Echo.app "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Echo -srcfolder "$STAGE" -ov -format UDZO -quiet Echo.dmg
```

## Status

Personal project. No warranty. Will probably break on Apple Silicon vs Intel
edge cases, on different mic input devices, and when Google ships a new Live
API protocol revision.

## License

Private.
