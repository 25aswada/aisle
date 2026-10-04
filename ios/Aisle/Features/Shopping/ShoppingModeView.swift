import SwiftUI

/// Full-screen Start Shopping mode: one stop at a time, Found / Skip per item, progress at the top.
struct ShoppingModeView: View {
    @State var model: ShoppingTripModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .aislePage()
                .tint(Theme.ink)
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
                    .tint(Theme.secondaryInk)
                Text("Planning your route…")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            AisleEmptyState(title: "Couldn't plan a route", systemImage: "map", message: message) {
                Button("Try again") { Task { await model.start() } }
                    .buttonStyle(.aisleAccent)
                Button("Shop in list order") { model.shopWithoutRoute() }
                    .buttonStyle(.aisleSoft)
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)
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

            if let next = model.nextLeg {
                Section {
                    NextStoreCard(done: model.storeName, next: next) {
                        Task { await model.goToNextStore() }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if let layout = model.layout, !model.isUnrouted, !model.isCurrentLegDone {
                Section {
                    StoreMapCard(
                        layout: layout,
                        retailer: model.retailerName,
                        highlighted: Set(model.currentStopIndex.flatMap { model.stops[$0].zoneID }.map { [$0] } ?? []),
                        completed: Set(model.stops.filter { model.pendingItems(in: $0).isEmpty }.compactMap(\.zoneID)),
                        route: model.stops.compactMap(\.zoneID),
                        height: 240
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
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
                    StopHeader(
                        stop: stop, number: index + 1, count: model.stops.count, unrouted: model.isUnrouted,
                        storeLabel: model.isMultiStore ? model.retailerName : nil
                    )
                }
            }

            if !model.upcomingStops.isEmpty {
                Section("Up next") {
                    ForEach(model.upcomingStops) { stop in
                        HStack {
                            Text(stop.department)
                            Spacer()
                            Text(itemCount(model.pendingItems(in: stop).count))
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
                            detail: model.isNowhere(item.id)
                                ? "None of your stores is likely to carry this. Ask an employee."
                                : item.reason == .notCarried
                                ? "\(model.retailerName) typically doesn't carry this. Ask an employee."
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
                    Text(model.pendingUnplaced.count == 1
                        ? "1 item we couldn't place comes last."
                        : "\(model.pendingUnplaced.count) items we couldn't place come last.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func itemCount(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
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
                    .font(.aisleHeadline)
                    .monospacedDigit()
                Spacer()
                if model.skippedCount > 0 {
                    Text("\(model.skippedCount) skipped")
                        .font(.aisleSubheadline)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: model.progress)
                .tint(Color(hex: 0xDC6F9C))
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
    /// The store's name on a multi-store trip.
    var storeLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(unrouted ? "No route available" : [storeLabel, "Stop \(number) of \(count)"].compactMap { $0 }.joined(separator: " · "))
                .font(.aisleCaption)
                .foregroundStyle(Theme.secondaryInk)
            // Explicit ink: `.primary` inside a List section header renders muted.
            Text(stop.department)
                .font(.aisleTitle)
                .foregroundStyle(Theme.ink)
                .textCase(nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Done at one store on a multi-store trip: where to go next.
private struct NextStoreCard: View {
    let done: String
    let next: TripLeg
    let onGo: () -> Void

    private var itemCount: Int {
        next.stops.reduce(0) { $0 + $1.items.count } + next.unplaced.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RetailerLogo(url: next.store.retailerLogoURL) {
                    Image(systemName: "storefront")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: 44, height: 44)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Done at \(done)")
                        .font(.aisleFootnote)
                        .foregroundStyle(Theme.secondaryInk)
                    Text("Next: \(next.store.name)")
                        .font(.aisleHeadline)
                        .foregroundStyle(Theme.ink)
                    Text(itemCount == 1 ? "1 item to find there" : "\(itemCount) items to find there")
                        .font(.aisleSubheadline)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            Button(action: onGo) {
                Label("I'm at \(next.store.retailerDisplayName)", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.aisleAccent)
            .accessibilityIdentifier("nextStoreButton")
            Button {
                let address = next.store.address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let url = URL(string: "maps://?daddr=\(address)") { UIApplication.shared.open(url) }
            } label: {
                Label("Directions", systemImage: "car.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.aisleSoft)
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
                .font(.aisleHeadline)
            if let detail {
                Text(detail)
                    .font(.aisleSubheadline)
                    .foregroundStyle(.secondary)
            }
            AdaptiveStack {
                Button(action: onFound) {
                    Label("Found", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aisleAccent)
                .accessibilityLabel("Found \(text)")

                Button(action: onSkip) {
                    Label("Skip", systemImage: "forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aisleSoft)
                .accessibilityLabel("Skip \(text)")
            }
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
                    .foregroundStyle(Theme.accentInk)
                    .accessibilityHidden(true)
                Text(model.skippedCount == 0 ? "All done!" : "Trip complete")
                    .font(.aisleLargeTitle)
                Text("Found \(model.foundCount) of \(model.totalCount) items.")
                    .foregroundStyle(.secondary)
                if !model.skippedTexts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Skipped").font(.aisleHeadline)
                        ForEach(model.skippedTexts, id: \.self) { Text("• \($0)") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    Button("Look for skipped items again") { withAnimation { model.retrySkipped() } }
                }
                Button("Done", action: onDone)
                    .buttonStyle(.aisleAccent)
            }
            .padding()
        }
    }
}
