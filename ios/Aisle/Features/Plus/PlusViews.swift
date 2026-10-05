import StoreKit
import SwiftUI

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

/// What a subscriber sees on the Aisle+ tab: what Aisle+ gave them lately, their plan,
/// and each benefit as a tile showing how they use it (or inviting them to try it).
private struct PlusMemberView: View {
    @Environment(PlusStore.self) private var plus
    @Environment(AccountStore.self) private var accounts
    @Environment(ShoppingListStore.self) private var lists
    @Environment(\.offlineMaps) private var offlineMaps
    @Environment(\.openTab) private var openTab
    @Environment(\.openURL) private var openURL
    @AppStorage(MemberActivity.photosKey) private var photos = 0
    @AppStorage(MemberActivity.followUpsKey) private var followUps = 0
    @AppStorage(MemberActivity.lastQuestionKey) private var lastQuestion = ""
    @AppStorage(MemberActivity.lastAnswerKey) private var lastAnswer = ""
    @AppStorage(MemberActivity.tripsKey) private var trips = 0

    @State private var days: [MemberActivity.Day] = []
    @State private var thumbnails: [UIImage] = []
    @State private var membership: PlusStore.Membership?
    @State private var savedMaps = 0
    @State private var managing = false
    @State private var restoreMessage: String?
    @State private var cancelling = false

