import UIKit
import XCTest
@testable import Aisle

@MainActor
final class ShoppingListStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "AisleTests.ShoppingList"

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func parsed(_ texts: [String]) -> [ParsedListItem] {
        texts.map { ParsedListItem(text: $0, quantity: nil, category: nil) }
    }

    func testAddEditAndPersist() {
        let store = ShoppingListStore(defaults: defaults)
        store.add(parsed(["milk", "eggs", "bananas", "toothpaste"]))
        XCTAssertEqual(store.items.map(\.text), ["milk", "eggs", "bananas", "toothpaste"])

        let eggs = store.items[1].id
        store.rename(eggs, to: " brown eggs ")
        store.setDone(store.items[0].id, true)
        let reloaded = ShoppingListStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.map(\.text), ["milk", "brown eggs", "bananas", "toothpaste"])
        XCTAssertTrue(reloaded.items[0].isDone)
        XCTAssertEqual(reloaded.remaining.count, 3)
    }

    func testRenameToBlankDeletes() {
        let store = ShoppingListStore(defaults: defaults)
        store.add(parsed(["milk"]))
        store.rename(store.items[0].id, to: "   ")
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRenameClearsStaleCategory() {
        let store = ShoppingListStore(defaults: defaults)
        store.add([ParsedListItem(text: "milk", quantity: "2", category: ItemCategory(slug: "dairy", name: "Milk & Dairy"))])
        XCTAssertEqual(store.items[0].categoryName, "Milk & Dairy")
        store.rename(store.items[0].id, to: "soap")
        XCTAssertNil(store.items[0].categoryName)
        XCTAssertEqual(store.items[0].quantity, "2")
    }

    func testMoveDeleteAndClear() {
        let store = ShoppingListStore(defaults: defaults)
        store.add(parsed(["a", "b", "c"]))
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.items.map(\.text), ["c", "a", "b"])
        store.remove(atOffsets: IndexSet(integer: 0))
        store.setDone(store.items[0].id, true)
        store.clearCompleted()
        XCTAssertEqual(store.items.map(\.text), ["b"])
        store.clearAll()
        XCTAssertTrue(store.items.isEmpty)
    }
}

@MainActor
final class ListComposerTests: XCTestCase {
    func testAddsServerParsedItems() async {
        let api = StubAPI()
        api.parseListResult = .success([
            ParsedListItem(text: "milk", quantity: nil, category: ItemCategory(slug: "dairy", name: "Milk & Dairy")),
            ParsedListItem(text: "eggs", quantity: nil, category: nil),
            ParsedListItem(text: "bananas", quantity: nil, category: nil),
            ParsedListItem(text: "toothpaste", quantity: nil, category: nil),
        ])
        let defaults = UserDefaults(suiteName: "AisleTests.Composer")!
        defaults.removePersistentDomain(forName: "AisleTests.Composer")
        let store = ShoppingListStore(defaults: defaults)
        let composer = ListComposerModel(api: api)
        composer.draft = "milk eggs bananas toothpaste"
        await composer.add(to: store)
        XCTAssertEqual(api.parsedTexts, ["milk eggs bananas toothpaste"])
        XCTAssertEqual(store.items.count, 4)
        XCTAssertEqual(store.items.first?.categoryName, "Milk & Dairy")
        XCTAssertEqual(composer.draft, "")
        XCTAssertNil(composer.notice)
    }

    func testFallsBackToLocalParserOffline() async {
        let api = StubAPI()
        api.parseListResult = .failure(APIError.transport("offline"))
        let defaults = UserDefaults(suiteName: "AisleTests.Composer2")!
        defaults.removePersistentDomain(forName: "AisleTests.Composer2")
        let store = ShoppingListStore(defaults: defaults)
        let composer = ListComposerModel(api: api)
        composer.draft = "milk eggs bananas toothpaste"
        await composer.add(to: store)
        XCTAssertEqual(store.items.map(\.text), ["milk", "eggs", "bananas", "toothpaste"])
        XCTAssertNotNil(composer.notice)
    }

