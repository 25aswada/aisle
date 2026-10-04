import SwiftUI

struct StorePickerView: View {
    @State var model: StorePickerModel
    let selected: Store?
    /// Ask for location as soon as the picker opens (the user tapped "Find stores near me").
    var startsWithLocation = false
    let onSelect: (Store) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    searchSection
                } else {
                    nearbySection
                }
                // Store locations come from OpenStreetMap, whose license asks for this credit.
                Section {} footer: {
                    Text("Store locations © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright)")
                        .font(.caption2)
                }
            }
            .aislePage()
            .tint(Theme.ink)
            .navigationTitle("Choose a store")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search stores by name or address"
            )
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if startsWithLocation, model.locationAuthorization == .notDetermined {
                    await model.requestLocationAndLoadNearby()
                } else {
                    await model.start()
                }
            }
            .task(id: query) {
                // Debounce keystrokes; `.task(id:)` cancels the previous run.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await model.search(query)
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var nearbySection: some View {
        Section {
            switch model.locationAuthorization {
            case .notDetermined:
                Button {
                    Task { await model.requestLocationAndLoadNearby() }
                } label: {
                    Label("Use my location to find nearby stores", systemImage: "location")
                }
                .accessibilityIdentifier("useLocationButton")
            case .denied, .restricted:
                Text("Location is off for Aisle. Search above to find your store.")
                    .foregroundStyle(.secondary)
            case .authorized:
                phaseRows(model.nearby, emptyMessage: "No stores found nearby. Try searching above.") {
                    Task { await model.loadNearby() }
                }
            }
        } header: {
            Text("Nearby")
        } footer: {
            if model.locationAuthorization == .notDetermined {
                Text("Optional. You can always search for a store instead.")
            }
        }
    }

    private var searchSection: some View {
        Section("Results") {
            phaseRows(model.searchResults, emptyMessage: "No stores match “\(query)”.") {
                Task { await model.search(query) }
            }
        }
    }

    @ViewBuilder
    private func phaseRows(
        _ phase: StorePickerModel.Phase,
        emptyMessage: String,
        retry: @escaping () -> Void
    ) -> some View {
        switch phase {
        case .idle:
            EmptyView()
        case .loading:
            HStack {
                ProgressView()
                Text("Loading…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).foregroundStyle(.secondary)
                Button("Try again", action: retry)
            }
        case .loaded(let stores) where stores.isEmpty:
            Text(emptyMessage).foregroundStyle(.secondary)
        case .loaded(let stores):
            ForEach(stores) { store in
                Button { onSelect(store) } label: {
                    StoreRow(store: store, isSelected: store.id == selected?.id)
                }
                .buttonStyle(.plain)
                // The selected store is marked by the soft gradient on its whole row.
                .listRowBackground(store.id == selected?.id ? Rectangle().fill(Theme.accentWash) : nil)
            }
        }
    }
}

struct StoreRow: View {
    let store: Store
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            RetailerLogo(url: store.retailerLogoURL) {
                Text(String(store.name.prefix(1)).uppercased())
                    .font(Theme.font(24, .bold, relativeTo: .title2))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.name)
                    .font(.aisleHeadline)
                    .foregroundStyle(Theme.ink)
                Text(store.address)
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(2)
                if let retailer = store.retailerName, retailer != store.name {
                    Text(retailer)
                        .font(.aisleCaption)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let miles = store.distanceMiles {
                    Text(Self.format(miles: miles))
                        .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                        .monospacedDigit()
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .accessibilityLabel("Selected")
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    static func format(miles: Double) -> String {
        miles < 10
            ? String(format: "%.1f mi", miles)
            : String(format: "%.0f mi", miles)
    }
}
