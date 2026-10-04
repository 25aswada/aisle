import Foundation
import SwiftUI

/// Aisle+ offline store maps. While Aisle+ is on, every store map, item spot and answer
/// the app gets is also saved on the phone, so with no signal in the store the map
/// still shows, past searches still answer, and Start Shopping still plans a route.
final class OfflineMaps: @unchecked Sendable {
    /// What's saved for one store.
    struct SavedStore: Codable, Equatable {
        var storeID: String
        var layout: StoreLayout?
        /// Where items are, by normalized item text.
        var spots: [String: Spot] = [:]
        /// Search answers, by normalized query.
        var answers: [String: ItemSearchResult] = [:]
        var updatedAt: Date = .now
    }

    struct Spot: Codable, Equatable {
        let department: String
        let zoneID: Int?
        let x: Double?
        let y: Double?
        let aisle: String?
        let section: String?
        let neighbors: [String]
    }

    static let maxAnswersPerStore = 200
    static let maxSpotsPerStore = 1_000

    private let directory: URL
    private let lock = NSLock()
    private var stores: [String: SavedStore] = [:]
    private var loaded = false
    private var enabled = false

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineMaps", isDirectory: true)
    }

    /// On while the shopper has Aisle+. Off, nothing is saved or served (saved maps stay
    /// on the phone in case Aisle+ comes back).
    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    // MARK: Reading

    func layout(storeID: String) -> StoreLayout? {
        withStores { $0[storeID]?.layout }
    }

    func answer(query: String, storeID: String) -> ItemSearchResult? {
        withStores { $0[storeID]?.answers[Self.key(query)] }
    }

    func spot(for text: String, storeID: String) -> Spot? {
        withStores { $0[storeID]?.spots[Self.key(text)] }
    }

    /// Stores with a saved map, newest first.
    var savedStoreIDs: [String] {
        withStores { stores in
            stores.values.filter { $0.layout != nil }.sorted { $0.updatedAt > $1.updatedAt }.map(\.storeID)
        }
    }

    // MARK: Saving

    func save(layout: StoreLayout, storeID: String) {
        update(storeID) { $0.layout = layout }
    }

    func save(answer: ItemSearchResult, storeID: String) {
        update(storeID) { saved in
            saved.answers[Self.key(answer.query)] = answer
            if saved.answers.count > Self.maxAnswersPerStore, let any = saved.answers.keys.first(where: { $0 != Self.key(answer.query) }) {
                saved.answers[any] = nil
            }
            if let department = answer.location.department {
                let zone = saved.layout?.zones.first { $0.id == answer.location.zoneID }
                saved.spots[Self.key(answer.item)] = Spot(
                    department: department, zoneID: answer.location.zoneID, x: zone?.x, y: zone?.y,
                    aisle: answer.location.aisle, section: answer.location.section, neighbors: answer.location.neighbors
                )
            }
        }
    }

    func save(route: RoutePlan, storeID: String) {
        update(storeID) { saved in
            for stop in route.stops {
                for item in stop.items where saved.spots.count < Self.maxSpotsPerStore || saved.spots[Self.key(item.text)] != nil {
                    saved.spots[Self.key(item.text)] = Spot(
                        department: stop.department, zoneID: stop.zoneID, x: stop.x, y: stop.y,
                        aisle: item.aisle, section: item.section, neighbors: item.neighbors
                    )
                }
            }
        }
    }

    /// Deletes every saved map from the phone.
    func removeAll() {
        lock.withLock {
            stores = [:]
            loaded = true
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Planning without the server

    /// A route from the spots saved on this phone: items grouped by their saved spot and
    /// walked nearest-first from the entrance; anything never seen here is unplaced.
    func offlineRoute(storeID: String, items: [ListItem]) -> RoutePlan? {
        guard let saved = withStores({ $0[storeID] }), saved.layout != nil || !saved.spots.isEmpty else { return nil }
        var stops: [String: (spot: Spot, items: [RouteStopItem])] = [:]
        var order: [String] = []
        var unplaced: [UnplacedItem] = []
        for item in items {
            guard let spot = saved.spots[Self.key(item.text)] else {
                unplaced.append(UnplacedItem(id: item.id.uuidString, text: item.text, reason: .unknown))
                continue
            }
            let key = spot.zoneID.map { "zone-\($0)" } ?? "department-\(spot.department)"
            if stops[key] == nil { order.append(key) }
            stops[key, default: (spot, [])].items.append(RouteStopItem(
                id: item.id.uuidString, text: item.text, aisle: spot.aisle, section: spot.section,
                neighbors: spot.neighbors, confidence: .medium, source: .fallback
            ))
        }
        let start = saved.layout?.entrance.map { ($0.x, $0.y) } ?? (0.5, 0)
        let walked = Self.nearestFirst(order.map { key in
            (key, stops[key]!.spot.x.flatMap { x in stops[key]!.spot.y.map { (x, $0) } })
        }, from: start)
        let routeStops = walked.enumerated().map { index, key in
            let stop = stops[key]!
            return RouteStop(order: index + 1, zoneID: stop.spot.zoneID, department: stop.spot.department,
                             x: stop.spot.x, y: stop.spot.y, items: stop.items)
        }
        var plan = RoutePlan(storeID: Int(storeID) ?? 0, stops: routeStops, unplaced: unplaced, distance: 0)
        plan.isOffline = true
        return plan
    }

    /// Keys with a position walked nearest-neighbor (Manhattan, like the server); the rest last.
    static func nearestFirst(_ points: [(String, (Double, Double)?)], from start: (Double, Double)) -> [String] {
        var remaining = points.compactMap { key, point in point.map { (key, $0) } }
        var here = start
        var walked: [String] = []
        while !remaining.isEmpty {
            let next = remaining.indices.min { a, b in
                distance(here, remaining[a].1) < distance(here, remaining[b].1)
            }!
            walked.append(remaining[next].0)
            here = remaining[next].1
            remaining.remove(at: next)
        }
        return walked + points.filter { $0.1 == nil }.map(\.0)
    }

    private static func distance(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        abs(a.0 - b.0) + abs(a.1 - b.1)
    }

    static func key(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Storage

    private func withStores<T>(_ body: ([String: SavedStore]) -> T) -> T {
        lock.withLock {
            loadIfNeeded()
            return body(enabled ? stores : [:])
        }
    }

    private func update(_ storeID: String, _ change: (inout SavedStore) -> Void) {
        lock.withLock {
            guard enabled else { return }
            loadIfNeeded()
            var saved = stores[storeID] ?? SavedStore(storeID: storeID)
            change(&saved)
            saved.updatedAt = .now
            stores[storeID] = saved
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(saved) {
                try? data.write(to: file(for: storeID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SavedStore.self, from: data) {
                stores[saved.storeID] = saved
            }
        }
    }

    private func file(for storeID: String) -> URL {
        let safe = storeID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("store-\(safe).json")
    }

    /// Errors that mean "no connection", where saved maps should step in.
    static func isConnectivity(_ error: Error) -> Bool {
        switch error as? APIError {
        case .offline, .timeout, .transport: return true
        case .httpStatus(let code): return code >= 500
        default: return false
        }
    }
}

/// The app's API with offline maps in front: saves what Aisle+ fetches, and answers from
/// what's saved when the server can't be reached.
struct OfflineAwareAPI: AisleAPI {
    let base: AisleAPI
    let maps: OfflineMaps

    func storeLayout(storeID: String) async throws -> StoreLayout {
        do {
            let layout = try await base.storeLayout(storeID: storeID)
            maps.save(layout: layout, storeID: storeID)
            return layout
        } catch where OfflineMaps.isConnectivity(error) {
            guard let saved = maps.layout(storeID: storeID) else { throw error }
            return saved
        }
    }

    func searchItem(query: String, storeID: String?) async throws -> ItemSearchResult {
        do {
            let result = try await base.searchItem(query: query, storeID: storeID)
            if let storeID { maps.save(answer: result, storeID: storeID) }
            return result
        } catch where OfflineMaps.isConnectivity(error) {
            guard let storeID, let saved = maps.answer(query: query, storeID: storeID) else { throw error }
            return saved
        }
    }

    func planRoute(storeID: String, items: [ListItem]) async throws -> RoutePlan {
        do {
            let plan = try await base.planRoute(storeID: storeID, items: items)
            maps.save(route: plan, storeID: storeID)
            return plan
        } catch where OfflineMaps.isConnectivity(error) {
            guard let saved = maps.offlineRoute(storeID: storeID, items: items) else { throw error }
            return saved
        }
    }

    func planMultiRoute(storeIDs: [String], items: [ListItem]) async throws -> MultiRoutePlan {
        do {
            let plan = try await base.planMultiRoute(storeIDs: storeIDs, items: items)
            for leg in plan.legs {
                maps.save(route: RoutePlan(storeID: leg.storeID, stops: leg.stops, unplaced: leg.unplaced,
                                           distance: leg.distance), storeID: String(leg.storeID))
            }
            return plan
        } catch where OfflineMaps.isConnectivity(error) {
            // Each item to the first store where it's been seen before.
            var byStore: [String: [ListItem]] = [:]
            var nowhere: [UnplacedItem] = []
            for item in items {
                if let storeID = storeIDs.first(where: { maps.spot(for: item.text, storeID: $0) != nil }) {
                    byStore[storeID, default: []].append(item)
                } else {
                    nowhere.append(UnplacedItem(id: item.id.uuidString, text: item.text, reason: .unknown))
                }
            }
            let legs = storeIDs.compactMap { storeID -> MultiRoutePlan.Leg? in
                guard let assigned = byStore[storeID], let plan = maps.offlineRoute(storeID: storeID, items: assigned)
                else { return nil }
                return .init(storeID: Int(storeID) ?? 0, storeName: "", retailerName: "", stops: plan.stops,
                             unplaced: plan.unplaced, distance: plan.distance)
            }
            guard !legs.isEmpty else { throw error }
            var plan = MultiRoutePlan(legs: legs, unplaced: nowhere)
            plan.isOffline = true
            return plan
        }
    }

    // Everything else goes straight to the server.
    func health() async throws -> HealthResponse { try await base.health() }
    func nearbyStores(latitude: Double, longitude: Double, limit: Int?) async throws -> [Store] {
        try await base.nearbyStores(latitude: latitude, longitude: longitude, limit: limit)
    }
    func searchStores(query: String, near: Coordinate?) async throws -> [Store] {
        try await base.searchStores(query: query, near: near)
    }
    func store(id: String) async throws -> Store { try await base.store(id: id) }
    func chat(storeID: String, messages: [ChatMessage]) async throws -> ChatReply {
        try await base.chat(storeID: storeID, messages: messages)
    }
    func identify(photo: Data, note: String?, storeID: String?) async throws -> String? {
        try await base.identify(photo: photo, note: note, storeID: storeID)
    }
    func zones(storeID: String) async throws -> [StoreZone] { try await base.zones(storeID: storeID) }
    func sendFeedback(_ body: FeedbackBody) async throws -> FeedbackReceipt { try await base.sendFeedback(body) }
    func parseList(text: String) async throws -> [ParsedListItem] { try await base.parseList(text: text) }
    func scanList(photo: Data) async throws -> [ParsedListItem] { try await base.scanList(photo: photo) }
    func sendEvents(_ events: [AnalyticsEvent]) async throws { try await base.sendEvents(events) }
}

extension EnvironmentValues {
    /// The app's saved offline maps; nil in previews and tests.
    @Entry var offlineMaps: OfflineMaps?
}
