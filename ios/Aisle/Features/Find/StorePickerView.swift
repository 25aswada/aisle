import SwiftUI

struct StorePickerView: View {
    @State var model: StorePickerModel
    let selected: Store?
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
            }
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
            .task { await model.start() }
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
            }
        }
    }
}

struct StoreRow: View {
    let store: Store
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.name).font(.body)
                Text(store.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let retailer = store.retailerName, retailer != store.name {
                    Text(retailer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let miles = store.distanceMiles {
                    Text(Self.format(miles: miles))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
        }
        .contentShape(Rectangle())
    }

    static func format(miles: Double) -> String {
        miles < 10
            ? String(format: "%.1f mi", miles)
            : String(format: "%.0f mi", miles)
    }
}
