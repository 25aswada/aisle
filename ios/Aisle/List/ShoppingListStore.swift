import Foundation
import Observation

/// The shopping list, persisted to `UserDefaults` as JSON.
@MainActor
@Observable
final class ShoppingListStore {
    static let defaultsKey = "aisle.shoppingList"

    private(set) var items: [ListItem] {
        didSet { save() }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.items = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([ListItem].self, from: $0) } ?? []
    }

    var remaining: [ListItem] { items.filter { !$0.isDone } }

    func add(_ parsed: [ParsedListItem]) {
        items.append(contentsOf: parsed.map {
            ListItem(text: $0.text, quantity: $0.quantity, categoryName: $0.category?.name)
        })
    }

    func rename(_ id: UUID, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if trimmed.isEmpty {
            items.remove(at: index)
        } else if items[index].text != trimmed {
            items[index].text = trimmed
            // The old category may no longer apply to the edited text.
            items[index].categoryName = nil
        }
    }

    func setDone(_ id: UUID, _ done: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone = done
    }

    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func clearCompleted() {
        items.removeAll(where: \.isDone)
    }

    func clearAll() {
        items.removeAll()
    }

    func resetProgress() {
        for index in items.indices { items[index].isDone = false }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Adds typed or pasted text to the list via the server parser, with an offline fallback.
@MainActor
@Observable
final class ListComposerModel {
    var draft = ""
    private(set) var isAdding = false
    private(set) var notice: String?

    @ObservationIgnored private let api: AisleAPI

    init(api: AisleAPI) {
        self.api = api
    }

    func add(to store: ShoppingListStore) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAdding else { return }
        isAdding = true
        notice = nil
        defer { isAdding = false }
        do {
            let parsed = try await api.parseList(text: text)
            store.add(parsed)
            draft = ""
        } catch is CancellationError {
            return
        } catch {
            let parsed = LocalListParser.parse(text)
            store.add(parsed)
            draft = ""
            notice = "Added offline. Check that multi-word items weren't split."
        }
    }
}
