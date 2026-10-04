import SwiftUI

/// Finished Start Shopping trips on this phone: where, how long, what was found.
struct PastTripsView: View {
    @Environment(ShoppingListStore.self) private var list
    @State private var expanded: UUID?
    @State private var addedTrip: UUID?

    private var history: TripHistory { .shared }

    private var thisMonth: [TripHistory.Trip] {
        let calendar = Calendar.current
        return history.trips.filter { calendar.isDate($0.endedAt, equalTo: .now, toGranularity: .month) }
    }

    var body: some View {
        MoreScreen(title: "Past trips") {
            if history.trips.isEmpty {
                empty.padding(.top, 60)
            } else {
                stats.padding(.top, 18)
                MoreSectionTitle(text: "Trips")
                VStack(spacing: 12) {
                    ForEach(history.trips) { trip in
                        card(trip)
                    }
                }
                Text("Trips are saved on this phone when you finish Start Shopping.")
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 20)
            }
        }
        .onAppear { expanded = expanded ?? history.trips.first?.id }
    }

    private var stats: some View {
        let trips = thisMonth
        let found = trips.reduce(0) { $0 + $1.foundCount }
        let minutes = trips.isEmpty ? 0 : trips.reduce(0) { $0 + $1.minutes } / trips.count
        return MoreCard(padding: 18) {
            Text("THIS MONTH")
                .font(Theme.font(11, .semibold, relativeTo: .caption2))
                .tracking(1)
                .foregroundStyle(Theme.secondaryInk)
                .padding(.bottom, 10)
            HStack(alignment: .top) {
                GradientFigure(value: "\(trips.count)", caption: trips.count == 1 ? "trip" : "trips")
                GradientFigure(value: "\(found)", caption: "items found")
                GradientFigure(value: trips.isEmpty ? "–" : "\(minutes)m", caption: "avg. trip")
            }
        }
    }

    private func card(_ trip: TripHistory.Trip) -> some View {
        let isOpen = expanded == trip.id
        return MoreCard(padding: 16) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded = isOpen ? nil : trip.id }
            } label: {
                HStack(spacing: 12) {
                    HStack(spacing: -8) {
                        ForEach(Array(trip.logoURLs.prefix(3).enumerated()), id: \.offset) { _, url in
                            SmallStoreLogo(url: url, size: 36)
                                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.surface, lineWidth: 2))
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trip.storeNames.joined(separator: " → "))
                            .font(Theme.font(16, .semibold, relativeTo: .body))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text("\(trip.endedAt.formatted(date: .abbreviated, time: .shortened)) · \(trip.listName)")
                            .font(Theme.font(12, relativeTo: .caption))
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.secondaryInk)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            progress(trip).padding(.top, 14)

            if isOpen {
                FlowLayout(spacing: 6) {
                    ForEach(Array(trip.items.enumerated()), id: \.offset) { _, item in
                        chip(item)
                    }
                }
                .padding(.top, 14)
                .transition(.opacity)

                let missed = trip.items.filter { !$0.found }
                Button {
                    let source = missed.isEmpty ? trip.items : missed
                    list.add(source.map { ParsedListItem(text: $0.text, quantity: nil, category: nil) })
                    withAnimation { addedTrip = trip.id }
                } label: {
                    Label(addedTrip == trip.id ? "Added to your list" : (missed.isEmpty ? "Add these to my list again" : "Add the \(missed.count) missed to my list"),
                          systemImage: addedTrip == trip.id ? "checkmark" : "plus")
                }
                .buttonStyle(.aisleSoft)
                .disabled(addedTrip == trip.id)
                .padding(.top, 14)
            }
        }
        .contextMenu {
            Button("Remove trip", systemImage: "trash", role: .destructive) {
                withAnimation { history.remove(trip.id) }
            }
        }
    }

    private func progress(_ trip: TripHistory.Trip) -> some View {
        let total = max(trip.items.count, 1)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule().fill(Theme.accent)
                        .frame(width: proxy.size.width * CGFloat(trip.foundCount) / CGFloat(total))
                }
            }
            .frame(height: 6)
            HStack {
                Text("\(trip.foundCount) of \(trip.items.count) found")
                Spacer()
                Text("\(trip.minutes) min")
            }
            .font(Theme.font(12, .medium, relativeTo: .caption))
            .foregroundStyle(Theme.secondaryInk)
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ item: TripHistory.Item) -> some View {
        HStack(spacing: 5) {
            ItemIconView(text: item.text, size: 16)
            Text(item.text)
                .strikethrough(!item.found, color: Theme.secondaryInk)
        }
        .font(Theme.font(13, .medium, relativeTo: .footnote))
        .foregroundStyle(item.found ? Theme.ink : Theme.secondaryInk)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.fill, in: Capsule())
        .accessibilityLabel("\(item.text), \(item.found ? "found" : "not found")")
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "cart")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
            Text("No trips yet")
                .font(Theme.font(18, .bold, relativeTo: .headline))
            Text("Finish a Start Shopping trip and it shows up here.")
                .font(.aisleSubheadline)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
