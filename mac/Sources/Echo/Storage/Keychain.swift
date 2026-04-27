import Foundation
import KeychainAccess

enum KeychainStore {
    static let service = "com.echo"
    private static let keychain = Keychain(service: service)

    /// In-memory cache of API keys, populated by `preloadAll()` at app launch.
    /// Keychain reads from a cold app can take 1-4s on first hit; caching
    /// removes that latency from the hotkey activation path.
    private static var cache: [ProviderKind: String] = [:]
    private static let cacheLock = NSLock()

    /// Eager load all known provider keys into memory. Call at app launch on a
    /// background queue so the first hotkey press doesn't pay the Keychain
    /// unlock cost.
    static func preloadAll() {
        for provider in ProviderKind.allCases {
            if let v = (try? keychain.get(key(for: provider))) ?? nil, !v.isEmpty {
                cacheLock.lock()
                cache[provider] = v
                cacheLock.unlock()
            }
        }
    }

    private static func key(for provider: ProviderKind) -> String {
        "apiKey.\(provider.rawValue)"
    }

    static func setAPIKey(_ key: String, for provider: ProviderKind) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if k.isEmpty {
                try keychain.remove(self.key(for: provider))
                cacheLock.lock(); cache.removeValue(forKey: provider); cacheLock.unlock()
            } else {
                try keychain.set(k, key: self.key(for: provider))
                cacheLock.lock(); cache[provider] = k; cacheLock.unlock()
            }
        } catch {
            NSLog("Keychain set error: \(error)")
        }
    }

    static func apiKey(for provider: ProviderKind) -> String? {
        cacheLock.lock()
        if let cached = cache[provider] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        do {
            let v = try keychain.get(key(for: provider))
            if let v = v {
                cacheLock.lock(); cache[provider] = v; cacheLock.unlock()
            }
            return v
        } catch {
            NSLog("Keychain get error: \(error)")
            return nil
        }
    }

    static func removeAPIKey(for provider: ProviderKind) {
        do {
            try keychain.remove(key(for: provider))
            cacheLock.lock(); cache.removeValue(forKey: provider); cacheLock.unlock()
        } catch {
            NSLog("Keychain remove error: \(error)")
        }
    }
}
