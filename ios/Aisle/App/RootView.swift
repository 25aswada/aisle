import SwiftUI

struct RootView: View {
    let api: AisleAPI
    let location: LocationProviding

    var body: some View {
        TabView {
            FindView(api: api, location: location)
                .tabItem { Label("Find", systemImage: "magnifyingglass") }

            ShoppingListView(api: api)
                .tabItem { Label("List", systemImage: "checklist") }

            YouView()
                .tabItem { Label("You", systemImage: "person.crop.circle") }
        }
    }
}
