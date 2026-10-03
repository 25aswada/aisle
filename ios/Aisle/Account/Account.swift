import Foundation
import Observation

enum AuthProvider: String, Codable, Equatable {
    case apple, google, email

    var label: String {
        switch self {
        case .apple: return "Apple"
        case .google: return "Google"
        case .email: return "Email"
        }
    }
}

/// The signed-in shopper. Optional: everything in Aisle works without one.
struct Account: Codable, Equatable {
    var id: String
    var provider: AuthProvider
    var email: String?
    var firstName: String
    var wantsTips: Bool

    var initial: String {
        firstName.first.map { String($0).uppercased() } ?? "A"
    }
}

/// What a sign-in method returns before the shopper picks a name.
struct VerifiedIdentity: Equatable {
    let id: String
    let provider: AuthProvider
    let email: String?
    /// Some providers share a name; it pre-fills the name step.
    let suggestedFirstName: String?
}

enum AuthError: LocalizedError, Equatable {
    case invalidEmail
    case invalidCode
    case providerUnavailable(AuthProvider)
    case network

    var errorDescription: String? {
        switch self {
        case .invalidEmail: return "That email doesn't look right."
        case .invalidCode: return "That code didn't work. Check the email and try again."
        case .providerUnavailable(let provider): return "\(provider.label) sign-in isn't available yet. Use email instead."
        case .network: return "Couldn't reach Aisle. Check your connection and try again."
        }
    }
}

/// Sign-in backend. Swap `LocalAuthService` for a real implementation once the
/// server has account endpoints.
@MainActor
protocol AuthService: AnyObject {
    func sendCode(to email: String) async throws
    func verify(email: String, code: String) async throws -> VerifiedIdentity
    func signIn(with provider: AuthProvider) async throws -> VerifiedIdentity
}

/// Development stand-in so the sign-up flow can be built and tested before the
/// backend exists. It sends no email and accepts any 6-digit code.
/// Do not ship this: replace it with a server-backed `AuthService`.
@MainActor
final class LocalAuthService: AuthService {
    func sendCode(to email: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    func verify(email: String, code: String) async throws -> VerifiedIdentity {
        try await Task.sleep(for: .milliseconds(400))
        guard code.count == 6, code.allSatisfy(\.isNumber) else { throw AuthError.invalidCode }
        return VerifiedIdentity(id: UUID().uuidString, provider: .email, email: email, suggestedFirstName: nil)
    }

    func signIn(with provider: AuthProvider) async throws -> VerifiedIdentity {
        // Apple needs the Sign in with Apple capability; Google needs its SDK.
        throw AuthError.providerUnavailable(provider)
    }
}

/// The current account, persisted on the device.
@MainActor
@Observable
final class AccountStore {
    static let defaultsKey = "aisle.account"

    private(set) var account: Account? {
        didSet { save() }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.account = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
    }

    var isSignedIn: Bool { account != nil }

    func signIn(_ account: Account) {
        self.account = account
    }

    func signOut() {
        account = nil
    }

    private func save() {
        if let account, let data = try? JSONEncoder().encode(account) {
            defaults.set(data, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}

/// Drives the email / code / name steps of sign-up.
@MainActor
@Observable
final class SignUpModel {
    var email = ""
    var code = "" {
        didSet {
            let digits = String(code.filter(\.isNumber).prefix(6))
            if digits != code { code = digits }
        }
    }
    var firstName = ""
    var wantsTips = false

    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var identity: VerifiedIdentity?

    @ObservationIgnored private let auth: AuthService

    init(auth: AuthService) {
        self.auth = auth
    }

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isEmailValid: Bool {
        let parts = trimmedEmail.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !trimmedEmail.contains(" ") else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    var isCodeComplete: Bool { code.count == 6 }

    var trimmedName: String {
        firstName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canFinish: Bool { identity != nil && !trimmedName.isEmpty }

    func clearError() { errorMessage = nil }

    /// Returns true when the code was sent.
    func sendCode() async -> Bool {
        guard isEmailValid else {
            errorMessage = AuthError.invalidEmail.errorDescription
            return false
        }
        return await run { try await auth.sendCode(to: trimmedEmail) }
    }

    /// Returns true when the code was accepted.
    func verifyCode() async -> Bool {
        await run {
            identity = try await auth.verify(email: trimmedEmail, code: code)
        }
    }

    /// Apple or Google. Returns true when signed in.
    func continueWith(_ provider: AuthProvider) async -> Bool {
        await run {
            let verified = try await auth.signIn(with: provider)
            identity = verified
            if firstName.isEmpty, let suggested = verified.suggestedFirstName {
                firstName = suggested
            }
        }
    }

    func makeAccount() -> Account? {
        guard let identity, !trimmedName.isEmpty else { return nil }
        return Account(
            id: identity.id, provider: identity.provider, email: identity.email,
            firstName: String(trimmedName.prefix(40)), wantsTips: wantsTips
        )
    }

    private func run(_ work: () async throws -> Void) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
            return true
        } catch let error as AuthError {
            errorMessage = error.errorDescription
        } catch is CancellationError {
        } catch {
            errorMessage = AuthError.network.errorDescription
        }
        return false
    }
}
