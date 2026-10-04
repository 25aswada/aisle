import SwiftUI

/// The shopping list: a progress card with Start Shopping, an add bar that takes whole
/// lists, items grouped by department, and checked items folded into "Done".
struct ShoppingListView: View {
    let api: AisleAPI
    let location: LocationProviding
    let analytics: AnalyticsTracking

    @Environment(ShoppingListStore.self) private var list
    @Environment(StoreSelection.self) private var storeSelection
    @Environment(RecentSearches.self) private var recents
    @State private var composer: ListComposerModel
    @State private var trip: ShoppingTripModel?
    @State private var showNeedsStore = false
    @State private var showDone = false
    @FocusState private var composerFocused: Bool
    @State private var scrolledUnderStatusBar: CGFloat = 0
    @State private var isScanning = false
    @State private var confirmingNewList = false
    @Environment(PlusStore.self) private var plus
    @Environment(AccountStore.self) private var accounts
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ListSheet?
    @State private var confirmingDelete = false
    @State private var sharingError: String?

    /// The list screens' sheets, one at a time.
    enum ListSheet: Identifiable {
        case share, join(String), rename, signIn, tripStores, pastTrips
        var id: String {
            switch self {
            case .tripStores: return "tripStores"
            case .pastTrips: return "pastTrips"
            case .share: return "share"
            case .join(let code): return "join-\(code)"
            case .rename: return "rename"
            case .signIn: return "signIn"
            }
        }
    }

    init(api: AisleAPI, location: LocationProviding, analytics: AnalyticsTracking) {
        self.api = api
        self.location = location
        self.analytics = analytics
        _composer = State(initialValue: ListComposerModel(api: api, analytics: analytics))
    }

    private var groups: [(name: String, items: [ListItem])] {
        var order: [String] = []
        var byName: [String: [ListItem]] = [:]
        for item in list.remaining {
            let name = item.categoryName?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Other"
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(item)
        }
        // "Other" last; everything else keeps the order it was added in.
        let sorted = order.filter { $0 != "Other" } + order.filter { $0 == "Other" }
        return sorted.map { ($0, byName[$0] ?? []) }
    }

    private var done: [ListItem] { list.items.filter(\.isDone) }

