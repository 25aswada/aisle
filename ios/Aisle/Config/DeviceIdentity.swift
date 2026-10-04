import Foundation

/// A random install identifier, not tied to the device hardware. The server uses it to
/// count repeat reports once and to key anonymous searches and events. A new one is made
/// on every sign-out and account deletion, so what happens on this phone afterwards can't
/// be linked back to the previous account.
enum DeviceIdentity {
    static let defaultsKey = "aisle.deviceID"

    /// Starts over with a new identifier.
    static func rotate(defaults: UserDefaults = .standard) {
        defaults.set(UUID().uuidString.lowercased(), forKey: defaultsKey)
    }

    static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }
}
