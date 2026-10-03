import Foundation
import Observation

/// The user's current store, persisted to `UserDefaults` so it survives relaunches.
@MainActor
@Observable
final class StoreSelection {
    static let defaultsKey = "aisle.selectedStore"

    private(set) var current: Store?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.current = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
    }

    func select(_ store: Store) {
        current = store
        if let data = try? JSONEncoder().encode(store) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func clear() {
        current = nil
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
