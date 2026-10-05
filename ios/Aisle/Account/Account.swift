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

/// The signed-in shopper, as the server knows them. Guests have none (see `GuestMode`).
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

    /// The sign-in method to show ("Signed in with Apple"). A phone number added later in
    /// You doesn't replace the way the account was made.
    var provider: AuthProvider {
        for preferred in [AuthProvider.apple, .google, .email, .phone] where providers.contains(preferred) {
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
    /// Adding a phone number to the signed-in account: text a code, then check it.
    func sendAddPhoneCode(token: String, phone: String) async throws -> CodeSent
    func addPhone(token: String, phone: String, code: String) async throws -> Account
    func signOut(token: String) async
    func deleteAccount(token: String) async throws
    /// Before deleting an account with Sign in with Apple: Apple's sheet again, for a fresh
    /// one-time code the server uses to revoke the Apple sign-in, as Apple requires. Throws
    /// `CancellationError` if the shopper backs out.
    func appleDeletionCode() async throws -> String?
    func deleteAccount(token: String, appleAuthorizationCode: String?) async throws
}

extension AuthService {
    func appleDeletionCode() async throws -> String? { nil }

    func deleteAccount(token: String, appleAuthorizationCode: String?) async throws {
        try await deleteAccount(token: token)
    }
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
        endSession()
        if let token, let auth {
            Task { await auth.signOut(token: token) }
        }
    }

    /// Deletes the account on the server, then erases what the phone kept for it
    /// (`eraseLocalData`) and signs out here. Nothing is erased if the server refuses.
    /// With Sign in with Apple, the shopper confirms with Apple first so the server can
    /// revoke it; backing out of Apple's sheet deletes nothing. `confirmWithApple: false` skips
    /// the sheet (the shopper chose "Delete anyway"); the server revokes with what it kept.
    func deleteAccount(confirmWithApple: Bool = true, eraseLocalData: () -> Void = {}) async throws {
        guard let token = tokens.token, let auth else { return }
        var appleCode: String?
        if confirmWithApple, account?.providers.contains(.apple) == true {
            do {
                appleCode = try await auth.appleDeletionCode()
            } catch is CancellationError {
                throw AuthError.server(Self.appleConfirmationNeeded)
            } catch {
                // Apple's sheet couldn't open (e.g. no Apple ID on this phone). Deleting still
                // works; the server revokes with the token it kept from sign-in.
            }
        }
        try await auth.deleteAccount(token: token, appleAuthorizationCode: appleCode)
        eraseLocalData()
        endSession()
    }

    static let appleConfirmationNeeded = "To delete your account, confirm with Apple. Nothing was deleted."

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

    /// Texts a code to a number the shopper wants to add, so it signs in to this account.
    func sendAddPhoneCode(to phone: String) async throws -> CodeSent {
        guard let token = tokens.token, let auth else { throw AuthError.signedOut }
        do {
            return try await auth.sendAddPhoneCode(token: token, phone: phone)
        } catch AuthError.signedOut {
            signOutLocally()
            throw AuthError.signedOut
        }
    }

    /// Checks the texted code and adds the number. Signing in with it later opens this account.
    func addPhone(_ phone: String, code: String) async throws {
        guard let token = tokens.token, let auth else { throw AuthError.signedOut }
        do {
            let saved = try await auth.addPhone(token: token, phone: phone, code: code)
            if tokens.token == token { account = saved }
        } catch AuthError.signedOut {
            signOutLocally()
            throw AuthError.signedOut
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
        endSession()
    }

    /// Forgets the session and starts a new install ID, so later anonymous requests from
    /// this phone can't be tied back to the account on the server.
    private func endSession() {
        tokens.token = nil
        account = nil
        DeviceIdentity.rotate(defaults: defaults)
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
    /// How `session` was signed in to.
    private(set) var method: AuthProvider?
    /// Shown on the method screen after backing out of a new account ("sign in to yours, then…").
    private(set) var notice: String?

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

    var isPhoneValid: Bool { Self.looksLikePhone(phone) }

    /// Ten US digits, or a number with its country code (the server checks it properly).
    static func looksLikePhone(_ phone: String) -> Bool {
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

    /// A new account, or one that never got a name, asks for one before finishing. An Apple
    /// account that chose to stay nameless isn't asked again at every sign-in.
    var needsName: Bool {
        guard let session else { return false }
        return session.isNew || (session.account.firstName.isEmpty && !isNameOptional)
    }

    /// Signed in with Apple: the shopper may have chosen not to share a name, and Apple
    /// asks apps not to require it again, so the name step can be skipped.
    var isNameOptional: Bool { method == .apple }

    var canFinish: Bool { session != nil && (!trimmedName.isEmpty || isNameOptional) }

    /// A phone or email code just made a brand-new account. Someone who already uses Aisle
    /// another way (say Google) gets a second, empty account this way, so ask first.
    var shouldConfirmNewAccount: Bool {
        session?.isNew == true && (method == .phone || method == .email)
    }

    func clearError() { errorMessage = nil }

    func choose(_ channel: CodeChannel) {
        self.channel = channel
        code = ""
        codeSent = nil
        errorMessage = nil
        notice = nil
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
        let method: AuthProvider = channel == .phone ? .phone : .email
        return await run { accept(try await auth.verifyCode(channel, target: target, code: code), via: method) }
    }

    /// Apple or Google. Returns true when signed in; false (with no message) if cancelled.
    func continueWith(_ provider: AuthProvider) async -> Bool {
        notice = nil
        return await run { accept(try await auth.signIn(with: provider), via: provider) }
    }

    /// "I already have an account": deletes the empty account the code just made (nothing
    /// is in it yet) and goes back to choosing how to sign in. Returns true when done.
    func useExistingAccount() async -> Bool {
        guard let session, session.isNew else { return false }
        let byPhone = method == .phone
        guard await run({ try await auth.deleteAccount(token: session.token) }) else { return false }
        self.session = nil
        method = nil
        code = ""
        codeSent = nil
        notice = byPhone
            ? "Sign in the way you first signed up. Then add this number in You, under Phone number, and it will open that account too."
            : "Sign in the way you first signed up."
        return true
    }

    /// Saves the name (for new accounts) and returns the finished session to sign in with.
    func finish() async -> AuthSession? {
        guard var finished = session else { return nil }
        guard needsName else { return finished }
        guard canFinish else { return nil }
        let name = trimmedName.isEmpty ? nil : String(trimmedName.prefix(40))
        let saved = await run {
            finished.account = try await auth.updateProfile(token: finished.token, firstName: name, wantsTips: wantsTips)
        }
        return saved ? finished : nil
    }

    private func accept(_ session: AuthSession, via method: AuthProvider) {
        self.session = session
        self.method = method
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
