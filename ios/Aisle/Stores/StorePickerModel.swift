import Foundation
import Observation

/// Drives the store picker: nearby stores when location is allowed, manual search always.
@MainActor
@Observable
final class StorePickerModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded([Store])
        case failed(String)
    }

    static let nearbyLimit = 20

    private(set) var locationAuthorization: LocationAuthorization
    private(set) var nearby: Phase = .idle
    private(set) var searchResults: Phase = .idle

    @ObservationIgnored private let api: AisleAPI
    @ObservationIgnored private let location: LocationProviding

    init(api: AisleAPI, location: LocationProviding) {
        self.api = api
        self.location = location
        self.locationAuthorization = location.authorization
    }

    /// Location was refused by the user or by device policy. Manual search is the only path.
    var isLocationBlocked: Bool {
        locationAuthorization == .denied || locationAuthorization == .restricted
    }

    /// Call when the picker appears. Never prompts for permission on its own.
    func start() async {
        locationAuthorization = location.authorization
        if locationAuthorization == .authorized, nearby == .idle {
            await loadNearby()
        }
    }

    /// Called when the user explicitly asks to use their location.
    func requestLocationAndLoadNearby() async {
        locationAuthorization = await location.requestAuthorization()
        if locationAuthorization == .authorized {
            await loadNearby()
        }
    }

    func loadNearby() async {
        nearby = .loading
        do {
            let coordinate = try await location.currentCoordinate()
            let stores = try await api.nearbyStores(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                limit: Self.nearbyLimit
            )
            nearby = .loaded(stores)
        } catch is CancellationError {
            nearby = .idle
        } catch is LocationError {
            nearby = .failed("Couldn't determine your location. Search for a store instead.")
        } catch {
            nearby = .failed(Self.message(for: error))
        }
    }

    func search(_ rawQuery: String) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = .idle
            return
        }
        searchResults = .loading
        do {
            let stores = try await api.searchStores(query: query)
            try Task.checkCancellation()
            searchResults = .loaded(stores)
        } catch is CancellationError {
            // A newer query superseded this one; leave state for it to update.
        } catch {
            searchResults = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
    }
}