    static let supportEmail = "support@shopaisle.app"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                UsageChart(days: days)
                    .padding(.top, 20)
                planStrip
                    .padding(.top, 12)
                Text("What you're getting")
                    .font(Theme.font(20, .bold, relativeTo: .title3))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                    .accessibilityAddTraits(.isHeader)
                bento
                HStack(spacing: 22) {
                    Button("Restore purchases") { Task { await restore() } }
                    Button("Help") { mail(subject: "Aisle+ help") }
                    if membership?.willRenew ?? true {
                        Button("Cancel Aisle+") { cancelling = true }
                            .accessibilityIdentifier("cancelPlusButton")
                    }
                }
                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(Theme.secondaryInk)
                .frame(maxWidth: .infinity)
                .padding(.top, 26)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .task { await refresh() }
        .sheet(isPresented: $cancelling, onDismiss: { Task { membership = await plus.membership() } }) {
            CancelPlusFlow(
                extraPhotoSearches: days.reduce(0) { $0 + $1.extra },
                sharedLists: sharedLists.count
            )
            .presentationDetents([.large])
        }
        .manageSubscriptionsSheet(isPresented: $managing)
        .onChange(of: managing) { _, open in
            if !open { Task { membership = await plus.membership() } }
        }
        .alert("Restore purchases", isPresented: Binding(get: { restoreMessage != nil }, set: { if !$0 { restoreMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreMessage ?? "")
        }
    }

    // MARK: - Header and plan

    private var firstName: String? { accounts.account?.firstName }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.everyMinute) { context in
                    Text(greeting(context.date) + (firstName.map { ", \($0)" } ?? ""))
                        .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(Theme.secondaryInk)
                }
                (Text("Your aisle") + Text("+").foregroundStyle(Theme.accentInk))
                    .font(Theme.font(32, .bold, relativeTo: .largeTitle))
                    .tracking(-1.2)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            ZStack {
                Circle().fill(AngularGradient(
                    colors: [Color(hex: 0xE2CFF9), Theme.glow, Color(hex: 0xFFDDC6), Color(hex: 0xFFEDC2), Color(hex: 0xE2CFF9)],
                    center: .center, angle: .degrees(210)))
                Circle().fill(Theme.surface).padding(3)
                if let initial = accounts.account?.initial {
                    Text(initial).font(Theme.font(17, .bold, relativeTo: .headline)).foregroundStyle(Theme.ink)
                } else {
                    AisleMark(size: 20)
                }
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)
        }
    }

    private func greeting(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var planStrip: some View {
        HStack(spacing: 14) {
            Image("AisleLogo")
                .resizable().renderingMode(.template).scaledToFit()
                .foregroundStyle(Theme.onAccent)
                .frame(width: 32, height: 32)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(planTitle).font(Theme.font(15, .bold, relativeTo: .subheadline))
                if let planDetail {
                    Text(planDetail).font(Theme.font(12, relativeTo: .caption)).opacity(0.75)
                }
            }
            Spacer(minLength: 8)
            Button("Manage") { managing = true }
                .font(Theme.font(12, .bold, relativeTo: .caption))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(.white.opacity(0.6), in: Capsule())
                .accessibilityHint("Change your plan or cancel in the App Store")
        }
        .foregroundStyle(Theme.onAccent)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Theme.glow.opacity(0.2), radius: 14, y: 10)
    }

    private var planTitle: String {
        guard let membership else { return "Aisle+" }
        let plan = membership.plan == .yearly ? "Yearly" : "Monthly"
        return membership.isTrial ? "\(plan) · free trial" : plan
    }

    private var planDetail: String? {
        guard let membership, let date = membership.nextDate else { return nil }
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        if !membership.willRenew { return "Ends \(day)" }
        return membership.isTrial ? "First charge \(membership.price) on \(day)" : "Renews \(day) · \(membership.price)"
    }

    // MARK: - Benefits

    private var sharedLists: [ShoppingList] { lists.lists.filter { $0.shared != nil } }

    private var sharedPeople: [String] {
        var seen: [String] = []
        for list in sharedLists {
            for member in list.shared?.members ?? [] where !member.isYou && !seen.contains(member.firstName) {
                seen.append(member.firstName)
            }
        }
        return seen
    }

    private var bento: some View {
        VStack(spacing: 12) {
            PhotoTile(count: photos, thumbnails: thumbnails) { snap() }
            HStack(alignment: .top, spacing: 12) {
                FollowUpTile(count: followUps, question: lastQuestion, answer: lastAnswer)
                FamilyTile(lists: sharedLists.count, people: sharedPeople) { openTab(.list) }
            }
            HStack(alignment: .top, spacing: 12) {
                TripTile(count: trips) { openTab(.list) }
                OfflineTile(stores: savedMaps)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Got an idea for Aisle+?").font(Theme.font(15, .bold, relativeTo: .subheadline))
                    Text("Members shape what we build next.")
                        .font(Theme.font(12, relativeTo: .caption))
                        .foregroundStyle(Theme.secondaryInk)
                }
                Spacer(minLength: 8)
                Button("Suggest") { mail(subject: "Aisle+ idea") }
                    .font(Theme.font(12, .bold, relativeTo: .caption))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Theme.surface, in: Capsule())
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }

    // MARK: - Actions

    private func refresh() async {
        days = MemberActivity.recentDays()
        thumbnails = MemberActivity.thumbnails()
        savedMaps = offlineMaps?.savedStoreIDs.count ?? 0
        membership = await plus.membership()
    }

    private func snap() {
        openTab(.find)
        NotificationCenter.default.post(name: .aisleOpenCamera, object: nil)
    }

    private func mail(subject: String) {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = Self.supportEmail
        parts.queryItems = [URLQueryItem(name: "subject", value: subject)]
        if let url = parts.url { openURL(url) }
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

// MARK: - Usage chart

/// Photo searches per day for two weeks: the free part grey, anything past the daily
/// free limit in the accent gradient, with a dashed line at the limit.
private struct UsageChart: View {
    let days: [MemberActivity.Day]

    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var extraTotal: Int { days.reduce(0) { $0 + $1.extra } }
    private var maxCount: Int { max(days.map(\.count).max() ?? 0, MemberActivity.freePhotosPerDay + 2) }
    private var freeColor: Color { colorScheme == .dark ? Color(hex: 0x3A3440) : Color(hex: 0xDDE0D9) }
    private let chartHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Last 2 weeks")
                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(Theme.secondaryInk)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(extraTotal)")
                    .font(Theme.font(44, .bold, relativeTo: .largeTitle))
                    .tracking(-2)
                    .foregroundStyle(Theme.accentInk)
                    .contentTransition(.numericText(value: Double(extraTotal)))
                Text(extraTotal == 1 ? "photo search past the free limit" : "photo searches past the free limit")
                    .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            ZStack(alignment: .topLeading) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        bar(day, index: index)
                        if index < days.count - 1 { Spacer(minLength: 2) }
                    }
                }
                .frame(height: chartHeight, alignment: .bottom)
                let lineY = chartHeight - CGFloat(MemberActivity.freePhotosPerDay) / CGFloat(maxCount) * chartHeight
                Path { path in
                    path.move(to: CGPoint(x: 0, y: lineY))
                    path.addLine(to: CGPoint(x: 2000, y: lineY))
                }
                .stroke(Theme.secondaryInk.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .frame(height: chartHeight)
                .clipped()
                Text("Free: \(MemberActivity.freePhotosPerDay) a day")
                    .font(Theme.font(10, .semibold, relativeTo: .caption2))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.horizontal, 4)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(y: lineY - 18)
            }
            .frame(height: chartHeight)
            .padding(.top, 18)
            .accessibilityHidden(true)

            HStack {
                Text(days.first.map { $0.date.formatted(.dateTime.month(.abbreviated).day()) } ?? "")
                Spacer()
                Text("Today")
            }
            .font(Theme.font(11, relativeTo: .caption2))
            .foregroundStyle(Theme.secondaryInk)
            .padding(.top, 8)

            HStack(spacing: 14) {
                legend(AnyShapeStyle(freeColor), "Included free")
                legend(AnyShapeStyle(LinearGradient(colors: [Theme.glow, Color(hex: 0xFFDDC6)], startPoint: .top, endPoint: .bottom)), "Thanks to Aisle+")
            }
            .padding(.top, 14)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 16, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("In the last 2 weeks, \(extraTotal) photo searches went past the free limit of \(MemberActivity.freePhotosPerDay) a day.")
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.8).delay(0.15)) { grown = true }
        }
    }

    private func bar(_ day: MemberActivity.Day, index: Int) -> some View {
        let unit = chartHeight / CGFloat(maxCount)
        let freePart = CGFloat(min(day.count, MemberActivity.freePhotosPerDay)) * unit
        let extraPart = CGFloat(day.extra) * unit
        return VStack(spacing: 0) {
            if day.extra > 0 {
                UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5)
                    .fill(LinearGradient(colors: [Theme.glow, Color(hex: 0xFFDDC6)], startPoint: .top, endPoint: .bottom))
                    .frame(height: grown ? extraPart : 0)
            }
            UnevenRoundedRectangle(
                topLeadingRadius: day.extra > 0 ? 0 : 5, bottomLeadingRadius: 5,
                bottomTrailingRadius: 5, topTrailingRadius: day.extra > 0 ? 0 : 5
            )
            .fill(freeColor)
            .frame(height: max(3, freePart))
        }
        .frame(width: 14)
    }

    private func legend(_ style: AnyShapeStyle, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(style).frame(width: 10, height: 10)
            Text(text)
        }
        .font(Theme.font(12, relativeTo: .caption))
        .foregroundStyle(Theme.secondaryInk)
    }
}

