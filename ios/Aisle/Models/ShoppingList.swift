import Foundation

/// One line on the shopping list. Lists live only on the device.
struct ListItem: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var text: String
    var quantity: String?
    var categoryName: String?
    var isDone: Bool

    init(id: UUID = UUID(), text: String, quantity: String? = nil, categoryName: String? = nil, isDone: Bool = false) {
        self.id = id
        self.text = text
        self.quantity = quantity
        self.categoryName = categoryName
        self.isDone = isDone
    }
}

struct ParsedListItem: Codable, Equatable {
    let text: String
    let quantity: String?
    let category: ItemCategory?
}

struct ListParseResponse: Codable, Equatable {
    let items: [ParsedListItem]
}

struct ListParseRequestBody: Encodable {
    let text: String
}

/// Offline fallback when `/lists/parse` is unreachable: split on separators, or on
/// spaces when there are none. The server parser is smarter about multi-word items.
enum LocalListParser {
    static func parse(_ text: String) -> [ParsedListItem] {
        let separators = CharacterSet(charactersIn: "\n,;•")
        let hasSeparators = text.rangeOfCharacter(from: separators) != nil
        let pieces = hasSeparators
            ? text.components(separatedBy: separators)
            : text.components(separatedBy: .whitespaces)
        return pieces
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-*"))) }
            .filter { !$0.isEmpty }
            .map { ParsedListItem(text: $0.lowercased(), quantity: nil, category: nil) }
    }
}
