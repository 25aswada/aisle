import SwiftUI

/// What Aisle+ adds. Keep this list to things the app actually does.
enum PlusFeature: CaseIterable, Identifiable {
    case photos, sharedLists, multiStore, offlineMaps

    var id: Self { self }

    var title: String {
        switch self {
        case .photos: return "Unlimited photo search"
        case .sharedLists: return "Shared family lists"
        case .multiStore: return "Multi-store trips"
        case .offlineMaps: return "Offline store maps"
        }
    }

    var detail: String {
        switch self {
        case .photos: return "Snap any item or a whole paper list."
        case .sharedLists: return "Everyone adds, everyone sees it checked off."
        case .multiStore: return "One plan across several stores."
        case .offlineMaps: return "Works in the back corner with no signal."
        }
    }

    var symbol: String {
        switch self {
        case .photos: return "camera"
        case .sharedLists: return "person.2"
        case .multiStore: return "point.topleft.down.to.point.bottomright.curvepath"
        case .offlineMaps: return "map"
        }
    }
}

// MARK: - Tab

/// The Aisle+ tab: the upgrade offer itself, or, for subscribers, what they have.
struct PlusTabView: View {
    var body: some View {
        NavigationStack {
            PaywallView(reason: nil, inTab: true)
                .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// What a subscriber sees on the Aisle+ tab: a living gradient card, what they get, and Free vs Aisle+.
private struct PlusMemberView: View {
    @Environment(PlusStore.self) private var plus

    private let comparison: [(String, String, String)] = [
        ("Find items in any store", "✓", "✓"),
        ("Photo searches", "5 a day", "Unlimited"),
        ("Follow-up questions", "10 a day", "Unlimited"),
        ("Lists", "1", "Unlimited, shared"),
        ("Multi-store trips", "—", "✓"),
        ("Offline store maps", "—", "✓"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HeroCard(isPlus: true, yearlyPrice: plus.price(.yearly)) {}
                    .padding(.top, 22)

                sectionTitle("What you get").padding(.top, 30)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(PlusFeature.allCases) { feature in
                        FeatureTile(feature: feature)
                    }
                }

                sectionTitle("Free vs Aisle+").padding(.top, 30)
                comparisonTable
                Text("Everything that helps you find an item stays free. Aisle+ adds more photos, sharing and bigger trips.")
                    .font(Theme.font(12, relativeTo: .caption))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(20, .bold, relativeTo: .title3))
            .tracking(-0.4)
            .foregroundStyle(Theme.ink)
            .padding(.bottom, 12)
            .accessibilityAddTraits(.isHeader)
    }

    private var comparisonTable: some View {
        VStack(spacing: 0) {
            row(Text(""), Text("Free").foregroundStyle(Theme.secondaryInk),
                Text("Aisle+").foregroundStyle(Theme.accentInk), header: true)
            ForEach(Array(comparison.enumerated()), id: \.offset) { index, item in
                Divider().overlay(Theme.hairline)
                HStack(spacing: 0) {
                    Text(item.0)
                        .font(Theme.font(14, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    cell(item.1, plus: false).frame(width: 76)
                    cell(item.2, plus: true).frame(width: 96)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.0): free, \(spoken(item.1)); Aisle+, \(spoken(item.2))")
            }
        }
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
    }

    private func row(_ a: Text, _ b: Text, _ c: Text, header: Bool) -> some View {
        HStack(spacing: 0) {
            a.frame(maxWidth: .infinity, alignment: .leading)
            b.frame(width: 76)
            c.frame(width: 96)
        }
        .font(Theme.font(12, .bold, relativeTo: .caption))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cell(_ value: String, plus: Bool) -> some View {
        if value == "✓" {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(plus ? Theme.onAccent : Theme.ink)
                .frame(width: 24, height: 24)
                .background(plus ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fill), in: Circle())
        } else {
            Text(value)
                .font(Theme.font(13, plus ? .bold : .regular, relativeTo: .footnote))
                .foregroundStyle(plus ? Theme.ink : Theme.secondaryInk)
                .multilineTextAlignment(.center)
        }
    }

    private func spoken(_ value: String) -> String {
        switch value {
        case "✓": return "included"
        case "—": return "not included"
        default: return value
        }
    }
}

/// "aisle+" with the plus in the gradient.
struct PlusWordmark: View {
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: size * 0.3) {
            AisleMark(size: size + 4)
            (Text("aisle") + Text("+").foregroundStyle(Theme.accentInk))
                .font(Theme.font(size, .bold, relativeTo: .title2))
                .tracking(-0.7)
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aisle plus")
    }
}

/// The big card: a slowly flowing gradient with a few sparkles.
private struct HeroCard: View {
    let isPlus: Bool
    let yearlyPrice: String
    let onTry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Aisle+", systemImage: "sparkles")
                .font(Theme.font(12, .bold, relativeTo: .caption))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.white.opacity(0.55), in: Capsule())
            Text(isPlus ? "You're on\nAisle+." : "Find it faster,\neverywhere.")
                .font(Theme.font(34, .bold, relativeTo: .largeTitle))
                .tracking(-1.2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Text(isPlus
                 ? "Unlimited photo search, shared lists and trips across stores are on. Thanks for supporting Aisle."
                 : "Unlimited photo search, shared lists and trips across stores. Aisle stays honest either way.")
                .font(Theme.font(15, relativeTo: .subheadline))
                .opacity(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            if !isPlus {
                Button(action: onTry) {
                    Text("Try 7 days free")
                        .font(.aisleHeadline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Color(hex: 0x1F1B24), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(PressableCardStyle())
                .padding(.top, 20)
                Text("Then \(yearlyPrice) a year · cancel anytime")
                    .font(Theme.font(12, relativeTo: .caption))
                    .opacity(0.7)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            }
        }
        .foregroundStyle(Theme.onAccent)
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                FlowingGradient(time: t)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: Theme.glow.opacity(0.25), radius: 22, y: 14)
    }
}

/// The accent gradient drifting slowly, with three twinkling sparkles.
struct FlowingGradient: View {
    let time: TimeInterval

    private static let sizes: [CGFloat] = [8, 5, 6]
    private static let offsets: [CGSize] = [CGSize(width: -26, height: 26), CGSize(width: -64, height: 58), CGSize(width: -40, height: 96)]

    var body: some View {
        let shift = sin(time * 2 * .pi / 12)
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [Color(hex: 0xE2CFF9), Color(hex: 0xF9CFE0), Color(hex: 0xFFDDC6), Color(hex: 0xFFEDC2), Color(hex: 0xF9CFE0)],
                startPoint: UnitPoint(x: -0.3 + 0.3 * shift, y: 0),
                endPoint: UnitPoint(x: 1.3 + 0.3 * shift, y: 1)
            )
            ForEach(0..<3, id: \.self) { index in
                let phase = (time / 2.4 + Double(index) * 0.33).truncatingRemainder(dividingBy: 1)
                let glow = 0.2 + 0.8 * abs(sin(phase * .pi))
                Circle()
                    .fill(.white)
                    .frame(width: Self.sizes[index], height: Self.sizes[index])
                    .opacity(glow)
                    .scaleEffect(0.6 + 0.4 * glow)
                    .offset(Self.offsets[index])
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FeatureTile: View {
    let feature: PlusFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: feature.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 40, height: 40)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            Text(feature.title)
                .font(Theme.font(15, .bold, relativeTo: .subheadline))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(feature.detail)
                .font(Theme.font(12, relativeTo: .caption))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Upgrade prompts

extension View {
    /// Opens the Aisle+ offer as a sheet when `reason` is set (e.g. a free-tier limit was
    /// hit), with the reason above it, and clears it when the sheet closes.
    func plusUpgradeSheet(reason: Binding<String?>) -> some View {
        sheet(isPresented: Binding(get: { reason.wrappedValue != nil }, set: { if !$0 { reason.wrappedValue = nil } })) {
            PaywallView(reason: reason.wrappedValue)
        }
    }
}

// MARK: - Paywall

/// The upgrade sheet: close and restore, a headline, a scrolling strip of what's included,
/// Free vs Aisle+, two plan cards side by side, and one big button.
struct PaywallView: View {
    /// Why the sheet opened, e.g. "You've used today's 5 photo searches." Nil from the tab.
    let reason: String?
    /// The Aisle+ tab rather than a sheet: the wordmark instead of Close, and subscribers
    /// see what they have instead of the offer.
    var inTab = false

    @Environment(PlusStore.self) private var plus
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var plan: PlusStore.Plan = .yearly
    @State private var trial: String?
    @State private var isBuying = false
    @State private var welcomed = false
    @State private var errorMessage: String?

    /// Your privacy policy page. Apple requires one before Aisle+ can ship; the link hides until it's set.
    static let privacyURL: URL? = nil
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    private static let table: [(String, Bool)] = [
        ("Find items in any store", true),
        ("Unlimited photo search", false),
        ("Unlimited follow-ups", false),
        ("Shared family lists", false),
        ("Multi-store trips", false),
        ("Offline store maps", false),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if inTab {
                    PlusWordmark(size: 22)
                } else {
                    CircleButton(systemImage: "xmark", label: "Close") { dismiss() }
                }
                Spacer()
                if !welcomed && !(inTab && plus.isPlus) {
                    Button("Restore") { Task { await restore() } }
                        .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 20)
                        .frame(height: 48)
                        .background(Theme.surface, in: Capsule())
                        .shadow(color: Theme.ink.opacity(0.08), radius: 12, y: 6)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            if welcomed {
                PlusWelcome {
                    if inTab {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { welcomed = false }
                    } else {
                        dismiss()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if inTab && plus.isPlus {
                PlusMemberView().transition(.opacity)
            } else {
                offer.transition(.opacity)
            }
        }
        .background(AisleBackground())
        .presentationDragIndicator(.hidden)
        .sensoryFeedback(.success, trigger: welcomed)
        .task {
            await plus.load()
            trial = await plus.trialLabel(.yearly)
        }
        .alert("Couldn't complete the purchase", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var offer: some View {
        ScrollView {
            VStack(spacing: 0) {
                (Text("Find everything,\nin ") + Text("every store").fontWeight(.bold).foregroundStyle(Theme.accentInk))
                    .font(Theme.font(30, .semibold, relativeTo: .largeTitle))
                    .tracking(-0.9)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)
                    .accessibilityAddTraits(.isHeader)
                if let reason {
                    Text(reason)
                        .font(Theme.font(14, relativeTo: .subheadline))
                        .foregroundStyle(Theme.secondaryInk)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }

                FeatureMarquee()
                    .padding(.horizontal, -18)
                    .padding(.top, 18)

                comparison.padding(.top, 22)

                HStack(spacing: 12) {
                    PlanTile(
                        title: "Yearly",
                        badge: "−\(plus.yearlySavingsPercent)%",
                        price: plus.price(.yearly), unit: "/yr",
                        note: "\(plus.yearlyPerMonth)/mo",
                        selected: plan == .yearly
                    ) { select(.yearly) }
                    PlanTile(
                        title: "Monthly", badge: nil,
                        price: plus.price(.monthly), unit: "/mo",
                        note: "\(plus.monthlyPerYear)/yr",
                        selected: plan == .monthly
                    ) { select(.monthly) }
                }
                .padding(.top, 18)

                Button { Task { await buy() } } label: {
                    ZStack {
                        if isBuying {
                            ProgressView().tint(Theme.onAccent)
                        } else {
                            Text(ctaTitle).font(Theme.font(18, .bold, relativeTo: .headline))
                        }
                    }
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background {
                        TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
                            FlowingGradient(time: timeline.date.timeIntervalSinceReferenceDate)
                        }
                    }
                    .clipShape(Capsule())
                    .shadow(color: Theme.glow.opacity(0.28), radius: 14, y: 10)
                }
                .buttonStyle(PressableCardStyle())
                .disabled(isBuying || !plus.canPurchase)
                .padding(.top, 18)
                .accessibilityIdentifier("plusPurchaseButton")

                Text(finePrint)
                    .font(Theme.font(12, relativeTo: .caption))
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                HStack(spacing: 16) {
                    Button("Terms") { openURL(Self.termsURL) }
                    if let privacy = Self.privacyURL {
                        Button("Privacy") { openURL(privacy) }
                    }
                }
                .font(Theme.font(12, .semibold, relativeTo: .caption))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 10)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var comparison: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Features").frame(maxWidth: .infinity, alignment: .leading)
                Text("Free").frame(width: 52)
                Text("Aisle+").fontWeight(.bold).foregroundStyle(Theme.accentInk).frame(width: 64)
            }
            .font(Theme.font(15, relativeTo: .subheadline))
            .foregroundStyle(Theme.secondaryInk)
            .frame(minHeight: 34)
            .accessibilityHidden(true)

            ForEach(Self.table, id: \.0) { feature, free in
                HStack(spacing: 0) {
                    Text(feature)
                        .font(Theme.font(16, relativeTo: .body))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if free {
                            Image(systemName: "checkmark").font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.secondaryInk)
                        } else {
                            Capsule().fill(Theme.secondaryInk.opacity(0.6)).frame(width: 14, height: 1.5)
                        }
                    }
                    .frame(width: 52)
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hex: 0xDC6F9C))
                        .frame(width: 64)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(feature): \(free ? "free and Aisle+" : "Aisle+ only")")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 16, y: 8)
    }

    private var ctaTitle: String {
        if !plus.canPurchase { return plus.isLoading ? "Loading…" : "Not available yet" }
        switch plan {
        case .yearly: return trial == nil ? "Get Aisle+" : "Start free week"
        case .monthly: return "Get Aisle+"
        }
    }

    private var finePrint: String {
        if let error = plus.loadError, !plus.canPurchase { return error }
        switch plan {
        case .yearly:
            let start = trial.map { "\($0.replacingOccurrences(of: "-", with: " ")) free, then " } ?? ""
            return "\(start)\(plus.price(.yearly))/year. Renews automatically. Cancel anytime."
        case .monthly:
            return "\(plus.price(.monthly))/month. Renews automatically. Cancel anytime."
        }
    }

    private func select(_ newPlan: PlusStore.Plan) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { plan = newPlan }
    }

    private func buy() async {
        isBuying = true
        defer { isBuying = false }
        do {
            if try await plus.purchase(plan) == .purchased {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { welcomed = true }
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Something went wrong. You weren't charged."
        }
    }

    private func restore() async {
        do {
            try await plus.restore()
            if plus.isPlus {
                withAnimation { welcomed = true }
            } else {
                errorMessage = "No Aisle+ purchase was found for this Apple ID."
            }
        } catch {
            errorMessage = "Couldn't reach the App Store. Try again in a moment."
        }
    }
}

private struct CircleButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 48, height: 48)
                .background(Theme.surface, in: Circle())
                .shadow(color: Theme.ink.opacity(0.08), radius: 12, y: 6)
        }
        .accessibilityLabel(label)
    }
}

/// What's included, scrolling sideways forever with faded edges.
private struct FeatureMarquee: View {
    private static let items: [(String, String)] = [
        ("camera", "Unlimited photos"),
        ("person.2", "Family lists"),
        ("point.topleft.down.to.point.bottomright.curvepath", "Multi-store trips"),
        ("map", "Offline maps"),
        ("bubble.left", "Unlimited follow-ups"),
        ("bolt", "Faster answers"),
    ]

