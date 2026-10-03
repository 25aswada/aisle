import SwiftUI

/// Settings. Aisle has no accounts; everything here stays on the device.
struct YouView: View {
    @AppStorage(AppearancePreference.defaultsKey) private var appearance = AppearancePreference.system
    @AppStorage(AnalyticsClient.enabledKey) private var analyticsEnabled = true
    @Environment(RecentSearches.self) private var recents
    @Environment(StoreSelection.self) private var storeSelection

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppearancePreference.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appearancePicker")
                }

                Section {
                    Toggle("Share anonymous usage data", isOn: $analyticsEnabled)
                        .tint(Theme.toggleOn)
                        .accessibilityIdentifier("analyticsToggle")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Counts of searches, list use, and shopping trips. Never what you search for. No account is needed.")
                }

                Section("Data on this device") {
                    Button("Clear recent searches", role: .destructive) { recents.clear() }
                        .disabled(recents.queries.isEmpty)
                    Button("Forget selected store", role: .destructive) { storeSelection.clear() }
                        .disabled(storeSelection.current == nil)
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                } footer: {
                    Text("Locations are estimates unless marked as store data or confirmed by shoppers. Aisle never guesses aisle numbers.")
                }
            }
            .aislePage()
            .tint(Theme.ink)
            .navigationTitle("You")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
