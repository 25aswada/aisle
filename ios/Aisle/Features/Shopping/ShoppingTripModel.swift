import Foundation
import Observation

/// Start Shopping mode: walks the route stop by stop with Found / Skip per item.
@MainActor
@Observable
final class ShoppingTripModel {
    enum Phase: Equatable {
        case loading
        case failed(String)
        case shopping
    }

    enum ItemStatus: Equatable {
        case pending, found, skipped
    }

    private(set) var phase: Phase = .loading
    private(set) var stops: [RouteStop] = []
    private(set) var unplaced: [UnplacedItem] = []
    private(set) var status: [String: ItemStatus] = [:]
    /// True when the trip uses list order because the route couldn't be planned.
    private(set) var isUnrouted = false
    /// The store's floor plan for the route map; nil until loaded or if unavailable.
    private(set) var layout: StoreLayout?

    @ObservationIgnored private let api: AisleAPI
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let list: ShoppingListStore
    @ObservationIgnored private var items: [ListItem] = []
    @ObservationIgnored private let analytics: AnalyticsTracking
    @ObservationIgnored private var reportedFinish = false

    init(api: AisleAPI, store: Store, list: ShoppingListStore, analytics: AnalyticsTracking? = nil) {
        self.api = api
        self.store = store
        self.list = list
        self.analytics = analytics ?? NoopAnalytics()
    }

    var storeName: String { store.name }
    var retailerName: String { store.retailerDisplayName }

    // MARK: Progress

    var allItemIDs: [String] {
        stops.flatMap { $0.items.map(\.id) } + unplaced.map(\.id)
    }

    var totalCount: Int { allItemIDs.count }
    var foundCount: Int { allItemIDs.filter { status[$0] == .found }.count }
    var skippedCount: Int { allItemIDs.filter { status[$0] == .skipped }.count }
    var progress: Double {
        totalCount == 0 ? 0 : Double(foundCount + skippedCount) / Double(totalCount)
    }

    func status(of id: String) -> ItemStatus { status[id] ?? .pending }

    func pendingItems(in stop: RouteStop) -> [RouteStopItem] {
        stop.items.filter { status(of: $0.id) == .pending }
    }

    /// The first stop that still has items to look for.
    var currentStopIndex: Int? {
        stops.firstIndex { !pendingItems(in: $0).isEmpty }
    }

    var upcomingStops: [RouteStop] {
        guard let current = currentStopIndex else { return [] }
        return stops[(current + 1)...].filter { !pendingItems(in: $0).isEmpty }
    }

    var pendingUnplaced: [UnplacedItem] {
        unplaced.filter { status(of: $0.id) == .pending }
    }

    var skippedTexts: [String] {
        let texts = Dictionary(
            uniqueKeysWithValues: stops.flatMap { $0.items.map { ($0.id, $0.text) } } + unplaced.map { ($0.id, $0.text) }
        )
        return allItemIDs.filter { status[$0] == .skipped }.compactMap { texts[$0] }
    }

    var isFinished: Bool {
        phase == .shopping && allItemIDs.allSatisfy { status(of: $0) != .pending }
    }

    // MARK: Actions

    func start() async {
        items = list.remaining
        guard !items.isEmpty else {
            phase = .failed("Your list has no items left to find.")
            return
        }
        phase = .loading
        do {
            let plan = try await api.planRoute(storeID: store.id, items: items)
            stops = plan.stops
            unplaced = plan.unplaced
            isUnrouted = false
            phase = .shopping
            trackStart()
            // The map is a nice-to-have: load it after the route, and ignore failures.
            layout = try? await api.storeLayout(storeID: store.id)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't plan a route.")
        }
    }

    /// Fallback when the server is unreachable: one stop with the list in its own order.
    func shopWithoutRoute() {
        items = list.remaining
        stops = [RouteStop(
            order: 1, zoneID: nil, department: "Your list", x: nil, y: nil,
            items: items.map {
                RouteStopItem(id: $0.id.uuidString, text: $0.text, aisle: nil, section: nil,
                              neighbors: [], confidence: .low, source: .fallback)
            }
        )]
        unplaced = []
        isUnrouted = true
        phase = .shopping
        trackStart()
    }

    private func trackStart() {
        analytics.track(.shoppingStarted, [
            "items": .int(totalCount), "stops": .int(stops.count), "unrouted": .bool(isUnrouted),
        ])
    }

    private func trackFinishIfNeeded() {
        guard isFinished, !reportedFinish else { return }
        reportedFinish = true
        analytics.track(.shoppingFinished, [
            "found": .int(foundCount), "skipped": .int(skippedCount), "total": .int(totalCount),
        ])
    }

    func markFound(_ id: String) {
        status[id] = .found
        if let uuid = UUID(uuidString: id) {
            list.setDone(uuid, true)
        }
        reportFound(id)
        analytics.track(.shoppingItemFound)
        trackFinishIfNeeded()
    }

    func skip(_ id: String) {
        status[id] = .skipped
        analytics.track(.shoppingItemSkipped)
        trackFinishIfNeeded()
    }

    func undo(_ id: String) {
        if status[id] == .found, let uuid = UUID(uuidString: id) {
            list.setDone(uuid, false)
        }
        status[id] = .pending
    }

    func retrySkipped() {
        for (id, value) in status where value == .skipped {
            status[id] = .pending
        }
        reportedFinish = false
    }

    /// Finding an item at a routed stop confirms that zone for other shoppers.
    private func reportFound(_ id: String) {
        guard !isUnrouted, let storeID = Int(store.id),
              let stop = stops.first(where: { $0.items.contains { $0.id == id } }),
              let zoneID = stop.zoneID,
              let item = stop.items.first(where: { $0.id == id }) else { return }
        let body = FeedbackBody(storeID: storeID, item: item.text, verdict: .found, zoneID: zoneID)
        Task { [api] in _ = try? await api.sendFeedback(body) }
    }
}
