import Foundation

struct Store: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double
    /// Only present on results from `/stores/nearby`.
    let distanceMiles: Double?
    let retailerName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, address, latitude, longitude
        case distanceMiles = "distance_miles"
        case retailerName = "retailer_name"
    }
}

struct StoresResponse: Codable, Equatable {
    let stores: [Store]
}