    private var suggestions: [String] {
        let have = Set(list.items.map { $0.text.lowercased() })
        return Array(recents.queries.filter { !have.contains($0.lowercased()) }.prefix(5))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .trackingScrollUnderStatusBar($scrolledUnderStatusBar)
                    if !list.items.isEmpty {
                        ProgressCard(
                            total: list.items.count, left: list.remaining.count,
                            departments: groups.count, storeName: storeSelection.current?.name,
                            isPlus: plus.isPlus,
                            onStart: startShopping,
                            onMultiStore: multiStoreTapped
                        )
                        .padding(.top, 20)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                    }
                    composerBar.padding(.top, 18)
                    if list.items.isEmpty {
                        EmptyListCard(onTemplate: addText)
                            .padding(.top, 26)
                            .transition(.opacity.combined(with: .offset(y: 10)))
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.name) { index, group in
                        DepartmentSection(name: group.name, colorIndex: index, items: group.items)
                            .padding(.top, 24)
                    }
                    if !done.isEmpty {
                        doneSection.padding(.top, 22)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .animation(.spring(response: 0.45, dampingFraction: 0.86), value: list.items)
                .animation(.spring(response: 0.45, dampingFraction: 0.86), value: showDone)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) { StatusBarBackdrop(scrolled: scrolledUnderStatusBar) }
            .background(AisleBackground())
            .toolbar(.hidden, for: .navigationBar)
            .cameraOverlay(isPresented: $isScanning) { photo in
                Task { await composer.add(photo: photo, to: list) }
            }
            .plusUpgradeSheet(reason: $composer.upgradePrompt)
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .share: ShareListSheet().presentationDetents([.large])
                case .join(let code): JoinListSheet(code: code).presentationDetents([.medium, .large])
                case .rename: RenameListSheet().presentationDetents([.medium])
                case .signIn:
                    if let auth = accounts.auth { AccountSheet(auth: auth) }
                case .tripStores:
                    TripStoresSheet(api: api, location: location, first: storeSelection.current) { stores in
                        composerFocused = false
                        trip = ShoppingTripModel(api: api, stores: stores, list: list, analytics: analytics)
                    }
                    .presentationDetents([.large])
                case .pastTrips:
                    PastTripsView()
                }
            }
            .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(deleteAction, role: .destructive) {
                    Task {
                        do { try await list.deleteCurrent() } catch {
                            sharingError = (error as? LocalizedError)?.errorDescription ?? "Couldn't do that. Try again."
                        }
                    }
                }
            } message: {
                Text(deleteMessage)
            }
            .alert("Couldn't share", isPresented: Binding(get: { sharingError != nil }, set: { if !$0 { sharingError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sharingError ?? "")
            }
            // Shared lists: pick up the family's changes while the list is open.
            .task(id: list.current.shared?.serverID) {
                guard list.current.shared != nil else { return }
                while !Task.isCancelled {
                    await list.refreshShared()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            .task(id: accounts.account?.id) {
                if accounts.isSignedIn { await list.refreshMemberships() }
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active { Task { await list.refreshShared() } }
            }
            .task(id: list.pendingJoinCode) {
                // An invite link (also when it opened the app on this tab).
                guard let code = list.pendingJoinCode else { return }
                list.pendingJoinCode = nil
                sheet = accounts.isSignedIn ? .join(code) : .signIn
            }
            .sensoryFeedback(.impact(weight: .light), trigger: list.remaining.count)
            .fullScreenCover(item: $trip) { trip in
                ShoppingModeView(model: trip)
            }
            .alert("Choose a store first", isPresented: $showNeedsStore) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Pick your store on the Find tab, then start shopping.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                AisleWordmark(size: 26)
                Spacer()
                if !list.items.isEmpty || list.lists.count > 1 {
                    Button(action: newListTapped) {
                        Label("New list", systemImage: "square.and.pencil")
                            .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(Theme.surface.opacity(0.9), in: Capsule())
                            .shadow(color: Theme.ink.opacity(0.06), radius: 12, y: 6)
                    }
                    .buttonStyle(PressableCardStyle())
                    .accessibilityIdentifier("newListButton")
                    .confirmationDialog(
                        "Start a new list?", isPresented: $confirmingNewList, titleVisibility: .visible
                    ) {
                        Button("Start over", role: .destructive, action: startNewList)
                        Button("Keep more lists with Aisle+") {
                            composer.upgradePrompt = "Keep a list for every store and occasion with Aisle+."
                        }
                    } message: {
                        Text("Starting over clears all \(list.items.count) \(list.items.count == 1 ? "item" : "items") on your list. With Aisle+ you can keep more than one list.")
                    }
                }
                Menu {
                    if list.current.shared != nil {
                        Button("Sharing…", systemImage: "person.2") { sheet = .share }
                    } else {
                        Button("Share with family…", systemImage: "person.2.badge.plus") { shareTapped() }
                    }
                    Button("Join a shared list…", systemImage: "person.crop.circle.badge.plus") {
                        sheet = accounts.isSignedIn ? .join("") : .signIn
                    }
                    Button("Rename list…", systemImage: "pencil") { sheet = .rename }
                    Button("Past trips", systemImage: "clock.arrow.circlepath") { sheet = .pastTrips }
                    Divider()
                    Button("Clear checked items", systemImage: "checkmark.circle") { list.clearCompleted() }
                        .disabled(done.isEmpty)
                    Button("Clear all", systemImage: "trash", role: .destructive) { list.clearAll() }
                        .disabled(list.items.isEmpty)
                    if list.lists.count > 1 || list.current.shared != nil {
                        Button(deleteAction, systemImage: "xmark.bin", role: .destructive) { confirmingDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .background(Theme.surface.opacity(0.9), in: Circle())
                        .shadow(color: Theme.ink.opacity(0.06), radius: 12, y: 6)
                }
                .accessibilityLabel("List options")
            }
            listTitle
                .padding(.top, 20)
            if let with = list.current.shared?.withLabel {
                Label(with, systemImage: "person.2.fill")
                    .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.accentInk)
                    .padding(.top, 6)
            }
            if let problem = list.syncProblem {
                Label(problem, systemImage: "arrow.triangle.2.circlepath")
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 6)
            }
            if let store = storeSelection.current {
                HStack(spacing: 8) {
                    RetailerLogo(url: store.retailerLogoURL, size: 22) {
                        Image(systemName: "storefront").font(.system(size: 11, weight: .semibold))
                    }
                    Text("for \(store.name)").lineLimit(1)
                }
                .font(Theme.font(14, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 6)
            }
        }
    }

    // MARK: - Add bar

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityHidden(true)
                TextField("Add items, like milk, eggs, bread", text: $composer.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.aisleBody)
                    .foregroundStyle(Theme.ink)
                    .focused($composerFocused)
                    .submitLabel(.done)
                    .textInputAutocapitalization(.never)
                    .onSubmit(submit)
                    .accessibilityIdentifier("listComposerField")
                CameraButton(action: scanList)
                    .disabled(composer.isAdding)
                    .accessibilityLabel("Scan a written list")
                    .accessibilityIdentifier("listCameraButton")
                if composer.isAdding {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 44, height: 44)
                            .background(Theme.accent, in: Circle())
                    }
                    .disabled(composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add")
                    .accessibilityIdentifier("listAddButton")
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .frame(minHeight: 58)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 29, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 29, style: .continuous).strokeBorder(Theme.accentRing, lineWidth: 1.5))
            .shadow(color: Theme.glow.opacity(0.10), radius: 14, y: 8)

            if composer.isReadingPhoto {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your list…")
                }
                .font(.aisleFootnote)
                .foregroundStyle(Theme.secondaryInk)
                .padding(.leading, 6)
                .accessibilityElement(children: .combine)
            } else if let photoNotice = composer.photoNotice {
                HStack(spacing: 10) {
                    Label(photoNotice.message, systemImage: photoNotice.added.isEmpty ? "exclamationmark.triangle" : "text.viewfinder")
                        .font(.aisleFootnote)
                        .foregroundStyle(Theme.secondaryInk)
                    Spacer(minLength: 0)
                    if !photoNotice.added.isEmpty {
                        Button("Undo") { withAnimation { composer.undoPhoto(in: list) } }
                            .font(Theme.font(13, .semibold, relativeTo: .footnote))
                            .foregroundStyle(Theme.ink)
                            .accessibilityLabel("Undo adding items from the photo")
                    }
                    Button { composer.dismissPhotoNotice() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.secondaryInk)
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("Dismiss")
                }
                .padding(.leading, 6)
            } else if let notice = composer.notice {
                Label(notice, systemImage: "wifi.slash")
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.leading, 6)
            } else if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button { addText(suggestion) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Color(hex: 0xDC6F9C))
                                    Text(suggestion)
                                }
                                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                                .foregroundStyle(Theme.ink)
                                .padding(.leading, 10)
                                .padding(.trailing, 13)
                                .frame(height: 34)
                                .background(Theme.fill, in: Capsule())
                            }
                            .buttonStyle(PressableCardStyle())
                            .accessibilityLabel("Add \(suggestion)")
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
    }

    // MARK: - Done

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { showDone.toggle() } label: {
                HStack(spacing: 8) {
                    Text("Done · \(done.count)")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(showDone ? 180 : 0))
                }
                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Theme.fill, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showDone ? "Hides checked items" : "Shows checked items")
            if showDone {
                ItemsCard(items: done)
                    .opacity(0.8)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
    }

    // MARK: - Actions

    private func submit() {
        Task { await composer.add(to: list) }
    }

    /// Clears the list and puts the cursor in the add bar for the first item.
    /// "Your list" for a single list of your own; otherwise the list's name, which switches lists.
    @ViewBuilder
    private var listTitle: some View {
        if list.lists.count == 1 && list.current.shared == nil {
            (Text("Your ") + Text("list").foregroundStyle(Theme.accentInk))
                .font(Theme.font(34, .bold, relativeTo: .largeTitle))
                .tracking(-1)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
        } else {
            Menu {
                ForEach(list.lists) { item in
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { list.select(item.id) }
                    } label: {
                        if item.id == list.currentID {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Label(item.name, systemImage: item.shared == nil ? "list.bullet" : "person.2")
                        }
                    }
                }
                Divider()
                Button("New list", systemImage: "plus", action: newListTapped)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(list.current.name)
                        .font(Theme.font(34, .bold, relativeTo: .largeTitle))
                        .tracking(-1)
                        .foregroundStyle(Theme.accentInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.ink)
                }
            }
            .accessibilityLabel("List: \(list.current.name). Switch lists")
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// Aisle+ adds another list; the free tier has one, so it's start over or upgrade.
    private func newListTapped() {
        if plus.isPlus {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                list.createList()
                composer.dismissPhotoNotice()
                showDone = false
            }
            composerFocused = true
        } else if list.items.isEmpty && list.ownLists.count <= 1 {
            composerFocused = true
        } else {
            confirmingNewList = true
        }
    }

    /// Sharing needs an account (to know who's on the list) and Aisle+ (the server checks too).
    private func shareTapped() {
        guard accounts.isSignedIn else {
            sheet = .signIn
            return
        }
        guard plus.isPlus else {
            composer.upgradePrompt = "Sharing lists with your family is part of Aisle+."
            return
        }
        Task {
            do {
                try await list.shareCurrent()
                sheet = .share
            } catch APIError.plusRequired(_, let message) {
                composer.upgradePrompt = message
            } catch {
                sharingError = (error as? LocalizedError)?.errorDescription ?? "Couldn't share the list. Try again."
            }
        }
    }

    private var deleteTitle: String {
        guard let shared = list.current.shared else { return "Delete “\(list.current.name)”?" }
        return shared.isOwner ? "Delete “\(list.current.name)” for everyone?" : "Leave “\(list.current.name)”?"
    }

    private var deleteAction: String {
        guard let shared = list.current.shared else { return "Delete list" }
        return shared.isOwner ? "Delete for everyone" : "Leave list"
    }

    private var deleteMessage: String {
        guard let shared = list.current.shared else { return "Its items are removed from this phone." }
        return shared.isOwner ? "Everyone on the list loses it." : "The others keep the list."
    }

    private func startNewList() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            list.clearAll()
            composer.dismissPhotoNotice()
            showDone = false
        }
        composerFocused = true
    }

    /// Opens the camera over the list; the overlay slides its own card up.
    private func scanList() {
        composerFocused = false
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { isScanning = true }
    }

    private func addText(_ text: String) {
        composer.draft = text
        submit()
    }

    private func startShopping() {
        composerFocused = false
        guard let store = storeSelection.current else {
            showNeedsStore = true
            return
        }
        trip = ShoppingTripModel(api: api, store: store, list: list, analytics: analytics)
    }

    /// Several stores in one trip is Aisle+; free shoppers get the offer.
    private func multiStoreTapped() {
        composerFocused = false
        if plus.isPlus {
            sheet = .tripStores
        } else {
            composer.upgradePrompt = "Shopping more than one store in a trip is part of Aisle+."
        }
    }
}