    func testBlankDraftDoesNothing() async {
        let api = StubAPI()
        let store = ShoppingListStore(defaults: UserDefaults(suiteName: "AisleTests.Composer3")!)
        let composer = ListComposerModel(api: api)
        composer.draft = "  "
        await composer.add(to: store)
        XCTAssertTrue(api.parsedTexts.isEmpty)
    }

    func testPhotoOfAListAddsItsItemsAndCanBeUndone() async {
        let api = StubAPI()
        api.scanListResult = .success([
            ParsedListItem(text: "chicken", quantity: "2 lbs", category: ItemCategory(slug: "meat", name: "Meat & Poultry")),
            ParsedListItem(text: "bananas", quantity: nil, category: nil),
        ])
        let store = ShoppingListStore(defaults: .fresh("AisleTests.ComposerPhoto"))
        store.add([ParsedListItem(text: "milk", quantity: nil, category: nil)])
        let composer = ListComposerModel(api: api)
        let photo = Data([0xFF, 0xD8, 0x01])
        await composer.add(photo: photo, to: store)

        XCTAssertEqual(api.scannedPhotos, [photo])
        XCTAssertEqual(store.items.map(\.text), ["milk", "chicken", "bananas"])
        XCTAssertEqual(store.items[1].quantity, "2 lbs")
        XCTAssertEqual(composer.photoNotice?.message, "Added 2 items from your photo")
        XCTAssertFalse(composer.isReadingPhoto)

        composer.undoPhoto(in: store)
        XCTAssertEqual(store.items.map(\.text), ["milk"], "Undo takes back only what the photo added")
        XCTAssertNil(composer.photoNotice)
    }

    func testScanOverTheFreeLimitOpensTheUpgrade() async {
        let api = StubAPI()
        api.scanListResult = .failure(APIError.plusRequired(feature: "photo_search", message: "Out of free photo searches."))
        let composer = ListComposerModel(api: api)
        await composer.add(photo: Data([0xFF, 0xD8]), to: ShoppingListStore(defaults: .fresh("AisleTests.ScanLimit")))
        XCTAssertEqual(composer.upgradePrompt, "Out of free photo searches.")
    }

    func testPhotoWithoutAListSaysSo() async {
        let api = StubAPI()
        let store = ShoppingListStore(defaults: .fresh("AisleTests.ComposerPhoto2"))
        let composer = ListComposerModel(api: api)
        await composer.add(photo: Data([0xFF, 0xD8]), to: store)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(composer.photoNotice?.added, [])
        XCTAssertNotNil(composer.photoNotice?.message)

        api.scanListResult = .failure(APIError.timeout)
        await composer.add(photo: Data([0xFF, 0xD8]), to: store)
        XCTAssertEqual(composer.photoNotice?.message, APIError.timeout.errorDescription)
    }
}

final class LocalListParserTests: XCTestCase {
    func testSplitsOnSeparatorsOrSpaces() {
        XCTAssertEqual(LocalListParser.parse("milk eggs bananas toothpaste").map(\.text),
                       ["milk", "eggs", "bananas", "toothpaste"])
        XCTAssertEqual(LocalListParser.parse("maple syrup, Paper Towels\n- eggs").map(\.text),
                       ["maple syrup", "paper towels", "eggs"])
        XCTAssertTrue(LocalListParser.parse("  ").isEmpty)
    }
}

