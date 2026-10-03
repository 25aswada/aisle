import SwiftUI
import UIKit

/// Aisle's visual language: warm off-white surfaces, near-black ink and one soft
/// pastel gradient (lavender → pink → peach → butter) as the only accent.
/// Screens pull colours, type and shapes from here so the look changes in one place.
enum Theme {
    // MARK: - Colours

    static let background = Color(light: 0xF3F4F1, dark: 0x131115)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1F1C22)
    static let fill = Color(light: 0xEFF1EC, dark: 0x2A2630)
    static let hairline = Color(light: 0xECEEE9, dark: 0x312C36)
    static let ink = Color(light: 0x1F1B24, dark: 0xF4F1F6)
    static let secondaryInk = Color(light: 0x4E544F, dark: 0xB9B3BF)
    static let bubble = Color(light: 0xEDE6F2, dark: 0x2D2733)
    static let warning = Color(light: 0xB4532F, dark: 0xF2A07E)
    /// Text and icons drawn on the gradient. Always dark, because the gradient is always light.
    static let onAccent = Color(hex: 0x1F1B24)
    /// "On" tint for switches. Ink in light mode; in dark mode ink is near-white and
    /// the white knob would vanish, so use the deep pink from `accentInk`.
    static let toggleOn = Color(light: 0x1F1B24, dark: 0xDC6F9C)
    /// Soft pink used for glows under accent elements.
    static let glow = Color(hex: 0xF48FB8)

    // MARK: - The accent gradient

    static let accentColors: [Color] = [
        Color(hex: 0xE2CFF9), Color(hex: 0xF9CFE0), Color(hex: 0xFFDDC6), Color(hex: 0xFFEDC2),
    ]

    /// Buttons, the high-confidence card and other primary moments.
    static var accent: LinearGradient {
        LinearGradient(colors: accentColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Paler version for tags and highlights.
    static var accentSoft: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0xF5EDFD), Color(hex: 0xFDEBF2), Color(hex: 0xFFF0E4), Color(hex: 0xFFF7DE)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Border around the search bar.
    static var accentRing: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0xE0CBF8), Color(hex: 0xF6C2D7), Color(hex: 0xFFD3B6), Color(hex: 0xFFE6AE)],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// Deeper version that stays readable as text ("looking for?").
    static var accentInk: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x9A6BD6), Color(hex: 0xDC6F9C), Color(hex: 0xEC9560)],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// Quiet grey-blue used for "likely" results.
    static var section: LinearGradient {
        LinearGradient(
            colors: [Color(light: 0xEEF0EA, dark: 0x2A2630), Color(light: 0xDDE2E8, dark: 0x24212B)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Background of icon and picture tiles.
    static var tile: LinearGradient {
        LinearGradient(
            colors: [Color(light: 0xFBEAF3, dark: 0x2E2632), Color(light: 0xFFF3DC, dark: 0x2F2A24)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // MARK: - Shape

    enum Radius {
        static let card: CGFloat = 24
        static let tile: CGFloat = 14
        static let button: CGFloat = 16
    }

    // MARK: - Type (Geist, bundled under Resources/Fonts)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(fontName(weight), size: size, relativeTo: style)
    }

    static func fontName(_ weight: Font.Weight) -> String {
        switch weight {
        case .medium: return "Geist-Medium"
        case .semibold: return "Geist-SemiBold"
        case .bold, .heavy, .black: return "Geist-Bold"
        default: return "Geist-Regular"
        }
    }

    static func uiFont(_ size: CGFloat, _ weight: Font.Weight) -> UIFont {
        UIFont(name: fontName(weight), size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }

    /// Navigation bar titles in Geist. Call once at launch.
    @MainActor
    static func applyAppearance() {
        let ink = UIColor(Theme.ink)
        let titles: (UINavigationBarAppearance) -> Void = { appearance in
            appearance.largeTitleTextAttributes = [.font: uiFont(34, .bold), .foregroundColor: ink]
            appearance.titleTextAttributes = [.font: uiFont(17, .semibold), .foregroundColor: ink]
        }
        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        titles(standard)
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        titles(edge)
        UINavigationBar.appearance().standardAppearance = standard
        UINavigationBar.appearance().compactAppearance = standard
        UINavigationBar.appearance().scrollEdgeAppearance = edge
    }
}

extension Font {
    static let aisleLargeTitle = Theme.font(34, .bold, relativeTo: .largeTitle)
    static let aisleTitle = Theme.font(26, .bold, relativeTo: .title)
    static let aisleTitle3 = Theme.font(20, .semibold, relativeTo: .title3)
    static let aisleHeadline = Theme.font(17, .semibold, relativeTo: .headline)
    static let aisleBody = Theme.font(17, relativeTo: .body)
    static let aisleCallout = Theme.font(16, relativeTo: .callout)
    static let aisleSubheadline = Theme.font(15, relativeTo: .subheadline)
    static let aisleFootnote = Theme.font(13, relativeTo: .footnote)
    static let aisleCaption = Theme.font(12, .medium, relativeTo: .caption)
}

extension Color {
    /// `0xRRGGBB` in sRGB.
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }

    /// Adapts to light and dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Off-white page with faint pink and butter glows in opposite corners.
struct AisleBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(
                colors: [Theme.glow.opacity(0.15), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 420
            )
            RadialGradient(
                colors: [Color(hex: 0xFFD872).opacity(0.15), .clear],
                center: .bottomLeading, startRadius: 0, endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}
