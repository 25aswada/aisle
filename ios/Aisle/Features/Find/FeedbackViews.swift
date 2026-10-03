import SwiftUI

/// "Found it" / "Not here" buttons and the follow-up states below a result.
struct FeedbackBar: View {
    let state: FindModel.FeedbackState
    let onFound: () -> Void
    let onNotHere: () -> Void
    let onCorrect: () -> Void

    var body: some View {
        switch state {
        case .none, .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text("Was it there?")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 10) {
                    Button(action: onFound) {
                        Label("Found it", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("foundItButton")

                    Button(action: onNotHere) {
                        Label("Not here", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("notHereButton")
                }
                .controlSize(.large)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        case .sending:
            HStack(spacing: 8) {
                ProgressView()
                Text("Sending…").foregroundStyle(.secondary)
            }
        case .confirmed:
            Label("Thanks! That helps other shoppers.", systemImage: "hand.thumbsup.fill")
                .foregroundStyle(.green)
        case .reportedMissing:
            VStack(alignment: .leading, spacing: 8) {
                Label("Thanks for letting us know.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                Button("Tell us where you found it", action: onCorrect)
                    .accessibilityIdentifier("correctLocationButton")
            }
        case .corrected(let zone):
            Label("Thanks! We noted it's in \(zone).", systemImage: "hand.thumbsup.fill")
                .foregroundStyle(.green)
        }
    }
}

/// Correction entry: pick the department where the item really was, plus optional aisle text.
struct CorrectionSheet: View {
    let api: AisleAPI
    let storeID: String
    let item: String
    let onSubmit: (StoreZone, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var zones: [StoreZone] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var selected: StoreZone?
    @State private var aisle = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isLoading {
                        HStack { ProgressView(); Text("Loading departments…").foregroundStyle(.secondary) }
                    } else if let loadError {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(loadError).foregroundStyle(.secondary)
                            Button("Try again") { Task { await load() } }
                        }
                    } else {
                        ForEach(zones) { zone in
                            Button {
                                selected = zone
                            } label: {
                                HStack {
                                    Text(zone.name).foregroundStyle(.primary)
                                    Spacer()
                                    if selected == zone {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .accessibilityAddTraits(selected == zone ? .isSelected : [])
                        }
                    }
                } header: {
                    Text("Where did you find \(item)?")
                }
                Section {
                    TextField("Aisle or sign, if you saw one (optional)", text: $aisle)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Only enter what's posted in the store. Aisle text appears once other shoppers agree.")
                }
            }
            .navigationTitle("Correct location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        if let selected {
                            onSubmit(selected, String(aisle.prefix(40)))
                            dismiss()
                        }
                    }
                    .disabled(selected == nil)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            zones = try await api.zones(storeID: storeID)
        } catch {
            loadError = "Couldn't load this store's departments."
        }
        isLoading = false
    }
}
