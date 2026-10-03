import Foundation

/// A random, anonymous install identifier. It is not tied to an account or the
/// device hardware; the server uses it only to count repeat reports once.
enum DeviceIdentity {
    static let defaultsKey = "aisle.deviceID"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }
}