final class ListParseClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testParseListDecodesBackendShape() async throws {
        StubURLProtocol.respond(json: """
        {"items":[{"text":"milk","quantity":null,"category":{"slug":"dairy","name":"Milk & Dairy"}},
        {"text":"eggs","quantity":"a dozen","category":{"slug":"eggs","name":"Eggs"}},
        {"text":"flux capacitor","quantity":null,"category":null}]}
        """)
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:8000")!, session: StubURLProtocol.makeSession())
        let items = try await client.parseList(text: "milk, a dozen eggs, flux capacitor")
        XCTAssertEqual(items.map(\.text), ["milk", "eggs", "flux capacitor"])
        XCTAssertEqual(items[1].quantity, "a dozen")
        XCTAssertNil(items[2].category)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/lists/parse")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.bodyData)) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "milk, a dozen eggs, flux capacitor")
    }
}

// MARK: - Multiple and shared lists

@MainActor
private final class FakeSharedLists: SharedListService {
    var server: [String: SharedListPayload] = [:]
    private(set) var sent: [[SharedChange]] = []
    private(set) var deleted: [String] = []
    var gone = false

    private func payload(_ id: String, name: String, items: [ListItem], version: Int, owner: Bool = true) -> SharedListPayload {
        SharedListPayload(
            id: id, name: name, inviteCode: "K7Q2MX", version: version, isOwner: owner,
            members: [.init(firstName: "Sam", isOwner: true, isYou: owner), .init(firstName: "Alex", isOwner: false, isYou: !owner)],
            items: items.enumerated().map { .init($1, position: $0) }
        )
    }

    func share(name: String, items: [ListItem]) async throws -> SharedListPayload {
        let made = payload("srv-1", name: name, items: items, version: 1)
        server["srv-1"] = made
        return made
    }

    func join(code: String) async throws -> SharedListPayload {
        guard code == "K7Q2MX" else { throw SharedListError.gone }
        let joined = payload("srv-9", name: "Family", items: [ListItem(text: "milk")], version: 3, owner: false)
        server["srv-9"] = joined
        return joined
    }

    func fetch(serverID: String) async throws -> SharedListPayload {
        if gone { throw SharedListError.gone }
        return server[serverID]!
    }

    func send(serverID: String, changes: [SharedChange]) async throws -> SharedListPayload {
        if gone { throw SharedListError.gone }
        sent.append(changes)
        let current = server[serverID]!
        var items = current.items.sorted { $0.position < $1.position }.map(\.listItem)
        for change in changes {
            switch change {
            case .upsert(let item, let position):
                items.removeAll { $0.id == item.id }
                items.insert(item, at: min(position, items.count))
            case .delete(let id):
                items.removeAll { $0.id == id }
            }
        }
        let updated = payload(serverID, name: current.name, items: items, version: current.version + 1, owner: current.isOwner)
        server[serverID] = updated
        return updated
    }

    func rename(serverID: String, name: String) async throws -> SharedListPayload { server[serverID]! }

    func deleteOrLeave(serverID: String) async throws { deleted.append(serverID) }

    func memberships() async throws -> [String] { Array(server.keys) }

    /// Someone else on the list adds an item.
    func someoneAdds(_ text: String, to id: String) {
        let current = server[id]!
        var items = current.items.map(\.listItem)
        items.append(ListItem(text: text))
        server[id] = payload(id, name: current.name, items: items, version: current.version + 1, owner: current.isOwner)
    }
}

@MainActor
final class MultipleListsTests: XCTestCase {
    func testTheOldSingleListBecomesTheFirstList() throws {
        let defaults = UserDefaults.fresh("AisleTests.Legacy")
        defaults.set(try JSONEncoder().encode([ListItem(text: "milk")]), forKey: ShoppingListStore.legacyItemsKey)
        let store = ShoppingListStore(defaults: defaults)
        XCTAssertEqual(store.lists.count, 1)
        XCTAssertEqual(store.current.name, "My list")
        XCTAssertEqual(store.items.map(\.text), ["milk"])
    }

