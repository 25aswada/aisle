import XCTest
@testable import Aisle

/// Deleting an account with Sign in with Apple asks Apple for a fresh code first, so the
/// server can revoke the Apple sign-in.
@MainActor
private final class AppleDeletionAuth: AuthService {
    var appleResult: Result<String?, Error> = .success("fresh-code")
    var deleted: [(String, String?)] = []

    func sendCode(_ channel: CodeChannel, to target: String) async throws -> CodeSent {
        CodeSent(sentTo: target, retryAfter: 30)
    }

    func verifyCode(_ channel: CodeChannel, target: String, code: String) async throws -> AuthSession {
        throw AuthError.invalidCode
    }

    func signIn(with provider: AuthProvider) async throws -> AuthSession { throw AuthError.providerUnavailable(provider) }
    func currentAccount(token: String) async throws -> Account { throw AuthError.network }
    func updateProfile(token: String, firstName: String?, wantsTips: Bool?) async throws -> Account { throw AuthError.network }
    func sendAddPhoneCode(token: String, phone: String) async throws -> CodeSent { throw AuthError.network }
    func addPhone(token: String, phone: String, code: String) async throws -> Account { throw AuthError.network }
    func signOut(token: String) async {}

    func deleteAccount(token: String) async throws {
        deleted.append((token, nil))
    }

    func appleDeletionCode() async throws -> String? { try appleResult.get() }

    func deleteAccount(token: String, appleAuthorizationCode: String?) async throws {
        deleted.append((token, appleAuthorizationCode))
    }
}

@MainActor
final class AppleAccountDeletionTests: XCTestCase {
    private func store(_ auth: AppleDeletionAuth, providers: [AuthProvider], _ name: String) -> AccountStore {
        let store = AccountStore(defaults: .fresh("AppleAccountDeletionTests.\(name)"), tokens: InMemoryTokenStore(), auth: auth)
        store.signIn(AuthSession(token: "tok", account: Account(
            id: "7", firstName: "Sam", email: nil, phone: nil, wantsTips: false, providers: providers
        ), isNew: false))
        return store
    }

    func testAppleAccountsSendAFreshCode() async throws {
        let auth = AppleDeletionAuth()
        let store = store(auth, providers: [.apple], "Code")
        var erased = false
        try await store.deleteAccount { erased = true }
        XCTAssertEqual(auth.deleted.map(\.1), ["fresh-code"])
        XCTAssertTrue(erased)
        XCTAssertFalse(store.isSignedIn)
    }

    func testBackingOutOfAppleDeletesNothing() async {
        let auth = AppleDeletionAuth()
        auth.appleResult = .failure(CancellationError())
        let store = store(auth, providers: [.apple, .phone], "Cancel")
        do {
            try await store.deleteAccount()
            XCTFail("Deleted without confirming with Apple")
        } catch {
            XCTAssertEqual(error as? AuthError, .server(AccountStore.appleConfirmationNeeded))
        }
        XCTAssertTrue(auth.deleted.isEmpty)
        XCTAssertTrue(store.isSignedIn)
    }

    func testDeleteAnywaySkipsApple() async throws {
        let auth = AppleDeletionAuth()
        auth.appleResult = .failure(CancellationError())
        let store = store(auth, providers: [.apple], "Anyway")
        try await store.deleteAccount(confirmWithApple: false)
        XCTAssertEqual(auth.deleted.count, 1)
        XCTAssertNil(auth.deleted[0].1)
        XCTAssertFalse(store.isSignedIn)
    }

    func testOtherAccountsDeleteWithoutApple() async throws {
        let auth = AppleDeletionAuth()
        auth.appleResult = .failure(AuthError.network)
        let store = store(auth, providers: [.phone], "Phone")
        try await store.deleteAccount()
        XCTAssertEqual(auth.deleted.count, 1)
        XCTAssertNil(auth.deleted[0].1)
    }
}
