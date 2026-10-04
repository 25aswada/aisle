import SwiftUI

struct RootView: View {
    let api: AisleAPI
    let location: LocationProviding
    let analytics: AnalyticsTracking
    let recents: RecentSearches

    enum Tab: Hashable { case find, list, plus, you }

    @Environment(ShoppingListStore.self) private var list
    @State private var tab: Tab = .find

    var body: some View {
        TabView(selection: $tab) {
            FindView(api: api, location: location, analytics: analytics, recents: recents)
                .tabItem { Label("Find", systemImage: "magnifyingglass") }
                .tag(Tab.find)

            ShoppingListView(api: api, location: location, analytics: analytics)
                .tabItem { Label("List", systemImage: "checklist") }
                .tag(Tab.list)

            PlusTabView()
                .tabItem { Label("Aisle+", systemImage: "sparkles") }
                .tag(Tab.plus)

            YouView(api: api, location: location)
                .tabItem { Label("You", systemImage: "person.crop.circle") }
                .tag(Tab.you)
        }
        // A shared-list invite link opens the List tab, which shows the join sheet.
        .onChange(of: list.pendingJoinCode) {
            if list.pendingJoinCode != nil { tab = .list }
        }
        .environment(\.openTab) { tab = $0 }
        .tint(Theme.ink)
        .font(.aisleBody)
    }
}

extension EnvironmentValues {
    /// Switches the main tab, e.g. from the Aisle+ tab's shortcuts.
    @Entry var openTab: (RootView.Tab) -> Void = { _ in }
}
