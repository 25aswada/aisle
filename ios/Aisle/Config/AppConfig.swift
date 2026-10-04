import Foundation

/// Runtime configuration for the app.
///
/// The API base URL is resolved in this order:
/// 1. `AISLE_API_BASE_URL` environment variable (handy from an Xcode scheme).
/// 2. `AisleAPIBaseURL` in Info.plist (set from the `AISLE_API_BASE_URL` build setting).
/// 3. `AppConfig.defaultAPIBaseURL`.
struct AppConfig {
    static let defaultAPIBaseURL = URL(string: "http://127.0.0.1:8000")!

    let apiBaseURL: URL
    /// The iOS OAuth client ID for Sign in with Google (`AisleGoogleClientID` in Info.plist).
    /// Not a secret: it ships inside the app. Nil turns Google sign-in off.
    var googleClientID: String?

    static let current = AppConfig(
        environment: ProcessInfo.processInfo.environment,
        infoDictionary: Bundle.main.infoDictionary ?? [:]
    )

    init(apiBaseURL: URL) {
        self.apiBaseURL = apiBaseURL
    }

    init(environment: [String: String], infoDictionary: [String: Any]) {
        let candidates = [
            environment["AISLE_API_BASE_URL"],
            infoDictionary["AisleAPIBaseURL"] as? String,
        ]
        let resolved = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("$(") }
            .flatMap(URL.init(string:))
        self.apiBaseURL = resolved ?? Self.defaultAPIBaseURL
        self.googleClientID = (infoDictionary["AisleGoogleClientID"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
    }
}
