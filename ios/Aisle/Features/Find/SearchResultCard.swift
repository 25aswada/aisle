import SwiftUI

/// Renders a structured `ItemSearchResult`. All text is composed here from fields.
struct SearchResultCard: View {
    let result: ItemSearchResult
    let storeName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConfidenceHero(result: result)
            details
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("searchResultCard")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !result.location.neighbors.isEmpty {
                neighborsBlock
            }
            if let reports = result.reports, reports.found + reports.notHere > 0 {
                ReportSummary(reports: reports)
            }
            if result.availability == .unlikely {
                Label("This store may not carry this item.", systemImage: "exclamationmark.triangle")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.warning)
            }
            Label(result.source.label, systemImage: result.source.symbol)
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
                if let department = result.location.department {
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
    var label: String {
        switch self {
        case .database: return "From store data"
        case .observations: return "Confirmed by shoppers"
        case .storeLayout: return "From this store's layout"
        case .model: return "AI estimate for this kind of store"
        case .fallback: return "Typical layout for this kind of store"
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

    /// A short, friendly answer composed on the device from the structured fields.
    /// It only restates what the result contains; it never adds an aisle or a place.
    var replyText: AttributedString {
        var reply = AttributedString()
        func plain(_ text: String) { reply.append(AttributedString(text)) }
        func strong(_ text: String) {
            var run = AttributedString(text)
            run.font = Theme.font(16, .semibold, relativeTo: .callout)
            reply.append(run)
        }

        let name = item.prefix(1).uppercased() + item.dropFirst()
        guard let department = location.department else {
            plain("I'm not sure where ")
            strong(item)
            plain(" is in this store yet. Try a more common name, or ask someone who works here.")
            return reply
        }

        switch confidence {
        case .high:
            if let aisle = aisleDisplay {
                plain("Found it! \(name) is in ")
                strong(aisle)
                plain(", in \(department).")
            } else {
                plain("\(name) is in ")
                strong(department)
                plain(".")
            }
        case .medium:
            plain("\(name) is most likely in ")
            strong(aisleDisplay.map { "\($0), \(department)" } ?? department)
            plain(".")
        case .low:
            plain("I'm not certain yet, but stores like this usually keep \(item) in ")
            strong(department)
            plain(".")
        }

        let near = location.neighbors.prefix(2).map { $0.lowercased() }
        if !near.isEmpty {
            plain(" Look near \(near.joined(separator: " and ")).")
        }
        if availability == .unlikely {
            plain(" Heads up: this store may not carry it.")
        }
        return reply
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
