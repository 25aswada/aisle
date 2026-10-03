import SwiftUI

struct ListPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Your list",
                systemImage: "checklist",
                description: Text("Shopping lists are coming soon.")
            )
            .navigationTitle("List")
        }
    }
}
