import SwiftUI

// Pieces of the Find home screen: a time-of-day line, a search hint that cycles
// through examples, recent searches that show where things were, and a small
// 3D model of the current store.

// MARK: - Greeting

/// A short line above the headline that fits the time of day.
struct TimeGreeting: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.line(for: context.date))
                .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
        }
    }

    static func line(for date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<11: return "Good morning"
        case 11..<14: return "Midday run?"
        case 14..<17: return "Good afternoon"
        case 17..<21: return "Good evening"
        default: return "Late-night run?"
        }
    }
}

// MARK: - Cycling hint

/// "Try 'maple syrup'" and friends, fading from one to the next. Shown while the field is empty.
struct RotatingSearchHint: View {
    static let examples = ["maple syrup", "birthday candles", "AA batteries", "oat milk", "sunscreen"]

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Text("Try")
            Text("“\(Self.examples[index])”")
                .id(index)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 8)),
                    removal: .opacity.combined(with: .offset(y: -8))
                ))
        }
        .font(.aisleBody)
        .foregroundStyle(Theme.secondaryInk.opacity(0.85))
        .lineLimit(1)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2.6)) } catch { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
                    index = (index + 1) % Self.examples.count
                }
            }
        }
    }
}

// MARK: - Recent searches with answers

/// Two columns of cards: the item, where it was (in the accent gradient) and the department.
struct RecentAnswerGrid: View {
    let recents: RecentSearches
    let storeID: String?
    let onSelect: (String) -> Void

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent")
                    .font(Theme.font(22, .bold, relativeTo: .title2))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear") {
                    withAnimation(.easeInOut(duration: 0.25)) { recents.clear() }
                }
                .font(.aisleSubheadline)
                .foregroundStyle(Theme.secondaryInk)
                .accessibilityLabel("Clear recent searches")
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(recents.queries.prefix(6)), id: \.self) { query in
                    RecentAnswerCard(query: query, answer: recents.answer(for: query, storeID: storeID)) {
                        onSelect(query)
                    }
                    .contextMenu {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            withAnimation { recents.remove(query) }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("recentSearches")
    }
}

private struct RecentAnswerCard: View {
    let query: String
    let answer: RecentAnswer?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(query)
                        .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let answer {
                        ConfidenceBars(level: answer.confidence.level, height: 11)
                    }
                }
                if let answer {
                    placeText(answer)
                    Text(answer.detail ?? " ")
                        .font(Theme.font(12, relativeTo: .caption))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                } else {
                    // Searched before answers were saved, or at another store.
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(height: 28, alignment: .leading)
                    Text("Search again")
                        .font(Theme.font(12, relativeTo: .caption))
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(answer.map { "\(query), \($0.place), \($0.confidence.shortLabel)" } ?? query)
        .accessibilityHint("Searches again")
    }

    private func placeText(_ answer: RecentAnswer) -> some View {
        Text(answer.place)
            .font(Theme.font(24, .bold, relativeTo: .title2))
            .tracking(-0.6)
            .foregroundStyle(Theme.accentInk)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Cards shrink a touch while pressed.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Store at a glance

/// A small, slowly turning 3D model of the current store, with its departments as buttons.
struct StoreGlanceCard: View {
    let layout: StoreLayout
    let storeName: String
    let retailer: String
    let onOpenMap: () -> Void
    let onDepartment: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(retailer) at a glance")
                    .font(Theme.font(22, .bold, relativeTo: .title2))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Open map", action: onOpenMap)
                    .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
            }
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onOpenMap) {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        FloorPlanView(
                            layout: layout, targetZoneID: nil, pinTitle: "",
                            tilt: 1, yaw: reduceMotion ? 0 : 6 * sin(t * 2 * .pi / 9)
                        )
                    }
                    .frame(height: 250)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(storeName) map")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(layout.placedZones) { zone in
                            Button(zone.name) { onDepartment(zone.name) }
                                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(Theme.fill, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                }
                Text(layout.approximate ? "Typical layout · approximate · tap a department to ask" : "This store's layout · tap a department to ask")
                    .font(Theme.font(11, relativeTo: .caption2))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Theme.ink.opacity(0.06), radius: 16, y: 8)
        }
    }
}

/// Full-screen store map with no item: top down or 3D, draggable in 3D.
struct StoreGlanceMap: View {
    let layout: StoreLayout
    let storeName: String

    @State private var tilted = true
    @State private var yaw: Double = 0
    @State private var dragStart: Double = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Theme.surface, in: Circle())
                }
                .accessibilityLabel("Close")
                Spacer()
                Text(storeName)
                    .font(Theme.font(17, .bold, relativeTo: .headline))
                    .lineLimit(1)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 20)

            Picker("View", selection: Binding(get: { tilted }, set: { value in
                withAnimation(.spring(response: 0.8, dampingFraction: 0.86)) {
                    tilted = value
                    if !value { yaw = 0; dragStart = 0 }
                }
            })) {
                Text("3D").tag(true)
                Text("Top down").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            FloorPlanView(layout: layout, targetZoneID: nil, pinTitle: "", tilt: tilted ? 1 : 0, yaw: tilted ? yaw : 0)
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { yaw = min(max(dragStart + $0.translation.width * 0.25, -40), 40) }
                        .onEnded { _ in dragStart = yaw },
                    including: tilted ? .all : .none
                )

            Label(layout.approximate ? "Typical layout · approximate" : "This store's layout", systemImage: "map")
                .font(.aisleFootnote)
                .foregroundStyle(Theme.secondaryInk)
                .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .foregroundStyle(Theme.ink)
        .background(AisleBackground())
    }
}
