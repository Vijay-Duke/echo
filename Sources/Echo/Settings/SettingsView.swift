import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProfilesSettingsView()
                .tabItem { Label("Profiles", systemImage: "person.crop.circle") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @State private var geminiKey: String = ""
    @State private var outputDevice: String = "System Default"
    @State private var showDockIcon: Bool = UserDefaults.standard.bool(forKey: AppDelegate.showDockIconKey)

    var body: some View {
        Form {
            Section("Hotkey") {
                HotkeyRecorderView()
            }
            Section("Appearance") {
                Toggle("Show in Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, newValue in
                        AppDelegate.setDockIconVisible(newValue)
                    }
                Text("When off, the app runs as a menu bar accessory only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("API Keys") {
                apiRow(label: "Gemini", text: $geminiKey, provider: .gemini)
            }
            Section("Audio") {
                Picker("Output device", selection: $outputDevice) {
                    Text("System Default").tag("System Default")
                }
                .pickerStyle(.menu)
                Text("Device selection coming soon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear {
            geminiKey = KeychainStore.apiKey(for: .gemini) ?? ""
        }
    }

    @ViewBuilder
    private func apiRow(label: String, text: Binding<String>, provider: ProviderKind) -> some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            SecureField("API key", text: text)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                KeychainStore.setAPIKey(text.wrappedValue, for: provider)
                AppController.shared?.warmShadowIfPossible()
            }
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// MARK: - Hotkey recorder

/// A single app-wide chord editor. The chord is global — one press activates
/// whichever profile is first-enabled — so this lives in General, not per-row.
private struct HotkeyRecorderView: View {
    // Mirrors `ChordMonitor`'s persisted binding; `@AppStorage` keeps the label
    // in sync the moment `ChordMonitor.saveBinding()` writes a new chord.
    @AppStorage("chord.keyCode.v1") private var keyCode: Int = 50
    @AppStorage("chord.modifier.v1") private var modifierRaw: Int = Int(CGEventFlags.maskAlternate.rawValue)
    @State private var capturing = false
    @State private var tapRunning = false

    private var label: String {
        ChordMonitor.describe(modifier: CGEventFlags(rawValue: UInt64(modifierRaw)),
                              keyCode: Int64(keyCode))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tapRunning {
                HStack(spacing: 8) {
                    Text(capturing ? "Press chord…" : label)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(capturing ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1))
                    Button(capturing ? "Cancel" : "Record") { toggleCapture() }
                }
                Text("Hold the full chord to talk · release the trigger key to send · release the modifier to hibernate. A modifier (⌘/⌃/⌥/⇧) is required.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Label("Accessibility permission required", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                Text("Echo needs Accessibility access to capture the global hotkey. Grant it in System Settings, then click Re-check.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings") { openAccessibilitySettings() }
                    Button("Re-check") { recheck() }
                }
            }
        }
        .onAppear { recheck() }
        .onDisappear { AppController.shared?.chord.onCapture = nil }
    }

    /// Try to (re)arm the event tap and reflect whether it is live.
    private func recheck() {
        tapRunning = AppController.shared?.chord.start() ?? false
    }

    private func toggleCapture() {
        guard let chord = AppController.shared?.chord else { return }
        if capturing {
            chord.onCapture = nil
            capturing = false
            return
        }
        // Re-arm before recording — the tap may have failed at launch.
        guard chord.start() else {
            tapRunning = false
            return
        }
        capturing = true
        // `@AppStorage` picks up the new binding written by `saveBinding()`.
        chord.onCapture = { _, _ in capturing = false }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Profiles

private struct ProfilesSettingsView: View {
    @EnvironmentObject var profiles: ProfilesStore
    @State private var expandedPrompts: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(profiles.profiles) { profile in
                        ProfileRow(
                            profile: bindingFor(profile),
                            isPromptExpanded: expandedPrompts.contains(profile.id),
                            onTogglePrompt: { togglePrompt(profile.id) },
                            onDelete: { profiles.remove(id: profile.id) }
                        )
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    profiles.add()
                } label: {
                    Label("Add Profile", systemImage: "plus")
                }
                .padding(12)
            }
        }
    }

    private func togglePrompt(_ id: UUID) {
        if expandedPrompts.contains(id) {
            expandedPrompts.remove(id)
        } else {
            expandedPrompts.insert(id)
        }
    }

    private func bindingFor(_ profile: Profile) -> Binding<Profile> {
        Binding<Profile>(
            get: {
                profiles.profiles.first(where: { $0.id == profile.id }) ?? profile
            },
            set: { newValue in
                profiles.update(newValue)
            }
        )
    }
}

private struct ProfileRow: View {
    @Binding var profile: Profile
    let isPromptExpanded: Bool
    let onTogglePrompt: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row.
            HStack(spacing: 10) {
                Toggle("", isOn: $profile.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()

                TextField("Name", text: $profile.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 12) {
                TextField("Model", text: $profile.modelName)
                    .textFieldStyle(.roundedBorder)
                TextField("Voice", text: $profile.voiceName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
            }

            HStack(spacing: 12) {
                Picker("Output", selection: $profile.output) {
                    ForEach(OutputTarget.allCases) { o in
                        Text(o.displayName).tag(o)
                    }
                }
                .frame(maxWidth: 220)

                Toggle("Web search", isOn: Binding(
                    get: { profile.webSearchEnabled ?? false },
                    set: { profile.webSearchEnabled = $0 }
                ))
                .help("Google Search grounding (~$35 per 1,000 grounded queries)")
            }

            // Prompt collapsible.
            DisclosureGroup(
                isExpanded: Binding(get: { isPromptExpanded }, set: { _ in onTogglePrompt() })
            ) {
                TextEditor(text: $profile.systemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            } label: {
                Text("System prompt")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - About

private struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Echo")
                .font(.system(size: 20, weight: .semibold))
            Text("Voice-first assistant for macOS.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("v1.0.3")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