    @State private var rowWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The strip (two copies of the row, for a seamless loop) is far wider than the
        // screen, so it's an overlay: overlays don't size their parent, which stays as wide
        // as it's offered.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .overlay(alignment: .leading) {
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let speed = 22.0   // points per second
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let offset = rowWidth > 0 && !reduceMotion ? -CGFloat((t * speed).truncatingRemainder(dividingBy: Double(rowWidth))) : 0
                    HStack(spacing: 0) {
                        row.background(GeometryReader { geo in
                            Color.clear.onAppear { rowWidth = geo.size.width }
                        })
                        row
                    }
                    .offset(x: offset)
                }
            }
            .clipped()
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
            .init(color: .black, location: 0.88), .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.items.map(\.1).joined(separator: ", "))
    }

    private var row: some View {
        HStack(spacing: 26) {
            ForEach(Self.items, id: \.1) { symbol, title in
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xDC6F9C))
                    Text(title)
                        .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                        .fixedSize()
                }
            }
        }
        .padding(.trailing, 26)
        .fixedSize()
    }
}

/// A plan card; the chosen one gets a gradient outline and a check that pops onto its corner.
private struct PlanTile: View {
    let title: String
    let badge: String?
    let price: String
    let unit: String
    let note: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Theme.font(15, relativeTo: .subheadline))
                        .foregroundStyle(Theme.secondaryInk)
                    if let badge {
                        Text(badge)
                            .font(Theme.font(11, .bold, relativeTo: .caption2))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                (Text(price).font(Theme.font(26, .bold, relativeTo: .title))
                    + Text(" \(unit)").font(Theme.font(14, .medium, relativeTo: .footnote)).foregroundStyle(Theme.secondaryInk))
                    .foregroundStyle(Theme.ink)
                    .tracking(-0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 8)
                Text(note)
                    .font(Theme.font(13, relativeTo: .footnote))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.accentRing) : AnyShapeStyle(Theme.hairline), lineWidth: 1.5)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent, in: Circle())
                    .shadow(color: Theme.glow.opacity(0.3), radius: 5, y: 4)
                    .scaleEffect(selected ? 1 : 0.4)
                    .opacity(selected ? 1 : 0)
                    .offset(x: 8, y: -10)
            }
            .shadow(color: Theme.glow.opacity(selected ? 0.18 : 0), radius: 12, y: 10)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel("\(title), \(price) \(unit == "/yr" ? "a year" : "a month"). \(note)")
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// After buying: a burst around the badge and a first thing to try.
private struct PlusWelcome: View {
    let onDone: () -> Void

