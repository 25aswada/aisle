import Foundation

/// Structured result of `POST /search`. The app renders these fields; the server never sends prose.
struct ItemSearchResult: Codable, Equatable, Hashable {
    let query: String
    let item: String
    let modifiers: [String]
    let quantity: String?
    let storeID: Int?
    let concept: ItemConcept?
    let category: ItemCategory?
    let location: ItemLocation
    let availability: Availability
    let confidence: Confidence
    let source: LocationSource

    enum CodingKeys: String, CodingKey {
        case query, item, modifiers, quantity, concept, category, location, availability, confidence, source
        case storeID = "store_id"
    }
}

struct ItemConcept: Codable, Equatable, Hashable {
    let id: Int
    let name: String
}

struct ItemCategory: Codable, Equatable, Hashable {
    let slug: String
    let name: String
}

struct ItemLocation: Codable, Equatable, Hashable {
    let department: String?
    /// The store zone the department maps to, when the store has zones.
    let zoneID: Int?
    /// Only present when a database row supports it. Never inferred.
    let aisle: String?
    let section: String?
    let neighbors: [String]

    enum CodingKeys: String, CodingKey {
        case department, aisle, section, neighbors
        case zoneID = "zone_id"
    }
}

enum Confidence: String, Codable, Equatable, Hashable {
    case high, medium, low

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Confidence(rawValue: raw) ?? .low
    }
}

enum Availability: String, Codable, Equatable, Hashable {
    case likely, unlikely, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Availability(rawValue: raw) ?? .unknown
    }
}

enum LocationSource: String, Codable, Equatable, Hashable {
    case database
    case observations
    case storeLayout = "store_layout"
    case model
    case fallback

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LocationSource(rawValue: raw) ?? .fallback
    }
}

struct SearchRequestBody: Encodable, Equatable {
    let query: String
    let storeID: Int?

    enum CodingKeys: String, CodingKey {
        case query
        case storeID = "store_id"
    }
}
