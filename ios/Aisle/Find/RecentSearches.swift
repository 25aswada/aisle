import Foundation
import Observation

/// Recent item searches, most recent first, stored on the device.
@MainActor
@Observable
final class RecentSearches {
    static let defaultsKey = "aisle.recentSearches"
    static let limit = 8

    private(set) var queries: [String]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.queries = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        queries.insert(trimmed, at: 0)
        if queries.count > Self.limit {
            queries.removeLast(queries.count - Self.limit)
        }
        defaults.set(queries, forKey: Self.defaultsKey)
    }

    func remove(_ query: String) {
        queries.removeAll { $0 == query }
        defaults.set(queries, forKey: Self.defaultsKey)
    }

    func clear() {
        queries.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// Short-lived cache of search results so repeat searches feel instant and work
/// briefly offline. Entries for an item are dropped when feedback is sent for it.
@MainActor
final class SearchCache {
    private struct Entry {
        let result: ItemSearchResult
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let now: () -> Date

    init(ttl: TimeInterval = 300, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    static func key(query: String, storeID: String?) -> String {
        "\(storeID ?? "-")|\(query.lowercased().split(separator: " ").joined(separator: " "))"
    }

    func result(query: String, storeID: String?) -> ItemSearchResult? {
        let key = Self.key(query: query, storeID: storeID)
        guard let entry = entries[key] else { return nil }
        guard now().timeIntervalSince(entry.storedAt) < ttl else {
            entries[key] = nil
            return nil
        }
        return entry.result
    }

    func store(_ result: ItemSearchResult, query: String, storeID: String?) {
        entries[Self.key(query: query, storeID: storeID)] = Entry(result: result, storedAt: now())
    }

    func invalidate(item: String, storeID: String?) {
        let prefix = "\(storeID ?? "-")|"
        entries = entries.filter { key, entry in
            !(key.hasPrefix(prefix) && entry.result.item.caseInsensitiveCompare(item) == .orderedSame)
        }
    }
}
