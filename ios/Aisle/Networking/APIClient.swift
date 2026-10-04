import Foundation

enum APIError: Error, Equatable, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case decoding(String)
    case transport(String)
    case offline
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The request URL was invalid."
        case .invalidResponse: return "The server sent an unexpected response."
        case .httpStatus(let code) where code >= 500: return "Aisle is having trouble right now. Try again in a moment."
        case .httpStatus(let code): return "The server returned an error (\(code))."
        case .decoding: return "The server response couldn't be read. You may need to update the app."
        case .transport: return "Couldn't reach the Aisle server."
        case .offline: return "You're offline. Check your connection and try again."
        case .timeout: return "The request took too long. Try again."
        }
    }

    /// A short, stable label for analytics. Never includes server text.
    var kind: String {
        switch self {
        case .invalidURL: return "invalid_url"
        case .invalidResponse: return "invalid_response"
        case .httpStatus(let code): return "http_\(code)"
        case .decoding: return "decoding"
        case .transport: return "transport"
        case .offline: return "offline"
        case .timeout: return "timeout"
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
    /// The next Aisle reply in a conversation that started with a search, with a search
    /// result when the shopper asked where to find a new item.
    func chat(storeID: String, messages: [ChatMessage]) async throws -> ChatReply
    /// A search phrase for the product in a photo (JPEG); nil when there's none to name.
    func identify(photo: Data, note: String?, storeID: String?) async throws -> String?
    func zones(storeID: String) async throws -> [StoreZone]
    func storeLayout(storeID: String) async throws -> StoreLayout
    func sendFeedback(_ body: FeedbackBody) async throws -> FeedbackReceipt
    func parseList(text: String) async throws -> [ParsedListItem]
    /// The items on a photographed shopping list (JPEG); empty when there's none to read.
    func scanList(photo: Data) async throws -> [ParsedListItem]
    func planRoute(storeID: String, items: [ListItem]) async throws -> RoutePlan
    func sendEvents(_ events: [AnalyticsEvent]) async throws
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
        try await post(
            "search", body: SearchRequestBody(query: query, storeID: storeID.flatMap(Int.init)),
            timeout: Self.replyTimeout
        )
    }

    func chat(storeID: String, messages: [ChatMessage]) async throws -> ChatReply {
        guard let store = Int(storeID) else { throw APIError.invalidURL }
        return try await post(
            "chat", body: ChatRequestBody(storeID: store, messages: messages), timeout: Self.replyTimeout
        )
    }

    func identify(photo: Data, note: String?, storeID: String?) async throws -> String? {
        let body = IdentifyRequestBody(storeID: storeID.flatMap(Int.init), image: photo.base64EncodedString(), note: note)
        let response: IdentifyResponse = try await post("identify", body: body, timeout: Self.replyTimeout)
        return response.item
    }

    func zones(storeID: String) async throws -> [StoreZone] {
        try await get("stores/\(storeID)/zones")
    }

    func storeLayout(storeID: String) async throws -> StoreLayout {
        try await get("stores/\(storeID)/layout")
    }

    func sendFeedback(_ body: FeedbackBody) async throws -> FeedbackReceipt {
        try await post("feedback", body: body)
    }

    func parseList(text: String) async throws -> [ParsedListItem] {
        let response: ListParseResponse = try await post("lists/parse", body: ListParseRequestBody(text: text))
        return response.items
    }

    func scanList(photo: Data) async throws -> [ParsedListItem] {
        let response: ListParseResponse = try await post(
            "lists/scan", body: ListScanRequestBody(image: photo.base64EncodedString()), timeout: Self.replyTimeout
        )
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

    func sendEvents(_ events: [AnalyticsEvent]) async throws {
        let _: AnalyticsAccepted = try await post("events", body: AnalyticsBatchBody(events: events))
    }

    /// Requests that wait on a written AI reply get longer than the default 10 seconds.
    static let replyTimeout: TimeInterval = 40

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

    private func post<Body: Encodable, T: Decodable>(
        _ path: String, body: Body, timeout: TimeInterval = 10
    ) async throws -> T {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, timeout: timeout)
    }

    private func send<T: Decodable>(_ request: URLRequest, timeout: TimeInterval = 10) async throws -> T {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let deviceID {
            request.setValue(deviceID, forHTTPHeaderField: "X-Aisle-Device")
        }
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError
            where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
            throw APIError.offline
        } catch let error as URLError where error.code == .timedOut {
            throw APIError.timeout
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

extension AisleAPI {
    /// Stand-ins without a map; the app just hides it.
    func storeLayout(storeID: String) async throws -> StoreLayout {
        throw URLError(.unsupportedURL)
    }
}
