import SwiftUI

struct YouView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "You",
                systemImage: "person.crop.circle",
                description: Text("Profile and settings are coming soon.")
            )
            .navigationTitle("You")
        }
    }
}
