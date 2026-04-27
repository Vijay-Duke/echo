import Foundation
import Combine
import KeyboardShortcuts

final class ProfilesStore: ObservableObject {
    @Published var profiles: [Profile] = []

    private let defaultsKey = "profiles.v1"
    private let userDefaults: UserDefaults
    private var saveCancellable: AnyCancellable?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
        // Persist on every change.
        saveCancellable = $profiles
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] profiles in
                self?.save(profiles)
            }
    }

    // MARK: - Load / Save

    private func load() {
        guard let data = userDefaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data),
              !decoded.isEmpty
        else {
            profiles = [Profile.defaultGemini()]
            save(profiles)
            seedDefaultHotkeyIfNeeded()
            return
        }
        profiles = decoded
        seedDefaultHotkeyIfNeeded()
    }

    /// On first launch, give the default profile a working hotkey so the user can
    /// invoke the assistant without opening Settings first. ⌃⌥Space — chord includes
    /// Ctrl to satisfy macOS Sequoia's modifier requirement, leaves ⌘Space alone.
    private func seedDefaultHotkeyIfNeeded() {
        guard userDefaults.bool(forKey: "defaultHotkeySeeded.v1") == false else { return }
        guard let p = profiles.first(where: { $0.hotkeyName == "profile-quick" }) else { return }
        let name = KeyboardShortcuts.Name(p.hotkeyName)
        if KeyboardShortcuts.getShortcut(for: name) == nil {
            // Space key is .space; modifiers are NSEvent.ModifierFlags.
            // Backtick (`) — hold to invoke. macOS Sequoia blocks naked
            // backtick, so we pair it with Control to satisfy the modifier
            // requirement while staying out of the way of normal typing.
            KeyboardShortcuts.setShortcut(
                .init(.backtick, modifiers: [.control]),
                for: name
            )
        }
        userDefaults.set(true, forKey: "defaultHotkeySeeded.v1")
    }

    private func save(_ profiles: [Profile]) {
        do {
            let data = try JSONEncoder().encode(profiles)
            userDefaults.set(data, forKey: defaultsKey)
        } catch {
            NSLog("ProfilesStore save error: \(error)")
        }
    }

    // MARK: - Mutations

    func add() {
        var p = Profile.defaultGemini()
        p.id = UUID()
        p.name = "New Profile"
        p.hotkeyName = "profile-\(p.id.uuidString.prefix(8))"
        profiles.append(p)
    }

    func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
    }

    func update(_ profile: Profile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
    }

    func move(from source: IndexSet, to destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
    }

    func profile(for hotkeyName: String) -> Profile? {
        profiles.first { $0.hotkeyName == hotkeyName }
    }

    func binding(for id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }
}
