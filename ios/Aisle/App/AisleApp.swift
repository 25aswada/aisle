import SwiftUI

@main
struct AisleApp: App {
    @State private var health: HealthMonitor
    @State private var storeSelection: StoreSelection
    private let api: AisleAPI
    private let location: LocationProvider

    init() {
        let api = APIClient(baseURL: AppConfig.current.apiBaseURL)
        self.api = api
        self.location = LocationProvider()
        _health = State(initialValue: HealthMonitor(api: api))
        _storeSelection = State(initialValue: StoreSelection())
    }

    var body: some Scene {
        WindowGroup {
            RootView(api: api, location: location)
                .environment(health)
                .environment(storeSelection)
                .task { await health.check() }
        }
    }
}
