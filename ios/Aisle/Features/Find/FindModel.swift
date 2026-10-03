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

    init(api: AisleAPI) {
        self.api = api
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
        phase = .loading
        feedback = .none
        do {
            let result = try await api.searchItem(query: text, storeID: storeID)
            try Task.checkCancellation()
            phase = .loaded(result)
        } catch is CancellationError {
            // A newer search replaced this one.
        } catch APIError.httpStatus(404) {
            phase = .failed("This store is no longer available. Choose another store.")
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong.")
        }
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
        } catch is CancellationError {
            feedback = previous
        } catch {
            feedback = .failed("Couldn't send that. Check your connection and try again.")
        }
    }
}
