import Foundation

/// One of the shopper's lists. Lists live on the phone; a shared one also lives on the
/// server so everyone on it sees the same items.
struct ShoppingList: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var items: [ListItem]
    /// Set once the list is shared (Aisle+) or joined with an invite code.
    var shared: SharedInfo?
    /// Changes made on this phone that the server hasn't confirmed yet, oldest first.
    var pending: [SharedChange] = []

    init(id: UUID = UUID(), name: String, items: [ListItem] = [], shared: SharedInfo? = nil) {
        self.id = id
        self.name = name
        self.items = items
        self.shared = shared
    }
}

struct SharedInfo: Codable, Equatable {
    var serverID: String
    var inviteCode: String
    var version: Int
    var isOwner: Bool
    var members: [SharedMember]

    /// "Shared with Alex and Jo": everyone but you.
    var withLabel: String? {
        let others = members.filter { !$0.isYou }.map(\.firstName)
        guard !others.isEmpty else { return nil }
        if others.count == 1 { return "Shared with \(others[0])" }
        return "Shared with " + others.dropLast().joined(separator: ", ") + " and " + others.last!
    }
}

struct SharedMember: Codable, Equatable {
    let firstName: String
    let isOwner: Bool
    let isYou: Bool
}

/// One change to a shared list: add or update an item, or delete one.
enum SharedChange: Codable, Equatable {
    case upsert(ListItem, position: Int)
    case delete(UUID)

    var itemID: UUID {
        switch self {
        case .upsert(let item, _): return item.id
        case .delete(let id): return id
        }
    }
}

// MARK: - Wire format

/// A shared list as the server returns it.
struct SharedListPayload: Decodable, Equatable {
    struct Item: Codable, Equatable {
        let id: String
        let text: String
        let quantity: String?
        let categoryName: String?
        let isDone: Bool
        let position: Double

        enum CodingKeys: String, CodingKey {
            case id, text, quantity, position
            case categoryName = "category_name"
            case isDone = "is_done"
        }

        init(_ item: ListItem, position: Int) {
            id = item.id.uuidString
            text = item.text
            quantity = item.quantity
            categoryName = item.categoryName
            isDone = item.isDone
            self.position = Double(position)
        }

        var listItem: ListItem {
            ListItem(id: UUID(uuidString: id) ?? UUID(), text: text, quantity: quantity,
                     categoryName: categoryName, isDone: isDone)
        }
    }

    struct Member: Decodable, Equatable {
        let firstName: String
        let isOwner: Bool
        let isYou: Bool

        enum CodingKeys: String, CodingKey {
            case firstName = "first_name"
            case isOwner = "is_owner"
            case isYou = "is_you"
        }
    }

    let id: String
    let name: String
    let inviteCode: String
    let version: Int
    let isOwner: Bool
    let members: [Member]
    let items: [Item]

    enum CodingKeys: String, CodingKey {
        case id, name, version, members, items
        case inviteCode = "invite_code"
        case isOwner = "is_owner"
    }

    var info: SharedInfo {
        SharedInfo(
            serverID: id, inviteCode: inviteCode, version: version, isOwner: isOwner,
            members: members.map { SharedMember(firstName: $0.firstName, isOwner: $0.isOwner, isYou: $0.isYou) }
        )
    }
}

/// Shared-list calls to the Aisle server. Every call needs the shopper signed in.
@MainActor
protocol SharedListService: AnyObject {
    func share(name: String, items: [ListItem]) async throws -> SharedListPayload
    func join(code: String) async throws -> SharedListPayload
    func fetch(serverID: String) async throws -> SharedListPayload
    func send(serverID: String, changes: [SharedChange]) async throws -> SharedListPayload
    func rename(serverID: String, name: String) async throws -> SharedListPayload
    func deleteOrLeave(serverID: String) async throws
    /// Ids of the shared lists this account is on, to pick up lists joined on another phone.
    func memberships() async throws -> [String]
}

/// The real service, over the app's API client (which sends the session).
@MainActor
final class RemoteSharedLists: SharedListService {
    private let client: APIClient

    init(client: APIClient) {
        self.client = client
    }

    func share(name: String, items: [ListItem]) async throws -> SharedListPayload {
        struct Body: Encodable { let name: String; let items: [SharedListPayload.Item] }
        let body = Body(name: name, items: items.enumerated().map { SharedListPayload.Item($1, position: $0) })
        return try await client.sharedListRequest("POST", "lists", body: body)
    }

    func join(code: String) async throws -> SharedListPayload {
        try await client.sharedListRequest("POST", "lists/join", body: ["code": code])
    }

    func fetch(serverID: String) async throws -> SharedListPayload {
        try await client.sharedListRequest("GET", "lists/\(serverID)", body: nil as String?)
    }

    func send(serverID: String, changes: [SharedChange]) async throws -> SharedListPayload {
        struct Change: Encodable {
            let op: String
            let item: SharedListPayload.Item?
            let id: String?
        }
        struct Body: Encodable { let changes: [Change] }
        let wire = changes.map { change -> Change in
            switch change {
            case .upsert(let item, let position):
                return Change(op: "upsert", item: SharedListPayload.Item(item, position: position), id: nil)
            case .delete(let id):
                return Change(op: "delete", item: nil, id: id.uuidString)
            }
        }
        return try await client.sharedListRequest("POST", "lists/\(serverID)/changes", body: Body(changes: wire))
    }

    func rename(serverID: String, name: String) async throws -> SharedListPayload {
        try await client.sharedListRequest("PATCH", "lists/\(serverID)", body: ["name": name])
    }

    func deleteOrLeave(serverID: String) async throws {
        let _: SharedListEmpty = try await client.sharedListRequest("DELETE", "lists/\(serverID)", body: nil as String?)
    }

    func memberships() async throws -> [String] {
        struct Summary: Decodable { let id: String }
        let lists: [Summary] = try await client.sharedListRequest("GET", "lists", body: nil as String?)
        return lists.map(\.id)
    }
}

/// For calls that answer 204 No Content.
struct SharedListEmpty: Decodable {}

enum SharedListError: LocalizedError, Equatable {
    /// The list was deleted, or you were taken off it.
    case gone
    case signedOut

    var errorDescription: String? {
        switch self {
        case .gone: return "That list isn't shared with you anymore."
        case .signedOut: return "Sign in to use shared lists."
        }
    }
}
