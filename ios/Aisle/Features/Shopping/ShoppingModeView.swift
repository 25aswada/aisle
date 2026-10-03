import SwiftUI

/// Full-screen Start Shopping mode: one stop at a time, Found / Skip per item, progress at the top.
struct ShoppingModeView: View {
    @State var model: ShoppingTripModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.storeName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("End") { dismiss() }
                            .accessibilityIdentifier("endShoppingButton")
                    }
                }
        }
        .task {
            if model.phase == .loading { await model.start() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Planning your route…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't plan a route", systemImage: "map")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.start() } }
                    .buttonStyle(.borderedProminent)
                Button("Shop in list order") { model.shopWithoutRoute() }
            }
        case .shopping:
            if model.isFinished {
                TripSummary(model: model) { dismiss() }
            } else {
                tripList
            }
        }
    }

    private var tripList: some View {
        List {
            Section {
                TripProgress(model: model)
            }

            if let index = model.currentStopIndex {
                let stop = model.stops[index]
                Section {
                    ForEach(model.pendingItems(in: stop)) { item in
                        TripItemRow(
                            text: item.text,
                            detail: detail(for: item),
                            onFound: { withAnimation { model.markFound(item.id) } },
                            onSkip: { withAnimation { model.skip(item.id) } }
                        )
                    }
                } header: {
                    StopHeader(stop: stop, number: index + 1, count: model.stops.count, unrouted: model.isUnrouted)
                }
            }

            if !model.upcomingStops.isEmpty {
                Section("Up next") {
                    ForEach(model.upcomingStops) { stop in
                        HStack {
                            Text(stop.department)
                            Spacer()
                            Text("\(model.pendingItems(in: stop).count) items")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if model.currentStopIndex == nil, !model.pendingUnplaced.isEmpty {
                Section {
                    ForEach(model.pendingUnplaced) { item in
                        TripItemRow(
                            text: item.text,
                            detail: item.reason == .notCarried
                                ? "This store may not carry this."
                                : "We don't know where this is. Ask a store employee.",
                            onFound: { withAnimation { model.markFound(item.id) } },
                            onSkip: { withAnimation { model.skip(item.id) } }
                        )
                    }
                } header: {
                    Text("Not on the map")
                }
            } else if !model.pendingUnplaced.isEmpty {
                Section {
                    Text("\(model.pendingUnplaced.count) items we couldn't place come last.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detail(for item: RouteStopItem) -> String? {
        var parts: [String] = []
        if let aisle = item.aisle {
            parts.append([aisle, item.section].compactMap { $0 }.joined(separator: " · "))
        }
        if !item.neighbors.isEmpty {
            parts.append("Near \(item.neighbors.prefix(3).joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}

private struct TripProgress: View {
    let model: ShoppingTripModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(model.foundCount) of \(model.totalCount) found")
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                if model.skippedCount > 0 {
                    Text("\(model.skippedCount) skipped")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: model.progress)
                .tint(.green)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.foundCount) of \(model.totalCount) found, \(model.skippedCount) skipped")
        .accessibilityIdentifier("tripProgress")
    }
}

private struct StopHeader: View {
    let stop: RouteStop
    let number: Int
    let count: Int
    let unrouted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(unrouted ? "No route available" : "Stop \(number) of \(count)")
                .font(.caption)
            Text(stop.department)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct TripItemRow: View {
    let text: String
    let detail: String?
    let onFound: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text.capitalized)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            AdaptiveStack {
                Button(action: onFound) {
                    Label("Found", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityLabel("Found \(text)")

                Button(action: onSkip) {
                    Label("Skip", systemImage: "forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Skip \(text)")
            }
            .controlSize(.large)
        }
        .padding(.vertical, 4)
    }
}

private struct TripSummary: View {
    let model: ShoppingTripModel
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: model.skippedCount == 0 ? "checkmark.circle.fill" : "flag.checkered")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(model.skippedCount == 0 ? "All done!" : "Trip complete")
                    .font(.title.weight(.bold))
                Text("Found \(model.foundCount) of \(model.totalCount) items.")
                    .foregroundStyle(.secondary)
                if !model.skippedTexts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Skipped").font(.headline)
                        ForEach(model.skippedTexts, id: \.self) { Text("• \($0)") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    Button("Look for skipped items again") { withAnimation { model.retrySkipped() } }
                }
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding()
        }
    }
}