extension ShoppingTripModel: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Progress card

private struct ProgressCard: View {
    let total: Int
    let left: Int
    let departments: Int
    let storeName: String?
    let isPlus: Bool
    let onStart: () -> Void
    let onMultiStore: () -> Void

    private var fraction: Double { total == 0 ? 0 : Double(total - left) / Double(total) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Theme.onAccent.opacity(0.12), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Theme.onAccent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: fraction)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Theme.font(15, .bold, relativeTo: .subheadline))
                        .contentTransition(.numericText(value: fraction))
                }
                .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(left == 0 ? "All done!" : "\(left) \(left == 1 ? "item" : "items") left")
                        .font(Theme.font(22, .bold, relativeTo: .title2))
                        .tracking(-0.4)
                        .contentTransition(.numericText(value: Double(left)))
                    Text(summary)
                        .font(Theme.font(13, relativeTo: .footnote))
                        .opacity(0.75)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)

            Button(action: onStart) {
                Label("Start shopping · best route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.aisleHeadline)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color(hex: 0x1F1B24), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableCardStyle())
            .disabled(left == 0)
            .opacity(left == 0 ? 0.5 : 1)
            .accessibilityIdentifier("startShoppingButton")

            Button(action: onMultiStore) {
                HStack(spacing: 6) {
                    Image(systemName: "storefront")
                    Text("Shop at more than one store")
                    if !isPlus {
                        Text("Aisle+")
                            .font(Theme.font(11, .bold, relativeTo: .caption2))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.onAccent.opacity(0.14), in: Capsule())
                    }
                }
                .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(left == 0)
            .opacity(left == 0 ? 0.5 : 1)
            .accessibilityIdentifier("multiStoreButton")
        }
        .foregroundStyle(Theme.onAccent)
        .padding(18)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.glow.opacity(0.22), radius: 18, y: 12)
    }

    private var summary: String {
        let depts = "\(departments) \(departments == 1 ? "department" : "departments")"
        return storeName.map { "\(depts) · sorted for \($0)" } ?? depts
    }
}

