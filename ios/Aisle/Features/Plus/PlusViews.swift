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

/// The Aisle+ tab: a living gradient card, what you get, and Free vs Aisle+.
struct PlusTabView: View {
    @Environment(PlusStore.self) private var plus
    @State private var showingPaywall = false
    @State private var restoreMessage: String?
    @State private var scrolledUnderStatusBar: CGFloat = 0

    private let comparison: [(String, String, String)] = [
        ("Find items in any store", "✓", "✓"),
        ("Photo searches", "5 a day", "Unlimited"),
        ("Follow-up questions", "10 a day", "Unlimited"),
        ("Lists", "1", "Unlimited, shared"),
        ("Multi-store trips", "—", "✓"),
        ("Offline store maps", "—", "✓"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        PlusWordmark(size: 22)
                        Spacer()
                        if !plus.isPlus {
                            Button("Restore") { Task { await restore() } }
                                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(Theme.surface.opacity(0.92), in: Capsule())
                        }
                    }
                    .trackingScrollUnderStatusBar($scrolledUnderStatusBar)

                    HeroCard(isPlus: plus.isPlus, yearlyPrice: plus.price(.yearly)) {
                        showingPaywall = true
                    }
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
            .safeAreaInset(edge: .top, spacing: 0) { StatusBarBackdrop(scrolled: scrolledUnderStatusBar) }
            .background(AisleBackground())
            .toolbar(.hidden, for: .navigationBar)
            .task { await plus.load() }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(reason: nil)
            }
            .alert("Restore purchases", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(restoreMessage ?? "")
            }
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

    private func restore() async {
        do {
            try await plus.restore()
            restoreMessage = plus.isPlus ? "Aisle+ is active on this device." : "No Aisle+ purchase was found for this Apple ID."
        } catch {
            restoreMessage = "Couldn't reach the App Store. Try again in a moment."
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

// MARK: - Paywall

/// The upgrade sheet: why it appeared, benefits, two plans, the button, and the small print.
struct PaywallView: View {
    /// Why the sheet opened, e.g. "You've used today's 5 photo searches." Nil from the tab.
    let reason: String?

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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if welcomed {
                PlusWelcome { dismiss() }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                offer.transition(.opacity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 36, height: 36)
                    .background(Theme.fill, in: Circle())
            }
            .accessibilityLabel("Close")
            .padding(16)
        }
        .background(AisleBackground())
        .presentationDragIndicator(.visible)
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
                PlusBadge().padding(.top, 36)
                (Text("Unlock ") + Text("Aisle+").foregroundStyle(Theme.accentInk))
                    .font(Theme.font(30, .bold, relativeTo: .largeTitle))
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 18)
                    .accessibilityAddTraits(.isHeader)
                if let reason {
                    Text(reason)
                        .font(Theme.font(14, relativeTo: .subheadline))
                        .foregroundStyle(Theme.secondaryInk)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(PlusFeature.allCases) { feature in
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 24, height: 24)
                                .background(Theme.accent, in: Circle())
                            Text(feature.title)
                                .font(Theme.font(15, relativeTo: .subheadline))
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 22)

                VStack(spacing: 10) {
                    PlanCard(
                        title: "Yearly",
                        detail: "\(plus.yearlyPerMonth) a month, billed \(plus.price(.yearly))",
                        price: plus.price(.yearly),
                        badge: "Save \(plus.yearlySavingsPercent)%",
                        selected: plan == .yearly
                    ) { select(.yearly) }
                    PlanCard(
                        title: "Monthly", detail: "Billed every month",
                        price: plus.price(.monthly), badge: nil,
                        selected: plan == .monthly
                    ) { select(.monthly) }
                }
                .padding(.top, 22)

                Button { Task { await buy() } } label: {
                    ZStack {
                        if isBuying {
                            ProgressView().tint(Theme.onAccent)
                        } else {
                            Text(ctaTitle).font(Theme.font(17, .bold, relativeTo: .headline))
                        }
                    }
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background {
                        TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
                            FlowingGradient(time: timeline.date.timeIntervalSinceReferenceDate)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Theme.glow.opacity(0.25), radius: 12, y: 8)
                }
                .buttonStyle(PressableCardStyle())
                .disabled(isBuying || !plus.canPurchase)
                .padding(.top, 20)
                .accessibilityIdentifier("plusPurchaseButton")

                Text(finePrint)
                    .font(Theme.font(12, relativeTo: .caption))
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                HStack(spacing: 18) {
                    Button("Restore purchases") { Task { await restore() } }
                    Button("Terms") { openURL(URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) }
                    if let privacy = PaywallView.privacyURL {
                        Button("Privacy") { openURL(privacy) }
                    }
                }
                .font(Theme.font(12, .semibold, relativeTo: .caption))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 16)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
        }
    }

    private var ctaTitle: String {
        if !plus.canPurchase { return plus.isLoading ? "Loading…" : "Not available yet" }
        switch plan {
        case .yearly: return trial.map { "Start \($0) free trial" } ?? "Subscribe for \(plus.price(.yearly)) a year"
        case .monthly: return "Subscribe for \(plus.price(.monthly)) a month"
        }
    }

    private var finePrint: String {
        if let error = plus.loadError, !plus.canPurchase { return error }
        switch plan {
        case .yearly:
            let start = trial.map { "Free for \($0.replacingOccurrences(of: "-", with: " ")), then " } ?? ""
            return "\(start)\(plus.price(.yearly)) a year. Renews automatically. Cancel anytime in Settings."
        case .monthly:
            return "\(plus.price(.monthly)) a month. Renews automatically. Cancel anytime in Settings."
        }
    }

    private func select(_ newPlan: PlusStore.Plan) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { plan = newPlan }
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

/// The logo on a gradient tile with a soft spinning glow and a "+" badge.
private struct PlusBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(AngularGradient(colors: [Color(hex: 0xE2CFF9), Theme.glow, Color(hex: 0xFFDDC6), Color(hex: 0xFFEDC2), Color(hex: 0xE2CFF9)], center: .center))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .blur(radius: 14)
                .opacity(0.7)
                .frame(width: 96, height: 96)
            Image("AisleLogo")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(Theme.onAccent)
                .frame(width: 46, height: 46)
                .frame(width: 84, height: 84)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .frame(width: 96, height: 96)
            Text("+")
                .font(Theme.font(18, .bold, relativeTo: .headline))
                .foregroundStyle(Color(hex: 0xFFEDC2))
                .frame(width: 30, height: 30)
                .background(Color(hex: 0x1F1B24), in: Circle())
                .offset(x: 6, y: -6)
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

private struct PlanCard: View {
    let title: String
    let detail: String
    let price: String
    let badge: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle()
                    .strokeBorder(selected ? Color(hex: 0xDC6F9C) : Theme.hairline, lineWidth: selected ? 7 : 2)
                    .background(Circle().fill(selected ? Color.white : Color.clear))
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.font(16, .bold, relativeTo: .body))
                    Text(detail).font(Theme.font(12, relativeTo: .caption)).foregroundStyle(Theme.secondaryInk)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    if let badge {
                        Text(badge)
                            .font(Theme.font(11, .bold, relativeTo: .caption2))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Theme.accent, in: Capsule())
                    }
                    Text(price).font(Theme.font(15, .bold, relativeTo: .subheadline))
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: 72)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.accentRing) : AnyShapeStyle(Theme.hairline), lineWidth: 2)
            }
            .shadow(color: Theme.glow.opacity(selected ? 0.18 : 0), radius: 11, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityLabel("\(title), \(price). \(detail)")
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
