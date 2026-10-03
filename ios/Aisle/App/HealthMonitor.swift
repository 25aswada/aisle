import Foundation
import Observation

/// Pings `GET /health` so the UI can quietly note when the server is unreachable.
@MainActor
@Observable
final class HealthMonitor {
    enum Status: Equatable {
        case unknown
        case ok
        case unreachable
    }

    private(set) var status: Status = .unknown

    @ObservationIgnored private let api: AisleAPI

    init(api: AisleAPI) {
        self.api = api
    }

    func check() async {
        do {
            let response = try await api.health()
            status = response.isOK ? .ok : .unreachable
        } catch is CancellationError {
            // Leave the previous status in place.
        } catch {
            status = .unreachable
        }
    }
}
