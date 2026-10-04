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

/// A trip across several stores (Aisle+), in the order the shopper will visit them.
struct MultiRouteRequestBody: Encodable {
    let storeIDs: [Int]
    let items: [RouteRequestBody.Item]

    enum CodingKeys: String, CodingKey {
        case items
        case storeIDs = "store_ids"
    }
}

struct MultiRoutePlan: Codable, Equatable {
    struct Leg: Codable, Equatable {
        let storeID: Int
        let storeName: String
        let retailerName: String
        let stops: [RouteStop]
        let unplaced: [UnplacedItem]
        let distance: Double

        enum CodingKeys: String, CodingKey {
            case stops, unplaced, distance
            case storeID = "store_id"
            case storeName = "store_name"
            case retailerName = "retailer_name"
        }
    }

    let legs: [Leg]
    /// Items none of the stores is likely to carry.
    let unplaced: [UnplacedItem]
    /// Planned on the phone from saved maps (Aisle+ offline), not by the server.
    var isOffline = false

    enum CodingKeys: String, CodingKey {
        case legs, unplaced
    }
}

struct RoutePlan: Codable, Equatable {
    let storeID: Int
    let stops: [RouteStop]
    let unplaced: [UnplacedItem]
    let distance: Double
    /// Planned on the phone from saved maps (Aisle+ offline), not by the server.
    var isOffline = false

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
