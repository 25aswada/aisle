import Foundation

/// Event names the server accepts (see `ANALYTICS_EVENT_NAMES` in the backend).
enum AnalyticsEventName: String, Codable, CaseIterable {
    case appOpened = "app_opened"
    case storeSelected = "store_selected"
    case searchSubmitted = "search_submitted"
    case searchFailed = "search_failed"
    case recentSearchTapped = "recent_search_tapped"
    case feedbackSent = "feedback_sent"
    case listItemsAdded = "list_items_added"
    case shoppingStarted = "shopping_started"
    case shoppingItemFound = "shopping_item_found"
    case shoppingItemSkipped = "shopping_item_skipped"
    case shoppingFinished = "shopping_finished"
    case followUpSent = "follow_up_sent"
}

/// Property values are small scalars. Never put item text or queries in analytics.
enum AnalyticsValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(String(value.prefix(80)))
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else { self = .string(try container.decode(String.self)) }
    }
}

extension AnalyticsValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

struct AnalyticsEvent: Codable, Equatable {
    let name: AnalyticsEventName
    let occurredAt: Date
    let properties: [String: AnalyticsValue]

    enum CodingKeys: String, CodingKey {
        case name, properties
        case occurredAt = "occurred_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(properties, forKey: .properties)
        try container.encode(ISO8601DateFormatter().string(from: occurredAt), forKey: .occurredAt)
    }
}

struct AnalyticsBatchBody: Encodable {
    let events: [AnalyticsEvent]
}

struct AnalyticsAccepted: Decodable {
    let accepted: Int
}

@MainActor
protocol AnalyticsTracking: AnyObject {
    func track(_ name: AnalyticsEventName, _ properties: [String: AnalyticsValue])
}

extension AnalyticsTracking {
    func track(_ name: AnalyticsEventName) { track(name, [:]) }
}

/// Used in previews and tests that don't care about analytics.
@MainActor
final class NoopAnalytics: AnalyticsTracking {
    func track(_ name: AnalyticsEventName, _ properties: [String: AnalyticsValue]) {}
}

/// Batches events and sends them to `POST /events`. Respects the in-app opt-out.
@MainActor
final class AnalyticsClient: AnalyticsTracking {
    static let enabledKey = "aisle.analyticsEnabled"
    static let batchSize = 10
    static let maxQueued = 200

    private(set) var queue: [AnalyticsEvent] = []
    private let api: AisleAPI
    private let defaults: UserDefaults
    private let now: () -> Date
    private var isFlushing = false

    init(api: AisleAPI, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.defaults = defaults
        self.now = now
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func track(_ name: AnalyticsEventName, _ properties: [String: AnalyticsValue]) {
        guard isEnabled else { return }
        queue.append(AnalyticsEvent(name: name, occurredAt: now(), properties: properties))
        if queue.count > Self.maxQueued {
            queue.removeFirst(queue.count - Self.maxQueued)
        }
        if queue.count >= Self.batchSize {
            Task { await flush() }
        }
    }

    /// Sends queued events. Failed batches stay queued for the next flush.
    func flush() async {
        guard isEnabled else {
            queue.removeAll()
            return
        }
        guard !isFlushing, !queue.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        while !queue.isEmpty {
            let batch = Array(queue.prefix(50))
            do {
                try await api.sendEvents(batch)
                queue.removeFirst(batch.count)
            } catch {
                return
            }
        }
    }
}
