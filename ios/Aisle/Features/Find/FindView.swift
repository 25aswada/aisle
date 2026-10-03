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
                VStack(alignment: .leading, spacing: 16) {
                    CurrentStoreCard(store: storeSelection.current) {
                        isPickingStore = true
                    }

                    if let store = storeSelection.current {
                        ItemSearchField(query: $model.query, focused: $searchFocused) {
                            runSearch(store: store)
                        } onClear: {
                            model.clear()
                        }
                        resultSection(store: store)
                    } else {
                        Text("Choose a store to start finding items.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
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
                Text("Search for an item to see where it usually is in \(store.name).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                RecentSearchList(recents: model.recents) { query in
                    searchFocused = false
                    Task { await model.searchRecent(query, storeID: store.id) }
                }
            }
        case .loading:
            SearchResultCard(result: .placeholder, storeName: nil)
                .redacted(reason: .placeholder)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Finding \(model.trimmedQuery)")
                .overlay(alignment: .topTrailing) { ProgressView().padding() }
        case .loaded(let result):
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
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Try again") { runSearch(store: store) }
            }
        }
    }
}

struct RecentSearchList: View {
    let recents: RecentSearches
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent searches")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Clear") { recents.clear() }
                    .font(.subheadline)
                    .accessibilityLabel("Clear recent searches")
            }
            ForEach(recents.queries, id: \.self) { query in
                Button { onSelect(query) } label: {
                    Label(query, systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
                .accessibilityHint("Searches again")
                .contextMenu { Button("Remove", systemImage: "trash", role: .destructive) { recents.remove(query) } }
            }
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search for an item, like maple syrup", text: $query)
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("itemSearchField")
            if !query.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CurrentStoreCard: View {
    let store: Store?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "storefront")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store == nil ? "No store selected" : "Current store")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(store?.name ?? "Choose a store")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let address = store?.address {
                        Text(address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                Text(store == nil ? "Choose" : "Change")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
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
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("serverStatusNote")
    }
}
