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

    /// Adds the items and returns their ids, so an add can be undone.
    @discardableResult
    func add(_ parsed: [ParsedListItem]) -> [UUID] {
        let added = parsed.map {
            ListItem(text: $0.text, quantity: $0.quantity, categoryName: $0.category?.name)
        }
        items.append(contentsOf: added)
        return added.map(\.id)
    }

    func remove(_ ids: [UUID]) {
        let gone = Set(ids)
        items.removeAll { gone.contains($0.id) }
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

/// Adds typed or pasted text to the list via the server parser, with an offline fallback,
/// or a photographed list read by the server's AI.
@MainActor
@Observable
final class ListComposerModel {
    /// What happened with a photographed list: how many items were added (undoable), or why none were.
    struct PhotoNotice: Equatable {
        let message: String
        let added: [UUID]
    }

    var draft = ""
    private(set) var isAdding = false
    private(set) var notice: String?
    private(set) var isReadingPhoto = false
    private(set) var photoNotice: PhotoNotice?
    /// Set when a free-tier limit is hit, to open the Aisle+ sheet saying why.
    var upgradePrompt: String?

    @ObservationIgnored private let api: AisleAPI
    @ObservationIgnored private let analytics: AnalyticsTracking

    init(api: AisleAPI, analytics: AnalyticsTracking? = nil) {
        self.api = api
        self.analytics = analytics ?? NoopAnalytics()
    }

    func add(to store: ShoppingListStore) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAdding else { return }
        isAdding = true
        notice = nil
        photoNotice = nil
        defer { isAdding = false }
        do {
            let parsed = try await api.parseList(text: text)
            store.add(parsed)
            draft = ""
            analytics.track(.listItemsAdded, ["count": .int(parsed.count), "offline": false])
        } catch is CancellationError {
            return
        } catch {
            let parsed = LocalListParser.parse(text)
            store.add(parsed)
            draft = ""
            notice = "Added offline. Check that multi-word items weren't split."
            analytics.track(.listItemsAdded, ["count": .int(parsed.count), "offline": true])
        }
    }

    /// Reads a photographed list and adds what's on it straight away, with an undo.
    func add(photo: Data, to store: ShoppingListStore) async {
        guard !isAdding else { return }
        isAdding = true
        isReadingPhoto = true
        notice = nil
        photoNotice = nil
        defer {
            isAdding = false
            isReadingPhoto = false
        }
        do {
            let parsed = try await api.scanList(photo: photo)
            guard !parsed.isEmpty else {
                photoNotice = PhotoNotice(
                    message: "Couldn't find a list in that photo. Try a closer, brighter shot.", added: []
                )
                return
            }
            let added = store.add(parsed)
            photoNotice = PhotoNotice(
                message: "Added \(parsed.count) \(parsed.count == 1 ? "item" : "items") from your photo", added: added
            )
            analytics.track(.listItemsAdded, ["count": .int(parsed.count), "offline": false, "photo": true])
        } catch is CancellationError {
            return
        } catch {
            photoNotice = PhotoNotice(
                message: (error as? LocalizedError)?.errorDescription ?? "Couldn't read that photo.", added: []
            )
            if case APIError.plusRequired(_, let message) = error { upgradePrompt = message }
        }
    }

    /// Takes back the items a photo just added.
    func undoPhoto(in store: ShoppingListStore) {
        guard let added = photoNotice?.added else { return }
        store.remove(added)
        photoNotice = nil
    }

    func dismissPhotoNotice() {
        photoNotice = nil
    }
}