// MARK: - Tiles

private struct TileLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.font(12, .bold, relativeTo: .caption))
            .tracking(0.7)
            .foregroundStyle(Theme.secondaryInk)
    }
}

private struct BigFigure: View {
    let value: String
    var caption: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.font(30, .bold, relativeTo: .title))
                .tracking(-1.3)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption).font(Theme.font(12, relativeTo: .caption)).foregroundStyle(Theme.secondaryInk)
            }
        }
    }
}

private extension View {
    func tile(minHeight: CGFloat = 196) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
    }
}

private struct GradientPill: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 13, weight: .semibold)) }
                Text(title)
            }
            .font(Theme.font(12, .bold, relativeTo: .caption))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(PressableCardStyle())
    }
}

private struct PhotoTile: View {
    let count: Int
    let thumbnails: [UIImage]
    let onSnap: () -> Void

    @State private var shown = false
    private static let tilts: [Double] = [-6, 3, -2, 5]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    TileLabel(text: "Photo search")
                    BigFigure(value: count == 1 ? "1 snap" : "\(count) snaps")
                }
                Spacer()
                GradientPill(title: "Snap", systemImage: "camera", action: onSnap)
            }
            HStack(spacing: 10) {
                if thumbnails.isEmpty {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            .frame(width: 60, height: 64)
                            .rotationEffect(.degrees(Self.tilts[index]))
                    }
                } else {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { index, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accentRing, lineWidth: 1.5))
                            .rotationEffect(.degrees(Self.tilts[index % Self.tilts.count]))
                            .shadow(color: Theme.ink.opacity(0.10), radius: 7, y: 6)
                            .opacity(shown ? 1 : 0)
                            .offset(y: shown ? 0 : 10)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15 + Double(index) * 0.07), value: shown)
                    }
                    if count > thumbnails.count {
                        Text("+\(count - thumbnails.count)")
                            .font(Theme.font(14, .bold, relativeTo: .subheadline))
                            .foregroundStyle(Theme.secondaryInk)
                            .frame(width: 58, height: 64)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.top, 14)
            .accessibilityHidden(true)
            Text(thumbnails.isEmpty ? "Snap anything you can't find. No daily cap." : "Your latest finds, no daily cap.")
                .font(Theme.font(12, relativeTo: .caption))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 12)
        }
        .tile(minHeight: 0)
        .onAppear { shown = true }
        .accessibilityElement(children: .combine)
    }
}