    func testListsKeepTheirOwnItemsAndTheCurrentOneIsRemembered() {
        let defaults = UserDefaults.fresh("AisleTests.Lists")
        let store = ShoppingListStore(defaults: defaults)
        store.add([ParsedListItem(text: "milk", quantity: nil, category: nil)])
        let second = store.createList()
        XCTAssertEqual(store.current.name, "List 2")
        XCTAssertTrue(store.items.isEmpty)
        store.add([ParsedListItem(text: "nails", quantity: nil, category: nil)])
        store.select(store.lists[0].id)
        XCTAssertEqual(store.items.map(\.text), ["milk"])
        store.select(second)

        let reopened = ShoppingListStore(defaults: defaults)
        XCTAssertEqual(reopened.current.id, second)
        XCTAssertEqual(reopened.items.map(\.text), ["nails"])
        XCTAssertEqual(ShoppingListStore.nextName(after: ["My list", "List 3"]), "List 4")
    }

    func testTheFreePlanHasOneListAndAislePlusHasNoLimit() {
        let store = ShoppingListStore(defaults: .fresh("AisleTests.ListLimit"))
        XCTAssertFalse(store.canCreateList(isPlus: false))
        XCTAssertTrue(store.canCreateList(isPlus: true))
        for _ in 0..<5 { store.createList() }
        XCTAssertEqual(store.lists.count, 6)
        XCTAssertTrue(store.canCreateList(isPlus: true))
        // Lists made on Aisle+ stay if it ends; only making more needs it.
        XCTAssertFalse(store.canCreateList(isPlus: false))
    }

    func testListsCanBeRenamedAndDeletedWithoutOpeningThem() async throws {
        let store = ShoppingListStore(defaults: .fresh("AisleTests.ListByID"))
        let first = store.current.id
        let second = store.createList()
        store.select(first)
        store.renameList(second, to: "  Costco run  ")
        XCTAssertEqual(store.lists.first { $0.id == second }?.name, "Costco run")
        XCTAssertEqual(store.current.id, first)
        try await store.deleteList(second)
        XCTAssertEqual(store.lists.map(\.id), [first])
        XCTAssertEqual(store.current.id, first)
    }

