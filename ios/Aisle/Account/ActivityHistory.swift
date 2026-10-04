import Foundation
import Observation

/// On-phone history behind the "more" screens: every search, finished trips, and the
/// spots the shopper confirmed. Each is a small JSON file in Application Support.
private enum HistoryFile {
    static func url(_ name: String) -> URL? {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("History", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let url = url(name), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func remove(_ name: String) {
        if let url = url(name) { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Searches

@MainActor
@Observable
final class SearchHistory {
    static let shared = SearchHistory()
    static let limit = 500

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let query: String
        let item: String
        let storeID: String
        let storeName: String
        let logoURL: URL?
        let place: String?
        let detail: String?
        let confidence: Confidence
        let isPhoto: Bool
        let date: Date
    }

    private(set) var entries: [Entry]

    private init() {
        entries = HistoryFile.load("searches.json", as: [Entry].self) ?? []
    }

    func record(_ result: ItemSearchResult, query: String, store: Store, isPhoto: Bool) {
        let place = result.aisleLabel ?? result.placeInStore
        let detail = result.aisleLabel != nil ? result.placeInStore : result.category?.name
        let shown = query.isEmpty ? result.item : query
        // Don't stack the same search twice in a row (e.g. a cached repeat).
        if let last = entries.first, last.query.caseInsensitiveCompare(shown) == .orderedSame,
           last.storeID == store.id, Date().timeIntervalSince(last.date) < 60 { return }
        entries.insert(Entry(
            query: shown, item: result.item, storeID: store.id, storeName: store.name,
            logoURL: store.retailerLogoURL, place: place, detail: detail,
            confidence: result.confidence, isPhoto: isPhoto, date: .now
        ), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        HistoryFile.save(entries, to: "searches.json")
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        HistoryFile.save(entries, to: "searches.json")
    }

    func clear() {
        entries.removeAll()
        HistoryFile.remove("searches.json")
    }
}

// MARK: - Trips

@MainActor
@Observable
final class TripHistory {
    static let shared = TripHistory()

    struct Item: Codable, Equatable {
        let text: String
        let found: Bool
    }

    struct Trip: Codable, Identifiable, Equatable {
        var id = UUID()
        let listName: String
        let storeNames: [String]
        let logoURLs: [URL?]
        let items: [Item]
        let startedAt: Date
        let endedAt: Date

        var foundCount: Int { items.filter(\.found).count }
        var minutes: Int { max(1, Int(endedAt.timeIntervalSince(startedAt) / 60)) }
    }

    private(set) var trips: [Trip]

    private init() {
        trips = HistoryFile.load("trips.json", as: [Trip].self) ?? []
    }

    func record(_ trip: Trip) {
        trips.insert(trip, at: 0)
        if trips.count > 200 { trips.removeLast(trips.count - 200) }
        HistoryFile.save(trips, to: "trips.json")
    }

    func remove(_ id: UUID) {
        trips.removeAll { $0.id == id }
        HistoryFile.save(trips, to: "trips.json")
    }

    func clear() {
        trips.removeAll()
        HistoryFile.remove("trips.json")
    }
}

// MARK: - Contributions

@MainActor
@Observable
final class ContributionLog {
    static let shared = ContributionLog()

    enum Kind: String, Codable { case found, notHere, corrected }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let item: String
        let storeName: String
        let logoURL: URL?
        let kind: Kind
        let place: String?
        let date: Date
    }

    /// Milestones for the progress strip.
    static let milestones: [(count: Int, title: String)] = [(1, "First spot"), (10, "Helper"), (25, "Regular"), (50, "Aisle expert")]

    private(set) var entries: [Entry]

    private init() {
        entries = HistoryFile.load("contributions.json", as: [Entry].self) ?? []
    }

    /// Spots confirmed or corrected (a "Not here" doesn't count toward milestones).
    var confirmedCount: Int { entries.filter { $0.kind != .notHere }.count }

    func record(item: String, store: Store, kind: Kind, place: String?) {
        entries.insert(Entry(item: item, storeName: store.name, logoURL: store.retailerLogoURL,
                             kind: kind, place: place, date: .now), at: 0)
        HistoryFile.save(entries, to: "contributions.json")
    }

    func clear() {
        entries.removeAll()
        HistoryFile.remove("contributions.json")
    }
}

// MARK: - Rating prompt

/// When to show Apple's own rating prompt: only right after a "Found it", at a few
/// milestones, and never more than once every four months. Apple also caps it.
enum ReviewPrompter {
    static let lastAskedKey = "aisle.review.lastAsked"
    private static let thresholds: Set<Int> = [3, 15, 40]

    /// Aisle's App Store ID (App Store Connect → App Information → Apple ID). Until it's set,
    /// the "Rate Aisle" row stays hidden, since a button that might do nothing is worse than none.
    static let appStoreID: String? = nil

    static var writeReviewURL: URL? {
        appStoreID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)?action=write-review") }
    }

    static func shouldAsk(afterConfirmations count: Int, defaults: UserDefaults = .standard) -> Bool {
        guard thresholds.contains(count) else { return false }
        let last = defaults.double(forKey: lastAskedKey)
        guard last == 0 || Date().timeIntervalSince1970 - last > 120 * 86_400 else { return false }
        defaults.set(Date().timeIntervalSince1970, forKey: lastAskedKey)
        return true
    }
}
