import SwiftUI

/// Renders a structured `ItemSearchResult`. All text is composed here from fields.
struct SearchResultCard: View {
    let result: ItemSearchResult
    /// Chain name ("Trader Joe's") used in place of "this store"; nil for the loading placeholder.
    let retailer: String?
    /// The store's floor plan, when loaded; the map shows only if the result's zone is on it.
    var layout: StoreLayout? = nil

    @State private var showingWay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConfidenceHero(result: result)
            if let layout, let zoneID = mappedZone(in: layout) {
                Button { showingWay = true } label: {
                    StoreMapCard(layout: layout, retailer: retailer, highlighted: [zoneID], height: 200)
                        .overlay(alignment: .topTrailing) {
                            Label("Show me the way", systemImage: "figure.walk")
                                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.accent, in: Capsule())
                                .shadow(color: Theme.glow.opacity(0.25), radius: 8, y: 4)
                                .padding(20)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the map, a 3D view and step-by-step directions")
                .accessibilityIdentifier("showMeTheWay")
                .fullScreenCover(isPresented: $showingWay) {
                    StoreWayView(layout: layout, zoneID: zoneID, result: result, retailer: retailer)
                }
            }
            details
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("searchResultCard")
    }

    /// The zone to highlight, if the result points somewhere real that the map can place.
    private func mappedZone(in layout: StoreLayout) -> Int? {
        guard result.placeInStore != nil, let zoneID = result.location.zoneID,
              layout.placedZones.contains(where: { $0.id == zoneID }) else { return nil }
        return zoneID
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Neighbours only help when there's a real place to look.
            if !result.location.neighbors.isEmpty, result.placeInStore != nil {
                neighborsBlock
            }
            if let reports = result.reports, reports.found + reports.notHere > 0 {
                ReportSummary(reports: reports)
            }
            if result.availability == .unlikely {
                Label("\(retailer ?? "This store") typically doesn't carry this.", systemImage: "exclamationmark.triangle")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.warning)
            }
            Label(result.source.label(for: retailer), systemImage: result.source.symbol)
                .font(.aisleFootnote)
                .foregroundStyle(Theme.secondaryInk)
        }
        .aisleCard()
    }

    private var neighborsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Look near")
                .font(.aisleCaption)
                .foregroundStyle(Theme.secondaryInk)
            FlowTags(tags: result.location.neighbors)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Look near \(result.location.neighbors.joined(separator: ", "))")
    }
}

/// The big "where is it" card. Its style shows how sure Aisle is:
/// gradient = confident, soft grey = likely, dashed outline = best guess.
struct ConfidenceHero: View {
    let result: ItemSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ConfidenceBadge(confidence: result.confidence)
            VStack(alignment: .leading, spacing: 4) {
                if let department = result.placeInStore {
                    if let aisle = result.aisleLabel {
                        // Section rides with the department so the big line never wraps mid-phrase.
                        Text(aisle)
                            .font(Theme.font(40, .bold, relativeTo: .largeTitle))
                            .tracking(-1)
                            .accessibilityIdentifier("resultAisle")
                        Text([result.sectionLabel, department].compactMap { $0 }.joined(separator: " · "))
                            .font(.aisleHeadline)
                            .accessibilityIdentifier("resultDepartment")
                    } else {
                        Text(department)
                            .font(Theme.font(32, .bold, relativeTo: .largeTitle))
                            .tracking(-0.8)
                            .accessibilityIdentifier("resultDepartment")
                        Text("No aisle number on file for this store.")
                            .font(.aisleFootnote)
                            .opacity(0.75)
                    }
                } else if result.availability == .unlikely {
                    Text("Probably not sold here")
                        .font(.aisleTitle)
                    Text("Ask an employee to be sure.")
                        .font(.aisleSubheadline)
                        .opacity(0.75)
                } else {
                    Text("Not sure where this is")
                        .font(.aisleTitle)
                    Text("Try a more common name, or ask a store employee.")
                        .font(.aisleSubheadline)
                        .opacity(0.75)
                }
                Text(itemLine)
                    .font(.aisleFootnote)
                    .opacity(0.75)
                    .padding(.top, 2)
            }
        }
        .foregroundStyle(result.confidence == .high ? Theme.onAccent : Theme.ink)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { background }
    }

    private var itemLine: String {
        let item = result.item.capitalized
        guard let category = result.category?.name,
              category.caseInsensitiveCompare(item) != .orderedSame else { return item }
        return "\(item) · \(category)"
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        switch result.confidence {
        case .high:
            shape.fill(Theme.accent)
                .shadow(color: Theme.glow.opacity(0.14), radius: 13, y: 10)
        case .medium:
            shape.fill(Theme.section)
        case .low:
            shape.fill(Theme.surface)
                .overlay(shape.strokeBorder(Theme.secondaryInk.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
    }
}

struct ReportSummary: View {
    let reports: ReportCounts

    var body: some View {
        HStack(spacing: 12) {
            if reports.found > 0 {
                Label("\(reports.found) found it here", systemImage: "person.fill.checkmark")
            }
            if reports.notHere > 0 {
                Label("\(reports.notHere) didn't", systemImage: "person.fill.xmark")
            }
        }
        .font(.aisleFootnote)
        .foregroundStyle(Theme.secondaryInk)
        .accessibilityElement(children: .combine)
    }
}

struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        HStack(spacing: 8) {
            ConfidenceBars(level: confidence.level)
            Text(confidence.shortLabel)
                .font(Theme.font(13, .semibold, relativeTo: .footnote))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(confidence.label)
        .accessibilityIdentifier("confidenceBadge")
    }
}

/// Tags that wrap onto as many rows as they need.
struct FlowTags: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.aisleSubheadline)
                    // The soft gradient is light in both modes, so the text stays dark.
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.accentSoft, in: Capsule())
            }
        }
    }
}