    func testDeletingTheLastListLeavesAnEmptyOne() async throws {
        let store = ShoppingListStore(defaults: .fresh("AisleTests.DeleteLast"))
        store.add([ParsedListItem(text: "milk", quantity: nil, category: nil)])
        try await store.deleteCurrent()
        XCTAssertEqual(store.lists.count, 1)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testChangesBetweenTwoVersions() {
        let milk = ListItem(text: "milk"), eggs = ListItem(text: "eggs"), bread = ListItem(text: "bread")
        var checked = milk
        checked.isDone = true
        let changes = ShoppingListStore.changes(from: [milk, eggs, bread], to: [checked, bread])
        XCTAssertEqual(changes, [.delete(eggs.id), .upsert(checked, position: 0), .upsert(bread, position: 1)])
        XCTAssertEqual(ShoppingListStore.changes(from: [milk], to: [milk]), [])
    }

    func testSharingSendsEditsAndMergesOthers() async throws {
        let service = FakeSharedLists()
        let store = ShoppingListStore(defaults: .fresh("AisleTests.Share"), service: service)
        store.add([ParsedListItem(text: "milk", quantity: nil, category: nil)])
        try await store.shareCurrent()
        XCTAssertEqual(store.current.shared?.inviteCode, "K7Q2MX")
        XCTAssertEqual(store.current.shared?.withLabel, "Shared with Alex")

        store.add([ParsedListItem(text: "eggs", quantity: nil, category: nil)])
        XCTAssertEqual(store.current.pending.count, 1)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(service.sent.count, 1, "edits go out after a short pause")
        XCTAssertTrue(store.current.pending.isEmpty)

        // Someone else adds bread while this phone checks off milk, before syncing.
        service.someoneAdds("bread", to: "srv-1")
        let milk = store.items.first { $0.text == "milk" }!
        store.setDone(milk.id, true)
        await store.refreshShared()
        XCTAssertEqual(Set(store.items.map(\.text)), ["milk", "eggs", "bread"])
        XCTAssertEqual(store.items.first { $0.text == "milk" }?.isDone, true)
        XCTAssertTrue(service.server["srv-1"]!.items.first { $0.text == "milk" }!.isDone)
    }

    func testAListThatIsGoneStaysOnThisPhone() async throws {
        let service = FakeSharedLists()
        let store = ShoppingListStore(defaults: .fresh("AisleTests.Gone"), service: service)
        store.add([ParsedListItem(text: "milk", quantity: nil, category: nil)])
        try await store.shareCurrent()
        service.gone = true
        await store.refreshShared()
        XCTAssertNil(store.current.shared)
        XCTAssertEqual(store.items.map(\.text), ["milk"])
        XCTAssertNotNil(store.syncProblem)
    }

    func testJoiningAddsTheListOnceAndLeavingRemovesIt() async throws {
        let service = FakeSharedLists()
        let store = ShoppingListStore(defaults: .fresh("AisleTests.Join"), service: service)
        try await store.join(code: "K7Q2MX")
        try await store.join(code: "K7Q2MX")
        XCTAssertEqual(store.lists.count, 2)
        XCTAssertEqual(store.current.name, "Family")
        XCTAssertEqual(store.items.map(\.text), ["milk"])
        XCTAssertEqual(store.ownLists.count, 1, "joined lists don't count as your own")

        try await store.stopSharingCurrent()
        XCTAssertEqual(service.deleted, ["srv-9"])
        XCTAssertEqual(store.lists.count, 1)
    }
}

/// The intro's practice list: grouping, adding and walking order, and department pictures.
final class PracticeListTests: XCTestCase {
    func testDepartmentsKeepAddedOrderWithOtherLast() {
        let departments = PracticeList.departments([
            ListItem(text: "tape"),
            ListItem(text: "bananas", categoryName: "Fruit"),
            ListItem(text: "milk", categoryName: "Milk & Dairy"),
            ListItem(text: "apples", categoryName: " Fruit "),
        ])
        XCTAssertEqual(departments.map(\.name), ["Fruit", "Milk & Dairy", "Other"])
        XCTAssertEqual(departments[0].items.map(\.text), ["bananas", "apples"])
    }

    func testNewItemsSkipWhatsAlreadyThere() {
        let parsed = [
            ParsedListItem(text: "milk", quantity: nil, category: nil),
            ParsedListItem(text: "eggs", quantity: "12", category: ItemCategory(slug: "eggs", name: "Eggs")),
            ParsedListItem(text: "EGGS", quantity: nil, category: nil),
        ]
        let added = PracticeList.newItems(from: parsed, existing: [ListItem(text: "Milk")])
        XCTAssertEqual(added.map(\.text), ["eggs"])
        XCTAssertEqual(added.first?.categoryName, "Eggs")
        XCTAssertEqual(added.first?.quantity, "12")
    }

    func testWalkingOrderIsFreshFirstColdLast() {
        let departments = PracticeList.departments([
            ListItem(text: "milk", categoryName: "Milk & Dairy"),
            ListItem(text: "tape"),
            ListItem(text: "widgets", categoryName: "Gadgets"),
            ListItem(text: "rice", categoryName: "Rice, Grains & Beans"),
            ListItem(text: "spinach", categoryName: "Vegetables"),
        ])
        XCTAssertEqual(
            PracticeList.walkingOrder(departments).map(\.name),
            ["Vegetables", "Rice, Grains & Beans", "Milk & Dairy", "Gadgets", "Other"]
        )
    }

    func testEveryDepartmentHasAPicture() {
        for name in PracticeList.typicalWalk + ["Other", "Produce", "Frozen pizza aisle", "Something new"] {
            XCTAssertNotNil(UIImage(named: DepartmentIcon.assetName(for: name)), name)
        }
    }

    func testStartersAreDistinct() {
        XCTAssertEqual(Set(ListStarter.all.map(\.id)).count, ListStarter.all.count)
    }
}
