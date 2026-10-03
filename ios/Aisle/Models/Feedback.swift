import Foundation

struct StoreZone: Codable, Equatable, Hashable, Identifiable {
    let id: Int
    let name: String
    let aisleLabel: String?
    let source: String

    enum CodingKeys: String, CodingKey {
        case id, name, source
        case aisleLabel = "aisle_label"
    }
}

enum FeedbackVerdict: String, Codable, Equatable {
    case found
    case notHere = "not_here"
}

struct FeedbackBody: Encodable, Equatable {
    let storeID: Int
    let item: String
    let verdict: FeedbackVerdict
    var searchID: String?
    var zoneID: Int?
    var aisle: String?

    enum CodingKeys: String, CodingKey {
        case item, verdict, aisle
        case storeID = "store_id"
        case searchID = "search_id"
        case zoneID = "zone_id"
    }
}

struct ReportCounts: Codable, Equatable, Hashable {
    let found: Int
    let notHere: Int

    enum CodingKeys: String, CodingKey {
        case found
        case notHere = "not_here"
    }
}

struct FeedbackReceipt: Codable, Equatable {
    let id: Int
    let verdict: FeedbackVerdict
    let zoneID: Int?
    let reports: ReportCounts?

    enum CodingKeys: String, CodingKey {
        case id, verdict, reports
        case zoneID = "zone_id"
    }
}
