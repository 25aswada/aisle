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

    var query = ""
    private(set) var phase: Phase = .idle

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
    }
}
