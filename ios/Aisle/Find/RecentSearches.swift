import Foundation
import Observation

/// Recent item searches, most recent first, stored on the device.
@MainActor
@Observable
final class RecentSearches {
    static let defaultsKey = "aisle.recentSearches"
    static let limit = 8

    static let answersKey = "aisle.recentAnswers"

    private(set) var queries: [String]
    /// Where each recent search pointed, per store, so the home screen can show it.
    private(set) var answers: [String: RecentAnswer]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.queries = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        self.answers = defaults.data(forKey: Self.answersKey)
            .flatMap { try? JSONDecoder().decode([String: RecentAnswer].self, from: $0) } ?? [:]
    }

    /// Records the search and remembers where it pointed in this store.
    func record(_ query: String, result: ItemSearchResult, storeID: String?) {
        record(query)
        guard let storeID, let answer = RecentAnswer(result) else { return }
        answers[Self.answerKey(query, storeID: storeID)] = answer
        let kept = Set(queries.map { $0.lowercased() })
        answers = answers.filter { key, _ in kept.contains(String(key.split(separator: "|", maxSplits: 1).last ?? "")) }
        saveAnswers()
    }

    /// The remembered answer for a recent search at this store, if any.
    func answer(for query: String, storeID: String?) -> RecentAnswer? {
        guard let storeID else { return nil }
        return answers[Self.answerKey(query, storeID: storeID)]
    }

    private static func answerKey(_ query: String, storeID: String) -> String {
        "\(storeID)|\(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func saveAnswers() {
        if let data = try? JSONEncoder().encode(answers) {
            defaults.set(data, forKey: Self.answersKey)
        }
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
        let lowered = query.lowercased()
        answers = answers.filter { key, _ in !key.hasSuffix("|\(lowered)") }
        saveAnswers()
    }

    func clear() {
        queries.removeAll()
        answers.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.answersKey)
    }
}

/// The short "where it was" for a recent search: "Aisle 12" + "Pantry · Rice".
struct RecentAnswer: Codable, Equatable {
    let place: String
    let detail: String?
    let confidence: Confidence

    /// Nil when the result had no real place in the store.
    init?(_ result: ItemSearchResult) {
        guard let department = result.placeInStore else { return nil }
        if let aisle = result.aisleLabel {
            place = aisle
            detail = [department, result.sectionLabel].compactMap { $0 }.joined(separator: " · ")
        } else {
            place = department
            detail = result.category?.name
        }
        confidence = result.confidence
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
