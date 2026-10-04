import SwiftUI

/// A schematic floor plan: departments as labels placed by their approximate position,
/// the entrance at the bottom and the checkout, plus either a highlighted department
/// (search results) or a walking route through the stops (Start Shopping).
///
/// Positions are approximate (often a per-format template), so callers caption it
/// as a typical layout. Bare icons only; the highlight is carried by the label itself.
struct StoreMapView: View {
    let layout: StoreLayout
    /// Departments to emphasise (the result's zone, or the current stop).
    var highlighted: Set<Int> = []
    /// Departments already done on a shopping trip; drawn quieter.
    var completed: Set<Int> = []
    /// Ordered route through these zones, drawn from the entrance to the checkout.
    var route: [Int] = []
    var height: CGFloat = 220

    var body: some View {
        GeometryReader { geo in
            let frame = CGRect(origin: .zero, size: geo.size).insetBy(dx: 14, dy: 26)
            ZStack {
                if !routePoints(in: frame).isEmpty {
                    routePath(in: frame)
                        .stroke(Theme.accentInk, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [6, 6]))
                        .opacity(0.8)
                }
                if let entrance = layout.entrance {
                    marker("Entrance", systemImage: "arrow.up", at: place(entrance, in: frame), below: true)
                }
                if let checkout = layout.checkout {
                    marker("Checkout", systemImage: "cart", at: place(checkout, in: frame), below: true)
                }
                ForEach(layout.placedZones) { zone in
                    if let point = zone.point {
                        zoneDot(zone).position(place(point, in: frame))
                    }
                }
                ForEach(labelledZones(in: frame)) { zone in
                    if let point = zone.point {
                        zoneLabel(zone).position(labelPosition(for: place(point, in: frame), zone: zone, in: frame))
                    }
                }
            }
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card - 6, style: .continuous)
                .fill(Theme.fill.opacity(0.6))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Pieces

    private func zoneDot(_ zone: StoreLayout.Zone) -> some View {
        let isHighlighted = highlighted.contains(zone.id)
        let isDone = completed.contains(zone.id)
        return Circle()
            .fill(isHighlighted ? AnyShapeStyle(Theme.accentInk) : AnyShapeStyle(Theme.secondaryInk.opacity(isDone ? 0.25 : 0.5)))
            .frame(width: isHighlighted ? 10 : 6, height: isHighlighted ? 10 : 6)
    }

    @ViewBuilder
    private func zoneLabel(_ zone: StoreLayout.Zone) -> some View {
        let isHighlighted = highlighted.contains(zone.id)
        let isDone = completed.contains(zone.id)
        Text(zone.name)
            .font(Theme.font(isHighlighted ? 12 : 10, isHighlighted ? .bold : .medium, relativeTo: .caption2))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(isHighlighted ? Theme.onAccent : Theme.secondaryInk.opacity(isDone ? 0.45 : 1))
            .padding(.horizontal, isHighlighted ? 10 : 7)
            .padding(.vertical, isHighlighted ? 6 : 4)
            .background {
                if isHighlighted {
                    Capsule().fill(Theme.accent)
                        .shadow(color: Theme.glow.opacity(0.3), radius: 8, y: 3)
                } else {
                    Capsule().fill(Theme.surface.opacity(isDone ? 0.5 : 0.95))
                }
            }
            .frame(maxWidth: 130)
            .zIndex(isHighlighted ? 1 : 0)
    }

    private func marker(_ title: String, systemImage: String, at point: CGPoint, below: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(Theme.font(10, .semibold, relativeTo: .caption2))
            .foregroundStyle(Theme.ink.opacity(0.7))
            .position(x: point.x, y: point.y + (below ? 16 : -16))
    }

    // MARK: - Labels