// MARK: - Sections and rows

private struct DepartmentSection: View {
    let name: String
    let colorIndex: Int
    let items: [ListItem]

    private static let dots: [Color] = [
        Color(hex: 0xE2CFF9), Color(hex: 0xF9CFE0), Color(hex: 0xFFDDC6),
        Color(hex: 0xFFEDC2), Color(hex: 0xD9E4F7), Color(hex: 0xD7EFDF),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Self.dots[colorIndex % Self.dots.count]).frame(width: 8, height: 8)
                Text(name.uppercased()).fontWeight(.bold)
                Text("· \(items.count)")
            }
            .font(Theme.font(13, .medium, relativeTo: .footnote))
            .tracking(0.3)
            .foregroundStyle(Theme.secondaryInk)
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ItemsCard(items: items)
        }
    }
}

private struct ItemsCard: View {
    let items: [ListItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                ListItemRow(item: item)
                if index < items.count - 1 {
                    Divider().overlay(Theme.hairline).padding(.leading, 54)
                }
            }
        }
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
    }
}

/// One item: a gradient check, the name (editable in place) and its quantity.
struct ListItemRow: View {
    let item: ListItem

    @Environment(ShoppingListStore.self) private var list
    @State private var text = ""
    @State private var showingDetails = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    list.setDone(item.id, !item.isDone)
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Theme.secondaryInk.opacity(0.45), lineWidth: 2)
                        .opacity(item.isDone ? 0 : 1)
                    Circle()
                        .fill(Theme.accent)
                        .scaleEffect(item.isDone ? 1.05 : 0.3)
                        .opacity(item.isDone ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Theme.onAccent)
                        .scaleEffect(item.isDone ? 1 : 0.4)
                        .opacity(item.isDone ? 1 : 0)
                }
                .frame(width: 26, height: 26)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark \(item.text) as not done" : "Mark \(item.text) as done")

            // The item's picture when there is one; no placeholder otherwise.
            ItemIconView(text: item.text, size: 26)
                .opacity(item.isDone ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 1) {
                TextField("Item", text: $text)
                    .font(Theme.font(17, relativeTo: .body))
                    .focused($editing)
                    .strikethrough(item.isDone, color: Color(hex: 0xDC6F9C).opacity(0.7))
                    .foregroundStyle(item.isDone ? Theme.secondaryInk : Theme.ink)
                    .submitLabel(.done)
                    .onSubmit { list.rename(item.id, to: text) }
                    .accessibilityLabel("Item name")
                if let detail = detailLine {
                    Text(detail)
                        .font(Theme.font(12, relativeTo: .caption))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }
            }

            if let quantity = item.quantity, !quantity.isEmpty {
                Text(quantity)
                    .font(Theme.font(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 9)
                    .frame(minWidth: 28, minHeight: 26)
                    .background(Theme.fill, in: Capsule())
                    .accessibilityLabel("Quantity \(quantity)")
            }

            Button { showingDetails = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Theme.secondaryInk.opacity(0.8))
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Details for \(item.text)")

            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { list.remove(item.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk.opacity(0.7))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.text)")
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(minHeight: 56)
        .contextMenu {
            Button("Details", systemImage: "info.circle") { showingDetails = true }
            Button("Remove", systemImage: "trash", role: .destructive) { list.remove(item.id) }
        }
        .sheet(isPresented: $showingDetails) {
            ListItemDetailSheet(itemID: item.id)
        }
        .onAppear { text = item.text }
        .onChange(of: item.text) { text = item.text }
        .onChange(of: editing) { _, isEditing in
            if !isEditing { list.rename(item.id, to: text) }
        }
    }
}

