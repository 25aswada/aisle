import Foundation
import Observation

enum AuthProvider: String, Codable, Equatable {
    case apple, google, phone, email

    var label: String {
        switch self {
        case .apple: return "Apple"
        case .google: return "Google"
        case .phone: return "phone"
        case .email: return "email"
        }
    }
}

/// How a sign-in code is sent.
enum CodeChannel: Equatable {
    case phone, email
}

/// The signed-in shopper, as the server knows them. Required to use the app.
struct Account: Codable, Equatable {
    var id: String
    /// Stamped on this account's Aisle+ purchases (StoreKit's appAccountToken), so the
    /// subscription belongs to this account rather than the Apple ID or phone.
    var plusToken: UUID? = nil
    var firstName: String
    var email: String?
    var phone: String?
    var wantsTips: Bool
    /// The ways this account can sign in.
    var providers: [AuthProvider]

    /// The sign-in method to show ("Signed in with Apple").
    var provider: AuthProvider {
        for preferred in [AuthProvider.apple, .google, .phone, .email] where providers.contains(preferred) {
            return preferred
        }
        return .email
    }

    var initial: String {
        firstName.first.map { String($0).uppercased() } ?? "A"
    }
}

/// A completed sign-in: the session token and who it belongs to.
struct AuthSession: Equatable {
    let token: String
    var account: Account
    /// The account was created by this sign-in, so the app asks for a name.
    let isNew: Bool
}

/// Where a code went and when another may be sent.
struct CodeSent: Equatable {
    let sentTo: String
    let retryAfter: Int
}

enum AuthError: LocalizedError, Equatable {
    case invalidEmail
    case invalidPhone
    case invalidCode
    case providerUnavailable(AuthProvider)
    case signedOut
    case network
    /// A message from the server the shopper can act on ("Too many codes…").
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail: return "That email doesn't look right."
        case .invalidPhone: return "That phone number doesn't look right."
        case .invalidCode: return "That code didn't work. Check it and try again."
        case .providerUnavailable(let provider): return "\(provider.label) sign-in isn't available right now. Try another way."
        case .signedOut: return "You've been signed out. Sign in again."
        case .network: return "Couldn't reach Aisle. Check your connection and try again."
        case .server(let message): return message
        }
    }
}

/// Sign-in and account calls to the Aisle server. `RemoteAuthService` is the real one.
@MainActor
protocol AuthService: AnyObject {
    func sendCode(_ channel: CodeChannel, to target: String) async throws -> CodeSent
    func verifyCode(_ channel: CodeChannel, target: String, code: String) async throws -> AuthSession
    /// Apple or Google, shown by the system. Throws `CancellationError` if the shopper backs out.
    func signIn(with provider: AuthProvider) async throws -> AuthSession
    func currentAccount(token: String) async throws -> Account
    func updateProfile(token: String, firstName: String?, wantsTips: Bool?) async throws -> Account
    func signOut(token: String) async
    func deleteAccount(token: String) async throws
}

/// The signed-in account. The account is cached in `UserDefaults` for display; the
/// session token lives in the Keychain. Changes are saved to the server.
@MainActor
@Observable
final class AccountStore {
    static let defaultsKey = "aisle.account"

    private(set) var account: Account? {
        didSet { save() }
    }

    /// Sign-in for screens that start it (onboarding, the You tab). Nil in tests that don't need it.
    @ObservationIgnored let auth: AuthService?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokens: TokenStore

    init(defaults: UserDefaults = .standard, tokens: TokenStore = KeychainTokenStore(), auth: AuthService? = nil) {
        self.defaults = defaults
        self.tokens = tokens
        self.auth = auth
        let saved = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        // An account without a session (e.g. from the old on-device stand-in) isn't signed in.
        if let saved, tokens.token != nil {
            self.account = saved
        } else {
            self.account = nil
            defaults.removeObject(forKey: Self.defaultsKey)
            tokens.token = nil
        }
    }

    var isSignedIn: Bool { account != nil }

    var token: String? { tokens.token }

    func signIn(_ session: AuthSession) {
        tokens.token = session.token
        account = session.account
    }

    /// Signs out here right away, and ends the session on the server in the background.
    func signOut() {
        let token = tokens.token
        tokens.token = nil
        account = nil
        if let token, let auth {
            Task { await auth.signOut(token: token) }
        }
    }