    /// Which zones get a text label: highlighted ones first, then the rest in layout
    /// order, skipping any whose label would overlap one already placed. Unlabelled
    /// zones still show as dots.
    private func labelledZones(in frame: CGRect) -> [StoreLayout.Zone] {
        let ordered = layout.placedZones.filter { highlighted.contains($0.id) }
            + layout.placedZones.filter { !highlighted.contains($0.id) }
        var taken: [CGRect] = []
        if let entrance = layout.entrance { taken.append(markerRect(at: place(entrance, in: frame))) }
        if let checkout = layout.checkout { taken.append(markerRect(at: place(checkout, in: frame))) }
        var chosen: [StoreLayout.Zone] = []
        for zone in ordered {
            guard let point = zone.point else { continue }
            let rect = labelRect(for: zone, at: labelPosition(for: place(point, in: frame), zone: zone, in: frame))
            if highlighted.contains(zone.id) || !taken.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(rect) }) {
                taken.append(rect)
                chosen.append(zone)
            }
        }
        return chosen
    }

    /// Labels sit just above their dot, nudged to stay inside the map.
    private func labelPosition(for dot: CGPoint, zone: StoreLayout.Zone, in frame: CGRect) -> CGPoint {
        let size = labelSize(for: zone)
        let x = min(max(dot.x, frame.minX - 8 + size.width / 2), frame.maxX + 8 - size.width / 2)
        return CGPoint(x: x, y: dot.y - size.height / 2 - 5)
    }

    /// Estimated label size; Geist at these sizes averages ~0.56em per character.
    private func labelSize(for zone: StoreLayout.Zone) -> CGSize {
        let isHighlighted = highlighted.contains(zone.id)
        let fontSize: CGFloat = isHighlighted ? 12 : 10
        let width = min(CGFloat(zone.name.count) * fontSize * 0.56 + (isHighlighted ? 20 : 14), 130)
        return CGSize(width: width, height: isHighlighted ? 26 : 20)
    }

    private func labelRect(for zone: StoreLayout.Zone, at center: CGPoint) -> CGRect {
        let size = labelSize(for: zone)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private func markerRect(at point: CGPoint) -> CGRect {
        CGRect(x: point.x - 34, y: point.y + 6, width: 68, height: 20)
    }

    // MARK: - Geometry

    /// Floor-plan point to view space. y runs front (bottom) to back (top).
    private func place(_ point: StoreLayout.Point, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x * frame.width, y: frame.maxY - point.y * frame.height)
    }

    private func routePoints(in frame: CGRect) -> [CGPoint] {
        guard !route.isEmpty else { return [] }
        let zones = Dictionary(uniqueKeysWithValues: layout.zones.map { ($0.id, $0) })
        let stops = route.compactMap { zones[$0]?.point }.map { place($0, in: frame) }
        guard !stops.isEmpty else { return [] }
        var points: [CGPoint] = []
        if let entrance = layout.entrance { points.append(place(entrance, in: frame)) }
        points += stops
        if let checkout = layout.checkout { points.append(place(checkout, in: frame)) }
        return points
    }

    /// Walk the aisles: horizontal then vertical between stops, like the server's routing.
    private func routePath(in frame: CGRect) -> Path {
        let points = routePoints(in: frame)
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            let current = path.currentPoint ?? first
            path.addLine(to: CGPoint(x: point.x, y: current.y))
            path.addLine(to: point)
        }
        return path
    }

    private var accessibilitySummary: String {
        let names = layout.zones.filter { highlighted.contains($0.id) }.map(\.name)
        if !route.isEmpty {
            let order = route.compactMap { id in layout.zones.first { $0.id == id }?.name }
            return "Store map. Route: \(order.joined(separator: ", "))."
        }
        return names.isEmpty ? "Store map." : "Store map, \(names.joined(separator: ", ")) highlighted."
    }
}

/// The map in a card with an honest caption about where the layout comes from.
struct StoreMapCard: View {
    let layout: StoreLayout
    let retailer: String?
    var highlighted: Set<Int> = []
    var completed: Set<Int> = []
    var route: [Int] = []
    var height: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StoreMapView(layout: layout, highlighted: highlighted, completed: completed, route: route, height: height)
            Label(caption, systemImage: "map")
                .font(.aisleFootnote)
                .foregroundStyle(Theme.secondaryInk)
        }
        .aisleCard(padding: 12)
    }

    private var caption: String {
        guard layout.approximate else { return "This store's layout" }
        return "Typical \(retailer ?? "store") layout · approximate"
    }
}
