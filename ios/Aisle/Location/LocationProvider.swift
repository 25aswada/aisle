import CoreLocation
import Foundation

enum LocationAuthorization: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorizedWhenInUse, .authorizedAlways: self = .authorized
        case .restricted: self = .restricted
        case .denied: self = .denied
        @unknown default: self = .denied
        }
    }
}

struct Coordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

enum LocationError: Error, Equatable {
    case notAuthorized
    case unavailable
}

@MainActor
protocol LocationProviding: AnyObject {
    var authorization: LocationAuthorization { get }
    /// Shows the system prompt if needed and returns the resulting authorization.
    func requestAuthorization() async -> LocationAuthorization
    /// Returns a single location fix. Throws if not authorized or no fix is available.
    func currentCoordinate() async throws -> Coordinate
}

/// Thin async wrapper around `CLLocationManager`. Location is always optional in Aisle,
/// so callers must handle `.denied` / `.restricted` by falling back to manual search.
@MainActor
final class LocationProvider: NSObject, LocationProviding {
    private let manager = CLLocationManager()
    private var authorizationContinuations: [CheckedContinuation<LocationAuthorization, Never>] = []
    private var locationContinuations: [CheckedContinuation<Coordinate, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorization: LocationAuthorization {
        LocationAuthorization(manager.authorizationStatus)
    }

    func requestAuthorization() async -> LocationAuthorization {
        guard authorization == .notDetermined else { return authorization }
        return await withCheckedContinuation { continuation in
            authorizationContinuations.append(continuation)
            if authorizationContinuations.count == 1 {
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    func currentCoordinate() async throws -> Coordinate {
        guard authorization == .authorized else { throw LocationError.notAuthorized }
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuations.append(continuation)
            if locationContinuations.count == 1 {
                manager.requestLocation()
            }
        }
    }

    private func handleAuthorizationChange() {
        let current = authorization
        guard current != .notDetermined else { return }
        let waiting = authorizationContinuations
        authorizationContinuations.removeAll()
        waiting.forEach { $0.resume(returning: current) }
    }

    private func finishLocationRequest(with result: Result<Coordinate, Error>) {
        let waiting = locationContinuations
        locationContinuations.removeAll()
        waiting.forEach { $0.resume(with: result) }
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    // CLLocationManager delivers callbacks on the thread it was created on (main here).
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { handleAuthorizationChange() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last.map {
            Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        MainActor.assumeIsolated {
            if let coordinate {
                finishLocationRequest(with: .success(coordinate))
            } else {
                finishLocationRequest(with: .failure(LocationError.unavailable))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            finishLocationRequest(with: .failure(LocationError.unavailable))
        }
    }
}
