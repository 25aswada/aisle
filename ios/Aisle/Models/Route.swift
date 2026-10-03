import Foundation

struct RouteRequestBody: Encodable {
    struct Item: Encodable {
        let id: String
        let text: String
    }

    let storeID: Int
    let items: [Item]

    enum CodingKeys: String, CodingKey {
        case items
        case storeID = "store_id"
    }
}

struct RoutePlan: Codable, Equatable {
    let storeID: Int
    let stops: [RouteStop]
    let unplaced: [UnplacedItem]
    let distance: Double

    enum CodingKeys: String, CodingKey {
        case stops, unplaced, distance
        case storeID = "store_id"
    }
}

struct RouteStop: Codable, Equatable, Identifiable {
    let order: Int
    let zoneID: Int?
    let department: String
    let x: Double?
    let y: Double?
    let items: [RouteStopItem]

    var id: Int { order }

    enum CodingKeys: String, CodingKey {
        case order, department, x, y, items
        case zoneID = "zone_id"
    }
}

struct RouteStopItem: Codable, Equatable, Identifiable {
    let id: String
    let text: String
    let aisle: String?
    let section: String?
    let neighbors: [String]
    let confidence: Confidence
    let source: LocationSource
}

struct UnplacedItem: Codable, Equatable, Identifiable {
    enum Reason: String, Codable {
        case unknown
        case notCarried = "not_carried"

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Reason(rawValue: raw) ?? .unknown
        }
    }

    let id: String
    let text: String
    let reason: Reason
}
