import SwiftUI

/// The aisle logo next to the lowercase wordmark.
struct AisleWordmark: View {
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: size * 0.28) {
            Image("AisleLogo")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: size, height: size)
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

/// Small "Aisle" avatar: a soft gradient ring.
struct AisleAvatar: View {
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(AngularGradient(colors: Theme.accentColors + [Theme.accentColors[0]], center: .center))
            .overlay(Circle().inset(by: size * 0.24).fill(Color.white.opacity(0.6)))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The shopper's question, right-aligned like a chat message.
struct QueryBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.aisleBody)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You asked: \(text)")
    }
}

/// A short chat-style answer from Aisle.
struct AisleReply<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AisleAvatar()
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
struct StatusBarBackdrop: View {
    var body: some View {
        // Sits at the top of the safe area and draws upward over the status bar.
        // Solid behind the clock, fading out so the page's glows show through at rest.
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
        }
        .frame(height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .shadow(color: Theme.glow.opacity(0.16), radius: 9, y: 6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
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
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Theme.accent, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
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

/// A short confirmation line with a gradient check, e.g. after "Found it".
struct AisleNote: View {
    let text: String
    var systemImage = "checkmark"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 26, height: 26)
                .background(Theme.accent, in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.aisleSubheadline)
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }
}
