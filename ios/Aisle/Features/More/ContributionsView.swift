import SwiftUI

/// Every "Found it", "Not here" and correction you've sent. Each one teaches Aisle a store.
struct ContributionsView: View {
    private var log: ContributionLog { .shared }

    var body: some View {
        MoreScreen(title: "Your contributions") {
            hero.padding(.top, 18)
            milestones.padding(.top, 12)

            if log.entries.isEmpty {
                Text("Tap “Found it” after a search to confirm a spot. It helps the next shopper.")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 24)
            } else {
                MoreSectionTitle(text: "Recent")
                MoreCard(padding: 0) {
                    ForEach(Array(log.entries.prefix(50).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().overlay(Theme.hairline).padding(.leading, 66)
                        }
                        row(entry)
                    }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                Text("Reports are sent without your name. Other shoppers only see that a spot was confirmed, never who confirmed it.")
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 20)
        }
    }

    private var hero: some View {
        let count = log.confirmedCount
        let stores = Set(log.entries.map(\.storeName)).count
        return MoreCard(padding: 20) {
            Text("\(count)")
                .font(Theme.font(64, .bold, relativeTo: .largeTitle))
                .tracking(-3)
                .foregroundStyle(Theme.accentInk)
                .contentTransition(.numericText())
            Text(count == 1 ? "spot confirmed" : "spots confirmed")
                .font(Theme.font(17, .semibold, relativeTo: .headline))
            if stores > 0 {
                Text("Across \(stores) \(stores == 1 ? "store" : "stores")")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var milestones: some View {
        let count = log.confirmedCount
        let next = ContributionLog.milestones.first { $0.count > count }
        return MoreCard(padding: 16) {
            HStack(spacing: 8) {
                ForEach(ContributionLog.milestones.indices, id: \.self) { index in
                    let milestone = ContributionLog.milestones[index]
                    let reached = count >= milestone.count
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(reached ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fill))
                            Text("\(milestone.count)")
                                .font(Theme.font(14, .bold, relativeTo: .footnote))
                                .foregroundStyle(reached ? Theme.onAccent : Theme.secondaryInk)
                        }
                        .frame(width: 40, height: 40)
                        Text(milestone.title)
                            .font(Theme.font(11, .medium, relativeTo: .caption2))
                            .foregroundStyle(reached ? Theme.ink : Theme.secondaryInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(milestone.title), \(milestone.count) spots, \(reached ? "reached" : "not yet")")
                }
            }
            if let next {
                Text("\(next.count - count) more to “\(next.title)”")
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
    }

    private func row(_ entry: ContributionLog.Entry) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if ItemIcon.assetName(for: entry.item) != nil {
                    ItemIconView(text: entry.item, size: 40, tile: true)
                } else {
                    SmallStoreLogo(url: entry.logoURL, size: 40)
                }
                Image(systemName: symbol(entry.kind))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 18, height: 18)
                    .background(entry.kind == .notHere ? AnyShapeStyle(Theme.fill) : AnyShapeStyle(Theme.accent), in: Circle())
                    .overlay(Circle().stroke(Theme.surface, lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.capitalizedFirst)
                    .font(Theme.font(16, .semibold, relativeTo: .body))
                    .lineLimit(1)
                Text([verb(entry.kind) + (entry.place.map { " · \($0)" } ?? ""), entry.storeName].joined(separator: " · "))
                    .font(Theme.font(12, relativeTo: .caption))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                .font(Theme.font(12, relativeTo: .caption))
                .foregroundStyle(Theme.secondaryInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func verb(_ kind: ContributionLog.Kind) -> String {
        switch kind {
        case .found: return "Found it"
        case .notHere: return "Not here"
        case .corrected: return "Corrected"
        }
    }

    private func symbol(_ kind: ContributionLog.Kind) -> String {
        switch kind {
        case .found: return "checkmark"
        case .notHere: return "xmark"
        case .corrected: return "arrow.triangle.2.circlepath"
        }
    }
}
