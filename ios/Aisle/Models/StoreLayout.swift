import Foundation

/// `GET /stores/{id}/layout`: an approximate floor plan for drawing a schematic map.
/// Positions are 0...1 (x left to right, y front to back). Template positions are
/// shared by every store of a format, so `approximate` is true for them.
struct StoreLayout: Codable, Equatable {
    struct Point: Codable, Equatable {
        let x: Double
        let y: Double
    }

    struct Zone: Codable, Equatable, Identifiable {
        let id: Int
        let name: String
        let x: Double?
        let y: Double?
        let source: String

        var point: Point? {
            guard let x, let y else { return nil }
            return Point(x: x, y: y)
        }
    }

    let storeID: Int
    let entrance: Point?
    let checkout: Point?
    let zones: [Zone]
    let approximate: Bool

    enum CodingKeys: String, CodingKey {
        case entrance, checkout, zones, approximate
        case storeID = "store_id"
    }

    /// Zones that can be placed on the map.
    var placedZones: [Zone] { zones.filter { $0.point != nil } }
}