/// Left-aligned rows that wrap, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = fittedSize(subviews[index], maxWidth: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = fittedSize(subviews[index], maxWidth: maxWidth)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    /// Natural size, but a tag wider than the row wraps its text instead of overflowing.
    private func fittedSize(_ subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard natural.width > maxWidth else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}

extension Confidence {
    var label: String {
        switch self {
        case .high: return "High confidence"
        case .medium: return "Medium confidence"
        case .low: return "Low confidence"
        }
    }

    /// Short label shown next to the bars.
    var shortLabel: String {
        switch self {
        case .high: return "Confident"
        case .medium: return "Likely here"
        case .low: return "Best guess"
        }
    }

    /// Number of filled bars, 1–3.
    var level: Int {
        switch self {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }

    var symbol: String {
        switch self {
        case .high: return "checkmark.seal.fill"
        case .medium: return "circle.lefthalf.filled"
        case .low: return "questionmark.circle"
        }
    }
}

extension LocationSource {
    func label(for retailer: String?) -> String {
        switch self {
        case .database: return "From store data"
        case .observations: return "Confirmed by shoppers"
        case .storeLayout: return "From this store's layout"
        case .model: return retailer.map { "AI estimate for \($0)" } ?? "AI estimate"
        case .fallback: return retailer.map { "Typical \($0) layout" } ?? "Typical store layout"
        }
    }

    var symbol: String {
        switch self {
        case .database: return "building.2"
        case .observations: return "person.2"
        case .storeLayout: return "map"
        case .model: return "text.magnifyingglass"
        case .fallback: return "square.grid.2x2"
        }
    }
}

extension ItemSearchResult {
    /// The department to send the shopper to, or nil when there's no real place for it.
    /// When the store probably doesn't stock an item and no store zone matched, the
    /// server's `department` is only the item's category (e.g. "Clothing" at Trader Joe's),
    /// not somewhere in this store, so it must not be presented as a location.
    var placeInStore: String? {
        if availability == .unlikely, location.zoneID == nil { return nil }
        return location.department
    }

    /// "Aisle 7" when the store has an aisle on file. Never inferred.
    var aisleLabel: String? {
        guard let raw = location.aisle?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.first?.isNumber == true ? "Aisle \(raw)" : raw
    }

    /// The section on file, e.g. "Left side".
    var sectionLabel: String? {
        guard let section = location.section, !section.isEmpty else { return nil }
        return section
    }

    /// "Aisle 7 · Left side" when the store has an aisle on file. Never inferred.
    var aisleDisplay: String? {
        guard let aisle = aisleLabel else { return nil }
        return sectionLabel.map { "\(aisle) · \($0)" } ?? aisle
    }

