import SwiftUI

/// Shared bits for the "more" screens: a sheet scaffold with a back/close button,
/// section titles, cards and a small store logo.
struct MoreScreen<Content: View, Trailing: View>: View {
    var title: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 44, height: 44)
                            .background(Theme.surface.opacity(0.92), in: Circle())
                            .shadow(color: Theme.ink.opacity(0.06), radius: 12, y: 6)
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                    trailing()
                }
                if let title {
                    Text(title)
                        .font(Theme.font(32, .bold, relativeTo: .largeTitle))
                        .tracking(-1.2)
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 18)
                        .accessibilityAddTraits(.isHeader)
                }
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .background(AisleBackground())
        .foregroundStyle(Theme.ink)
    }
}

extension MoreScreen where Trailing == EmptyView {
    init(title: String?, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

struct MoreSectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.font(20, .bold, relativeTo: .title3))
            .tracking(-0.4)
            .foregroundStyle(Theme.ink)
            .padding(.top, 26)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)
    }
}

struct MoreCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
    }
}

struct SmallStoreLogo: View {
    let url: URL?
    var size: CGFloat = 34
    var body: some View {
        RetailerLogo(url: url, size: size) {
            Image(systemName: "storefront")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: size, height: size)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        }
        .accessibilityHidden(true)
    }
}

/// A big number in the accent gradient with a caption under it.
struct GradientFigure: View {
    let value: String
    let caption: String
    var size: CGFloat = 30
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(Theme.font(size, .bold, relativeTo: .title))
                .tracking(-size * 0.04)
                .foregroundStyle(Theme.accentInk)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(Theme.font(12, relativeTo: .caption))
                .foregroundStyle(Theme.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
