import SwiftUI

/// The aisle logo next to the lowercase wordmark.
struct AisleWordmark: View {
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: size * 0.28) {
            AisleMark(size: size)
            Text("aisle")
                .font(Theme.font(size * 0.8, .bold))
                .tracking(-0.6)
        }
        .foregroundStyle(Theme.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aisle")
        .accessibilityAddTraits(.isHeader)
    }
}

/// A retailer's logo drawn bare (no tile), or `placeholder` while loading, offline, or
/// when there's no logo. Asks logo.dev for the variant made for the current light or
/// dark background, so no backing tile is needed.
struct RetailerLogo<Placeholder: View>: View {
    let url: URL?
    var size: CGFloat = 44
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let url = themed(url) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                } else {
                    placeholder()
                }
            }
            .frame(width: size, height: size)
        } else {
            placeholder()
        }
    }

    /// Sets logo.dev's `theme` parameter to match the colour scheme.
    private func themed(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "theme" }
        items.append(URLQueryItem(name: "theme", value: colorScheme == .dark ? "dark" : "light"))
        components.queryItems = items
        return components.url ?? url
    }
}

/// The Aisle logo on its own. Always drawn bare, never on a tile or circle.
struct AisleMark: View {
    var size: CGFloat = 16

    var body: some View {
        Image("AisleLogo")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Theme.ink)
            .accessibilityHidden(true)
    }
}

/// The shopper's question, right-aligned like a chat message, with their photo above it.
struct QueryBubble: View {
    let text: String
    var photo: Data? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let photo, let image = UIImage(data: photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            if !text.isEmpty {
                Text(text)
                    .font(.aisleBody)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .padding(.leading, 48)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo == nil ? "You asked: \(text)" : "You sent a photo\(text.isEmpty ? "" : ": \(text)")")
    }
}

/// A short chat-style answer from Aisle.
struct AisleReply<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AisleMark(size: 16)
                Text("Aisle")
                    .font(Theme.font(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(Theme.ink)
            }
            content()
                .font(.aisleCallout)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Three rising bars: how sure Aisle is (1–3).
struct ConfidenceBars: View {
    let level: Int
    var height: CGFloat = 14

    var body: some View {
        let ratios: [CGFloat] = [0.43, 0.71, 1]
        return HStack(alignment: .bottom, spacing: height * 0.15) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < level ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                    .frame(width: height * 0.29, height: height * ratios[index])
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Covers the status bar on screens that hide the navigation bar, so content
/// scrolling up doesn't run under the clock. Use as a top `safeAreaInset`.
///
/// It stays clear while the page is at rest, so the background's glow runs up behind the
/// clock uncut, and fades in as content scrolls under it. Pair it with
/// `trackingScrollUnderStatusBar` on the first view in the scroll content.
struct StatusBarBackdrop: View {
    /// How far the page has scrolled up under the status bar, in points.
    var scrolled: CGFloat

    private var opacity: Double { min(1, scrolled / 30) }

    var body: some View {
        // Sits at the top of the safe area and draws upward over the status bar.
        // Solid behind the clock, fading out at its bottom edge.
        GeometryReader { proxy in
            LinearGradient(
                stops: [
                    .init(color: Theme.background, location: 0),
                    .init(color: Theme.background, location: 0.75),
                    .init(color: Theme.background.opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: proxy.safeAreaInsets.top)
            .offset(y: -proxy.safeAreaInsets.top)
            .opacity(opacity)
        }
        .frame(height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Reports how far this view (the first in a scroll view's content) has scrolled up
    /// under the status bar, measured from where it rests. `topPadding` is the page's top
    /// padding: the gap before content reaches the clock.
    func trackingScrollUnderStatusBar(_ scrolled: Binding<CGFloat>, topPadding: CGFloat = 8) -> some View {
        modifier(StatusBarScrollTracker(scrolled: scrolled, topPadding: topPadding))
    }
}

private struct StatusBarScrollTracker: ViewModifier {
    @Binding var scrolled: CGFloat
    let topPadding: CGFloat
    @State private var restTop: CGFloat?

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .scrollView).minY
        } action: { top in
            let rest = restTop ?? top
            restTop = rest
            scrolled = max(0, rest - topPadding - top)
        }
    }
}

/// White rounded card on the off-white page.
struct AisleCardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

extension View {
    func aisleCard(padding: CGFloat = 16) -> some View {
        modifier(AisleCardModifier(padding: padding))
    }

    /// Hides a List/Form's grey backdrop and shows the Aisle page instead.
    func aislePage() -> some View {
        scrollContentBackground(.hidden)
            .background(AisleBackground())
            .font(.aisleBody)
    }
}

// MARK: - Buttons

/// Full-width gradient button with dark text.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentButtonBody(configuration: configuration)
    }
}

private struct AccentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.aisleHeadline)
            .foregroundStyle(isEnabled ? Theme.onAccent : Theme.secondaryInk)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(
                AccentFill(isEnabled: isEnabled),
                in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
            )
            .shadow(color: Theme.glow.opacity(isEnabled ? 0.16 : 0), radius: 9, y: 6)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Full-width white button, the quieter partner of the accent button.
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aisleHeadline)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Compact gradient pill, e.g. the list's "Add" button.
struct AccentPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentPillBody(configuration: configuration)
    }
}

private struct AccentPillBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(Theme.font(15, .semibold, relativeTo: .subheadline))
            .foregroundStyle(isEnabled ? Theme.onAccent : Theme.secondaryInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(AccentFill(isEnabled: isEnabled), in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The gradient when enabled. Disabled, a flat neutral fill: a faded pastel turns
/// muddy on the dark page.
private struct AccentFill: ShapeStyle {
    let isEnabled: Bool

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        isEnabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fill)
    }
}

extension ButtonStyle where Self == AccentButtonStyle {
    static var aisleAccent: AccentButtonStyle { AccentButtonStyle() }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var aisleSoft: SoftButtonStyle { SoftButtonStyle() }
}

extension ButtonStyle where Self == AccentPillButtonStyle {
    static var aisleAccentPill: AccentPillButtonStyle { AccentPillButtonStyle() }
}

/// Geist version of `ContentUnavailableView`: gradient icon, title, message, optional buttons.
struct AisleEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.accentInk)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(title)
                    .font(.aisleTitle3)
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
            .multilineTextAlignment(.center)
            VStack(spacing: 10) { actions() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 8)
    }
}

extension AisleEmptyState where Actions == EmptyView {
    init(title: String, systemImage: String, message: String) {
        self.init(title: title, systemImage: systemImage, message: message) { EmptyView() }
    }
}

/// A short confirmation line with a gradient check mark, e.g. after "Found it".
struct AisleNote: View {
    let text: String
    var systemImage = "checkmark"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.accentInk)
                .accessibilityHidden(true)
            Text(text)
                .font(.aisleSubheadline)
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }
}
