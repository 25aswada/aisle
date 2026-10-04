import XCTest
@testable import Aisle

@MainActor
private final class FakeAuth: AuthService {
    var sent: [(CodeChannel, String)] = []
    var providerResult: Result<AuthSession, Error> = .failure(AuthError.providerUnavailable(.apple))
    var returning = false
    var profileUpdates: [(String?, Bool?)] = []
    var signedOutTokens: [String] = []
    var deleted: [String] = []
    var deleteFails = false
    var meResult: Result<Account, Error> = .failure(AuthError.network)

    static func account(_ name: String = "", providers: [AuthProvider] = [.phone]) -> Account {
        Account(id: "7", firstName: name, email: nil, phone: "+12155550123", wantsTips: false, providers: providers)
    }

    func sendCode(_ channel: CodeChannel, to target: String) async throws -> CodeSent {
        sent.append((channel, target))
        if target.contains("busy") { throw AuthError.server("Too many codes for this one. Try again in an hour.") }
        return CodeSent(sentTo: channel == .phone ? "+1 •••• 0123" : target, retryAfter: 30)
    }

    func verifyCode(_ channel: CodeChannel, target: String, code: String) async throws -> AuthSession {
        guard code == "123456" else { throw AuthError.invalidCode }
        return AuthSession(token: "tok", account: Self.account(returning ? "Sam" : ""), isNew: !returning)
    }

    func signIn(with provider: AuthProvider) async throws -> AuthSession { try providerResult.get() }

    func currentAccount(token: String) async throws -> Account { try meResult.get() }

    func updateProfile(token: String, firstName: String?, wantsTips: Bool?) async throws -> Account {
        profileUpdates.append((firstName, wantsTips))
        var account = Self.account(firstName ?? "Sam")
        account.wantsTips = wantsTips ?? false
        return account
    }

    var addedPhones: [(String, String)] = []

    func sendAddPhoneCode(token: String, phone: String) async throws -> CodeSent {
        CodeSent(sentTo: "+1 •••• 0188", retryAfter: 30)
    }

    func addPhone(token: String, phone: String, code: String) async throws -> Account {
        guard code == "123456" else { throw AuthError.invalidCode }
        if phone.contains("0199") {
            throw AuthError.server("That number already has its own Aisle account.")
        }
        addedPhones.append((token, phone))
        return Self.account("Sam", providers: [.google, .phone])
    }

    func signOut(token: String) async { signedOutTokens.append(token) }

    func deleteAccount(token: String) async throws {
        if deleteFails { throw AuthError.network }
        deleted.append(token)
    }
}

@MainActor
final class SignUpTests: XCTestCase {
    func testEmailValidation() {
        let model = SignUpModel(auth: FakeAuth())
        for bad in ["", "sam", "sam@", "@example.com", "sam@example", "sam @example.com", "sam@example."] {
            model.email = bad
            XCTAssertFalse(model.isEmailValid, bad)
        }
        model.email = "  Sam@Example.com "
        XCTAssertTrue(model.isEmailValid)
        XCTAssertEqual(model.trimmedEmail, "sam@example.com")
    }

    func testPhoneValidation() {
        let model = SignUpModel(auth: FakeAuth())
        for good in ["(215) 555-0123", "2155550123", "1 215 555 0123", "+44 20 7946 0958"] {
            model.phone = good
            XCTAssertTrue(model.isPhoneValid, good)
        }
        for bad in ["", "555-0123", "+123", "21555501234"] {
            model.phone = bad
            XCTAssertFalse(model.isPhoneValid, bad)
        }
    }

    func testCodeKeepsOnlySixDigits() {
        let model = SignUpModel(auth: FakeAuth())
        model.code = "12a3-45678"
        XCTAssertEqual(model.code, "123456")
        XCTAssertTrue(model.isCodeComplete)
    }

    func testNewPhoneAccountAsksForANameAndSavesIt() async {
        let auth = FakeAuth()
        let model = SignUpModel(auth: auth)
        model.choose(.phone)
        model.phone = "(215) 555-0123"
        let sent = await model.sendCode()
        XCTAssertTrue(sent)
        XCTAssertEqual(auth.sent.first?.0, .phone)
        XCTAssertEqual(auth.sent.first?.1, "(215) 555-0123")
        XCTAssertEqual(model.sentToLabel, "+1 •••• 0123")

        model.code = "000000"
        let rejected = await model.verifyCode()
        XCTAssertFalse(rejected)
        XCTAssertEqual(model.errorMessage, AuthError.invalidCode.errorDescription)

        model.code = "123456"
        let verified = await model.verifyCode()
        XCTAssertTrue(verified)
        XCTAssertTrue(model.needsName)
        XCTAssertFalse(model.canFinish, "needs a name first")

        model.firstName = "  Sam "
        model.wantsTips = true
        let session = await model.finish()
        XCTAssertEqual(session?.account.firstName, "Sam")
        XCTAssertEqual(session?.account.wantsTips, true)
        XCTAssertEqual(auth.profileUpdates.first?.0, "Sam")
        XCTAssertEqual(auth.profileUpdates.first?.1, true)
    }

