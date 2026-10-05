import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Sign-in against the Aisle server. Apple and Google run on the device and hand the
/// server an ID token, which it checks before creating a session.
@MainActor
final class RemoteAuthService: AuthService {
    private let api: AccountAPI
    private let googleClientID: String?
    private let apple = AppleSignIn()
    private var google: GoogleSignIn?

    init(client: APIClient, googleClientID: String?) {
        self.api = AccountAPI(client: client)
        self.googleClientID = googleClientID
    }

    func sendCode(_ channel: CodeChannel, to target: String) async throws -> CodeSent {
        try await api.sendCode(channel, to: target)
    }

    func verifyCode(_ channel: CodeChannel, target: String, code: String) async throws -> AuthSession {
        try await api.verifyCode(channel, target: target, code: code)
    }

    func signIn(with provider: AuthProvider) async throws -> AuthSession {
        let nonce = Nonce.make()
        switch provider {
        case .apple:
            let credential = try await apple.signIn(hashedNonce: Nonce.sha256(nonce))
            return try await api.apple(
                identityToken: credential.identityToken, nonce: nonce, firstName: credential.firstName,
                authorizationCode: credential.authorizationCode
            )
        case .google:
            guard let googleClientID else { throw AuthError.providerUnavailable(.google) }
            let flow = GoogleSignIn(clientID: googleClientID)
            google = flow
            defer { google = nil }
            let idToken = try await flow.signIn(nonce: nonce)
            return try await api.google(idToken: idToken, nonce: nonce)
        case .phone, .email:
            throw AuthError.providerUnavailable(provider)
        }
    }

    func currentAccount(token: String) async throws -> Account {
        try await api.me(token: token)
    }

    func updateProfile(token: String, firstName: String?, wantsTips: Bool?) async throws -> Account {
        try await api.updateMe(token: token, firstName: firstName, wantsTips: wantsTips)
    }

    func sendAddPhoneCode(token: String, phone: String) async throws -> CodeSent {
        try await api.addPhoneStart(token: token, phone: phone)
    }

    func addPhone(token: String, phone: String, code: String) async throws -> Account {
        try await api.addPhoneVerify(token: token, phone: phone, code: code)
    }

    func signOut(token: String) async {
        try? await api.signOut(token: token)
    }

    func deleteAccount(token: String) async throws {
        try await api.deleteMe(token: token)
    }

    func appleDeletionCode() async throws -> String? {
        // Only the code is needed, so Apple asks for nothing new.
        try await apple.signIn(hashedNonce: Nonce.sha256(Nonce.make()), scopes: []).authorizationCode
    }

    func deleteAccount(token: String, appleAuthorizationCode: String?) async throws {
        try await api.deleteMe(token: token, appleAuthorizationCode: appleAuthorizationCode)
    }
}

/// A one-time random string tying a sign-in to this request, so a stolen token can't be replayed.
enum Nonce {
    static func make(length: Int = 32) -> String {
        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in characters.randomElement(using: &generator)! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private func keyWindow() -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
}

// MARK: - Apple

/// Apple's sign-in sheet. Apple shares the name only on the first sign-in, so it's
/// passed along to the server then.
@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Credential {
        let identityToken: String
        let firstName: String?
        /// One-time code the server trades for a token it revokes if the account is deleted.
        var authorizationCode: String?
    }

    private var continuation: CheckedContinuation<Credential, Error>?

    func signIn(hashedNonce: String, scopes: [ASAuthorization.Scope] = [.fullName, .email]) async throws -> Credential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = scopes
        request.nonce = hashedNonce
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        let token = credential?.identityToken.flatMap { String(data: $0, encoding: .utf8) }
        let firstName = credential?.fullName?.givenName
        let code = credential?.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        Task { @MainActor in
            if let token {
                self.finish(.success(Credential(identityToken: token, firstName: firstName, authorizationCode: code)))
            } else {
                self.finish(.failure(AuthError.providerUnavailable(.apple)))
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        Task { @MainActor in
            self.finish(.failure(cancelled ? CancellationError() : AuthError.providerUnavailable(.apple)))
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { keyWindow() }
    }

    private func finish(_ result: Result<Credential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

// MARK: - Google

/// Google sign-in in a secure system browser sheet (OAuth with PKCE), without Google's
/// SDK: Google redirects back to the app's reversed-client-ID scheme with a code, which
/// is exchanged for an ID token.
@MainActor
final class GoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    let clientID: String
    private var session: ASWebAuthenticationSession?

    init(clientID: String) {
        self.clientID = clientID
    }

    /// "com.googleusercontent.apps.1234-abc", from "1234-abc.apps.googleusercontent.com".
    var redirectScheme: String {
        let suffix = ".apps.googleusercontent.com"
        let id = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : clientID
        return "com.googleusercontent.apps." + id
    }

    var redirectURI: String { redirectScheme + ":/oauth2redirect" }

    func authorizationURL(state: String, nonce: String, codeChallenge: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The Google ID token for whoever signs in. Throws `CancellationError` if they back out.
    func signIn(nonce: String) async throws -> String {
        let verifier = Nonce.make(length: 64)
        let state = Nonce.make()
        let url = authorizationURL(state: state, nonce: nonce, codeChallenge: Self.codeChallenge(for: verifier))
        let callback = try await authorize(url)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            // access_denied: they declined on Google's screen, or Google refused the account.
            throw AuthError.server(error == "access_denied"
                ? "Google didn't allow this sign-in. Try again, or sign in another way."
                : "Google sign-in didn't finish (\(error)). Try again.")
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.server("Google sign-in didn't finish. Try again.")
        }
        return try await exchange(code: code, verifier: verifier)
    }

    private func authorize(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: redirectScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: CancellationError())
                } else {
                    let reason = error.map { ($0 as NSError).localizedDescription } ?? "unknown"
                    continuation.resume(throwing: AuthError.server("Couldn't open Google sign-in: \(reason)"))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AuthError.providerUnavailable(.google))
            }
        }
    }

    private func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        struct TokenResponse: Decodable { let id_token: String? }
        struct TokenError: Decodable { let error: String?; let error_description: String? }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthError.server("Couldn't reach Google: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let idToken = (try? JSONDecoder().decode(TokenResponse.self, from: data))?.id_token else {
            let detail = (try? JSONDecoder().decode(TokenError.self, from: data))
                .map { [$0.error, $0.error_description].compactMap { $0 }.joined(separator: ": ") } ?? ""
            throw AuthError.server("Google sign-in didn't finish (HTTP \(status)\(detail.isEmpty ? "" : ", \(detail)")). Try again.")
        }
        return idToken
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { keyWindow() }
    }
}
