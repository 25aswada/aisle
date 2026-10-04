import Foundation
import Observation

/// One store's part of a trip. A single-store trip has one leg.
struct TripLeg: Equatable {
    let store: Store
    var stops: [RouteStop]
    var unplaced: [UnplacedItem]
    /// The store's floor plan for the route map; nil until loaded or if unavailable.
    var layout: StoreLayout?
}

/// Start Shopping mode: walks the route stop by stop with Found / Skip per item. A
/// multi-store trip (Aisle+) finishes one store, then moves on to the next.
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
    private(set) var legs: [TripLeg]
    /// The store being shopped now.
    private(set) var legIndex = 0
    /// Items none of the trip's stores is likely to carry (multi-store trips).
    private(set) var nowhere: [UnplacedItem] = []
    private(set) var status: [String: ItemStatus] = [:]
    /// True when the trip uses list order because the route couldn't be planned.
    private(set) var isUnrouted = false

    @ObservationIgnored private let api: AisleAPI
    @ObservationIgnored private let stores: [Store]
    @ObservationIgnored private let list: ShoppingListStore
    @ObservationIgnored private var items: [ListItem] = []
    @ObservationIgnored private let analytics: AnalyticsTracking
    @ObservationIgnored private var reportedFinish = false

    convenience init(api: AisleAPI, store: Store, list: ShoppingListStore, analytics: AnalyticsTracking? = nil) {
        self.init(api: api, stores: [store], list: list, analytics: analytics)
    }

    /// `stores` in visiting order; more than one plans a multi-store trip (Aisle+).
    init(api: AisleAPI, stores: [Store], list: ShoppingListStore, analytics: AnalyticsTracking? = nil) {
        precondition(!stores.isEmpty, "A trip needs a store")
        self.api = api
        self.stores = stores
        self.list = list
        self.analytics = analytics ?? NoopAnalytics()
        self.legs = [TripLeg(store: stores[0], stops: [], unplaced: [])]
    }

    var isMultiStore: Bool { stores.count > 1 }

    private var leg: TripLeg { legs[legIndex] }
    var store: Store { leg.store }
    var storeName: String { leg.store.name }
    var retailerName: String { leg.store.retailerDisplayName }
    var stops: [RouteStop] { leg.stops }
    /// This store's unplaced items; on the last store, also the ones no store carries.
    var unplaced: [UnplacedItem] { leg.unplaced + (legIndex == legs.count - 1 ? nowhere : []) }
    var layout: StoreLayout? { leg.layout }

    /// The next store with something left to find, once this one is done.
    var nextLeg: TripLeg? {
        guard isCurrentLegDone else { return nil }
        return legs[(legIndex + 1)...].first { !pendingIDs(in: $0).isEmpty }
    }

    var isCurrentLegDone: Bool {
        phase == .shopping && (leg.stops.flatMap { $0.items.map(\.id) } + unplaced.map(\.id))
            .allSatisfy { status(of: $0) != .pending }
    }

    func isNowhere(_ id: String) -> Bool { nowhere.contains { $0.id == id } }

    // MARK: Progress

    var allItemIDs: [String] {
        legs.flatMap { $0.stops.flatMap { $0.items.map(\.id) } + $0.unplaced.map(\.id) } + nowhere.map(\.id)
    }

    private func pendingIDs(in leg: TripLeg) -> [String] {
        (leg.stops.flatMap { $0.items.map(\.id) } + leg.unplaced.map(\.id)).filter { status(of: $0) == .pending }
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
        let pairs = legs.flatMap { leg in
            leg.stops.flatMap { $0.items.map { ($0.id, $0.text) } } + leg.unplaced.map { ($0.id, $0.text) }
        } + nowhere.map { ($0.id, $0.text) }
        let texts = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
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
            if isMultiStore {
                let plan = try await api.planMultiRoute(storeIDs: stores.map(\.id), items: items)
                let byID = Dictionary(stores.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let planned = plan.legs.compactMap { leg in
                    byID[String(leg.storeID)].map { TripLeg(store: $0, stops: leg.stops, unplaced: leg.unplaced) }
                }
                // Nothing matched any store: keep the first so there's somewhere to stand.
                legs = planned.isEmpty ? [TripLeg(store: stores[0], stops: [], unplaced: [])] : planned
                nowhere = plan.unplaced
            } else {
                let plan = try await api.planRoute(storeID: stores[0].id, items: items)
                legs = [TripLeg(store: stores[0], stops: plan.stops, unplaced: plan.unplaced)]
                nowhere = []
            }
            legIndex = 0
            isUnrouted = false
            phase = .shopping
            trackStart()
            await loadLayout()
        } catch is CancellationError {
            return
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Couldn't plan a route.")
        }
    }

    /// The map is a nice-to-have: load it after the route, and ignore failures.
    private func loadLayout() async {
        guard legs[legIndex].layout == nil else { return }
        let index = legIndex
        let layout = try? await api.storeLayout(storeID: legs[index].store.id)
        if index < legs.count { legs[index].layout = layout }
    }

    /// Done at this store: on to the next one in the trip.
    func goToNextStore() async {
        guard let next = nextLeg, let index = legs.firstIndex(of: next) else { return }
        legIndex = index
        analytics.track(.shoppingStarted, [
            "items": .int(pendingIDs(in: next).count), "stops": .int(next.stops.count), "next_store": .bool(true),
        ])
        await loadLayout()
    }

    /// Fallback when the server is unreachable: one stop with the list in its own order.
    func shopWithoutRoute() {
        items = list.remaining
        let stops = [RouteStop(
            order: 1, zoneID: nil, department: "Your list", x: nil, y: nil,
            items: items.map {
                RouteStopItem(id: $0.id.uuidString, text: $0.text, aisle: nil, section: nil,
                              neighbors: [], confidence: .low, source: .fallback)
            }
        )]
        legs = [TripLeg(store: stores[0], stops: stops, unplaced: [], layout: nil)]
        legIndex = 0
        nowhere = []
        isUnrouted = true
        phase = .shopping
        trackStart()
    }

    private func trackStart() {
        analytics.track(.shoppingStarted, [
            "items": .int(totalCount), "stops": .int(legs.reduce(0) { $0 + $1.stops.count }),
            "unrouted": .bool(isUnrouted), "stores": .int(legs.count),
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
        // Back to the first store with something to look for.
        legIndex = legs.firstIndex { !pendingIDs(in: $0).isEmpty } ?? legIndex
    }

    /// Finding an item at a routed stop confirms that zone for other shoppers.
    private func reportFound(_ id: String) {
        guard !isUnrouted,
              let leg = legs.first(where: { $0.stops.contains { $0.items.contains { $0.id == id } } }),
              let storeID = Int(leg.store.id),
              let stop = leg.stops.first(where: { $0.items.contains { $0.id == id } }),
              let zoneID = stop.zoneID,
              let item = stop.items.first(where: { $0.id == id }) else { return }
        let body = FeedbackBody(storeID: storeID, item: item.text, verdict: .found, zoneID: zoneID)
        Task { [api] in _ = try? await api.sendFeedback(body) }
    }
}
