import SwiftUI

/// The moment between asking and the answer: the answer card itself, still blank. A small
/// status line ticks through what Aisle is doing while the aisle and department lines
/// shimmer, and the item's picture (when there is one) breathes on the right. It's the
/// same size as the result card, so nothing jumps when the answer lands.
/// The status is paced to the wait for a single request; it doesn't report server progress.
struct SearchingView: View {
    let query: String
    /// The photo being searched from, if any.
    var photo: Data? = nil
    let storeName: String
    /// Chain name for "Checking Costco's layout".
    let retailer: String

    @State private var stage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var statuses: [String] {
        [photo == nil ? "Reading “\(query)”" : "Looking at your photo", "Checking \(retailer)’s layout", "Finding the aisle"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            QueryBubble(text: query, photo: photo)
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                ghostCard(time: reduceMotion ? 0.6 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .task { await pace() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo == nil ? "Finding \(query) in \(storeName)" : "Finding what's in your photo in \(storeName)")
        .accessibilityValue(statuses[stage])
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Ghost card

    private func ghostCard(time: TimeInterval) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                statusRow(time: time)
                SkeletonBar(time: time, delay: 0)
                    .frame(width: 150, height: 36)
                SkeletonBar(time: time, delay: 0.12)
                    .frame(width: 118, height: 12)
            }
            Spacer(minLength: 0)
            if photo == nil, ItemIcon.assetName(for: query) != nil {
                ItemIconView(text: query, size: 52)
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.03 * (1 + sin(time * 2 * .pi / 2.2)))
                    .frame(width: 74, height: 74)
                    .background(
                        colorScheme == .dark ? AnyShapeStyle(Color.white.opacity(0.06)) : AnyShapeStyle(Theme.accentSoft),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 16)
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.92), in: shape)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
    }

    private func statusRow(time: TimeInterval) -> some View {
        HStack(spacing: 8) {
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color(hex: 0xDC6F9C), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(reduceMotion ? 0 : (time / 0.8).truncatingRemainder(dividingBy: 1) * 360))
            ZStack(alignment: .leading) {
                ForEach(statuses.indices, id: \.self) { index in
                    if index == stage {
                        Text(statuses[index])
                            .font(Theme.font(13, .semibold, relativeTo: .footnote))
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                            .shimmer(time: time)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 6)),
                                removal: .opacity.combined(with: .offset(y: -6))
                            ))
                    }
                }
            }
            .frame(height: 18, alignment: .leading)
            .clipped()
        }
    }

    private func pace() async {
        for next in 1...2 {
            do { try await Task.sleep(for: .milliseconds(1000)) } catch { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { stage = next }
        }
    }
}

// MARK: - Skeleton

/// A rounded placeholder with a soft light sweeping across it.
private struct SkeletonBar: View {
    let time: TimeInterval
    let delay: TimeInterval

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        shape
            .fill(colorScheme == .dark ? Color(hex: 0x38323F) : Theme.fill)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let progress = ((time - delay) / 1.6).truncatingRemainder(dividingBy: 1)
                        let band = geo.size.width * 0.6
                        LinearGradient(
                            colors: [.white.opacity(0), .white.opacity(colorScheme == .dark ? 0.07 : 0.75), .white.opacity(0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: band)
                        .offset(x: -band + (geo.size.width + band * 2) * progress)
                    }
                }
            }
            .clipShape(shape)
            .accessibilityHidden(true)
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
