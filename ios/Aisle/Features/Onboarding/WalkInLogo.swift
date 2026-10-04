import CoreMotion
import SwiftUI

/// The Aisle mark drawn as vector panels so its halves and shelves can move on their own.
///
/// When `walkedIn` turns on, each half swings in from nearly edge-on, hinged on its
/// outer edge, and the mark grows slightly, as if you'd stepped into the aisle; a soft
/// spring gives a small overshoot as the walls settle. Afterwards, tilting the phone
/// shifts near shelves more than far ones, so the mark reads as depth. Both effects are
/// off under Reduce Motion, where the logo simply appears.
struct WalkInLogo: View {
    var size: CGFloat = 140
    /// The halves stay swung open and hidden until this is true; flip it in your own timing.
    var walkedIn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tilt = DeviceTilt()

    /// Largest parallax shift, in points, for the nearest panel.
    private var maxShift: CGFloat { size * 0.045 }
    private var animation: Animation? {
        reduceMotion ? nil : .spring(response: 1.1, dampingFraction: 0.62)
    }

    var body: some View {
        ZStack {
            half(.left)
            half(.right)
        }
        .frame(width: size, height: size)
        .scaleEffect(walkedIn ? 1 : 0.82)
        .animation(animation, value: walkedIn)
        .onAppear { if !reduceMotion { tilt.start() } }
        .onDisappear { tilt.stop() }
        .accessibilityHidden(true)
    }

    private func half(_ side: LogoPanel.Side) -> some View {
        ZStack {
            ForEach(LogoPanel.all.filter { $0.side == side }) { panel in
                LogoPanelShape(points: panel.points)
                    .fill(Theme.ink)
                    .offset(
                        x: CGFloat(tilt.x) * panel.depth * maxShift,
                        y: CGFloat(tilt.y) * panel.depth * maxShift
                    )
            }
        }
        .frame(width: size, height: size)
        // Hinge on the outer edge: start almost edge-on, then swing into place.
        .rotation3DEffect(
            .degrees(walkedIn ? 0 : (side == .left ? 78 : -78)),
            axis: (x: 0, y: 1, z: 0),
            anchor: side == .left ? .leading : .trailing,
            perspective: 0.55
        )
        .opacity(walkedIn ? 1 : 0)
        .animation(animation, value: walkedIn)
    }
}

/// One shelf of the mark: a quadrilateral in the logo's 512-point artwork space.
private struct LogoPanel: Identifiable {
    enum Side { case left, right }

    let id: Int
    let points: [CGPoint]
    let side: Side
    /// Parallax weight: near panels (outer edge) move most, far ones least.
    let depth: CGFloat

    /// Left-side panels, traced from aisle-logo.png. The right side mirrors them.
    private static let left: [(points: [(CGFloat, CGFloat)], depth: CGFloat)] = [
        ([(145, 240), (220, 264), (220, 286), (145, 290)], 0.3),  // inner, middle
        ([(145, 156), (220, 212), (220, 255), (145, 225)], 0.3),  // inner, top
        ([(0, 192), (132, 235), (132, 290), (0, 295)], 1),        // outer, middle
        ([(0, 57), (132, 145), (132, 220), (0, 169)], 1),         // outer, top
        ([(0, 320), (220, 295), (220, 331), (0, 454)], 0.7),      // floor
    ]

    static let all: [LogoPanel] = {
        var panels: [LogoPanel] = []
        for (index, panel) in left.enumerated() {
            let points = panel.points.map { CGPoint(x: $0.0, y: $0.1) }
            panels.append(LogoPanel(id: index * 2, points: points, side: .left, depth: panel.depth))
            let mirrored = points.reversed().map { CGPoint(x: 512 - $0.x, y: $0.y) }
            panels.append(LogoPanel(id: index * 2 + 1, points: mirrored, side: .right, depth: panel.depth))
        }
        return panels
    }()
}

/// A quadrilateral with softly rounded corners, scaled from 512-point artwork space.
private struct LogoPanelShape: Shape {
    let points: [CGPoint]
    var cornerRadius: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 512
        let p = points.map { CGPoint(x: rect.minX + $0.x * scale, y: rect.minY + $0.y * scale) }
        let count = p.count
        var path = Path()
        // Start halfway along the last edge so every corner is drawn as an arc.
        path.move(to: CGPoint(x: (p[count - 1].x + p[0].x) / 2, y: (p[count - 1].y + p[0].y) / 2))
        for i in 0..<count {
            let corner = p[i]
            let next = p[(i + 1) % count]
            let previous = p[(i + count - 1) % count]
            // Keep the radius within half of the shorter adjoining edge (the inner shelves are thin).
            let radius = min(cornerRadius * scale, corner.distance(to: next) / 2, corner.distance(to: previous) / 2)
            path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
        }
        path.closeSubpath()
        return path
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}

/// Phone tilt relative to how it was held when tracking started, smoothed, in -1...1.
/// No-ops where device motion isn't available (e.g. the Simulator).
@MainActor
@Observable
final class DeviceTilt {
    private(set) var x: Double = 0
    private(set) var y: Double = 0

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var reference: CMAttitude?

    /// Radians of tilt that count as "fully tilted".
    private let range = 0.45
    /// Low-pass factor per update; lower is smoother.
    private let smoothing = 0.12

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        reference = nil
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated { self?.update(with: motion.attitude) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        x = 0
        y = 0
    }

    private func update(with attitude: CMAttitude) {
        guard let reference else {
            reference = attitude.copy() as? CMAttitude
            return
        }
        attitude.multiply(byInverseOf: reference)
        let targetX = max(-1, min(1, attitude.roll / range))
        let targetY = max(-1, min(1, attitude.pitch / range))
        x += (targetX - x) * smoothing
        y += (targetY - y) * smoothing
    }
}
