import Foundation
import Combine

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
            return
        }
        profiles = decoded
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

    func binding(for id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }
}
