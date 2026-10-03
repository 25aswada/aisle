import SwiftUI

@main
struct AisleApp: App {
    @State private var health: HealthMonitor
    @State private var storeSelection: StoreSelection
    @State private var shoppingList: ShoppingListStore
    @State private var recentSearches: RecentSearches
    @State private var accounts: AccountStore
    @AppStorage(OnboardingFlow.completedKey) private var onboardingComplete = false
    @AppStorage(AppearancePreference.defaultsKey) private var appearance = AppearancePreference.system
    @Environment(\.scenePhase) private var scenePhase
    private let api: AisleAPI
    private let location: LocationProvider
    private let analytics: AnalyticsClient
    /// Development stand-in until the server has account endpoints.
    private let auth: AuthService = LocalAuthService()

    init() {
        let configuration = URLSessionConfiguration.default
        // Lets responses with Cache-Control (e.g. store zones) be reused.
        configuration.urlCache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 20_000_000)
        let api = APIClient(
            baseURL: AppConfig.current.apiBaseURL,
            session: URLSession(configuration: configuration),
            deviceID: DeviceIdentity.current()
        )
        self.api = api
        self.location = LocationProvider()
        self.analytics = AnalyticsClient(api: api)
        _health = State(initialValue: HealthMonitor(api: api))
        _storeSelection = State(initialValue: StoreSelection())
        _shoppingList = State(initialValue: ShoppingListStore())
        _recentSearches = State(initialValue: RecentSearches())
        _accounts = State(initialValue: AccountStore())
        Theme.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingComplete {
                    RootView(api: api, location: location, analytics: analytics, recents: recentSearches)
                } else {
                    OnboardingFlow(api: api, location: location, auth: auth) {
                        withAnimation(.easeInOut(duration: 0.3)) { onboardingComplete = true }
                    }
                }
            }
                .environment(health)
                .environment(accounts)
                .environment(storeSelection)
                .environment(shoppingList)
                .environment(recentSearches)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    analytics.track(.appOpened)
                    await health.check()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await analytics.flush() }
            }
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    static let defaultsKey = "aisle.appearance"

    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
