import SwiftUI

/// Renders a structured `ItemSearchResult`. All text is composed here from fields.
struct SearchResultCard: View {
    let result: ItemSearchResult
    let storeName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            locationBlock
            if !result.location.neighbors.isEmpty {
                neighborsBlock
            }
            if let reports = result.reports, reports.found + reports.notHere > 0 {
                ReportSummary(reports: reports)
            }
            if result.availability == .unlikely {
                Label("This store may not carry this item.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Divider()
            HStack {
                ConfidenceBadge(confidence: result.confidence)
                Spacer(minLength: 8)
                Text(result.source.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("searchResultCard")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.item.capitalized)
                .font(.title3.weight(.semibold))
            if let category = result.category {
                Text(category.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var locationBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Check")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let department = result.location.department {
                Text(department)
                    .font(.title2.weight(.bold))
                    .accessibilityIdentifier("resultDepartment")
            } else {
                Text("Not sure where this is")
                    .font(.title3.weight(.semibold))
                Text("Try a more common name, or ask a store employee.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let aisle = result.location.aisle {
                Label(
                    [aisle, result.location.section].compactMap { $0 }.joined(separator: " · "),
                    systemImage: "signpost.right"
                )
                .font(.headline)
                .accessibilityIdentifier("resultAisle")
            } else if result.location.department != nil {
                Text("No aisle number on file for this store.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var neighborsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Look near")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            FlowTags(tags: result.location.neighbors)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Look near \(result.location.neighbors.joined(separator: ", "))")
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
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        Label(confidence.label, systemImage: confidence.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(confidence.tint)
            .background(confidence.tint.opacity(0.15), in: Capsule())
            .accessibilityLabel("\(confidence.label)")
            .accessibilityIdentifier("confidenceBadge")
    }
}

/// Simple wrapping row of tags.
struct FlowTags: View {
    let tags: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }

    private var chips: some View {
        ForEach(tags, id: \.self) { tag in
            Text(tag)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.fill.tertiary, in: Capsule())
        }
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

    var symbol: String {
        switch self {
        case .high: return "checkmark.seal.fill"
        case .medium: return "circle.lefthalf.filled"
        case .low: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low: return .secondary
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
}