extension ListItemRow {
    /// "Horizon Organic · lactose-free" under the name, when the item has details.
    var detailLine: String? {
        let parts = [item.brand, item.note].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Empty

private struct EmptyListCard: View {
    let onTemplate: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            illustration
            Text("Start a list")
                .font(Theme.font(22, .bold, relativeTo: .title2))
                .foregroundStyle(Theme.ink)
                .padding(.top, 18)
            Text("Type or paste a whole list at once. Aisle sorts it by department and plans the shortest walk.")
                .font(Theme.font(15, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Text("Or start from")
                .font(Theme.font(12, .semibold, relativeTo: .caption))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 18)
            FlowLayout(spacing: 8) {
                ForEach(ListStarter.all) { starter in
                    Button(starter.title) { onTemplate(starter.items) }
                        .font(Theme.font(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Theme.fill, in: Capsule())
                        .buttonStyle(PressableCardStyle())
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 22)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 16, y: 8)
    }

    private var illustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.fill)
                .frame(width: 140, height: 112)
                .rotationEffect(.degrees(-7))
                .offset(x: 6, y: 4)
            VStack(alignment: .leading, spacing: 12) {
                fakeRow(done: true, width: 70)
                fakeRow(done: false, width: 90)
                fakeRow(done: false, width: 56)
            }
            .padding(.horizontal, 16)
            .frame(width: 148, height: 116, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Theme.glow.opacity(0.18), radius: 15, y: 10)
            .rotationEffect(.degrees(4))
        }
        .frame(height: 128)
        .accessibilityHidden(true)
    }

    private func fakeRow(done: Bool, width: CGFloat) -> some View {
        HStack(spacing: 10) {
            if done {
                Circle().fill(Theme.accent).frame(width: 16, height: 16)
            } else {
                Circle().strokeBorder(Theme.hairline, lineWidth: 2).frame(width: 16, height: 16)
            }
            Capsule().fill(Theme.fill).frame(width: width, height: 8)
        }
    }
}
