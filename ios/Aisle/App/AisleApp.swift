import SwiftUI

@main
struct AisleApp: App {
    @State private var health: HealthMonitor
    @State private var storeSelection: StoreSelection
    @State private var shoppingList: ShoppingListStore
    @State private var recentSearches: RecentSearches
    @State private var accounts: AccountStore
    @State private var plus: PlusStore
    @AppStorage(OnboardingFlow.completedKey) private var onboardingComplete = false
    @AppStorage(GuestMode.key) private var isGuest = false
    @AppStorage(AppearancePreference.defaultsKey) private var appearance = AppearancePreference.system
    @Environment(\.scenePhase) private var scenePhase
    private let api: AisleAPI
    private let offlineMaps: OfflineMaps
    private let location: LocationProvider
    private let analytics: AnalyticsClient
    private let auth: AuthService

    init() {
        let configuration = URLSessionConfiguration.default
        // Lets responses with Cache-Control (e.g. store zones) be reused.
        configuration.urlCache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 20_000_000)
        let api = APIClient(
            baseURL: AppConfig.current.apiBaseURL,
            session: URLSession(configuration: configuration),
            deviceIDProvider: { DeviceIdentity.current() },
            authToken: { KeychainTokenStore().token }
        )
        // Aisle+ saves store maps and answers on the phone for when there's no signal.
        let offlineMaps = OfflineMaps()
        self.offlineMaps = offlineMaps
        self.api = OfflineAwareAPI(base: api, maps: offlineMaps)
        let auth = RemoteAuthService(client: api, googleClientID: AppConfig.current.googleClientID)
        self.auth = auth
        self.location = LocationProvider()
        self.analytics = AnalyticsClient(api: api)
        _health = State(initialValue: HealthMonitor(api: api))
        _storeSelection = State(initialValue: StoreSelection())
        _shoppingList = State(initialValue: ShoppingListStore(service: RemoteSharedLists(client: api)))
        _recentSearches = State(initialValue: RecentSearches())
        _accounts = State(initialValue: AccountStore(auth: auth))
        PurchaseAnalytics.start(apiKey: AppConfig.current.revenueCatAPIKey)
        let plus = PlusStore()
        plus.client = api
        _plus = State(initialValue: plus)
        Theme.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // The tabs open once someone is signed in or chose to look around as a guest.
                if onboardingComplete && (accounts.isSignedIn || isGuest) {
                    RootView(api: api, location: location, analytics: analytics, recents: recentSearches)
                } else {
                    // Signed out after the intro (or after "Sign out"): straight to sign-in,
                    // which offers guest again.
                    OnboardingFlow(api: api, location: location, auth: auth, signInOnly: onboardingComplete) {
                        withAnimation(.easeInOut(duration: 0.3)) { onboardingComplete = true }
                    }
                    .id(onboardingComplete)
                }
            }
                .environment(health)
                .environment(accounts)
                .environment(plus)
                .environment(storeSelection)
                .environment(shoppingList)
                .environment(recentSearches)
                .environment(\.offlineMaps, offlineMaps)
                .environment(\.analytics, analytics)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    await accounts.refresh()
                }
                .onChange(of: plus.isPlus, initial: true) {
                    offlineMaps.isEnabled = plus.isPlus
                    // Save the current store's map right away.
                    if plus.isPlus, let id = storeSelection.current?.id {
                        Task { _ = try? await api.storeLayout(storeID: id) }
                    }
                }
                .onChange(of: accounts.account?.id, initial: true) { _, id in
                    // The phone's lists, history and stats belong to one account. A guest's
                    // carry into the account they make; signing out later goes to sign-in.
                    guard let id else { return }
                    isGuest = false
                    LocalAccountData.adopt(accountID: id, .init(
                        lists: shoppingList, recents: recentSearches, storeSelection: storeSelection, offlineMaps: offlineMaps
                    ))
                }
                .onChange(of: accounts.account?.plusToken, initial: true) { _, token in
                    // Aisle+ belongs to the signed-in account; signed out, there's none.
                    plus.accountToken = token
                    Task { await PurchaseAnalytics.identify(token) }
                }
                .onOpenURL { url in
                    // A shared-list invite: https://shopaisle.app/join/K7Q2MXRT (a universal
                    // link), or aisle://join/K7Q2MX from older invites.
                    if let code = InviteLink.code(from: url) {
                        shoppingList.pendingJoinCode = code
                    }
                }
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