    /// Deletes the account on the server, then erases what the phone kept for it
    /// (`eraseLocalData`) and signs out here. Nothing is erased if the server refuses.
    func deleteAccount(eraseLocalData: () -> Void = {}) async throws {
        guard let token = tokens.token, let auth else { return }
        try await auth.deleteAccount(token: token)
        eraseLocalData()
        tokens.token = nil
        account = nil
    }

    /// Changes the account here at once, then saves it to the server, e.g. a new first
    /// name or the email-tips preference.
    func update(_ change: (inout Account) -> Void) {
        guard var current = account else { return }
        let before = current
        change(&current)
        account = current
        guard let token = tokens.token, let auth else { return }
        let firstName = current.firstName != before.firstName ? current.firstName : nil
        let wantsTips = current.wantsTips != before.wantsTips ? current.wantsTips : nil
        Task {
            do {
                let saved = try await auth.updateProfile(token: token, firstName: firstName, wantsTips: wantsTips)
                if self.tokens.token == token { self.account = saved }
            } catch AuthError.signedOut {
                self.signOutLocally()
            } catch {
                // Keep the local change; the next refresh brings back the server's copy.
            }
        }
    }

    /// Picks up changes made on other devices, and signs out if the session was ended.
    func refresh() async {
        guard let token = tokens.token, let auth else { return }
        do {
            let fresh = try await auth.currentAccount(token: token)
            if tokens.token == token { account = fresh }
        } catch AuthError.signedOut {
            signOutLocally()
        } catch {
            // Offline: keep showing the cached account.
        }
    }

    private func signOutLocally() {
        tokens.token = nil
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

/// Drives the sign-in screens: choose a method, enter a phone or email, enter the code,
/// then (new accounts only) a first name.
@MainActor
@Observable
final class SignUpModel {
    var channel: CodeChannel = .phone
    var email = ""
    var phone = ""
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
    private(set) var codeSent: CodeSent?
    private(set) var session: AuthSession?

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

    /// Ten US digits, or a number with its country code (the server checks it properly).
    var isPhoneValid: Bool {
        let digits = phone.filter(\.isNumber)
        if phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") { return (8...15).contains(digits.count) }
        return digits.count == 10 || (digits.count == 11 && digits.hasPrefix("1"))
    }

    var isTargetValid: Bool { channel == .phone ? isPhoneValid : isEmailValid }

    private var target: String { channel == .phone ? phone : trimmedEmail }

    /// What to show on the code screen: "+1 •••• 0123" or the email.
    var sentToLabel: String { codeSent?.sentTo ?? target }

    var isCodeComplete: Bool { code.count == 6 }

    var trimmedName: String {
        firstName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A new account, or one that never got a name, asks for one before finishing.
    var needsName: Bool {
        guard let session else { return false }
        return session.isNew || session.account.firstName.isEmpty
    }

    var canFinish: Bool { session != nil && !trimmedName.isEmpty }

    func clearError() { errorMessage = nil }

    func choose(_ channel: CodeChannel) {
        self.channel = channel
        code = ""
        codeSent = nil
        errorMessage = nil
    }

    /// Returns true when the code was sent.
    func sendCode() async -> Bool {
        guard isTargetValid else {
            errorMessage = (channel == .phone ? AuthError.invalidPhone : AuthError.invalidEmail).errorDescription
            return false
        }
        return await run { codeSent = try await auth.sendCode(channel, to: target) }
    }

    /// Returns true when the code was accepted and the shopper is signed in.
    func verifyCode() async -> Bool {
        await run { accept(try await auth.verifyCode(channel, target: target, code: code)) }
    }

    /// Apple or Google. Returns true when signed in; false (with no message) if cancelled.
    func continueWith(_ provider: AuthProvider) async -> Bool {
        await run { accept(try await auth.signIn(with: provider)) }
    }

    /// Saves the name (for new accounts) and returns the finished session to sign in with.
    func finish() async -> AuthSession? {
        guard var finished = session else { return nil }
        guard needsName else { return finished }
        guard !trimmedName.isEmpty else { return nil }
        let saved = await run {
            finished.account = try await auth.updateProfile(
                token: finished.token, firstName: String(trimmedName.prefix(40)), wantsTips: wantsTips
            )
        }
        return saved ? finished : nil
    }

    private func accept(_ session: AuthSession) {
        self.session = session
        if firstName.isEmpty { firstName = session.account.firstName }
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
            // The shopper closed the Apple or Google sheet.
        } catch {
            errorMessage = AuthError.network.errorDescription
        }
        return false
    }
}
