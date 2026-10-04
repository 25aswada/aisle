import Foundation
import Observation

/// The shopper's lists, persisted to `UserDefaults` as JSON. Everything that works on
/// "the list" (adding, checking off, shopping) works on the current one through `items`.
///
/// Free shoppers have one list of their own; Aisle+ adds more and sharing (the screens
/// decide that). A shared list also lives on the server: every change made here is
/// recorded as a pending change, sent shortly after, and kept on the phone until the
/// server confirms it, so nothing is lost offline. Other people's changes come in on
/// `refreshShared()`; changes still pending here are replayed on top of them.
@MainActor
@Observable
final class ShoppingListStore {
    static let legacyItemsKey = "aisle.shoppingList"
    static let listsKey = "aisle.shoppingLists"
    static let currentKey = "aisle.currentList"

    private(set) var lists: [ShoppingList] {
        didSet { save() }
    }
    private(set) var currentID: UUID {
        didSet { defaults.set(currentID.uuidString, forKey: Self.currentKey) }
    }
    /// The last problem syncing a shared list, for a quiet notice. Nil when all is well.
    private(set) var syncProblem: String?
    /// A join code from a link (aisle://join/CODE), waiting for the List tab to handle.
    var pendingJoinCode: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var service: SharedListService?
    @ObservationIgnored private var pushTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var inFlight: Set<UUID> = []

    init(defaults: UserDefaults = .standard, service: SharedListService? = nil) {
        self.defaults = defaults
        self.service = service
        var saved = defaults.data(forKey: Self.listsKey)
            .flatMap { try? JSONDecoder().decode([ShoppingList].self, from: $0) } ?? []
        if saved.isEmpty {
            // First run, or the single list from before multiple lists.
            let legacy = defaults.data(forKey: Self.legacyItemsKey)
                .flatMap { try? JSONDecoder().decode([ListItem].self, from: $0) } ?? []
            saved = [ShoppingList(name: "My list", items: legacy)]
        }
        self.lists = saved
        let remembered = defaults.string(forKey: Self.currentKey).flatMap(UUID.init(uuidString:))
        self.currentID = saved.contains { $0.id == remembered } ? remembered! : saved[0].id
    }

    // MARK: Lists

    private var currentIndex: Int {
        lists.firstIndex { $0.id == currentID } ?? 0
    }

    var current: ShoppingList { lists[currentIndex] }

    /// The current list's items. Setting them records changes for a shared list.
    var items: [ListItem] {
        get { lists[currentIndex].items }
        set {
            let index = currentIndex
            let old = lists[index].items
            lists[index].items = newValue
            if lists[index].shared != nil {
                record(Self.changes(from: old, to: newValue), in: index)
            }
        }
    }

    /// Lists you made yourself (joined lists don't count against the free tier's one list).
    var ownLists: [ShoppingList] { lists.filter { $0.shared == nil || $0.shared?.isOwner == true } }

    func select(_ id: UUID) {
        guard lists.contains(where: { $0.id == id }) else { return }
        currentID = id
    }

    /// A new, empty list, made current.
    @discardableResult
    func createList(named name: String? = nil) -> UUID {
        let list = ShoppingList(name: name ?? Self.nextName(after: lists.map(\.name)))
        lists.append(list)
        currentID = list.id
        return list.id
    }

    func renameCurrent(to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !trimmed.isEmpty else { return }
        let index = currentIndex
        lists[index].name = trimmed
        if let serverID = lists[index].shared?.serverID, let service {
            Task { _ = try? await service.rename(serverID: serverID, name: trimmed) }
        }
    }

    /// Removes the current list from this phone (a shared one is deleted for everyone
    /// if you own it, otherwise you leave it). There's always at least one list.
    func deleteCurrent() async throws {
        let index = currentIndex
        if let serverID = lists[index].shared?.serverID, let service {
            do {
                try await service.deleteOrLeave(serverID: serverID)
            } catch SharedListError.gone {
                // Already gone on the server.
            }
        }
        removeLocally(at: index)
    }

    static func nextName(after names: [String]) -> String {
        var number = names.count + 1
        while names.contains("List \(number)") { number += 1 }
        return "List \(number)"
    }

    private func removeLocally(at index: Int) {
        let removed = lists[index].id
        pushTasks[removed]?.cancel()
        if lists.count == 1 {
            lists[0] = ShoppingList(name: "My list")
        } else {
            lists.remove(at: index)
        }
        if !lists.contains(where: { $0.id == currentID }) || removed == currentID {
            currentID = lists[max(0, min(index, lists.count - 1))].id
        }
    }