private struct FollowUpTile: View {
    let count: Int
    let question: String
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TileLabel(text: "Follow-ups")
            VStack(alignment: .leading, spacing: 6) {
                Text(question.isEmpty ? "is it gluten free?" : question)
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.accentSoft, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                HStack(spacing: 6) {
                    AisleMark(size: 13)
                    Text(answer.isEmpty ? "Ask Aisle anything after a search" : answer).lineLimit(2)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.fill, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 4, bottomTrailingRadius: 14, topTrailingRadius: 14))
            }
            .font(Theme.font(12, relativeTo: .caption))
            .foregroundStyle(Theme.ink)
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            BigFigure(value: "\(count)", caption: count == 1 ? "question asked" : "questions asked")
        }
        .tile()
        .accessibilityElement(children: .combine)
    }
}

private struct FamilyTile: View {
    let lists: Int
    let people: [String]
    let onInvite: () -> Void

    @State private var bob = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let spots: [CGPoint] = [CGPoint(x: 18, y: 36), CGPoint(x: 58, y: 18), CGPoint(x: 98, y: 40)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TileLabel(text: "Family lists")
            ZStack(alignment: .topLeading) {
                ForEach(Array(people.prefix(3).enumerated()), id: \.offset) { index, name in
                    Text(String(name.prefix(1)).uppercased())
                        .font(Theme.font(24, .bold, relativeTo: .title2))
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: 36, height: 36)
                        .position(Self.spots[index])
                        .offset(y: bob && !reduceMotion ? (index.isMultiple(of: 2) ? -3 : 3) : 0)
                }
                Button(action: onInvite) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(Theme.secondaryInk, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
                }
                .position(people.isEmpty ? Self.spots[0] : CGPoint(x: Self.spots[min(people.count, 3) - 1].x + 38, y: 36))
                .accessibilityLabel("Invite someone to a list")
            }
            .frame(height: 60)
            Spacer(minLength: 0)
            BigFigure(
                value: lists == 1 ? "1 list" : "\(lists) lists",
                caption: people.isEmpty ? "Share one with family" : "shared with \(people.count) \(people.count == 1 ? "person" : "people")"
            )
        }
        .tile()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { bob = true }
        }
    }
}

