import Foundation

struct HealthResponse: Codable, Equatable {
    let status: String

    var isOK: Bool { status == "ok" }
}
