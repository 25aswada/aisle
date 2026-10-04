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