private struct TripTile: View {
    let count: Int
    let onPlan: () -> Void

    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TileLabel(text: "Multi-store trips")
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 12, y: 44))
                    path.addCurve(to: CGPoint(x: 76, y: 12), control1: CGPoint(x: 40, y: 44), control2: CGPoint(x: 50, y: 12))
                    path.addCurve(to: CGPoint(x: 128, y: 14), control1: CGPoint(x: 102, y: 12), control2: CGPoint(x: 116, y: 30))
                }
                .stroke(Color(hex: 0xDC6F9C), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [3, 7], dashPhase: phase))
                ForEach(Array([CGPoint(x: 12, y: 44), CGPoint(x: 76, y: 12), CGPoint(x: 128, y: 14)].enumerated()), id: \.offset) { index, point in
                    Text("\(index + 1)")
                        .font(Theme.font(10, .bold, relativeTo: .caption2))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 18, height: 18)
                        .background([Color(hex: 0xE2CFF9), Color(hex: 0xF9CFE0), Color(hex: 0xFFDDC6)][index], in: Circle())
                        .position(point)
                }
            }
            .frame(width: 140, height: 56)
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            if count == 0 {
                Text("One route across stores. You haven't tried it yet.")
                    .font(Theme.font(13, relativeTo: .footnote))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                GradientPill(title: "Plan a trip", action: onPlan)
            } else {
                BigFigure(value: count == 1 ? "1 trip" : "\(count) trips", caption: "across stores")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
        .background(
            count == 0
                ? AnyShapeStyle(LinearGradient(colors: Theme.accentColors.map { $0.opacity(0.18) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                : AnyShapeStyle(Theme.surface.opacity(0.92)),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay {
            if count == 0 {
                RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.accentRing, lineWidth: 1.5)
            }
        }
        .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { phase = -10 }
        }
    }
}

private struct OfflineTile: View {
    let stores: Int

    private static let blocks: [(CGRect, Int)] = [
        (CGRect(x: 0, y: 0, width: 104, height: 10), 0), (CGRect(x: 0, y: 16, width: 12, height: 40), 0),
        (CGRect(x: 92, y: 16, width: 12, height: 40), 0), (CGRect(x: 20, y: 16, width: 8, height: 40), 1),
        (CGRect(x: 34, y: 16, width: 8, height: 40), 2), (CGRect(x: 48, y: 16, width: 8, height: 40), 1),
        (CGRect(x: 62, y: 16, width: 8, height: 40), 3), (CGRect(x: 76, y: 16, width: 8, height: 40), 1),
        (CGRect(x: 0, y: 62, width: 40, height: 10), 0), (CGRect(x: 58, y: 62, width: 46, height: 10), 0),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TileLabel(text: "Offline")
                Spacer()
                Image(systemName: "wifi.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
            }
            ZStack(alignment: .topLeading) {
                ForEach(Array(Self.blocks.enumerated()), id: \.offset) { _, block in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color(block.1))
                        .frame(width: block.0.width, height: block.0.height)
                        .offset(x: block.0.minX, y: block.0.minY)
                }
            }
            .frame(width: 104, height: 72, alignment: .topLeading)
            .rotationEffect(.degrees(-18))
            .rotation3DEffect(.degrees(48), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            BigFigure(
                value: stores == 1 ? "1 store" : "\(stores) stores",
                caption: stores == 0 ? "Open a store to save it" : "work with no signal"
            )
        }
        .tile()
        .accessibilityElement(children: .combine)
    }

    private func color(_ kind: Int) -> Color {
        switch kind {
        case 2: return Color(hex: 0xF9CFE0)
        case 3: return Color(hex: 0xFFDDC6)
        case 1: return Theme.hairline
        default: return Theme.fill
        }
    }
}

extension Notification.Name {
    /// Ask the Find tab to open the camera (from the Aisle+ tab's Snap button).
    static let aisleOpenCamera = Notification.Name("aisle.openCamera")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plan: PlusStore.Plan = .yearly
    @State private var trial: String?
    @State private var isBuying = false
    @State private var welcomed = false
    @State private var errorMessage: String?

    static let privacyURL = Legal.privacyURL
    /// Subscriptions use Apple's standard license agreement.
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// What each plan gets. Free values are what the free plan allows; Aisle+ is a check.
    private enum FreeValue { case included, notIncluded, text(String) }

