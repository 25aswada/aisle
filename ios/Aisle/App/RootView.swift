import SwiftUI

struct RootView: View {
    let api: AisleAPI
    let location: LocationProviding
    let analytics: AnalyticsTracking
    let recents: RecentSearches

    var body: some View {
        TabView {
            FindView(api: api, location: location, analytics: analytics, recents: recents)
                .tabItem { Label("Find", systemImage: "magnifyingglass") }

            ShoppingListView(api: api, analytics: analytics)
                .tabItem { Label("List", systemImage: "checklist") }

            PlusTabView()
                .tabItem { Label("Aisle+", systemImage: "sparkles") }

            YouView(api: api, location: location)
                .tabItem { Label("You", systemImage: "person.crop.circle") }
        }
        .tint(Theme.ink)
        .font(.aisleBody)
    }
}