    // MARK: Items

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
            var item = items[index]
            item.text = trimmed
            // The old category may no longer apply to the edited text.
            item.categoryName = nil
            items[index] = item
        }
    }

    /// Saves the item sheet: quantity, brand, note and department. Empty text clears a field.
    func updateDetails(_ id: UUID, quantity: String?, brand: String?, note: String?, categoryName: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
        }
        var item = items[index]
        item.quantity = clean(quantity)
        item.brand = clean(brand)
        item.note = clean(note)
        item.categoryName = clean(categoryName)
        guard item != items[index] else { return }
        items[index] = item
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
        var updated = items
        for index in updated.indices { updated[index].isDone = false }
        items = updated
    }

    // MARK: Sharing

    /// Shares the current list (needs Aisle+ and signing in; the server checks).
    func shareCurrent() async throws {
        guard let service else { throw SharedListError.signedOut }
        let index = currentIndex
        guard lists[index].shared == nil else { return }
        let payload = try await service.share(name: lists[index].name, items: lists[index].items)
        if let i = lists.firstIndex(where: { $0.id == lists[index].id }) {
            apply(payload, at: i)
        }
    }

    /// The owner stops sharing (everyone else loses it; the owner keeps a copy here);
    /// anyone else leaves (it goes from this phone).
    func stopSharingCurrent() async throws {
        let index = currentIndex
        guard let shared = lists[index].shared, let service else { return }
        do {
            try await service.deleteOrLeave(serverID: shared.serverID)
        } catch SharedListError.gone {
            // Already gone on the server.
        }
        guard let i = lists.firstIndex(where: { $0.shared?.serverID == shared.serverID }) else { return }
        if shared.isOwner {
            lists[i].shared = nil
            lists[i].pending = []
        } else {
            removeLocally(at: i)
        }
    }

    /// Joins a list with its invite code and makes it current.
    func join(code: String) async throws {
        guard let service else { throw SharedListError.signedOut }
        let payload = try await service.join(code: code)
        if let existing = lists.firstIndex(where: { $0.shared?.serverID == payload.id }) {
            apply(payload, at: existing)
            currentID = lists[existing].id
            return
        }
        var list = ShoppingList(name: payload.name)
        list.shared = payload.info
        lists.append(list)
        apply(payload, at: lists.count - 1)
        currentID = list.id
    }

    /// Sends pending changes and picks up everyone else's, for every shared list.
    func refreshShared() async {
        guard let service else { return }
        for list in lists where list.shared != nil {
            await sync(list.id, service: service)
        }
    }

    /// Adds shared lists this account joined on another phone.
    func refreshMemberships() async {
        guard let service, let ids = try? await service.memberships() else { return }
        let known = Set(lists.compactMap { $0.shared?.serverID })
        for id in ids where !known.contains(id) {
            if let payload = try? await service.fetch(serverID: id) {
                var list = ShoppingList(name: payload.name)
                list.shared = payload.info
                lists.append(list)
                apply(payload, at: lists.count - 1)
            }
        }
    }

    /// The phone signed out: shared lists stay as local copies until signing back in.
    func forgetSharing() {
        for index in lists.indices {
            lists[index].shared = nil
            lists[index].pending = []
        }
    }

    // MARK: Sync engine

    private func record(_ changes: [SharedChange], in index: Int) {
        guard !changes.isEmpty else { return }
        // A newer change to an item replaces any older one still waiting.
        let ids = Set(changes.map(\.itemID))
        lists[index].pending.removeAll { ids.contains($0.itemID) }
        lists[index].pending.append(contentsOf: changes)
        schedulePush(lists[index].id)
    }

    private func schedulePush(_ listID: UUID) {
        guard let service else { return }
        pushTasks[listID]?.cancel()
        pushTasks[listID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.sync(listID, service: service)
        }
    }

    private func sync(_ listID: UUID, service: SharedListService) async {
        guard !inFlight.contains(listID),
              let index = lists.firstIndex(where: { $0.id == listID }),
              let serverID = lists[index].shared?.serverID else { return }
        inFlight.insert(listID)
        defer { inFlight.remove(listID) }
        let sending = lists[index].pending
        do {
            let payload = sending.isEmpty
                ? try await service.fetch(serverID: serverID)
                : try await service.send(serverID: serverID, changes: sending)
            guard let i = lists.firstIndex(where: { $0.id == listID }) else { return }
            // Drop what the server confirmed; anything changed meanwhile stays pending.
            lists[i].pending.removeAll { change in sending.contains(change) }
            apply(payload, at: i)
            syncProblem = nil
            if !lists[i].pending.isEmpty { schedulePush(listID) }
        } catch SharedListError.gone {
            if let i = lists.firstIndex(where: { $0.id == listID }) {
                // Keep the items as a list on this phone.
                lists[i].shared = nil
                lists[i].pending = []
                syncProblem = "“\(lists[i].name)” isn't shared anymore. It's kept on this phone."
            }
        } catch is CancellationError {
        } catch SharedListError.signedOut {
            syncProblem = "Sign in to keep shared lists in sync. Changes are saved on this phone."
        } catch {
            syncProblem = "Couldn't sync shared lists. Changes are saved and will sync when you're back online."
        }
    }

    /// Takes the server's copy, then replays this phone's unconfirmed changes on top.
    private func apply(_ payload: SharedListPayload, at index: Int) {
        var items = payload.items.sorted { $0.position < $1.position }.map(\.listItem)
        for change in lists[index].pending {
            switch change {
            case .upsert(let item, let position):
                items.removeAll { $0.id == item.id }
                items.insert(item, at: min(position, items.count))
            case .delete(let id):
                items.removeAll { $0.id == id }
            }
        }
        // Brand and note live only on this phone; keep them across a sync.
        let local = Dictionary(lists[index].items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for i in items.indices {
            if let mine = local[items[i].id] {
                items[i].brand = items[i].brand ?? mine.brand
                items[i].note = items[i].note ?? mine.note
            }
        }
        lists[index].items = items
        lists[index].name = payload.name
        lists[index].shared = payload.info
    }

    /// What changed between two versions of a list: deleted items, and items that are new,
    /// edited or moved.
    static func changes(from old: [ListItem], to new: [ListItem]) -> [SharedChange] {
        let newIDs = Set(new.map(\.id))
        var changes: [SharedChange] = old.filter { !newIDs.contains($0.id) }.map { .delete($0.id) }
        let oldPositions = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($1.id, $0) })
        let oldItems = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        for (position, item) in new.enumerated() where oldItems[item.id] != item || oldPositions[item.id] != position {
            changes.append(.upsert(item, position: position))
        }
        return changes
    }

    private func save() {
        if let data = try? JSONEncoder().encode(lists) {
            defaults.set(data, forKey: Self.listsKey)
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
