import Foundation

/// Account endpoints. Unlike the rest of the API, failures carry the server's message
/// (e.g. "Too many codes for this number"), which sign-in screens show as-is.
struct AccountAPI {
    let client: APIClient

    struct UserBody: Decodable {
        let id: Int
        let plusToken: String?
        let firstName: String
        let email: String?
        let phone: String?
        let wantsTips: Bool
        let providers: [String]

        enum CodingKeys: String, CodingKey {
            case id, email, phone, providers
            case firstName = "first_name"
            case wantsTips = "wants_tips"
            case plusToken = "plus_token"
        }

        var account: Account {
            Account(
                id: String(id), plusToken: plusToken.flatMap(UUID.init(uuidString:)), firstName: firstName, email: email, phone: phone, wantsTips: wantsTips,
                providers: providers.compactMap(AuthProvider.init(rawValue:))
            )
        }
    }

    struct SessionBody: Decodable {
        let token: String
        let user: UserBody
        let isNew: Bool

        enum CodingKeys: String, CodingKey {
            case token, user
            case isNew = "is_new"
        }

        var session: AuthSession { AuthSession(token: token, account: user.account, isNew: isNew) }
    }

    struct CodeSentBody: Decodable {
        let sentTo: String
        let retryAfter: Int

        enum CodingKeys: String, CodingKey {
            case sentTo = "sent_to"
            case retryAfter = "retry_after"
        }
    }

    private struct Detail: Decodable {
        let detail: String?
    }

    func sendCode(_ channel: CodeChannel, to target: String) async throws -> CodeSent {
        let body: CodeSentBody = channel == .phone
            ? try await send("POST", "auth/phone/start", body: ["phone": target])
            : try await send("POST", "auth/email/start", body: ["email": target])
        return CodeSent(sentTo: body.sentTo, retryAfter: body.retryAfter)
    }

    func verifyCode(_ channel: CodeChannel, target: String, code: String) async throws -> AuthSession {
        let body: SessionBody = channel == .phone
            ? try await send("POST", "auth/phone/verify", body: ["phone": target, "code": code])
            : try await send("POST", "auth/email/verify", body: ["email": target, "code": code])
        return body.session
    }

    func apple(identityToken: String, nonce: String, firstName: String?) async throws -> AuthSession {
        var body = ["identity_token": identityToken, "nonce": nonce]
        if let firstName, !firstName.isEmpty { body["first_name"] = firstName }
        let session: SessionBody = try await send("POST", "auth/apple", body: body)
        return session.session
    }

    func google(idToken: String, nonce: String) async throws -> AuthSession {
        let session: SessionBody = try await send("POST", "auth/google", body: ["id_token": idToken, "nonce": nonce])
        return session.session
    }

    func me(token: String) async throws -> Account {
        let user: UserBody = try await send("GET", "me", body: nil as String?, token: token)
        return user.account
    }

    func updateMe(token: String, firstName: String?, wantsTips: Bool?) async throws -> Account {
        struct Patch: Encodable {
            let first_name: String?
            let wants_tips: Bool?
        }
        let user: UserBody = try await send("PATCH", "me", body: Patch(first_name: firstName, wants_tips: wantsTips), token: token)
        return user.account
    }

    /// Texts a code to a number the signed-in shopper wants to add to their account.
    func addPhoneStart(token: String, phone: String) async throws -> CodeSent {
        let body: CodeSentBody = try await send("POST", "me/phone/start", body: ["phone": phone], token: token)
        return CodeSent(sentTo: body.sentTo, retryAfter: body.retryAfter)
    }

    func addPhoneVerify(token: String, phone: String, code: String) async throws -> Account {
        let user: UserBody = try await send("POST", "me/phone/verify", body: ["phone": phone, "code": code], token: token)
        return user.account
    }

    func deleteMe(token: String) async throws {
        _ = try await data("DELETE", "me", body: nil as String?, token: token)
    }

    func signOut(token: String) async throws {
        _ = try await data("POST", "auth/signout", body: nil as String?, token: token)
    }

    // MARK: - Request

    private func send<Body: Encodable, T: Decodable>(
        _ method: String, _ path: String, body: Body?, token: String? = nil
    ) async throws -> T {
        let data = try await data(method, path, body: body, token: token)
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw AuthError.network }
        return decoded
    }

    /// The response body of a successful request; failures become `AuthError`s.
    private func data<Body: Encodable>(
        _ method: String, _ path: String, body: Body?, token: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: try client.makeURL(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let deviceID = client.deviceID {
            request.setValue(deviceID, forHTTPHeaderField: "X-Aisle-Device")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await client.session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AuthError.network
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.network }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401 where token != nil:
            throw AuthError.signedOut
        case 422:
            throw AuthError.server("Check what you entered and try again.")
        default:
            let message = (try? JSONDecoder().decode(Detail.self, from: data))?.detail
            if let message, http.statusCode < 500 || http.statusCode == 503 { throw AuthError.server(message) }
            throw AuthError.network
        }
    }
}
