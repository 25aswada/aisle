import Foundation
import Security

/// Where the session token is kept.
protocol TokenStore: AnyObject {
    var token: String? { get set }
}

/// The session token in the Keychain: encrypted, only readable after the phone is
/// first unlocked, and never backed up to another device.
final class KeychainTokenStore: TokenStore {
    private let service: String
    private let account = "session"

    init(service: String = "app.shopaisle.aisle.session") {
        self.service = service
    }

    var token: String? {
        get {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(baseQuery as CFDictionary)
            guard let newValue, let data = newValue.data(using: .utf8) else { return }
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// For tests and previews.
final class InMemoryTokenStore: TokenStore {
    var token: String?

    init(token: String? = nil) {
        self.token = token
    }
}
