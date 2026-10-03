import SwiftUI

/// Settings and the optional account. Lists and searches stay on the device.
struct YouView: View {
    @AppStorage(AppearancePreference.defaultsKey) private var appearance = AppearancePreference.system
    @AppStorage(AnalyticsClient.enabledKey) private var analyticsEnabled = true
    @Environment(RecentSearches.self) private var recents
    @Environment(StoreSelection.self) private var storeSelection
    @Environment(AccountStore.self) private var accounts
    @AppStorage(OnboardingFlow.completedKey) private var onboardingComplete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let account = accounts.account {
                        HStack(spacing: 12) {
                            Text(account.initial)
                                .font(Theme.font(17, .bold, relativeTo: .headline))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 40, height: 40)
                                .background(Theme.accent, in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.firstName)
                                    .font(.aisleHeadline)
                                Text(account.email ?? "Signed in with \(account.provider.label)")
                                    .font(.aisleFootnote)
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        Button("Sign out", role: .destructive) { accounts.signOut() }
                            .accessibilityIdentifier("signOutButton")
                    } else {
                        Button("Create an account or sign in") { onboardingComplete = false }
                            .accessibilityIdentifier("createAccountRowButton")
                    }
                }

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