    func testANewAccountFromACodeAsksFirstAndCanBackOut() async {
        let auth = FakeAuth()
        let model = SignUpModel(auth: auth)
        model.choose(.phone)
        model.phone = "2155550123"
        _ = await model.sendCode()
        model.code = "123456"
        _ = await model.verifyCode()
        XCTAssertTrue(model.shouldConfirmNewAccount)
        XCTAssertEqual(model.method, .phone)

        // "I already have an account": the empty account goes, and the method screen says what to do.
        let backedOut = await model.useExistingAccount()
        XCTAssertTrue(backedOut)
        XCTAssertEqual(auth.deleted, ["tok"])
        XCTAssertNil(model.session)
        XCTAssertFalse(model.shouldConfirmNewAccount)
        XCTAssertTrue(model.notice?.contains("Phone number") == true)

        // Choosing a method clears the note.
        model.choose(.email)
        XCTAssertNil(model.notice)
    }

    func testReturningAccountsAndProvidersDontAsk() async {
        let auth = FakeAuth()
        auth.returning = true
        let model = SignUpModel(auth: auth)
        model.choose(.phone)
        model.phone = "2155550123"
        model.code = "123456"
        _ = await model.verifyCode()
        XCTAssertFalse(model.shouldConfirmNewAccount, "the number already opens an account")
        let refused = await model.useExistingAccount()
        XCTAssertFalse(refused, "never deletes an existing account")
        XCTAssertTrue(auth.deleted.isEmpty)

        auth.providerResult = .success(AuthSession(token: "t", account: FakeAuth.account("Sam", providers: [.google]), isNew: true))
        _ = await model.continueWith(.google)
        XCTAssertFalse(model.shouldConfirmNewAccount, "Google links by email on the server")
    }

    func testAddingAPhoneToTheSignedInAccount() async throws {
        let auth = FakeAuth()
        let store = AccountStore(defaults: .fresh("SignUpTests.AddPhone"), tokens: InMemoryTokenStore(), auth: auth)
        store.signIn(AuthSession(token: "tok", account: FakeAuth.account("Sam", providers: [.google]), isNew: false))

        let sent = try await store.sendAddPhoneCode(to: "2155550188")
        XCTAssertEqual(sent.sentTo, "+1 •••• 0188")
        do {
            try await store.addPhone("2155550199", code: "123456")
            XCTFail("Expected a number with its own account to be refused")
        } catch AuthError.server(let message) {
            XCTAssertTrue(message.contains("own Aisle account"))
        }
        XCTAssertEqual(store.account?.providers, [.google])

        try await store.addPhone("2155550188", code: "123456")
        XCTAssertEqual(auth.addedPhones.first?.0, "tok")
        XCTAssertEqual(store.account?.providers, [.google, .phone])
    }

    func testReturningAccountSkipsTheNameStep() async {
        let auth = FakeAuth()
        auth.returning = true
        let model = SignUpModel(auth: auth)
        model.choose(.email)
        model.email = "sam@example.com"
        _ = await model.sendCode()
        model.code = "123456"
        _ = await model.verifyCode()
        XCTAssertFalse(model.needsName)
        let session = await model.finish()
        XCTAssertEqual(session?.account.firstName, "Sam")
        XCTAssertTrue(auth.profileUpdates.isEmpty)
    }

    func testServerMessagesAreShown() async {
        let model = SignUpModel(auth: FakeAuth())
        model.choose(.email)
        model.email = "busy@example.com"
        let sent = await model.sendCode()
        XCTAssertFalse(sent)
        XCTAssertEqual(model.errorMessage, "Too many codes for this one. Try again in an hour.")
    }

    func testProviderPrefillsTheNameAndCancellingIsQuiet() async {
        let auth = FakeAuth()
        let model = SignUpModel(auth: auth)

        auth.providerResult = .failure(CancellationError())
        let cancelled = await model.continueWith(.apple)
        XCTAssertFalse(cancelled)
        XCTAssertNil(model.errorMessage, "backing out of Apple's sheet isn't an error")

        auth.providerResult = .success(AuthSession(token: "t", account: FakeAuth.account("Sam", providers: [.google]), isNew: true))
        let ok = await model.continueWith(.google)
        XCTAssertTrue(ok)
        XCTAssertEqual(model.firstName, "Sam")
        XCTAssertTrue(model.needsName, "new accounts confirm their name")
    }

