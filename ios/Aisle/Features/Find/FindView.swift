import SwiftUI

struct FindView: View {
    let api: AisleAPI
    let location: LocationProviding

    @Environment(StoreSelection.self) private var storeSelection
    @Environment(HealthMonitor.self) private var health
    @State private var isPickingStore = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                CurrentStoreCard(store: storeSelection.current) {
                    isPickingStore = true
                }

                if storeSelection.current == nil {
                    Text("Choose a store to start finding items.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if health.status == .unreachable {
                    ServerStatusNote { Task { await health.check() } }
                }
            }
            .padding()
            .navigationTitle("Find")
            .sheet(isPresented: $isPickingStore) {
                StorePickerView(
                    model: StorePickerModel(api: api, location: location),
                    selected: storeSelection.current
                ) { store in
                    storeSelection.select(store)
                    isPickingStore = false
                }
            }
        }
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