    @State private var burst = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                ForEach(0..<12, id: \.self) { index in
                    let angle = Double(index) / 12 * 2 * .pi
                    Circle()
                        .fill(Theme.accentColors[index % Theme.accentColors.count])
                        .frame(width: index.isMultiple(of: 3) ? 11 : 8)
                        .offset(x: burst ? cos(angle) * 130 : 0, y: burst ? sin(angle) * 130 : 0)
                        .opacity(burst ? 0 : 1)
                }
                Image("AisleLogo")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 58, height: 58)
                    .frame(width: 120, height: 120)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                    .shadow(color: Theme.glow.opacity(0.35), radius: 22, y: 14)
                    .scaleEffect(burst ? 1 : 0.8)
            }
            .accessibilityHidden(true)
            (Text("Welcome to ") + Text("Aisle+").foregroundStyle(Theme.accentInk))
                .font(Theme.font(32, .bold, relativeTo: .largeTitle))
                .tracking(-1)
                .foregroundStyle(Theme.ink)
                .padding(.top, 26)
            Text("Everything in Aisle+ is on. Manage or cancel any time in Settings › Apple ID › Subscriptions.")
                .font(Theme.font(15, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Spacer()
            Button("Start shopping", action: onDone)
                .buttonStyle(.aisleAccent)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 24)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) { burst = true }
        }
    }
}
