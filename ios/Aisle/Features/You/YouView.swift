import SwiftUI

/// The You tab: who you are, what Aisle has helped with, your home store, appearance,
/// preferences, data and about. Deleting the account erases what's on the phone too.
struct YouView: View {
    let api: AisleAPI
    let location: LocationProviding

    @AppStorage(AppearancePreference.defaultsKey) private var appearance = AppearancePreference.system
    @AppStorage(AnalyticsClient.enabledKey) private var analyticsEnabled = true
    @AppStorage(OnboardingFlow.completedKey) private var onboardingComplete = false
    @AppStorage(ShopperStats.searchesKey) private var searches = 0
    @AppStorage(ShopperStats.confirmedKey) private var confirmed = 0
    @AppStorage(ShopperStats.storesKey) private var storeIDs = ""
    @AppStorage(ShopperStats.firstUseKey) private var firstUse: Double = 0
    @Environment(RecentSearches.self) private var recents
    @Environment(StoreSelection.self) private var storeSelection
    @Environment(AccountStore.self) private var accounts
    @Environment(PlusStore.self) private var plus
    @Environment(ShoppingListStore.self) private var lists
    @Environment(\.offlineMaps) private var offlineMaps

    @State private var isEditing = false
    @State private var isPickingStore = false
    @State private var showHowItWorks = false
    @State private var showLegal = false
    @State private var showHistory = false
    @State private var showTrips = false
    @State private var showContributions = false
    @State private var showAcknowledgements = false
    @State private var isAddingPhone = false
    @Environment(\.openURL) private var openURL
    @State private var confirmSignOut = false
    @State private var isSigningIn = false
    @State private var confirmDelete = false
    @State private var managingSubscription = false
    @State private var deleteError: String?
    @State private var scrolledUnderStatusBar: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                        .trackingScrollUnderStatusBar($scrolledUnderStatusBar)
                    if let account = accounts.account {
                        ProfileHeader(account: account)
                            .padding(.top, 26)
                    } else {
                        SignedOutCard { isSigningIn = true }
                            .padding(.top, 22)
                    }
                    if searches > 0 {
                        StatsCard(searches: searches, confirmed: confirmed, stores: ShopperStats.storeCount(storeIDs))
                            .padding(.top, 24)
                    }
                    homeStore.padding(.top, 24)
                    appearancePicker.padding(.top, 24)
                    if let account = accounts.account {
                        signIn(account).padding(.top, 24)
                    }
                    preferences.padding(.top, 24)
                    dataSection.padding(.top, 24)
                    about.padding(.top, 24)
                    if accounts.isSignedIn {
                        Button("Sign out") { confirmSignOut = true }
                            .font(.aisleHeadline)
                            .foregroundStyle(Color(hex: 0xE0607E))
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
                            .padding(.top, 26)
                            .accessibilityIdentifier("signOutButton")
                    }
                    if let since = memberSince {
                        Text(since)
                            .font(Theme.font(12, relativeTo: .caption))
                            .foregroundStyle(Theme.secondaryInk)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 14)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) { StatusBarBackdrop(scrolled: scrolledUnderStatusBar) }
            .background(AisleBackground())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $isEditing) {
                if let account = accounts.account {
                    EditProfileSheet(account: account) { name in
                        accounts.update { $0.firstName = name }
                    }
                    .presentationDetents([.medium])
                }
            }
            .sheet(isPresented: $isPickingStore) {
                StorePickerView(
                    model: StorePickerModel(api: api, location: location),
                    selected: storeSelection.current
                ) { store in
                    storeSelection.select(store)
                    isPickingStore = false
                }
            }
            .sheet(isPresented: $showLegal) { LegalDocumentSheet() }
            .sheet(isPresented: $showHistory) { SearchHistoryView(currentStoreID: storeSelection.current?.id) }
            .sheet(isPresented: $showTrips) { PastTripsView() }
            .sheet(isPresented: $showContributions) { ContributionsView() }
            .sheet(isPresented: $showAcknowledgements) { AcknowledgementsView() }
            .sheet(isPresented: $isAddingPhone) {
                AddPhoneSheet().presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showHowItWorks) {
                HowAisleWorksSheet().presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isSigningIn) {
                if let auth = accounts.auth {
                    AccountSheet(auth: auth)
                }
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                if plus.isPlus {
                    Button("Cancel Aisle+ first") { managingSubscription = true }
                }
                Button("Delete account", role: .destructive) {
                    Task { await deleteAccount() }
                }
            } message: {
                Text(plus.isPlus ? Self.deleteMessage + " " + Self.subscriptionNote : Self.deleteMessage)
            }
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
            .alert("Couldn't delete your account", isPresented: Binding(
                get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
            .confirmationDialog("Sign out of Aisle?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { accounts.signOut() }
            } message: {
                Text("Your lists and history stay on this phone for when you sign back in. If someone else signs in here, they start fresh.")
            }
        }
    }

    private var memberSince: String? {
        guard accounts.isSignedIn, firstUse > 0 else { return nil }
        let date = Date(timeIntervalSince1970: firstUse)
        return "Using Aisle since \(date.formatted(.dateTime.month(.wide).year()))"
    }

    // MARK: - Top

    private var topBar: some View {
        HStack {
            AisleWordmark(size: 26)
            Spacer()
            if accounts.isSignedIn {
                Button("Edit") { isEditing = true }
                    .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Theme.surface.opacity(0.92), in: Capsule())
                    .shadow(color: Theme.ink.opacity(0.06), radius: 12, y: 6)
            }
        }
    }

    // MARK: - Home store

    private var homeStore: some View {
        YouSection("Home store") {
            Button { isPickingStore = true } label: {
                HStack(spacing: 12) {
                    if let store = storeSelection.current {
                        RetailerLogo(url: store.retailerLogoURL, size: 44) {
                            Image(systemName: "storefront")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.name).font(Theme.font(16, .semibold, relativeTo: .body)).lineLimit(1)
                            Text(store.address).font(.aisleFootnote).foregroundStyle(Theme.secondaryInk).lineLimit(1)
                        }
                    } else {
                        IconTile(systemImage: "storefront")
                        Text("Choose your store").font(Theme.font(16, .semibold, relativeTo: .body))
                    }
                    Spacer(minLength: 8)
                    Text(storeSelection.current == nil ? "Choose" : "Change")
                        .font(Theme.font(13, .semibold, relativeTo: .footnote))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Theme.fill, in: Capsule())
                }
                .foregroundStyle(Theme.ink)
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Appearance

    private var appearancePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Appearance")
            HStack(spacing: 4) {
                ForEach(AppearancePreference.allCases) { option in
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { appearance = option }
                    } label: {
                        Text(option.label)
                            .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(appearance == option ? Theme.onAccent : Theme.secondaryInk)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background {
                                if appearance == option {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Theme.accent)
                                        .shadow(color: Theme.glow.opacity(0.2), radius: 6, y: 4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(appearance == option ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
            .sensoryFeedback(.selection, trigger: appearance)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Theme")
            .accessibilityIdentifier("appearancePicker")
        }
    }

    // MARK: - Sign-in

    /// The phone number that signs in to this account. Adding one means texting in later
    /// opens this account instead of making a new one.
    private func signIn(_ account: Account) -> some View {
        let hasPhone = account.providers.contains(.phone) && account.phone != nil
        return YouSection("Sign-in") {
            ActionRow(
                systemImage: "phone",
                title: hasPhone ? "Phone number" : "Add a phone number",
                subtitle: hasPhone
                    ? account.phone.map(ProfileHeader.formatted)
                    : "Sign in by text and land in this account"
            ) {
                isAddingPhone = true
            }
            .accessibilityIdentifier("addPhoneButton")
        }
    }

    // MARK: - Preferences

    private var preferences: some View {
        YouSection("Preferences") {
            SettingRow(systemImage: "lock.shield", title: "Share anonymous usage", subtitle: "Counts only, never what you search") {
                Toggle("", isOn: $analyticsEnabled)
                    .labelsHidden()
                    .tint(Theme.glow)
                    .accessibilityIdentifier("analyticsToggle")
            }
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        YouSection("Your data") {
            ActionRow(systemImage: "magnifyingglass", title: "Search history",
                      subtitle: historyCount(SearchHistory.shared.entries.count, "search", "searches")) {
                showHistory = true
            }
            RowDivider()
            ActionRow(systemImage: "cart", title: "Past trips",
                      subtitle: historyCount(TripHistory.shared.trips.count, "trip", "trips")) {
                showTrips = true
            }
            RowDivider()
            ActionRow(systemImage: "hand.thumbsup", title: "Your contributions",
                      subtitle: historyCount(ContributionLog.shared.confirmedCount, "spot confirmed", "spots confirmed")) {
                showContributions = true
            }
            RowDivider()
            ActionRow(systemImage: "clock.arrow.circlepath", title: "Clear search history", destructive: true) {
                withAnimation {
                    recents.clear()
                    SearchHistory.shared.clear()
                }
            }
            .disabled(recents.queries.isEmpty && SearchHistory.shared.entries.isEmpty)
            RowDivider()
            ActionRow(systemImage: "mappin.slash", title: "Forget home store", destructive: true) {
                storeSelection.clear()
            }
            .disabled(storeSelection.current == nil)
            RowDivider()
            ActionRow(systemImage: "sparkles", title: "Replay the intro") {
                onboardingComplete = false
            }
            if accounts.isSignedIn {
                RowDivider()
                ActionRow(systemImage: "person.crop.circle.badge.xmark", title: "Delete account", destructive: true) {
                    confirmDelete = true
                }
                .accessibilityIdentifier("deleteAccountButton")
            }
        }
    }

    static let deleteMessage = "This permanently deletes your Aisle account, your lists, history and stats, and ends Aisle+ on this account. Aisle starts over as if newly installed."
    static let subscriptionNote = "Apple bills Aisle+, and deleting your account doesn't cancel it. Cancel it first so you're not charged again."

    private func deleteAccount() async {
        do {
            try await accounts.deleteAccount {
                LocalAccountData.eraseForDeletedAccount(.init(
                    lists: lists, recents: recents, storeSelection: storeSelection, offlineMaps: offlineMaps
                ))
            }
        } catch {
            deleteError = (error as? LocalizedError)?.errorDescription ?? "Couldn't delete your account. Try again."
        }
    }

    // MARK: - About

    private var about: some View {
        YouSection("About") {
            ActionRow(systemImage: "info.circle", title: "How Aisle finds things",
                      subtitle: "Estimates unless confirmed. Never a made-up aisle.") {
                showHowItWorks = true
            }
            RowDivider()
            ActionRow(systemImage: "doc.text", title: "Terms & Privacy",
                      subtitle: "What you agreed to, in plain English") {
                showLegal = true
            }
            RowDivider()
            if let url = ReviewPrompter.writeReviewURL {
                ActionRow(systemImage: "star", title: "Rate Aisle", subtitle: "Takes a few seconds, helps a lot") {
                    openURL(url)
                }
                RowDivider()
            }
            ActionRow(systemImage: "text.book.closed", title: "Acknowledgements",
                      subtitle: "Fonts, icons and open-source code") {
                showAcknowledgements = true
            }
            RowDivider()
            SettingRow(systemImage: "number", title: "Version", subtitle: nil) {
                Text(Self.version)
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    private func historyCount(_ count: Int, _ one: String, _ many: String) -> String? {
        count == 0 ? nil : "\(count) \(count == 1 ? one : many)"
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Profile header

private struct ProfileHeader: View {
    let account: Account

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(AngularGradient(
                        colors: [Color(hex: 0xE2CFF9), Theme.glow, Color(hex: 0xFFDDC6), Color(hex: 0xFFEDC2), Color(hex: 0xE2CFF9)],
                        center: .center
                    ))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                Circle().fill(Theme.background).padding(4)
                Circle().fill(Theme.accent).padding(9)
                Text(account.initial)
                    .font(Theme.font(40, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.onAccent)
            }
            .frame(width: 108, height: 108)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) { spin = true }
            }

            Text(account.firstName)
                .font(Theme.font(30, .bold, relativeTo: .largeTitle))
                .tracking(-0.8)
                .foregroundStyle(Theme.ink)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            if let contact = account.email ?? account.phone.map(Self.formatted) {
                Text(contact)
                    .font(Theme.font(14, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 4)
            }
            Label("Signed in with \(account.provider.label)", systemImage: providerSymbol)
                .font(Theme.font(12, .semibold, relativeTo: .caption))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Theme.fill, in: Capsule())
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
    }

    private var providerSymbol: String {
        switch account.provider {
        case .apple: return "apple.logo"
        case .google: return "g.circle"
        case .phone: return "phone"
        case .email: return "envelope"
        }
    }

    /// "+12155550123" as "(215) 555-0123"; other countries as stored.
    static func formatted(_ phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        guard phone.hasPrefix("+1"), digits.count == 11 else { return phone }
        let d = Array(digits.dropFirst())
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }
}

private struct SignedOutCard: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AisleMark(size: 22)
                Text("Make Aisle yours")
                    .font(Theme.font(20, .bold, relativeTo: .title3))
            }
            Text("Aisle needs a free account. Sign in to share lists with family and keep Aisle+ on a new phone.")
                .font(Theme.font(15, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Button("Create an account or sign in", action: onCreate)
                .buttonStyle(.aisleAccent)
                .accessibilityIdentifier("createAccountRowButton")
        }
        .foregroundStyle(Theme.ink)
        .padding(18)
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 16, y: 8)
    }
}

// MARK: - Stats

private struct StatsCard: View {
    let searches: Int
    let confirmed: Int
    let stores: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image("AisleLogo")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text("Your Aisle").font(Theme.font(13, .semibold, relativeTo: .footnote))
            }
            HStack(alignment: .top, spacing: 8) {
                stat(searches, searches == 1 ? "item found" : "items found")
                stat(confirmed, confirmed == 1 ? "spot confirmed" : "spots confirmed")
                stat(stores, stores == 1 ? "store" : "stores")
            }
            Text(confirmed > 0
                 ? "Each “Found it” you tap makes Aisle more sure for the next shopper."
                 : "Tap “Found it” when you spot an item to make Aisle more sure for the next shopper.")
                .font(Theme.font(13, relativeTo: .footnote))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .foregroundStyle(Theme.onAccent)
        .padding(18)
        .background(
            ZStack(alignment: .topTrailing) {
                Theme.accent
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 80))
                    .frame(width: 160, height: 160)
                    .offset(x: 40, y: -40)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        )
        .shadow(color: Theme.glow.opacity(0.22), radius: 18, y: 12)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(Theme.font(32, .bold, relativeTo: .largeTitle))
                .tracking(-1.2)
                .contentTransition(.numericText(value: Double(value)))
            Text(label)
                .font(Theme.font(12, relativeTo: .caption))
                .opacity(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Building blocks

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.font(13, .bold, relativeTo: .footnote))
            .tracking(0.4)
            .foregroundStyle(Theme.secondaryInk)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct YouSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title)
            VStack(spacing: 0) { content() }
                .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
        }
    }
}