    func testAccountStoreKeepsTokenSyncsAndSignsOut() async throws {
        let defaults = UserDefaults.fresh("SignUpTests.Store")
        let tokens = InMemoryTokenStore()
        let auth = FakeAuth()
        let store = AccountStore(defaults: defaults, tokens: tokens, auth: auth)
        XCTAssertFalse(store.isSignedIn)

        store.signIn(AuthSession(token: "tok", account: FakeAuth.account("Sam"), isNew: false))
        XCTAssertEqual(tokens.token, "tok")
        XCTAssertEqual(AccountStore(defaults: defaults, tokens: tokens).account?.firstName, "Sam")

        store.update { $0.wantsTips = true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(auth.profileUpdates.last?.0, nil, "only what changed is sent")
        XCTAssertEqual(auth.profileUpdates.last?.1, true)

        auth.meResult = .failure(AuthError.signedOut)
        await store.refresh()
        XCTAssertFalse(store.isSignedIn, "a session ended elsewhere signs out here")
        XCTAssertNil(tokens.token)

        store.signIn(AuthSession(token: "tok2", account: FakeAuth.account("Sam"), isNew: false))
        store.signOut()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(auth.signedOutTokens, ["tok2"])
        XCTAssertNil(AccountStore(defaults: defaults, tokens: tokens).account)
    }

    func testDeleteAccount() async throws {
        let auth = FakeAuth()
        let store = AccountStore(defaults: .fresh("SignUpTests.Delete"), tokens: InMemoryTokenStore(), auth: auth)
        store.signIn(AuthSession(token: "tok", account: FakeAuth.account("Sam"), isNew: false))
        var erased = false
        try await store.deleteAccount { erased = true }
        XCTAssertEqual(auth.deleted, ["tok"])
        XCTAssertTrue(erased)
        XCTAssertFalse(store.isSignedIn)
    }

    func testAFailedDeletionKeepsTheAccountAndTheData() async {
        let auth = FakeAuth()
        auth.deleteFails = true
        let store = AccountStore(defaults: .fresh("SignUpTests.DeleteFails"), tokens: InMemoryTokenStore(), auth: auth)
        store.signIn(AuthSession(token: "tok", account: FakeAuth.account("Sam"), isNew: false))
        var erased = false
        do {
            try await store.deleteAccount { erased = true }
            XCTFail("Expected the deletion to fail")
        } catch {}
        XCTAssertFalse(erased)
        XCTAssertTrue(store.isSignedIn)
    }

    func testTheAccountCarriesItsAislePlusToken() throws {
        let json = #"{"id": 7, "plus_token": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "first_name": "Sam", "email": null, "phone": null, "wants_tips": false, "providers": ["apple"]}"#
        let account = try JSONDecoder().decode(AccountAPI.UserBody.self, from: Data(json.utf8)).account
        XCTAssertEqual(account.plusToken, UUID(uuidString: "6f9619ff-8b86-d011-b42d-00c04fc964ff"))
        // Cached before the token existed: still decodes, without one.
        let old = try JSONDecoder().decode(Account.self, from: Data(#"{"id": "7", "firstName": "Sam", "wantsTips": false, "providers": []}"#.utf8))
        XCTAssertNil(old.plusToken)
    }

    func testAnAccountWithoutASessionIsSignedOut() {
        let defaults = UserDefaults.fresh("SignUpTests.Legacy")
        let account = FakeAuth.account("Sam")
        defaults.set(try? JSONEncoder().encode(account), forKey: AccountStore.defaultsKey)
        let store = AccountStore(defaults: defaults, tokens: InMemoryTokenStore())
        XCTAssertFalse(store.isSignedIn)
    }

    func testGoogleRedirectSchemeAndChallenge() {
        let google = GoogleSignIn(clientID: "1234-abc.apps.googleusercontent.com")
        XCTAssertEqual(google.redirectScheme, "com.googleusercontent.apps.1234-abc")
        XCTAssertEqual(google.redirectURI, "com.googleusercontent.apps.1234-abc:/oauth2redirect")
        // RFC 7636 appendix B test vector.
        XCTAssertEqual(GoogleSignIn.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = google.authorizationURL(state: "s", nonce: "n", codeChallenge: "c")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["scope"], "openid email profile")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["nonce"], "n")
    }

    func testNonceHash() {
        XCTAssertEqual(Nonce.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Nonce.make().count, 32)
    }
}
