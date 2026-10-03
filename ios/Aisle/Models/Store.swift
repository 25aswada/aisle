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

    init(
        id: String, name: String, address: String, latitude: Double, longitude: Double,
        distanceMiles: Double?, retailerName: String?
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMiles = distanceMiles
        self.retailerName = retailerName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The backend uses integer primary keys; keep `id` a String on device.
        id = try container.decodeFlexibleID(forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        distanceMiles = try container.decodeIfPresent(Double.self, forKey: .distanceMiles)
        retailerName = try container.decodeIfPresent(String.self, forKey: .retailerName)
    }
}

/// `/stores/nearby` wraps stores in an object; `/stores/search` returns a bare array.
struct StoresResponse: Codable, Equatable {
    let stores: [Store]

    init(stores: [Store]) {
        self.stores = stores
    }

    private enum CodingKeys: String, CodingKey { case stores }

    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([Store].self) {
            stores = array
        } else {
            stores = try decoder.container(keyedBy: CodingKeys.self).decode([Store].self, forKey: .stores)
        }
    }
}

extension KeyedDecodingContainer {
    /// Decodes an identifier sent as either a JSON number or a string.
    func decodeFlexibleID(forKey key: Key) throws -> String {
        if let int = try? decode(Int.self, forKey: key) {
            return String(int)
        }
        return try decode(String.self, forKey: key)
    }
}