    /// A friendly, descriptive answer composed on the device from the structured fields:
    /// where to go, what it's shelved with and next to, where that answer came from, and
    /// what other shoppers reported. It names the shopper's store ("Trader Joe's usually
    /// keeps…"), and only restates what the result contains; it never adds an aisle or a place.
    func replyText(at retailer: String?) -> AttributedString {
        var reply = AttributedString()
        func plain(_ text: String) { reply.append(AttributedString(text)) }
        func strong(_ text: String) {
            var run = AttributedString(text)
            run.font = Theme.font(16, .semibold, relativeTo: .callout)
            reply.append(run)
        }

        let store = retailer ?? "This store"
        let storeLower = retailer ?? "this store"
        let possessive = retailer.map { "\($0)'s" } ?? "this store's"
        let atStore = retailer.map { "at \($0)" } ?? "in this store"
        let name = item.prefix(1).uppercased() + item.dropFirst()
        let department = placeInStore
        let categoryName = category?.name.lowercased()

        // The store probably doesn't stock it: say so, explain why, point to a person.
        if availability == .unlikely {
            plain("\(store) typically doesn't carry ")
            strong(item)
            plain(".")
            if let categoryName, categoryName != item.lowercased() {
                plain(" It's usually sold with \(categoryName), which \(storeLower) doesn't normally stock.")
            }
            if let department {
                plain(" If this location does have it, check ")
                strong(department)
                plain(" first, or ask an employee.")
            } else {
                plain(" An employee can tell you for sure, or point you to something similar.")
            }
            return reply
        }

        guard let department else {
            plain("I'm not sure where ")
            strong(item)
            plain(" is \(atStore) yet.")
            if let categoryName {
                plain(" It sounds like \(categoryName), so that part of the store is a good place to start.")
            }
            plain(" Try a more common name, or ask an employee.")
            return reply
        }

        // 1. Where to go.
        switch confidence {
        case .high:
            if let aisle = aisleDisplay {
                plain("Found it! \(name) is in ")
                strong(aisle)
                plain(", in the \(department) section\(retailer.map { " at \($0)" } ?? "").")
            } else {
                plain("\(name) is in ")
                strong(department)
                plain(retailer.map { " at \($0)." } ?? ".")
            }
        case .medium:
            plain(retailer.map { "At \($0), \(item) is most likely in " } ?? "\(name) is most likely in ")
            strong(aisleDisplay.map { "\($0), \(department)" } ?? department)
            plain(".")
        case .low:
            plain("I'm not certain, but \(storeLower) usually keeps \(item) in ")
            strong(department)
            plain(".")
        }

        // 2. What it's shelved with and next to.
        let near = location.neighbors.prefix(3).map { $0.lowercased() }
        // Skip "shelved with the cheese" when the category just repeats the item.
        let shelvedWith = categoryName.flatMap { $0 == item.lowercased() ? nil : "shelved with the \($0)" }
        let lookNear = near.isEmpty ? nil : "near \(Self.list(near))"
        switch (shelvedWith, lookNear) {
        case let (with?, near?): plain(" It's usually \(with), \(near).")
        case let (with?, nil): plain(" It's usually \(with).")
        case let (nil, near?): plain(" Look \(near).")
        case (nil, nil): break
        }

        // 3. Where the answer came from.
        switch source {
        case .database:
            plain(" This comes from \(possessive) own store data.")
        case .observations:
            plain(" Shoppers have confirmed it here.")
        case .storeLayout:
            plain(" That's from \(possessive) layout.")
        case .model:
            plain(" This is an AI estimate for \(storeLower), not a confirmed spot.")
        case .fallback:
            if aisleDisplay == nil {
                plain(" There's no aisle number on file, so this is based on \(possessive) typical layout.")
            } else {
                plain(" This is based on \(possessive) typical layout.")
            }
        }
        if let reports {
            switch (reports.found, reports.notHere) {
            case (0, 0): break
            case let (found, 0): plain(" \(Self.shoppers(found)) found it here.")
            case let (0, notHere): plain(" \(Self.shoppers(notHere)) couldn't find it here, so double-check.")
            case let (found, notHere): plain(" \(Self.shoppers(found)) found it here and \(notHere) didn't.")
            }
        }

        // 4. Anything the shopper asked for specifically.
        if !modifiers.isEmpty {
            plain(" You asked for \(Self.list(modifiers.map { $0.lowercased() })), so check the labels.")
        }
        if confidence == .low {
            plain(" If it's not there, ask an employee.")
        }
        return reply
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    private static func shoppers(_ count: Int) -> String {
        count == 1 ? "1 shopper" : "\(count) shoppers"
    }

    /// What Aisle says: the server's AI explanation when there is one (its **bold** place
    /// drawn semibold), otherwise the reply composed on the device.
    func reply(at retailer: String?) -> AttributedString {
        guard let explanation,
              var text = try? AttributedString(
                markdown: explanation,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
              )
        else { return replyText(at: retailer) }
        let bold = text.runs
            .filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map(\.range)
        for range in bold {
            text[range].font = Theme.font(16, .semibold, relativeTo: .callout)
        }
        return text
    }

    /// Shape-only stand-in shown redacted while a search loads.
    static let placeholder = ItemSearchResult(
        searchID: nil, query: "", item: "Searching item", modifiers: [], quantity: nil, storeID: nil,
        concept: nil, category: ItemCategory(slug: "", name: "Category name"),
        location: ItemLocation(
            department: "Department name", zoneID: nil, aisle: nil, section: nil,
            neighbors: ["Nearby item", "Another item"]
        ),
        availability: .likely, confidence: .medium, source: .fallback, reports: nil
    )
}
