import SwiftUI

/// Runs something that needs an account. Signed in, it just runs. A guest is asked to make
/// a free account first (`SignUpSheet`), and it runs once they have; "Not now" drops it.
struct RequireAccount {
    fileprivate let handler: @MainActor (SignUpReason, @escaping @MainActor () -> Void) -> Void

    @MainActor
    func callAsFunction(_ reason: SignUpReason, then action: @escaping @MainActor () -> Void = {}) {
        handler(reason, action)
    }
}

extension EnvironmentValues {
    /// Set by `signUpPrompts()`. Without one above (previews, tests), everything just runs.
    @Entry var requireAccount = RequireAccount { _, action in action() }
    /// For the sign-up prompt's events. Nil in previews and tests.
    @Entry var analytics: AnalyticsTracking? = nil
}

extension View {
    /// Lets features below ask a guest to make an account, in a sheet presented from here.
    /// Add it again inside a sheet with such features, since a sheet can't be presented
    /// from underneath another one.
    func signUpPrompts() -> some View {
        modifier(SignUpPromptHost())
    }
}

@MainActor
@Observable
private final class SignUpPrompter {
    var reason: SignUpReason?
    /// What the guest was doing, to finish once they've signed in.
    @ObservationIgnored var pending: (@MainActor () -> Void)?
}

private struct SignUpPromptHost: ViewModifier {
    @Environment(AccountStore.self) private var accounts
    @Environment(\.analytics) private var analytics
    @State private var prompter = SignUpPrompter()

    func body(content: Content) -> some View {
        content
            .environment(\.requireAccount, RequireAccount { [accounts, prompter, analytics] reason, action in
                guard !accounts.isSignedIn else { return action() }
                guard prompter.reason == nil else { return }
                prompter.pending = action
                prompter.reason = reason
                analytics?.track(.signUpPromptShown, ["reason": .string(reason.rawValue)])
            })
            .sheet(item: $prompter.reason, onDismiss: finish) { reason in
                if let auth = accounts.auth {
                    SignUpSheet(reason: reason, auth: auth) {
                        analytics?.track(.signUpPromptConverted, ["reason": .string(reason.rawValue)])
                    }
                }
            }
    }

    /// Back where they were: carry on with what needed the account, if they made one.
    private func finish() {
        let pending = prompter.pending
        prompter.pending = nil
        if accounts.isSignedIn { pending?() }
    }
}

/// "Create your free account", for a guest: why it's worth it (this reason first), then the
/// usual sign-in screens. Signing in or up closes it, and the phone's lists, history and
/// store come along (`LocalAccountData.adopt`).
private struct SignUpSheet: View {
    let reason: SignUpReason
    let onSignedIn: () -> Void

    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AccountFlowStep] = []
    @State private var model: SignUpModel
    /// Bumps when the shopper signs in, for the success haptic.
    @State private var signedIn = 0

    init(reason: SignUpReason, auth: AuthService, onSignedIn: @escaping () -> Void) {
        self.reason = reason
        self.onSignedIn = onSignedIn
        _model = State(initialValue: SignUpModel(auth: auth))
    }

    var body: some View {
        NavigationStack(path: $path) {
            screen(.method(returning: false))
                .navigationDestination(for: AccountFlowStep.self) { screen($0) }
        }
        .tint(Theme.ink)
        .font(.aisleBody)
        .environment(\.pressHaptics, true)
        .sensoryFeedback(.selection, trigger: path.count)
        .sensoryFeedback(.success, trigger: signedIn)
        // Past the first screen, a stray swipe shouldn't lose a code on its way.
        .interactiveDismissDisabled(!path.isEmpty)
    }

    private func screen(_ step: AccountFlowStep) -> some View {
        AccountFlowScreen(step: step, model: model, path: $path, reason: reason, onNotNow: { dismiss() }) { session in
            signedIn += 1
            accounts.signIn(session)
            onSignedIn()
            dismiss()
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }
}

/// What a free account adds, as rows of bare icons and text.
struct SignUpBenefits: View {
    let benefits: [(symbol: String, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(benefits, id: \.text) { benefit in
                HStack(spacing: 12) {
                    Image(systemName: benefit.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text(benefit.text)
                        .font(.aisleSubheadline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The You tab's invitation for a guest: what an account adds and one button. Closing it
/// leaves the smaller "Sign in" at the top of the tab.
struct GuestAccountCard: View {
    static let dismissedKey = "aisle.guest.cardDismissed"

    let onCreate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("You're using Aisle as a guest")
                        .font(Theme.font(22, .bold, relativeTo: .title2))
                        .tracking(-0.4)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Make a free account and everything here comes with you.")
                        .font(.aisleSubheadline)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.top, -10)
                .padding(.trailing, -10)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("dismissGuestCardButton")
            }
            SignUpBenefits(benefits: SignUpReason.allBenefits)
            Button("Create free account", action: onCreate)
                .buttonStyle(.aisleAccent)
                .accessibilityIdentifier("guestCreateAccountButton")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