    private var table: [(String, FreeValue)] {
        [
            ("Find items in any store", .included),
            ("Unlimited search", .text("\(plus.freeSearchesPerDay)/day")),
            ("Unlimited photo search", .text("\(plus.freePhotoSearchesPerDay)/day")),
            ("Unlimited follow-ups", .text("\(plus.freeFollowUpsPerSearch)/search")),
            ("Unlimited lists", .text("1")),
            ("Shared family lists", .notIncluded),
            ("Multi-store trips", .notIncluded),
            ("Offline store maps", .notIncluded),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            if !(inTab && plus.isPlus && !welcomed) {
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
            }

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
            await plus.refreshUsage()
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
                        // Still under Reduce Motion: the gradient holds its first frame.
                        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
                            FlowingGradient(time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
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
                    Button("Terms of Use") { openURL(Self.termsURL) }
                    Button("Privacy Policy") { openURL(Self.privacyURL) }
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
                Text("Free").frame(width: 56)
                Text("Aisle+").fontWeight(.bold).foregroundStyle(Theme.accentInk).frame(width: 64)
            }
            .font(Theme.font(15, relativeTo: .subheadline))
            .foregroundStyle(Theme.secondaryInk)
            .frame(minHeight: 34)
            .accessibilityHidden(true)

            ForEach(table, id: \.0) { feature, free in
                HStack(spacing: 0) {
                    Text(feature)
                        .font(Theme.font(16, relativeTo: .body))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        switch free {
                        case .included:
                            Image(systemName: "checkmark").font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.secondaryInk)
                        case .notIncluded:
                            Capsule().fill(Theme.secondaryInk.opacity(0.6)).frame(width: 14, height: 1.5)
                        case .text(let value):
                            Text(value)
                                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                                .foregroundStyle(Theme.secondaryInk)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(width: 56)
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hex: 0xDC6F9C))
                        .frame(width: 64)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(feature, free))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 16, y: 8)
    }

    private func accessibilityLabel(_ feature: String, _ free: FreeValue) -> String {
        switch free {
        case .included: return "\(feature): free and Aisle+"
        case .notIncluded: return "\(feature): Aisle+ only"
        case .text(let value): return "\(feature): free plan \(value), unlimited with Aisle+"
        }
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
            let start = trial.map { "\($0) free trial, then " } ?? ""
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

// MARK: - Offer at the end of sign-up

/// Shown once, right after a new account is made: what Aisle+ adds, an honest trial
/// timeline, and both plans. "Not now" is always visible and goes straight into the app.
struct OnboardingPlusOffer: View {
    let firstName: String?
    let storeName: String?
    let onDone: () -> Void

    @Environment(PlusStore.self) private var plus
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plan: PlusStore.Plan = .yearly
    @State private var trialDays: Int?
    @State private var isBuying = false
    @State private var welcomed = false
    @State private var errorMessage: String?

    private static let benefits: [(symbol: String, title: String)] = [
        ("magnifyingglass", "Unlimited search and follow-ups"),
        ("person.2", "Shared family lists"),
        ("map", "Offline store maps"),
        ("point.topleft.down.to.point.bottomright.curvepath", "Multi-store trips"),
    ]

    private var hasTrial: Bool { plan == .yearly && trialDays != nil }

    var body: some View {
        Group {
            if welcomed {
                PlusWelcome(onDone: onDone)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                offer.transition(.opacity)
            }
        }
        .background(AisleBackground())
        .environment(\.pressHaptics, true)
        .sensoryFeedback(.success, trigger: welcomed)
        .task {
            await plus.load()
            trialDays = await plus.trialDays(.yearly)
            if plus.isPlus { onDone() }
        }
        .alert("Couldn't complete the purchase", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var offer: some View {
        VStack(spacing: 0) {
            HStack {
                PlusWordmark(size: 20)
                Spacer()
                Button("Not now", action: onDone)
                    .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("plusOfferNotNow")
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headline
                    Text(subtitle)
                        .font(Theme.font(15, relativeTo: .subheadline))
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    VStack(spacing: 0) {
                        ForEach(Array(Self.benefits.enumerated()), id: \.offset) { index, benefit in
                            if index > 0 { Divider().overlay(Theme.hairline) }
                            HStack(spacing: 14) {
                                Image(systemName: benefit.symbol)
                                    .font(.system(size: 19, weight: .regular))
                                    .foregroundStyle(Color(hex: 0xDC6F9C))
                                    .frame(width: 26)
                                Text(benefit.title)
                                    .font(Theme.font(16, .semibold, relativeTo: .body))
                                    .foregroundStyle(Theme.ink)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 46)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                    .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
                    .padding(.top, 16)
                    .accessibilityElement(children: .combine)

                    if hasTrial, let days = trialDays {
                        TrialTimeline(days: days, price: plus.price(.yearly))
                            .padding(.top, 18)
                            .padding(.horizontal, 4)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    PlanTile(
                        title: "Yearly",
                        badge: "−\(plus.yearlySavingsPercent)%",
                        price: plus.price(.yearly), unit: "/yr",
                        note: trialDays.map { "\(plus.yearlyPerMonth)/mo · \($0) days free" } ?? "\(plus.yearlyPerMonth)/mo",
                        selected: plan == .yearly
                    ) { select(.yearly) }
                    PlanTile(
                        title: "Monthly", badge: nil,
                        price: plus.price(.monthly), unit: "/mo",
                        note: trialDays == nil ? "\(plus.monthlyPerYear)/yr" : "No free trial",
                        selected: plan == .monthly
                    ) { select(.monthly) }
                }

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
                        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
                            FlowingGradient(time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
                        }
                    }
                    .clipShape(Capsule())
                    .shadow(color: Theme.glow.opacity(0.28), radius: 14, y: 10)
                }
                .buttonStyle(PressableCardStyle())
                .sensoryFeedback(.impact(weight: .medium), trigger: isBuying) { _, new in new }
                .disabled(isBuying || !plus.canPurchase)
                .padding(.top, 12)
                .accessibilityIdentifier("plusOfferPurchaseButton")

                Text(finePrint)
                    .font(Theme.font(12, relativeTo: .caption))
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                HStack(spacing: 16) {
                    Button("Restore") { Task { await restore() } }
                    Button("Terms of Use") { openURL(PaywallView.termsURL) }
                    Button("Privacy Policy") { openURL(PaywallView.privacyURL) }
                }
                .font(Theme.font(12, .semibold, relativeTo: .caption))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    private var headline: some View {
        let name = firstName?.trimmingCharacters(in: .whitespaces) ?? ""
        let lead = name.isEmpty ? "Try Aisle+\n" : "\(name), try Aisle+\n"
        let accent: String = {
            if hasTrial, let days = trialDays { return days == 7 ? "free for 7 days" : "free for \(days) days" }
            return plan == .monthly ? "for \(plus.price(.monthly)) a month" : "for \(plus.yearlyPerMonth) a month"
        }()
        return (Text(lead) + Text(accent).foregroundStyle(Theme.accentInk))
            .font(Theme.font(31, .bold, relativeTo: .largeTitle))
            .tracking(-1)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .accessibilityAddTraits(.isHeader)
    }

    private var subtitle: String {
        if let storeName { return "Your account is ready. Here’s what Aisle+ adds at \(storeName)." }
        return "Your account is ready. Here’s what Aisle+ adds."
    }

    private var ctaTitle: String {
        if !plus.canPurchase { return plus.isLoading ? "Loading…" : "Not available yet" }
        if hasTrial { return trialDays == 7 ? "Start my free week" : "Start my free trial" }
        return "Get Aisle+"
    }

    private var finePrint: String {
        if let error = plus.loadError, !plus.canPurchase { return error }
        switch plan {
        case .yearly:
            let start = trialDays.map { "\($0) days free, then " } ?? ""
            return "\(start)\(plus.price(.yearly))/year. Renews automatically. Cancel anytime in Settings."
        case .monthly:
            return "\(plus.price(.monthly))/month. Renews automatically. Cancel anytime in Settings."
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

/// Today → last day to cancel → first charge, so nobody is surprised by the bill.
private struct TrialTimeline: View {
    let days: Int
    let price: String

    private var rows: [(String, String)] {
        [("Today", "Everything in Aisle+ unlocks."),
         ("Day \(max(1, days - 1))", "Last full day to cancel. Nothing charged yet."),
         ("Day \(days)", "\(price)/year starts. Cancel anytime in Settings.")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        Group {
                            if index == 0 {
                                Circle().fill(Theme.accent)
                            } else {
                                Circle().strokeBorder(Theme.secondaryInk.opacity(0.6), lineWidth: 2)
                            }
                        }
                        .frame(width: 12, height: 12)
                        .padding(.top, 4)
                        if index < rows.count - 1 {
                            Rectangle().fill(Theme.hairline).frame(width: 2).frame(minHeight: 26)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.0).font(Theme.font(15, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.ink)
                        Text(row.1).font(Theme.font(13, relativeTo: .footnote)).foregroundStyle(Theme.secondaryInk)
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .accessibilityElement(children: .combine)
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
        ("list.bullet", "Unlimited lists"),
        ("person.2", "Family lists"),
        ("point.topleft.down.to.point.bottomright.curvepath", "Multi-store trips"),
        ("map", "Offline maps"),
        ("bubble.left", "Unlimited follow-ups"),
        ("doc.text.viewfinder", "Unlimited list scans"),
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
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Theme.accentInk)
                    .frame(width: 28, height: 28)
                    .scaleEffect(selected ? 1 : 0.4)
                    .opacity(selected ? 1 : 0)
                    .padding(10)
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

/// After buying: a burst around the bare Aisle mark (a plain fade under Reduce Motion)
/// and a first thing to try.
private struct PlusWelcome: View {
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var burst = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                if !reduceMotion {
                    ForEach(0..<12, id: \.self) { index in
                        let angle = Double(index) / 12 * 2 * .pi
                        Circle()
                            .fill(Theme.accentColors[index % Theme.accentColors.count])
                            .frame(width: index.isMultiple(of: 3) ? 11 : 8)
                            .offset(x: burst ? cos(angle) * 130 : 0, y: burst ? sin(angle) * 130 : 0)
                            .opacity(burst ? 0 : 1)
                    }
                }
                Image("AisleLogo")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(Theme.ink)
                    .frame(width: 96, height: 96)
                    .scaleEffect(burst || reduceMotion ? 1 : 0.8)
                    .opacity(burst || !reduceMotion ? 1 : 0)
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
            withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.6, dampingFraction: 0.6)) { burst = true }
        }
    }
}
