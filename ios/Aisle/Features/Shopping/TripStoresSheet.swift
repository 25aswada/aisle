import SwiftUI

/// Choose the stores for a multi-store trip (Aisle+), in the order you'll visit them.
/// Each item on the list goes to the first store likely to carry it.
struct TripStoresSheet: View {
    static let maxStores = 4

    let api: AisleAPI
    let location: LocationProviding
    let onStart: ([Store]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stores: [Store]
    @State private var picking = false

    init(api: AisleAPI, location: LocationProviding, first: Store?, onStart: @escaping ([Store]) -> Void) {
        self.api = api
        self.location = location
        self.onStart = onStart
        _stores = State(initialValue: first.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(stores.enumerated()), id: \.element.id) { index, store in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(Theme.font(14, .bold, relativeTo: .subheadline))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 26, height: 26)
                                .background(Theme.accent, in: Circle())
                                .accessibilityHidden(true)
                            StoreRow(store: store, isSelected: false)
                        }
                    }
                    .onDelete { stores.remove(atOffsets: $0) }
                    .onMove { stores.move(fromOffsets: $0, toOffset: $1) }

                    if stores.count < Self.maxStores {
                        Button {
                            picking = true
                        } label: {
                            Label(stores.isEmpty ? "Add a store" : "Add another store", systemImage: "plus")
                        }
                        .accessibilityIdentifier("addTripStoreButton")
                    }
                } header: {
                    Text("Stores, in order")
                } footer: {
                    Text("Each item goes to the first store likely to carry it, and each store gets its own route. Drag to change the order. Up to \(Self.maxStores) stores.")
                }
            }
            .aislePage()
            .tint(Theme.ink)
            .environment(\.editMode, .constant(stores.count > 1 ? .active : .inactive))
            .navigationTitle("Multi-store trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let chosen = stores
                    dismiss()
                    onStart(chosen)
                } label: {
                    Text(stores.count < 2 ? "Add at least 2 stores" : "Start shopping · \(stores.count) stores")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aisleAccent)
                .disabled(stores.count < 2)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier("startTripButton")
            }
            .sheet(isPresented: $picking) {
                StorePickerView(model: StorePickerModel(api: api, location: location), selected: nil) { store in
                    if !stores.contains(where: { $0.id == store.id }), stores.count < Self.maxStores {
                        stores.append(store)
                    }
                    picking = false
                }
            }
        }
    }
}