/// A row's glyph, bare, in a fixed-width slot so the row text lines up.
private struct IconTile: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
    }
}

private struct SettingRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(16, .medium, relativeTo: .body)).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(Theme.font(12, relativeTo: .caption)).foregroundStyle(Theme.secondaryInk)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
    }
}

private struct ActionRow: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var destructive = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(systemImage: systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.font(16, .medium, relativeTo: .body))
                        .foregroundStyle(destructive ? Color(hex: 0xE0607E) : Theme.ink)
                    if let subtitle {
                        Text(subtitle).font(Theme.font(12, relativeTo: .caption)).foregroundStyle(Theme.secondaryInk)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 60)
    }
}

// MARK: - Sheets

private struct EditProfileSheet: View {
    let account: Account
    let onSave: (String) -> Void

    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit profile")
                .font(Theme.font(24, .bold, relativeTo: .title))
                .padding(.top, 24)
            Text("First name")
                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(Theme.secondaryInk)
            TextField("First name", text: $name)
                .textContentType(.givenName)
                .submitLabel(.done)
                .modifier(OnboardingFieldStyle())
            Spacer()
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { onSave(trimmed) }
                dismiss()
            }
            .buttonStyle(.aisleAccent)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .background(AisleBackground())
        .onAppear { name = account.firstName }
    }
}

