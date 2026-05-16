<div align="center">

<img src="assets/icon.png" alt="Echo" width="160" height="160" />

# Echo

**Push-to-talk voice assistant for macOS.**
Hold a hotkey, speak, get an instant spoken reply.

</div>

---

## What it is

Echo is a tiny menu-bar Mac app that streams your microphone over a realtime
WebSocket to **Gemini Live** and plays back the assistant's spoken reply in
milliseconds. No browser, no server hop, no chat history piling up — every
press is a fresh session.

Built for sub-300ms perceived latency. Engine prewarmed at launch, audio capture
runs in parallel with the WebSocket handshake, mic auto-mutes during playback so
you never bill for speaker bleed.

## Highlights

- **Hold the chord, talk, release.** One app-wide push-to-talk chord (default
  ⌥ + `` ` ``): hold the full chord to talk, release the trigger key to send,
  release the modifier to end the session. Rebind it in Settings → General.
- **Notch-engulfing HUD** that blends with the MacBook notch hardware
  (VoiceInk-style) showing live waveform, state, and per-session cost.
- **Gemini Live** (`gemini-3.1-flash-live-preview`) over the realtime
  BidiGenerateContent WebSocket.
- **Server-side VAD with explicit PTT markers.** The client brackets each hold
  with `activityStart`/`activityEnd`, so turns never wait on a silence timeout.
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
5. Hold the configured chord and start talking.

Echo also needs **Accessibility** permission — it captures the global chord via
a `CGEventTap` on the HID event stream, and posts a synthetic ⌘V for the
"Paste" output modes. macOS prompts on first launch; if you miss it, grant
access in System Settings → Privacy & Security → Accessibility and the hotkey
starts working immediately (no relaunch needed). For paste modes without it,
the transcript still lands on your clipboard — paste manually.

## Bring your own API key

Get one:

- **Gemini Live** — https://aistudio.google.com/apikey (free tier available; the
  Live API needs a billing-enabled project for production use).

Paste it into Echo Settings → *General* → API Keys.

## Hotkey

Echo uses one app-wide two-stage chord, captured via a `CGEventTap` on the HID
event stream (Accessibility permission required). Default is ⌥ + `` ` ``. A
modifier (`⌘`/`⌃`/`⌥`/`⇧`) plus a trigger key is required — record a new chord
in Settings → *General* → Hotkey.

## Repo layout

```
Sources/Echo/          SwiftUI app, providers, audio engine, chord monitor
Resources/             Info.plist, AppIcon.icns
Package.swift          Swift Package manifest
build-app.sh           Builds Echo.app, copies SPM resource bundles, ad-hoc signs
seed-keys.sh           Reads ./.env and seeds keys into Keychain
branding/              Source artwork (icns + PNG sizes)
assets/                Icons used in this README
```

Built artifacts (`Echo.app`, `Echo.dmg`, `.build/`) are gitignored — the .dmg
ships via [GitHub Releases](https://github.com/Vijay-Duke/echo/releases).

## Architecture (very short version)

- **`AudioEngine`** owns a single AVAudioEngine started at app launch with
  voice processing (AEC) on, capture tap installed, player primed with a silent
  buffer. Sessions just toggle `isBroadcasting` + swap callbacks — no
  per-press hardware setup.
- **`ChordMonitor`** owns the global two-stage chord via a `CGEventTap`.
- **`AppController`** wires chord events → session lifecycle. Each press =
  fresh `VoiceProvider`, fresh WebSocket, fresh transcript. Release = full
  teardown.
- **`GeminiProvider`** speaks the
  [Gemini Live BidiGenerateContent](https://ai.google.dev/gemini-api/docs/live)
  WS protocol directly, streams 16kHz PCM up and 24kHz PCM down. All outbound
  frames go through one FIFO queue so audio and utterance markers stay ordered.
  End-of-speech is server-detected; the client brackets each hold with explicit
  `activityStart`/`activityEnd` markers.

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

[MIT](LICENSE) — do whatever, no warranty.
