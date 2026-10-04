import Foundation

enum APIError: Error, Equatable, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case decoding(String)
    case transport(String)
    case offline
    case timeout
    /// A free-tier limit or an Aisle+ feature (HTTP 402). `message` says why, for the upgrade sheet.
    case plusRequired(feature: String, message: String)
    /// The server said no and why (a 4xx with a message), e.g. a fair-use or rate limit.
    case refused(status: Int, message: String)

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
        case .plusRequired(_, let message): return message
        case .refused(_, let message): return message
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
        case .plusRequired: return "plus_required"
        case .refused(let status, _): return "http_\(status)"
        }
    }
}

/// The subset of the Aisle API the app uses. Views and view models depend on
/// this protocol so tests can substitute a stub.
protocol AisleAPI: Sendable {
    func health() async throws -> HealthResponse
    func nearbyStores(latitude: Double, longitude: Double, limit: Int?) async throws -> [Store]
    /// Stores matching every word of `query`; nearest first when `near` is given.
    func searchStores(query: String, near: Coordinate?) async throws -> [Store]
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
    /// One trip across 2–4 stores (Aisle+).
    func planMultiRoute(storeIDs: [String], items: [ListItem]) async throws -> MultiRoutePlan
    func sendEvents(_ events: [AnalyticsEvent]) async throws
}

struct APIClient: AisleAPI {
    let baseURL: URL
    let session: URLSession
    /// Sent as `X-Aisle-Device` so the server can count repeat reports once. Read on every
    /// request, because it changes when the account signs out or is deleted.
    var deviceID: String? { deviceIDProvider?() ?? fixedDeviceID }
    private let fixedDeviceID: String?
    private let deviceIDProvider: (@Sendable () -> String?)?
    /// The signed-in session, sent as a bearer token so Aisle+ and the free tier's limits
    /// follow the account. Nil (or returning nil) when signed out.
    let authToken: (@Sendable () -> String?)?

    init(
        baseURL: URL = AppConfig.current.apiBaseURL, session: URLSession = .shared, deviceID: String? = nil,
        deviceIDProvider: (@Sendable () -> String?)? = nil, authToken: (@Sendable () -> String?)? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.fixedDeviceID = deviceID
        self.deviceIDProvider = deviceIDProvider
        self.authToken = authToken
    }

    func health() async throws -> HealthResponse {
        try await get("health")
    }

    /// A coordinate rounded to three decimals (about a city block), which is plenty to find
    /// nearby stores and is all that leaves the phone.
    static func coarse(_ degrees: Double) -> String {
        String((degrees * 1000).rounded() / 1000)
    }

    func nearbyStores(latitude: Double, longitude: Double, limit: Int? = nil) async throws -> [Store] {
        var query = [
            URLQueryItem(name: "lat", value: Self.coarse(latitude)),
            URLQueryItem(name: "lon", value: Self.coarse(longitude)),
        ]
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        let response: StoresResponse = try await get("stores/nearby", query: query)
        return response.stores
    }

    func searchStores(query: String, near: Coordinate?) async throws -> [Store] {
        var items = [URLQueryItem(name: "q", value: query)]
        if let near {
            items.append(URLQueryItem(name: "lat", value: Self.coarse(near.latitude)))
            items.append(URLQueryItem(name: "lon", value: Self.coarse(near.longitude)))
        }
        let response: StoresResponse = try await get("stores/search", query: items)
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

    func planMultiRoute(storeIDs: [String], items: [ListItem]) async throws -> MultiRoutePlan {
        let ids = storeIDs.compactMap(Int.init)
        guard ids.count == storeIDs.count else { throw APIError.invalidURL }
        let body = MultiRouteRequestBody(
            storeIDs: ids, items: items.map { .init(id: $0.id.uuidString, text: $0.text) }
        )
        return try await post("route/multi", body: body, timeout: Self.replyTimeout)
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
        if request.value(forHTTPHeaderField: "Authorization") == nil, let token = authToken?() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
        if http.statusCode == 402 {
            throw Self.plusRequired(from: data)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.refused(status: http.statusCode, from: data) ?? APIError.httpStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

// MARK: - Aisle+

/// `GET /plus/status`, `POST /plus/sync`: whether the server sees Aisle+, and today's free use.
struct PlusServerStatus: Decodable, Equatable {
    struct Usage: Decodable, Equatable {
        let used: Int
        let limit: Int
        var left: Int { max(0, limit - used) }
    }

    let isPlus: Bool
    let photoSearch: Usage
    let followUp: Usage

    enum CodingKeys: String, CodingKey {
        case isPlus = "is_plus"
        case photoSearch = "photo_search"
        case followUp = "follow_up"
    }
}

extension APIClient {
    /// Sends the App Store's signed transactions so the server can verify Aisle+.
    /// `claim` is "Restore purchases": also take over a subscription bought for a deleted account.
    func syncPlus(transactions: [String], claim: Bool = false) async throws -> PlusServerStatus {
        struct Body: Encodable { let transactions: [String]; let claim: Bool }
        return try await post("plus/sync", body: Body(transactions: transactions, claim: claim))
    }

    func plusStatus() async throws -> PlusServerStatus {
        try await get("plus/status")
    }

    /// The 402 body: {"detail": {"code": "plus_required", "feature": "...", "message": "..."}}.
    static func plusRequired(from data: Data) -> APIError {
        struct Body: Decodable {
            struct Detail: Decodable {
                let feature: String?
                let message: String?
            }
            let detail: Detail
        }
        let detail = (try? JSONDecoder().decode(Body.self, from: data))?.detail
        return .plusRequired(
            feature: detail?.feature ?? "plus",
            message: detail?.message ?? "That's part of Aisle+."
        )
    }

    /// A 4xx whose body says why: {"detail": "..."}. Nil for 401 and 404, which callers
    /// handle themselves, and for server errors and bodies without a message.
    static func refused(status: Int, from data: Data) -> APIError? {
        guard (400..<500).contains(status), status != 401, status != 404 else { return nil }
        struct Body: Decodable { let detail: String }
        guard let message = (try? JSONDecoder().decode(Body.self, from: data))?.detail, !message.isEmpty else { return nil }
        return .refused(status: status, message: message)
    }
}

// MARK: - Shared lists

extension APIClient {
    /// A shared-list call. 404 means the list is gone (or you were removed), 401 that
    /// you need to sign in, 402 that sharing needs Aisle+.
    func sharedListRequest<Body: Encodable, T: Decodable>(_ method: String, _ path: String, body: Body?) async throws -> T {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let deviceID {
            request.setValue(deviceID, forHTTPHeaderField: "X-Aisle-Device")
        }
        guard let token = authToken?() else { throw SharedListError.signedOut }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError
            where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
            throw APIError.offline
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            if http.statusCode == 204 || data.isEmpty, let empty = SharedListEmpty() as? T { return empty }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.decoding(String(describing: error))
            }
        case 401: throw SharedListError.signedOut
        case 402: throw Self.plusRequired(from: data)
        case 404: throw SharedListError.gone
        default: throw Self.refused(status: http.statusCode, from: data) ?? APIError.httpStatus(http.statusCode)
        }
    }
}

extension AisleAPI {
    func searchStores(query: String) async throws -> [Store] {
        try await searchStores(query: query, near: nil)
    }

    /// Stand-ins without a map; the app just hides it.
    func storeLayout(storeID: String) async throws -> StoreLayout {
        throw URLError(.unsupportedURL)
    }
}
