import XCTest
@testable import Aisle

@MainActor
private final class FakeAuth: AuthService {
    var sentTo: [String] = []
    var providerResult: Result<VerifiedIdentity, AuthError> = .failure(.providerUnavailable(.apple))

    func sendCode(to email: String) async throws { sentTo.append(email) }

    func verify(email: String, code: String) async throws -> VerifiedIdentity {
        guard code == "123456" else { throw AuthError.invalidCode }
        return VerifiedIdentity(id: "u1", provider: .email, email: email, suggestedFirstName: nil)
    }

    func signIn(with provider: AuthProvider) async throws -> VerifiedIdentity {
        try providerResult.get()
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

    func testCodeKeepsOnlySixDigits() {
        let model = SignUpModel(auth: FakeAuth())
        model.code = "12a3-45678"
        XCTAssertEqual(model.code, "123456")
        XCTAssertTrue(model.isCodeComplete)
    }

    func testEmailFlowCreatesAccount() async {
        let auth = FakeAuth()
        let model = SignUpModel(auth: auth)
        model.email = "sam@example.com"
        let sent = await model.sendCode()
        XCTAssertTrue(sent)
        XCTAssertEqual(auth.sentTo, ["sam@example.com"])

        model.code = "000000"
        let rejected = await model.verifyCode()
        XCTAssertFalse(rejected)
        XCTAssertNotNil(model.errorMessage)

        model.code = "123456"
        let verified = await model.verifyCode()
        XCTAssertTrue(verified)
        XCTAssertNil(model.makeAccount(), "needs a name first")

        model.firstName = "  Sam "
        model.wantsTips = true
        let account = model.makeAccount()
        XCTAssertEqual(account?.firstName, "Sam")
        XCTAssertEqual(account?.email, "sam@example.com")
        XCTAssertEqual(account?.provider, .email)
        XCTAssertEqual(account?.wantsTips, true)
    }

    func testUnavailableProviderShowsMessage() async {
        let model = SignUpModel(auth: FakeAuth())
        let ok = await model.continueWith(.apple)
        XCTAssertFalse(ok)
        XCTAssertEqual(model.errorMessage, AuthError.providerUnavailable(.apple).errorDescription)
    }

    func testAccountPersistsAndSignsOut() {
        let defaults = UserDefaults(suiteName: "SignUpTests")!
        defaults.removePersistentDomain(forName: "SignUpTests")
        let store = AccountStore(defaults: defaults)
        XCTAssertFalse(store.isSignedIn)
        store.signIn(Account(id: "u1", provider: .email, email: "sam@example.com", firstName: "Sam", wantsTips: false))
        XCTAssertEqual(AccountStore(defaults: defaults).account?.firstName, "Sam")
        store.signOut()
        XCTAssertNil(AccountStore(defaults: defaults).account)
    }
}
