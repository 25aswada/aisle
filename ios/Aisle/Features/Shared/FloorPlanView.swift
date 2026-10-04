import SwiftUI

/// The store floor drawn as soft rounded department tiles, with the target tile in the
/// accent gradient, a walking path from the entrance and a pin that stays upright.
///
/// `tilt` runs from 0 (top down) to 1 (a raised, rotated "model of the store"). It is
/// animatable, so switching between the two views swings the floor smoothly.
/// Positions come from the store's layout, which is often a typical template, so callers
/// caption it as approximate.
struct FloorPlanView: View, Animatable {
    let layout: StoreLayout
    /// The department to highlight; nil shows the floor on its own (home screen).
    let targetZoneID: Int?
    /// Text on the pin, e.g. "Aisle 7" or "Breakfast".
    let pinTitle: String
    var tilt: Double = 0
    /// Extra rotation from dragging, in degrees. Only applies when tilted.
    var yaw: Double = 0

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(tilt, yaw) }
        set { tilt = newValue.first; yaw = newValue.second }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let tiles = FloorTile.tiles(for: layout)
            let projector = FloorProjector(size: geo.size, tilt: tilt, yaw: yaw)
            let target = targetZoneID.flatMap { id in tiles.first { $0.id == id } }
            ZStack {
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, _ in
                        draw(in: &context, projector: projector, tiles: tiles, target: target, time: time)
                    }
                }
                if let target {
                    FloorPin(title: pinTitle)
                        .position(projector.point(target.rect.midX, target.rect.midY, lift: target.height(tilt: tilt)))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, projector: FloorProjector, tiles: [FloorTile], target: FloorTile?, time: TimeInterval) {
        let slab = CGRect(x: -0.04, y: -0.04, width: 1.08, height: 1.08)
        let slabPath = projector.roundedRect(slab, radius: 26)
        // Slab thickness, then its top.
        let slabDepth = 12 * tilt
        if slabDepth > 0.5 {
            for step in stride(from: -slabDepth, to: 0, by: 1) {
                context.fill(projector.roundedRect(slab, radius: 26, lift: step), with: .color(FloorColors.slabSide))
            }
        }
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: Theme.ink.opacity(0.08), radius: 22, y: 14))
            layer.fill(slabPath, with: .color(Theme.surface))
        }

        // Checkout lanes and entrance sit on the floor.
        if let checkout = layout.checkout {
            let rect = CGRect(x: checkout.x - 0.12, y: max(0.0, checkout.y - 0.035), width: 0.24, height: 0.07)
            context.fill(projector.roundedRect(rect, radius: 8), with: .color(Theme.fill))
            for lane in 0..<5 {
                let x = rect.minX + rect.width * (Double(lane) + 0.5) / 5
                var line = Path()
                line.move(to: projector.point(x, rect.minY + 0.012))
                line.addLine(to: projector.point(x, rect.maxY - 0.012))
                context.stroke(line, with: .color(FloorColors.tileSide), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            label(&context, "Checkout", at: projector.point(rect.midX, rect.minY - 0.03), highlighted: false)
        }

        // Tiles, back to front so nearer ones overlap farther ones.
        let ordered = tiles.sorted { projector.point($0.rect.midX, $0.rect.midY).y < projector.point($1.rect.midX, $1.rect.midY).y }
        for tile in ordered {
            drawTile(tile, highlighted: tile.id == targetZoneID, in: &context, projector: projector)
        }

        // Route from the entrance to the target, then the "you are here" dot.
        if let entrance = layout.entrance, let target {
            let points = Self.route(from: entrance, to: target).map { projector.point($0.x, $0.y, lift: 1) }
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: .color(Theme.surface), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            let phase = CGFloat(time.truncatingRemainder(dividingBy: 1)) * -24
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [Color(hex: 0x9A6BD6), Color(hex: 0xDC6F9C), Color(hex: 0xEC9560)]),
                    startPoint: points.first ?? .zero, endPoint: points.last ?? .zero
                ),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [2, 10], dashPhase: phase)
            )
            let dot = projector.point(entrance.x, entrance.y, lift: 1)
            let pulse = time.truncatingRemainder(dividingBy: 1.8) / 1.8
            if !reduceMotion {
                let radius = 8 + 18 * pulse
                context.fill(Path(ellipseIn: CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(Color(hex: 0x9A6BD6).opacity(0.5 * (1 - pulse))))
            }
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 9, y: dot.y - 9, width: 18, height: 18)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10)), with: .color(Color(hex: 0x9A6BD6)))
            label(&context, "Entrance", at: CGPoint(x: dot.x, y: dot.y + 18), highlighted: false)
        }
    }

    private func drawTile(_ tile: FloorTile, highlighted: Bool, in context: inout GraphicsContext, projector: FloorProjector) {
        let height = tile.height(tilt: tilt) + (highlighted ? 8 * tilt : 0)
        if height > 0.5 {
            let side = highlighted ? FloorColors.accentSide : FloorColors.tileSide
            for step in stride(from: 0, to: height, by: 1) {
                context.fill(projector.roundedRect(tile.rect, radius: 9, lift: step), with: .color(side))
            }
        }
        let top = projector.roundedRect(tile.rect, radius: 9, lift: height)
        if highlighted {
            let a = projector.point(tile.rect.minX, tile.rect.minY, lift: height)
            let b = projector.point(tile.rect.maxX, tile.rect.maxY, lift: height)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: Theme.glow.opacity(0.45), radius: 14, y: 6))
                layer.fill(top, with: .linearGradient(Gradient(colors: Theme.accentColors), startPoint: a, endPoint: b))
            }
        } else {
            context.fill(top, with: .color(Theme.fill))
            // A few shelf lines so interior departments read as aisles.
            if !tile.isWall, tile.rect.width > 0.09 {
                for index in 1...3 {
                    let x = tile.rect.minX + tile.rect.width * Double(index) / 4
                    var line = Path()
                    line.move(to: projector.point(x, tile.rect.minY + 0.02, lift: height))
                    line.addLine(to: projector.point(x, tile.rect.maxY - 0.02, lift: height))
                    context.stroke(line, with: .color(FloorColors.shelf), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        if !highlighted {
            label(&context, tile.name, at: projector.point(tile.rect.midX, tile.rect.midY, lift: height), highlighted: false)
        }
    }

    private func label(_ context: inout GraphicsContext, _ text: String, at point: CGPoint, highlighted: Bool) {
        let resolved = context.resolve(
            Text(text)
                .font(Theme.font(highlighted ? 12 : 10, highlighted ? .bold : .semibold, relativeTo: .caption2))
                .foregroundStyle(highlighted ? Theme.ink : Theme.secondaryInk)
        )
        context.draw(resolved, at: point, anchor: .center)
    }

    /// Along the front, then up toward the target's front edge.
    static func route(from entrance: StoreLayout.Point, to target: FloorTile) -> [CGPoint] {
        let start = CGPoint(x: entrance.x, y: entrance.y)
        let end = CGPoint(x: target.rect.midX, y: max(entrance.y, target.rect.minY - 0.015))
        let frontY = min(entrance.y + 0.05, end.y)
        if abs(start.x - end.x) < 0.03 { return [start, end] }
        return [start, CGPoint(x: start.x, y: frontY), CGPoint(x: end.x, y: frontY), end]
    }

    private var accessibilitySummary: String {
        guard let targetZoneID else { return "Store map." }
        let name = layout.zones.first { $0.id == targetZoneID }?.name ?? pinTitle
        return "Store map. A path goes from the entrance to \(name)."
    }
}

// MARK: - Geometry

/// A department drawn as a rounded tile, in floor units (x 0…1 left to right,
/// y 0 at the front to 1 at the back).
struct FloorTile: Identifiable, Equatable {
    let id: Int
    let name: String
    let rect: CGRect
    let isWall: Bool

    func height(tilt: Double) -> Double { (isWall ? 7 : 10) * tilt }

    /// Sizes each tile from the gap to its nearest neighbour; wall departments stretch along the wall.
    static func tiles(for layout: StoreLayout) -> [FloorTile] {
        let zones = layout.placedZones
        return zones.compactMap { zone -> FloorTile? in
            guard let p = zone.point else { return nil }
            let nearest = zones
                .filter { $0.id != zone.id }
                .compactMap { other in other.point.map { hypot($0.x - p.x, $0.y - p.y) } }
                .min() ?? 0.3
            var halfX = min(max(nearest * 0.42, 0.05), 0.12)
            var halfY = halfX
            var isWall = false
            if p.y > 0.82 {
                halfX *= 1.5; halfY *= 0.55; isWall = true
            } else if p.x < 0.12 || p.x > 0.88 {
                halfY *= 1.5; halfX *= 0.55; isWall = true
            }
            let minX = max(0.0, p.x - halfX), maxX = min(1.0, p.x + halfX)
            let minY = max(0.08, p.y - halfY), maxY = min(1.0, p.y + halfY)
            return FloorTile(id: zone.id, name: zone.name,
                             rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                             isWall: isWall)
        }
    }
}

/// Floor units to screen points. Orthographic, so tiles stay crisp and rounded:
/// rotate on the floor, tip it back, and lift raises a point toward the viewer.
struct FloorProjector {
    let size: CGSize
    let tilt: Double
    let yaw: Double

    private var plane: CGSize {
        let width = size.width * 0.86
        return CGSize(width: width, height: min(size.height * 0.84, width * 1.12))
    }

    private var scale: Double { 1 - 0.16 * tilt }

    func transform(lift: Double = 0) -> CGAffineTransform {
        let a = (-24 + yaw) * tilt * .pi / 180
        let b = 50 * tilt * .pi / 180
        let w = plane.width, h = plane.height, k = scale
        return CGAffineTransform(
            a: k * w * cos(a),
            b: k * cos(b) * w * sin(a),
            c: k * h * sin(a),
            d: -k * cos(b) * h * cos(a),
            tx: size.width / 2 + k * (-w / 2 * cos(a) - h / 2 * sin(a)),
            ty: size.height / 2 + k * cos(b) * (-w / 2 * sin(a) + h / 2 * cos(a)) - k * lift * sin(b) - 14 * tilt
        )
    }

    func point(_ x: Double, _ y: Double, lift: Double = 0) -> CGPoint {
        CGPoint(x: x, y: y).applying(transform(lift: lift))
    }

    /// A rounded rectangle on the floor; `radius` is in screen points.
    func roundedRect(_ rect: CGRect, radius: Double, lift: Double = 0) -> Path {
        let corner = CGSize(width: radius / plane.width, height: radius / plane.height)
        return Path(roundedRect: rect, cornerSize: corner).applying(transform(lift: lift))
    }
}

private enum FloorColors {
    static let tileSide = Color(light: 0xD7DBD3, dark: 0x3A3540)
    static let slabSide = Color(light: 0xE4E6E0, dark: 0x2A2630)
    static let shelf = Color(light: 0xE2E5DE, dark: 0x352F3B)
    static let accentSide = Color(hex: 0xEDB9CE)
}

/// The upright marker above the target: a chip with the place, a stem and a dot.
private struct FloorPin: View {
    let title: String
    @State private var bob = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                AisleMark(size: 18)
                    .frame(width: 26, height: 26)
                Text(title)
                    .font(Theme.font(13, .bold, relativeTo: .footnote))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .background(Theme.surface, in: Capsule())
            .shadow(color: Theme.glow.opacity(0.28), radius: 14, y: 8)
            Rectangle().fill(Theme.ink.opacity(0.8)).frame(width: 2, height: 14)
            Circle().fill(Theme.ink).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2).frame(width: 12, height: 12))
        }
        .fixedSize()
        .offset(y: bob ? -5 : 0)
        // Put the dot, not the middle of the pin, on the target.
        .offset(y: -25)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { bob = true }
        }
    }
}
