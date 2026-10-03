import Foundation
import Observation

/// Drives item search on the Find screen.
@MainActor
@Observable
final class FindModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(ItemSearchResult)
        case failed(String)
    }

    enum FeedbackState: Equatable {
        case none
        case sending
        /// The shopper confirmed the suggested location.
        case confirmed
        /// The shopper said "Not here"; offer to tell us where it was.
        case reportedMissing
        /// A correction with the real location was saved.
        case corrected(String)
        case failed(String)
    }

    var query = ""
    private(set) var phase: Phase = .idle
    private(set) var feedback: FeedbackState = .none

    @ObservationIgnored private let api: AisleAPI
    @ObservationIgnored private let analytics: AnalyticsTracking
    @ObservationIgnored let recents: RecentSearches
    @ObservationIgnored private let cache: SearchCache

    init(
        api: AisleAPI,
        analytics: AnalyticsTracking? = nil,
        recents: RecentSearches? = nil,
        cache: SearchCache? = nil
    ) {
        self.api = api
        self.analytics = analytics ?? NoopAnalytics()
        self.recents = recents ?? RecentSearches(defaults: UserDefaults(suiteName: "aisle.ephemeral") ?? .standard)
        self.cache = cache ?? SearchCache()
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(storeID: String?) async {
        let text = trimmedQuery
        guard !text.isEmpty else {
            phase = .idle
            return
        }
        feedback = .none
        if let cached = cache.result(query: text, storeID: storeID) {
            phase = .loaded(cached)
            recents.record(text)
            trackResult(cached, storeID: storeID, cached: true)
            return
        }
        phase = .loading
        do {
            let result = try await api.searchItem(query: text, storeID: storeID)
            try Task.checkCancellation()
            cache.store(result, query: text, storeID: storeID)
            recents.record(text)
            phase = .loaded(result)
            trackResult(result, storeID: storeID, cached: false)
        } catch is CancellationError {
            // A newer search replaced this one.
        } catch APIError.httpStatus(404) {
            phase = .failed("This store is no longer available. Choose another store.")
            analytics.track(.searchFailed, ["error": "store_not_found"])
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong.")
            analytics.track(.searchFailed, ["error": .string((error as? APIError)?.kind ?? "unknown")])
        }
    }

    /// Runs a recent search again.
    func searchRecent(_ query: String, storeID: String?) async {
        self.query = query
        analytics.track(.recentSearchTapped)
        await search(storeID: storeID)
    }

    private func trackResult(_ result: ItemSearchResult, storeID: String?, cached: Bool) {
        analytics.track(.searchSubmitted, [
            "source": .string(result.source.rawValue),
            "confidence": .string(result.confidence.rawValue),
            "has_store": .bool(storeID != nil),
            "has_aisle": .bool(result.location.aisle != nil),
            "cached": .bool(cached),
        ])
    }

    func clear() {
        query = ""
        phase = .idle
        feedback = .none
    }

    // MARK: - Feedback

    var currentResult: ItemSearchResult? {
        if case .loaded(let result) = phase { return result }
        return nil
    }

    /// "Found it": confirms the suggested zone.
    func confirmFound(storeID: String) async {
        guard let result = currentResult else { return }
        await send(storeID: storeID, verdict: .found, zoneID: result.location.zoneID, aisle: nil) {
            .confirmed
        }
    }

    /// "Not here": the item wasn't in the suggested zone.
    func reportNotHere(storeID: String) async {
        guard let result = currentResult else { return }
        await send(storeID: storeID, verdict: .notHere, zoneID: result.location.zoneID, aisle: nil) {
            .reportedMissing
        }
    }

    /// Correction entry: where the shopper actually found it.
    func submitCorrection(storeID: String, zone: StoreZone, aisle: String) async {
        let aisleText = aisle.trimmingCharacters(in: .whitespacesAndNewlines)
        await send(storeID: storeID, verdict: .found, zoneID: zone.id, aisle: aisleText.isEmpty ? nil : aisleText) {
            .corrected(zone.name)
        }
    }

    private func send(
        storeID: String, verdict: FeedbackVerdict, zoneID: Int?, aisle: String?,
        onSuccess: () -> FeedbackState
    ) async {
        guard let result = currentResult, let store = Int(storeID) else { return }
        let previous = feedback
        feedback = .sending
        let body = FeedbackBody(
            storeID: store, item: result.item, verdict: verdict,
            searchID: result.searchID, zoneID: zoneID, aisle: aisle
        )
        do {
            _ = try await api.sendFeedback(body)
            feedback = onSuccess()
            // The next search for this item should show the updated report counts.
            cache.invalidate(item: result.item, storeID: storeID)
            analytics.track(.feedbackSent, [
                "verdict": .string(verdict.rawValue),
                "correction": .bool(verdict == .found && zoneID != result.location.zoneID),
            ])
        } catch is CancellationError {
            feedback = previous
        } catch {
            feedback = .failed("Couldn't send that. Check your connection and try again.")
        }
    }
}