/// Adds a phone number to the signed-in account: the number, then the texted code.
private struct AddPhoneSheet: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss

    @State private var phone = ""
    @State private var code = ""
    @State private var sentTo: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var hasPhone: Bool { accounts.account?.providers.contains(.phone) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sentTo == nil ? (hasPhone ? "Change your number" : "Add your number") : "Check your texts")
                .font(Theme.font(24, .bold, relativeTo: .title))
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)
            if let sentTo {
                (Text("Enter the 6-digit code we sent to ")
                    + Text(sentTo).font(Theme.font(15, .semibold)).foregroundStyle(Theme.ink)
                    + Text("."))
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .modifier(OnboardingFieldStyle())
                    .accessibilityLabel("Verification code")
                    .accessibilityIdentifier("addPhoneCodeField")
                    .onChange(of: code) {
                        let digits = String(code.filter(\.isNumber).prefix(6))
                        if digits != code { code = digits }
                        if code.count == 6 { verify() }
                    }
            } else {
                Text("Signing in with a code texted to this number will open this account, with your lists and history, instead of making a new one.")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("(215) 555-0123", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($focused)
                    .modifier(OnboardingFieldStyle())
                    .accessibilityLabel("Mobile number")
                    .accessibilityIdentifier("addPhoneField")
                Text("US numbers work as is. For others, start with + and the country code.")
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: sentTo == nil ? send : verify) {
                if isWorking { ProgressView() } else { Text(sentTo == nil ? "Text me a code" : "Add number") }
            }
            .buttonStyle(.aisleAccent)
            .disabled(isWorking || (sentTo == nil ? !SignUpModel.looksLikePhone(phone) : code.count < 6))
            .accessibilityIdentifier("addPhoneSubmitButton")
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .background(AisleBackground())
        // Focus the number field, then the code field once it appears.
        .task(id: sentTo) { focused = true }
    }

    private func send() {
        guard SignUpModel.looksLikePhone(phone), !isWorking else { return }
        run {
            sentTo = try await accounts.sendAddPhoneCode(to: phone).sentTo
        }
    }

    private func verify() {
        guard code.count == 6, !isWorking else { return }
        run {
            try await accounts.addPhone(phone, code: code)
            dismiss()
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await work()
            } catch AuthError.signedOut {
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? AuthError.network.errorDescription
                code = ""
            }
        }
    }
}

private struct HowAisleWorksSheet: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("How Aisle finds things")
                    .font(Theme.font(26, .bold, relativeTo: .title))
                    .padding(.top, 24)
                point("Confident", "The store's own data or shoppers have confirmed this spot.", level: 3)
                point("Likely here", "We know the department, usually from the store's layout, but not the exact shelf.", level: 2)
                point("Best guess", "Based on how similar stores are laid out. We say so, and suggest asking someone.", level: 1)
                Text("Aisle never makes up an aisle number. When you tap “Found it” or correct a spot, the next shopper gets a surer answer.")
                    .font(Theme.font(15, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .foregroundStyle(Theme.ink)
        .background(AisleBackground())
    }

    private func point(_ title: String, _ text: String, level: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ConfidenceBars(level: level, height: 16)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.aisleHeadline)
                Text(text)
                    .font(Theme.font(15, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
