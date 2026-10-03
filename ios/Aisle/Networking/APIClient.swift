import Foundation

enum APIError: Error, Equatable, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The request URL was invalid."
        case .invalidResponse: return "The server sent an unexpected response."
        case .httpStatus(let code): return "The server returned an error (\(code))."
        case .decoding: return "The server response couldn't be read."
        case .transport: return "Couldn't reach the Aisle server."
        }
    }
}

/// The subset of the Aisle API the app uses. Views and view models depend on
/// this protocol so tests can substitute a stub.
protocol AisleAPI: Sendable {
    func health() async throws -> HealthResponse
    func nearbyStores(latitude: Double, longitude: Double, limit: Int?) async throws -> [Store]
    func searchStores(query: String) async throws -> [Store]
    func store(id: String) async throws -> Store
    func searchItem(query: String, storeID: String?) async throws -> ItemSearchResult
    func zones(storeID: String) async throws -> [StoreZone]
    func sendFeedback(_ body: FeedbackBody) async throws -> FeedbackReceipt
    func parseList(text: String) async throws -> [ParsedListItem]
    func planRoute(storeID: String, items: [ListItem]) async throws -> RoutePlan
}

struct APIClient: AisleAPI {
    let baseURL: URL
    let session: URLSession
    /// Sent as `X-Aisle-Device` so the server can count repeat reports once.
    let deviceID: String?

    init(baseURL: URL = AppConfig.current.apiBaseURL, session: URLSession = .shared, deviceID: String? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.deviceID = deviceID
    }

    func health() async throws -> HealthResponse {
        try await get("health")
    }

    func nearbyStores(latitude: Double, longitude: Double, limit: Int? = nil) async throws -> [Store] {
        var query = [
            URLQueryItem(name: "lat", value: String(latitude)),
            URLQueryItem(name: "lon", value: String(longitude)),
        ]
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        let response: StoresResponse = try await get("stores/nearby", query: query)
        return response.stores
    }

    func searchStores(query: String) async throws -> [Store] {
        let response: StoresResponse = try await get(
            "stores/search",
            query: [URLQueryItem(name: "q", value: query)]
        )
        return response.stores
    }

    func store(id: String) async throws -> Store {
        try await get("stores/\(id)")
    }

    func searchItem(query: String, storeID: String?) async throws -> ItemSearchResult {
        try await post("search", body: SearchRequestBody(query: query, storeID: storeID.flatMap(Int.init)))
    }

    func zones(storeID: String) async throws -> [StoreZone] {
        try await get("stores/\(storeID)/zones")
    }

    func sendFeedback(_ body: FeedbackBody) async throws -> FeedbackReceipt {
        try await post("feedback", body: body)
    }

    func parseList(text: String) async throws -> [ParsedListItem] {
        let response: ListParseResponse = try await post("lists/parse", body: ListParseRequestBody(text: text))
        return response.items
    }

    func planRoute(storeID: String, items: [ListItem]) async throws -> RoutePlan {
        guard let store = Int(storeID) else { throw APIError.invalidURL }
        let body = RouteRequestBody(
            storeID: store,
            items: items.map { .init(id: $0.id.uuidString, text: $0.text) }
        )
        return try await post("route", body: body)
    }

    // MARK: - Request building

    func makeURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        let url = path
            .split(separator: "/")
            .reduce(baseURL) { $0.appendingPathComponent(String($1)) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let result = components.url else { throw APIError.invalidURL }
        return result
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: try makeURL(path: path, query: query))
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let deviceID {
            request.setValue(deviceID, forHTTPHeaderField: "X-Aisle-Device")
        }
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.httpStatus(http.statusCode) }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}
