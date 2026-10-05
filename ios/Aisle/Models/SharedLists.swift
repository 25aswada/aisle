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

    /// Only a shared list's owner names it; everyone else sees their name.
    var canRename: Bool { shared?.isOwner != false }
}

struct SharedInfo: Codable, Equatable {
    var serverID: String
    /// Only the owner gets it: they decide who's invited.
    var inviteCode: String?
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

    var owner: SharedMember? { members.first(where: \.isOwner) }

    /// The link the owner sends, https://shopaisle.app/join/CODE.
    var inviteURL: URL? { inviteCode.map(InviteLink.url) }
}

struct SharedMember: Codable, Equatable {
    let firstName: String
    let isOwner: Bool
    let isYou: Bool
    /// The server's id for this person on the list, for the owner to remove them.
    var id: Int? = nil
}

/// Invite links: https://shopaisle.app/join/CODE opens Aisle (a universal link) or, without
/// it, a page saying how to get it. Older invites were aisle://join/CODE; those still work.
enum InviteLink {
    static let host = "shopaisle.app"

    static func url(for code: String) -> URL {
        URL(string: "https://\(host)/join/\(code)")!
    }

    /// The code in an invite link, or nil for any other link.
    static func code(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        var code: String?
        switch url.scheme?.lowercased() {
        case "aisle":
            if url.host == "join" { code = parts.first }
        case "https":
            let host = url.host?.lowercased()
            if host == Self.host || host == "www.\(Self.host)", parts.count == 2, parts[0] == "join" { code = parts[1] }
        default:
            break
        }
        guard let code, !code.isEmpty, code.count <= 20, code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return code
    }
}

/// Why someone reports a shared list. The raw values are the server's.
enum SharedListReportReason: String, CaseIterable, Identifiable {
    case spam, harassment, inappropriate, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spam: return "Spam"
        case .harassment: return "Harassment or bullying"
        case .inappropriate: return "Inappropriate or offensive"
        case .other: return "Something else"
        }
    }
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
        var id: Int? = nil

        enum CodingKeys: String, CodingKey {
            case id
            case firstName = "first_name"
            case isOwner = "is_owner"
            case isYou = "is_you"
        }
    }

    let id: String
    let name: String
    /// Nil unless you own the list.
    let inviteCode: String?
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
            members: members.map { SharedMember(firstName: $0.firstName, isOwner: $0.isOwner, isYou: $0.isYou, id: $0.id) }
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
    /// The owner's controls: take someone off the list for good, or make a new invite code
    /// so the old link stops working.
    func removeMember(serverID: String, memberID: Int) async throws -> SharedListPayload
    func newInviteCode(serverID: String) async throws -> SharedListPayload
    /// Reports the list to Aisle; with `leave`, also leaves it.
    func report(serverID: String, reason: SharedListReportReason, note: String?, leave: Bool) async throws
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

    func removeMember(serverID: String, memberID: Int) async throws -> SharedListPayload {
        try await client.sharedListRequest("DELETE", "lists/\(serverID)/members/\(memberID)", body: nil as String?)
    }

    func newInviteCode(serverID: String) async throws -> SharedListPayload {
        try await client.sharedListRequest("POST", "lists/\(serverID)/code", body: nil as String?)
    }

    func report(serverID: String, reason: SharedListReportReason, note: String?, leave: Bool) async throws {
        struct Body: Encodable { let reason: String; let note: String?; let leave: Bool }
        let body = Body(reason: reason.rawValue, note: note, leave: leave)
        let _: SharedListEmpty = try await client.sharedListRequest("POST", "lists/\(serverID)/report", body: body)
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
