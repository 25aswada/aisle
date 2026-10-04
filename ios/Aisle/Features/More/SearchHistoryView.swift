import SwiftUI

/// Every search on this phone, newest first, grouped by day. Tap one to search it again.
struct SearchHistoryView: View {
    var currentStoreID: String?
    /// Searches again at the current store. Without it, rows are read-only.
    var onSearch: ((String) -> Void)? = nil

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", thisStore = "This store", photos = "Photos"
        var id: Self { self }
    }

    @State private var filter: Filter = .all
    @State private var text = ""
    @State private var confirmClear = false

    private var history: SearchHistory { .shared }

    private var filtered: [SearchHistory.Entry] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return history.entries.filter { entry in
            switch filter {
            case .all: break
            case .thisStore: if entry.storeID != currentStoreID { return false }
            case .photos: if !entry.isPhoto { return false }
            }
            guard !needle.isEmpty else { return true }
            return entry.query.lowercased().contains(needle) || entry.item.lowercased().contains(needle)
                || entry.storeName.lowercased().contains(needle)
        }
    }

    private struct Day: Identifiable {
        let id: Date
        let label: String
        let entries: [SearchHistory.Entry]
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            Day(id: day, label: Self.dayLabel(day), entries: grouped[day] ?? [])
        }
    }

    var body: some View {
        MoreScreen(title: "Search history") {
            Button("Clear") { confirmClear = true }
                .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
                .disabled(history.entries.isEmpty)
        } content: {
            Text(summary)
                .font(.aisleSubheadline)
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 4)

            searchField.padding(.top, 18)
            filterChips.padding(.top, 12)

            if filtered.isEmpty {
                empty.padding(.top, 40)
            } else {
                ForEach(days, id: \.id) { day in
                    MoreSectionTitle(text: day.label)
                    MoreCard(padding: 0) {
                        ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Divider().overlay(Theme.hairline).padding(.leading, 70)
                            }
                            row(entry)
                        }
                    }
                }
                Text("Searches stay on this phone. Clearing them can't be undone.")
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 20)
            }
        }
        .confirmationDialog("Clear all search history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { withAnimation { history.clear() } }
        } message: {
            Text("This removes every search saved on this phone.")
        }
    }

    private var summary: String {
        let count = history.entries.count
        guard count > 0 else { return "Nothing yet" }
        let stores = Set(history.entries.map(\.storeID)).count
        return "\(count) \(count == 1 ? "search" : "searches") · \(stores) \(stores == 1 ? "store" : "stores")"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.secondaryInk)
            TextField("Search your history", text: $text)
                .font(Theme.font(16, relativeTo: .body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryInk)
                }
                .accessibilityLabel("Clear text")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Theme.surface.opacity(0.92), in: Capsule())
        .shadow(color: Theme.ink.opacity(0.05), radius: 10, y: 5)
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases) { option in
                Button(option.rawValue) {
                    withAnimation(.snappy(duration: 0.2)) { filter = option }
                }
                .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                .foregroundStyle(filter == option ? Theme.onAccent : Theme.ink)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background {
                    if filter == option {
                        Capsule().fill(Theme.accent)
                    } else {
                        Capsule().fill(Theme.fill)
                    }
                }
                .disabled(option == .thisStore && currentStoreID == nil)
                .accessibilityAddTraits(filter == option ? .isSelected : [])
            }
        }
    }

    private func row(_ entry: SearchHistory.Entry) -> some View {
        Button {
            onSearch?(entry.query)
        } label: {
            HStack(spacing: 12) {
                leading(entry)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if entry.isPhoto {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        Text(entry.query.capitalizedFirst)
                            .font(Theme.font(16, .semibold, relativeTo: .body))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                    Text("\(entry.storeName) · \(entry.date.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.font(12, relativeTo: .caption))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    if let place = entry.place {
                        Text(place)
                            .font(Theme.font(15, .bold, relativeTo: .subheadline))
                            .foregroundStyle(entry.confidence == .high ? AnyShapeStyle(Theme.accentInk) : AnyShapeStyle(Theme.ink))
                            .lineLimit(1)
                    } else {
                        Text("Not found")
                            .font(Theme.font(13, relativeTo: .footnote))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    ConfidenceBars(level: entry.confidence.level, height: 11)
                        .foregroundStyle(Theme.ink)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onSearch == nil)
        .contextMenu {
            if onSearch != nil {
                Button("Search again", systemImage: "arrow.clockwise") { onSearch?(entry.query) }
            }
            Button("Remove", systemImage: "trash", role: .destructive) {
                withAnimation { history.remove(entry.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(onSearch == nil ? "" : "Searches again")
    }

    /// The item's picture with a tiny store logo on its corner, or just the store logo
    /// when there's no picture for the item.
    @ViewBuilder
    private func leading(_ entry: SearchHistory.Entry) -> some View {
        let iconText = [entry.item, entry.query].first { ItemIcon.assetName(for: $0) != nil }
        if let iconText {
            ZStack(alignment: .bottomTrailing) {
                ItemIconView(text: iconText, size: 42, tile: true)
                SmallStoreLogo(url: entry.logoURL, size: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .offset(x: 4, y: 4)
            }
        } else {
            SmallStoreLogo(url: entry.logoURL, size: 42)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
            Text(history.entries.isEmpty ? "No searches yet" : "Nothing matches")
                .font(Theme.font(18, .bold, relativeTo: .headline))
            Text(history.entries.isEmpty ? "Things you look for will show up here." : "Try another word or filter.")
                .font(.aisleSubheadline)
                .foregroundStyle(Theme.secondaryInk)
        }
        .frame(maxWidth: .infinity)
    }

    static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: .now)).day, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        return day.formatted(.dateTime.month(.wide).day())
    }
}

extension String {
    /// "oat milk" → "Oat milk" (only the first letter).
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
