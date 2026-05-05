import SwiftUI
import KeyboardShortcuts

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

                ChordBindingView()

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

                Toggle("Inject clipboard", isOn: $profile.injectClipboard)

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

// MARK: - Chord binding

private struct ChordBindingView: View {
    @State private var label: String = ChordBindingView.formatBinding()
    @State private var capturing: Bool = false

    static func formatBinding() -> String {
        let mods = UserDefaults.standard.integer(forKey: "chord.modifier.v1")
        let kc = UserDefaults.standard.integer(forKey: "chord.keyCode.v1")
        let modMask: UInt64 = mods == 0 ? CGEventFlags.maskAlternate.rawValue : UInt64(mods)
        let keyCode = kc == 0 ? 50 : kc
        var parts: [String] = []
        if modMask & CGEventFlags.maskControl.rawValue   != 0 { parts.append("⌃") }
        if modMask & CGEventFlags.maskAlternate.rawValue != 0 { parts.append("⌥") }
        if modMask & CGEventFlags.maskShift.rawValue     != 0 { parts.append("⇧") }
        if modMask & CGEventFlags.maskCommand.rawValue   != 0 { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    static func keyCodeToString(_ kc: Int) -> String {
        switch kc {
        case 50: return "`"
        case 49: return "Space"
        case 36: return "Return"
        case 53: return "Esc"
        case 48: return "Tab"
        default: return "Key#\(kc)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hotkey").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(capturing ? "Press chord…" : label)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(capturing ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1))
                Button(capturing ? "Cancel" : "Record") {
                    if capturing {
                        AppController.shared?.chord.onCapture = nil
                        capturing = false
                    } else {
                        capturing = true
                        AppController.shared?.chord.onCapture = { _, _ in
                            label = ChordBindingView.formatBinding()
                            capturing = false
                        }
                    }
                }
            }
            Text("hold full chord to talk · release trigger to send · release modifier to hibernate")
                .font(.caption2).foregroundStyle(.secondary)
        }
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
            Text("v0.1.0")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
