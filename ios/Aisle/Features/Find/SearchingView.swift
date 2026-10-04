import SwiftUI

/// The moment between asking and the answer: a shimmering status line, a mini store
/// floor with a light sweeping across it, a glowing border and three progress chips.
/// The chips are paced to the wait for a single request; they don't report server progress.
struct SearchingView: View {
    let query: String
    /// The photo being searched from, if any.
    var photo: Data? = nil
    let storeName: String
    /// Chain name for "Checking Costco's layout".
    let retailer: String

    @State private var stage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statuses: [String] {
        [photo == nil ? "Reading “\(query)”" : "Looking at your photo", "Checking \(retailer)’s layout", "Finding the aisle"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            QueryBubble(text: query, photo: photo)
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let time = reduceMotion ? 0.6 : timeline.date.timeIntervalSinceReferenceDate
                VStack(alignment: .leading, spacing: 16) {
                    statusRow(time: time)
                    card(time: time)
                }
            }
        }
        .task { await pace() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo == nil ? "Finding \(query) in \(storeName)" : "Finding what's in your photo in \(storeName)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Status

    private func statusRow(time: TimeInterval) -> some View {
        let breathe = reduceMotion ? 1 : 1 + 0.035 * (1 + sin(time * 2 * .pi / 2.2))
        return HStack(spacing: 10) {
            AisleMark(size: 24)
                .shimmer(time: time)
                .scaleEffect(breathe)
            ZStack(alignment: .leading) {
                ForEach(statuses.indices, id: \.self) { index in
                    if index == stage {
                        Text(statuses[index])
                            .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                            .shimmer(time: time)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 8)),
                                removal: .opacity.combined(with: .offset(y: -8))
                            ))
                    }
                }
            }
            .frame(height: 22, alignment: .leading)
            .clipped()
        }
    }

    // MARK: - Card

    private func card(time: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            FloorScan(time: time)
                .frame(height: 164)
            HStack(spacing: 8) {
                ForEach(Array(["Item", "Store layout", "Aisle"].enumerated()), id: \.offset) { index, label in
                    StageChip(label: label, state: index < stage ? .done : (index == stage ? .working : .waiting), time: time)
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: 0.55),
                            .init(color: Color(hex: 0xE2CFF9), location: 0.72),
                            .init(color: Theme.glow, location: 0.86),
                            .init(color: Color(hex: 0xFFDDC6), location: 0.95),
                            .init(color: .clear, location: 1),
                        ],
                        center: .center,
                        angle: .degrees(reduceMotion ? 0 : (time / 2.6).truncatingRemainder(dividingBy: 1) * 360)
                    ),
                    lineWidth: 1.5
                )
        }
        .shadow(color: Theme.glow.opacity(0.12), radius: 22, y: 12)
    }

    private func pace() async {
        for next in 1...2 {
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { stage = next }
        }
    }
}

// MARK: - Floor scan

/// A tiny store floor; a wave of the accent gradient rolls across the aisles under a soft beam.
private struct FloorScan: View {
    let time: TimeInterval
    private let period = 2.4

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 22, style: .continuous),
                         with: .color(Theme.background.opacity(0.6)))

            // Tiles as (rect, wave delay in seconds).
            var tiles: [(CGRect, Double)] = [
                (CGRect(x: 14, y: 12, width: w - 28, height: 16), 0.5),
                (CGRect(x: 14, y: 36, width: 22, height: 92), 0),
                (CGRect(x: w - 36, y: 36, width: 22, height: 92), 1.05),
                (CGRect(x: 14, y: 136, width: w * 0.28, height: 16), 0.1),
                (CGRect(x: w - 14 - w * 0.37, y: 136, width: w * 0.37, height: 16), 0.9),
            ]
            let barsLeft = 46.0, barsRight = w - 46
            let count = 9
            let step = (barsRight - barsLeft - 14) / Double(count - 1)
            for index in 0..<count {
                tiles.append((CGRect(x: barsLeft + Double(index) * step, y: 36, width: 14, height: 92), Double(index) * 0.11))
            }

            for (rect, delay) in tiles {
                let phase = ((time - delay) / period).truncatingRemainder(dividingBy: 1)
                let wave = max(0, sin(max(0, min(phase, 0.5)) * 2 * .pi))   // rises and falls in the first half
                let lifted = rect.offsetBy(dx: 0, dy: -2 * wave)
                let radius = min(rect.width, rect.height) / 2
                let path = Path(roundedRect: lifted, cornerRadius: min(radius, 8), style: .continuous)
                context.fill(path, with: .color(Theme.fill))
                if wave > 0.01 {
                    var layer = context
                    layer.opacity = wave
                    layer.fill(path, with: .linearGradient(
                        Gradient(colors: [Color(hex: 0xEAD9FB), Color(hex: 0xFADCE7), Color(hex: 0xFFE6D2)]),
                        startPoint: CGPoint(x: lifted.midX, y: lifted.minY),
                        endPoint: CGPoint(x: lifted.midX, y: lifted.maxY)
                    ))
                }
            }

            // The beam.
            let progress = (time / period).truncatingRemainder(dividingBy: 1)
            let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
            let beamX = -80 + (w + 160) * eased
            context.fill(
                Path(CGRect(x: beamX - 35, y: 0, width: 70, height: h)),
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0), .white.opacity(0.7), .white.opacity(0)]),
                    startPoint: CGPoint(x: beamX - 35, y: 0), endPoint: CGPoint(x: beamX + 35, y: 0)
                )
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Stage chips

private struct StageChip: View {
    enum Status { case done, working, waiting }

    let label: String
    let state: Status
    let time: TimeInterval

    var body: some View {
        HStack(spacing: 6) {
            icon.frame(width: 18, height: 18)
            Text(label)
                .font(Theme.font(12, .semibold, relativeTo: .caption))
                .foregroundStyle(state == .waiting ? Theme.secondaryInk.opacity(0.75) : Theme.ink)
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 11)
        .frame(height: 30)
        .background {
            switch state {
            case .done: Capsule().fill(Theme.bubble)
            case .working:
                Capsule().fill(Theme.accentSoft)
                    .overlay(Capsule().strokeBorder(Theme.glow.opacity(0.3), lineWidth: 1))
            case .waiting: Capsule().fill(Theme.fill)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Theme.background)
                .frame(width: 18, height: 18)
                .background(Theme.ink, in: Circle())
                .transition(.scale.combined(with: .opacity))
        case .working:
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color(hex: 0xDC6F9C), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees((time / 0.8).truncatingRemainder(dividingBy: 1) * 360))
                .padding(1)
        case .waiting:
            Circle().strokeBorder(Theme.hairline, lineWidth: 2)
        }
    }
}

// MARK: - Shimmer

extension View {
    /// A pink-to-peach shine sweeping across the view, driven by the timeline's clock.
    func shimmer(time: TimeInterval) -> some View {
        modifier(ShimmerEffect(time: time))
    }
}

private struct ShimmerEffect: ViewModifier {
    let time: TimeInterval

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    let progress = (time / 2.2).truncatingRemainder(dividingBy: 1)
                    let band = max(geo.size.width * 0.5, 40)
                    LinearGradient(
                        colors: [.clear, Color(hex: 0xDC6F9C), Color(hex: 0xEC9560), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: band)
                    .offset(x: -band + (geo.size.width + band * 2) * progress)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
    }
}
