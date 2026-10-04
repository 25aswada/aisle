import StoreKit
import SwiftUI

/// Cancelling Aisle+. Apple does the actual cancelling, so this is one honest screen
/// before the App Store's own sheet: what changes and when, an optional reason, and
/// at most one relevant alternative. "Keep Aisle+" and "Continue to cancel" sit side
/// by side with equal weight; nothing hides the way out.
struct CancelPlusFlow: View {
    /// Photo searches past the free limit in the last two weeks, for "what changes".
    let extraPhotoSearches: Int
    let sharedLists: Int

    @Environment(PlusStore.self) private var plus
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum Reason: String, CaseIterable, Identifiable {
        case price = "Too expensive"
        case rarely = "I don't shop enough"
        case missing = "Missing something I need"
        case notUseful = "Answers weren't helpful"
        case trying = "Just trying it out"
        case other = "Something else"
        var id: String { rawValue }
    }

    enum Stage { case confirm, cancelled }

    @State private var stage: Stage = .confirm
    @State private var reason: Reason?
    @State private var membership: PlusStore.Membership?
    @State private var showingAppleSheet = false

    static let reasonKey = "aisle.plus.cancelReason"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40)
                        .background(Theme.fill, in: Circle())
                }
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            switch stage {
            case .confirm: confirm.transition(.opacity)
            case .cancelled: cancelled.transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .background(AisleBackground())
        .presentationDragIndicator(.visible)
        .task { membership = await plus.membership() }
        .manageSubscriptionsSheet(isPresented: $showingAppleSheet)
        .onChange(of: showingAppleSheet) { _, open in
            guard !open else { return }
            Task { await checkAfterAppleSheet() }
        }
        .sensoryFeedback(.selection, trigger: reason)
    }

    // MARK: - Before cancelling

    private var endDay: String? {
        membership?.nextDate?.formatted(.dateTime.month(.wide).day())
    }

    private var confirm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cancel Aisle+?")
                    .font(Theme.font(30, .bold, relativeTo: .largeTitle))
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(endDay.map { "You'll keep everything until \($0). After that, Aisle goes back to the free plan." }
                     ?? "You'll keep everything until the end of this billing period. After that, Aisle goes back to the free plan.")
                    .font(Theme.font(16, relativeTo: .body))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                changes.padding(.top, 22)

                Text("What's the main reason? (optional)")
                    .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 26)
                FlowLayout(spacing: 8) {
                    ForEach(Reason.allCases) { option in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                reason = reason == option ? nil : option
                            }
                        } label: {
                            Text(option.rawValue)
                                .font(Theme.font(14, .medium, relativeTo: .subheadline))
                                .foregroundStyle(reason == option ? Theme.onAccent : Theme.ink)
                                .padding(.horizontal, 14)
                                .frame(height: 38)
                                .background {
                                    if reason == option {
                                        Capsule().fill(Theme.accent)
                                    } else {
                                        Capsule().fill(Theme.surface)
                                    }
                                }
                                .overlay(Capsule().strokeBorder(reason == option ? Color.clear : Theme.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(reason == option ? .isSelected : [])
                    }
                }
                .padding(.top, 12)

                if let alternative {
                    alternative
                        .padding(.top, 18)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }

                HStack(spacing: 10) {
                    Button("Keep Aisle+") { dismiss() }
                        .buttonStyle(.aisleAccent)
                    Button("Continue to cancel") { continueToApple() }
                        .buttonStyle(.aisleSoftFilled)
                        .accessibilityHint("Opens the App Store, where Apple cancels the subscription")
                }
                .padding(.top, 26)

                Text("Apple handles subscriptions, so you'll finish in the App Store. You won't be charged again, and your lists and searches stay on your phone.")
                    .font(Theme.font(12, relativeTo: .caption))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
    }

    /// Concrete, from their own use where we have it.
    private var changes: some View {
        VStack(alignment: .leading, spacing: 0) {
            change(
                "camera",
                "Photo searches go back to \(MemberActivity.freePhotosPerDay) a day",
                extraPhotoSearches > 0 ? "You used \(extraPhotoSearches) more than that in the last 2 weeks." : nil
            )
            RowDivider()
            change("bubble.left", "Follow-ups go back to \(MemberActivity.freeFollowUpsPerDay) a day", nil)
            RowDivider()
            change(
                "person.2",
                "Sharing lists needs Aisle+",
                sharedLists > 0 ? "You share \(sharedLists == 1 ? "1 list" : "\(sharedLists) lists") right now." : nil
            )
            RowDivider()
            change("map", "Multi-store trips and offline maps need Aisle+", nil)
        }
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
    }

    private func change(_ symbol: String, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(15, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail).font(Theme.font(12, relativeTo: .caption)).foregroundStyle(Theme.secondaryInk)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// One alternative, only when it fits the reason.
    private var alternative: AnyView? {
        switch reason {
        case .price where membership?.plan == .monthly:
            return AnyView(offerCard(
                title: "Yearly is \(plus.yearlyPerMonth) a month",
                detail: "Switch plans instead and pay \(plus.yearlySavingsPercent)% less.",
                action: "Switch to yearly"
            ) { showingAppleSheet = true })
        case .missing, .notUseful:
            return AnyView(offerCard(
                title: "Tell us what went wrong",
                detail: "A real person reads every note, and it shapes what we fix next.",
                action: "Email us"
            ) { mail() })
        default:
            return nil
        }
    }

    private func offerCard(title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(15, .bold, relativeTo: .subheadline))
                Text(detail).font(Theme.font(12, relativeTo: .caption)).opacity(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action, action: perform)
                .font(Theme.font(12, .bold, relativeTo: .caption))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.white.opacity(0.6), in: Capsule())
        }
        .foregroundStyle(Theme.onAccent)
        .padding(16)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - After cancelling

    private var cancelled: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 84, height: 84)
                .background(Theme.accent, in: Circle())
                .shadow(color: Theme.glow.opacity(0.3), radius: 18, y: 10)
                .accessibilityHidden(true)
            Text("You're all set")
                .font(Theme.font(28, .bold, relativeTo: .largeTitle))
                .tracking(-0.8)
                .foregroundStyle(Theme.ink)
                .padding(.top, 22)
            Text(endDay.map { "Aisle+ stays on until \($0). You won't be charged again." }
                 ?? "Aisle+ stays on until the end of this period. You won't be charged again.")
                .font(Theme.font(16, relativeTo: .body))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text("Thanks for trying it. Aisle keeps finding things for free.")
                .font(Theme.font(14, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.aisleAccent)
            Button("Changed your mind? Turn it back on") { showingAppleSheet = true }
                .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
                .frame(minHeight: 44)
                .padding(.top, 6)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 20)
        .sensoryFeedback(.success, trigger: stage)
    }

    // MARK: - Actions

    private func continueToApple() {
        if let reason { UserDefaults.standard.set(reason.rawValue, forKey: Self.reasonKey) }
        showingAppleSheet = true
    }

    /// Back from Apple's sheet: if renewal is now off, show the confirmation; if they
    /// turned it back on, return to the start.
    private func checkAfterAppleSheet() async {
        await plus.refreshEntitlement()
        membership = await plus.membership()
        let renewing = membership?.willRenew ?? true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            stage = renewing ? .confirm : .cancelled
        }
    }

    private func mail() {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = "support@shopaisle.app"
        parts.queryItems = [URLQueryItem(name: "subject", value: "Aisle+ feedback\(reason.map { ": \($0.rawValue)" } ?? "")")]
        if let url = parts.url { openURL(url) }
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 60)
    }
}
