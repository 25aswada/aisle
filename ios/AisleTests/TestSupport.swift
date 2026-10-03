import Foundation
@testable import Aisle

/// Intercepts requests from a dedicated `URLSession` so `APIClient` can be tested offline.
final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var handler: Handler? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    static var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    static func reset() {
        lock.withLock {
            _handler = nil
            _requests = []
        }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func respond(status: Int = 200, json: String) {
        handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests.append(request) }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

enum Fixtures {
    static let mapleSyrupJSON = """
    {"search_id":"evt-1","query":"maple syrup","item":"maple syrup","modifiers":[],"quantity":null,"store_id":2,
    "concept":{"id":118,"name":"maple syrup"},
    "category":{"slug":"syrups-sweeteners","name":"Syrups & Sweeteners"},
    "location":{"department":"Breakfast/Pantry","zone_id":17,"aisle":null,"section":null,
    "neighbors":["pancake mix","honey","sweeteners"]},
    "availability":"likely","confidence":"medium","source":"fallback",
    "reports":{"found":0,"not_here":0}}
    """

    static let zones = [
        StoreZone(id: 17, name: "Breakfast/Pantry", aisleLabel: nil, source: "template"),
        StoreZone(id: 21, name: "Frozen", aisleLabel: nil, source: "template"),
    ]

    static var mapleSyrup: ItemSearchResult {
        try! JSONDecoder().decode(ItemSearchResult.self, from: Data(mapleSyrupJSON.utf8))
    }

    static let store = Store(
        id: "store-1", name: "Target Center City", address: "1128 Chestnut St, Philadelphia, PA",
        latitude: 39.9505, longitude: -75.1601, distanceMiles: 0.4, retailerName: "Target"
    )
}

final class StubAPI: AisleAPI, @unchecked Sendable {
    var healthResult: Result<HealthResponse, Error> = .success(HealthResponse(status: "ok"))
    var nearbyResult: Result<[Store], Error> = .success([Fixtures.store])
    var searchResult: Result<[Store], Error> = .success([Fixtures.store])
    var searchItemResult: Result<ItemSearchResult, Error> = .success(Fixtures.mapleSyrup)
    private(set) var itemSearches: [(String, String?)] = []
    var zonesResult: Result<[StoreZone], Error> = .success(Fixtures.zones)
    var feedbackResult: Result<FeedbackReceipt, Error> = .success(
        FeedbackReceipt(id: 1, verdict: .found, zoneID: 17, reports: nil)
    )
    private(set) var feedbackBodies: [FeedbackBody] = []
    private(set) var nearbyCalls: [(Double, Double, Int?)] = []
    private(set) var searchQueries: [String] = []

    func health() async throws -> HealthResponse { try healthResult.get() }

    func nearbyStores(latitude: Double, longitude: Double, limit: Int?) async throws -> [Store] {
        nearbyCalls.append((latitude, longitude, limit))
        return try nearbyResult.get()
    }

    func searchStores(query: String) async throws -> [Store] {
        searchQueries.append(query)
        return try searchResult.get()
    }

    func store(id: String) async throws -> Store { Fixtures.store }

    func searchItem(query: String, storeID: String?) async throws -> ItemSearchResult {
        itemSearches.append((query, storeID))
        return try searchItemResult.get()
    }

    func zones(storeID: String) async throws -> [StoreZone] { try zonesResult.get() }

    func sendFeedback(_ body: FeedbackBody) async throws -> FeedbackReceipt {
        feedbackBodies.append(body)
        return try feedbackResult.get()
    }
}

@MainActor
final class FakeLocationProvider: LocationProviding {
    var authorization: LocationAuthorization
    var authorizationAfterPrompt: LocationAuthorization
    var coordinate: Coordinate? = Coordinate(latitude: 39.95, longitude: -75.16)
    private(set) var promptCount = 0

    init(_ authorization: LocationAuthorization, afterPrompt: LocationAuthorization? = nil) {
        self.authorization = authorization
        self.authorizationAfterPrompt = afterPrompt ?? authorization
    }

    func requestAuthorization() async -> LocationAuthorization {
        if authorization == .notDetermined {
            promptCount += 1
            authorization = authorizationAfterPrompt
        }
        return authorization
    }

    func currentCoordinate() async throws -> Coordinate {
        guard authorization == .authorized else { throw LocationError.notAuthorized }
        guard let coordinate else { throw LocationError.unavailable }
        return coordinate
    }
}
