import SwiftUI

struct FindView: View {
    let api: AisleAPI
    let location: LocationProviding
    let analytics: AnalyticsTracking

    @Environment(StoreSelection.self) private var storeSelection
    @Environment(HealthMonitor.self) private var health
    @State private var isPickingStore = false
    @State private var model: FindModel
    @State private var isCorrecting = false
    @FocusState private var searchFocused: Bool

    init(api: AisleAPI, location: LocationProviding, analytics: AnalyticsTracking, recents: RecentSearches) {
        self.api = api
        self.location = location
        self.analytics = analytics
        _model = State(initialValue: FindModel(api: api, analytics: analytics, recents: recents))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AisleWordmark()

                    CurrentStoreCard(store: storeSelection.current) {
                        isPickingStore = true
                    }

                    if let store = storeSelection.current {
                        if model.phase == .idle {
                            title
                        }
                        ItemSearchField(query: $model.query, focused: $searchFocused) {
                            runSearch(store: store)
                        } onClear: {
                            model.clear()
                        }
                        resultSection(store: store)
                    } else {
                        Text("Choose a store to start finding items.")
                            .font(.aisleSubheadline)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.25), value: model.phase)
            }
            .safeAreaInset(edge: .top, spacing: 0) { StatusBarBackdrop() }
            .background(AisleBackground())
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if health.status == .unreachable {
                    ServerStatusNote { Task { await health.check() } }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .navigationTitle("Find")
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: storeSelection.current?.id) { model.clear() }
            .sheet(isPresented: $isPickingStore) {
                StorePickerView(
                    model: StorePickerModel(api: api, location: location),
                    selected: storeSelection.current
                ) { store in
                    storeSelection.select(store)
                    analytics.track(.storeSelected, ["nearby": .bool(store.distanceMiles != nil)])
                    isPickingStore = false
                }
            }
        }
    }

    private var title: some View {
        (Text("What are you ") + Text("looking for?").foregroundStyle(Theme.accentInk))
            .font(Theme.font(36, .bold, relativeTo: .largeTitle))
            .tracking(-1)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

extension FindView {
    private func runSearch(store: Store) {
        searchFocused = false
        Task { await model.search(storeID: store.id) }
    }

    @ViewBuilder
    private func resultSection(store: Store) -> some View {
        switch model.phase {
        case .idle:
            if model.recents.queries.isEmpty {
                Text("Ask for any item and Aisle will tell you where it usually is in \(store.name).")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                RecentSearchList(recents: model.recents) { query in
                    searchFocused = false
                    Task { await model.searchRecent(query, storeID: store.id) }
                }
            }
        case .loading:
            QueryBubble(text: model.trimmedQuery)
            AisleReply {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking in \(store.name)…")
                }
            }
            SearchResultCard(result: .placeholder, storeName: nil)
                .redacted(reason: .placeholder)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Finding \(model.trimmedQuery)")
        case .loaded(let result):
            QueryBubble(text: result.query.isEmpty ? result.item : result.query)
            AisleReply {
                Text(result.replyText)
            }
            SearchResultCard(result: result, storeName: store.name)
            FeedbackBar(
                state: model.feedback,
                onFound: { Task { await model.confirmFound(storeID: store.id) } },
                onNotHere: { Task { await model.reportNotHere(storeID: store.id) } },
                onCorrect: { isCorrecting = true }
            )
            .sheet(isPresented: $isCorrecting) {
                CorrectionSheet(api: api, storeID: store.id, item: result.item) { zone, aisle in
                    Task { await model.submitCorrection(storeID: store.id, zone: zone, aisle: aisle) }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                Button("Try again") { runSearch(store: store) }
                    .buttonStyle(.aisleSoft)
            }
        }
    }
}

struct RecentSearchList: View {
    let recents: RecentSearches
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent")
                    .font(Theme.font(22, .bold, relativeTo: .title2))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button("Clear") { recents.clear() }
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .accessibilityLabel("Clear recent searches")
            }
            VStack(spacing: 0) {
                ForEach(Array(recents.queries.enumerated()), id: \.element) { index, query in
                    Button { onSelect(query) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 40, height: 40)
                                .background(Theme.tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Text(query)
                                .font(.aisleBody)
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Searches again")
                    .contextMenu { Button("Remove", systemImage: "trash", role: .destructive) { recents.remove(query) } }
                    if index < recents.queries.count - 1 {
                        Divider().overlay(Theme.hairline).padding(.leading, 68)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .accessibilityIdentifier("recentSearches")
    }
}

struct ItemSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.ink)
            TextField("Ask Aisle, like “maple syrup”", text: $query)
                .font(.aisleBody)
                .foregroundStyle(Theme.ink)
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("itemSearchField")
            if !query.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryInk)
                }
                .accessibilityLabel("Clear search")
            }
            Button(action: onSubmit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: Circle())
            }
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Search")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(minHeight: 58)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.accentRing, lineWidth: 1.5))
        .shadow(color: Theme.glow.opacity(0.10), radius: 14, y: 8)
    }
}

private struct CurrentStoreCard: View {
    let store: Store?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "storefront")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 46, height: 46)
                    .background(Theme.tile, in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(store == nil ? "No store selected" : "You're shopping at")
                        .font(.aisleCaption)
                        .foregroundStyle(Theme.secondaryInk)
                    HStack(spacing: 4) {
                        Text(store?.name ?? "Choose a store")
                            .font(Theme.font(20, .bold, relativeTo: .title3))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.ink)
                    }
                    if let address = store?.address {
                        Text(address)
                            .font(.aisleFootnote)
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("currentStoreButton")
        .accessibilityHint("Opens the store picker")
    }
}

/// A low-key notice when `/health` fails. Never blocks the UI.
private struct ServerStatusNote: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text("Can't reach the Aisle server.")
            Spacer(minLength: 0)
            Button("Retry", action: onRetry)
                .foregroundStyle(Theme.ink)
        }
        .font(.aisleFootnote)
        .foregroundStyle(Theme.secondaryInk)
        .accessibilityIdentifier("serverStatusNote")
    }
}
