import SwiftUI

/// One message in the conversation after a search.
struct ChatTurn: Identifiable, Equatable {
    enum Role: String, Equatable {
        case shopper = "user"
        case aisle = "assistant"
    }

    let id = UUID()
    let role: Role
    let text: String
    /// A photo the shopper sent with this message (JPEG).
    var photo: Data? = nil
    /// When Aisle's reply answers "where's this new item?": that item's search, shown as a card.
    var result: ItemSearchResult? = nil
}

/// `POST /chat` wire format.
struct ChatMessage: Codable, Equatable {
    let role: String
    let content: String
    /// Base64 JPEG, on a shopper's message only.
    var image: String? = nil

    init(role: ChatTurn.Role, content: String, photo: Data? = nil) {
        self.role = role.rawValue
        self.content = content
        self.image = photo?.base64EncodedString()
    }
}

struct ChatRequestBody: Encodable {
    let storeID: Int
    let messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case storeID = "store_id"
        case messages
    }
}

/// `POST /chat` response: Aisle's reply, plus a search when the follow-up asked where to
/// find a new item.
struct ChatReply: Decodable, Equatable {
    var reply: String?
    var search: ItemSearchResult? = nil
}

/// `POST /identify`: a photo and what the shopper typed with it.
struct IdentifyRequestBody: Encodable {
    let storeID: Int?
    let image: String
    let note: String?

    enum CodingKeys: String, CodingKey {
        case storeID = "store_id"
        case image, note
    }
}

struct IdentifyResponse: Decodable {
    let item: String?
}

extension AttributedString {
    /// An Aisle reply written by the model: inline markdown, line breaks kept, its **bold**
    /// phrases drawn semibold. Nil if the text isn't valid markdown.
    static func aisleReply(markdown: String) -> AttributedString? {
        guard var text = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }
        let bold = text.runs
            .filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map(\.range)
        for range in bold {
            text[range].font = Theme.font(16, .semibold, relativeTo: .callout)
        }
        return text
    }
}
