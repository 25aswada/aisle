import SwiftUI

/// First launch: the animated walkthrough, then an account, which Aisle requires.
/// `signInOnly` skips the walkthrough, for a phone that has seen it but is signed out.
struct OnboardingFlow: View {
    static let completedKey = "aisle.onboardingComplete"

    let api: AisleAPI
    let location: LocationProviding
    let signInOnly: Bool
    let onFinish: () -> Void

    @Environment(AccountStore.self) private var accounts
    @Environment(PlusStore.self) private var plus
    @Environment(StoreSelection.self) private var storeSelection
    @State private var path: [AccountFlowStep] = []
    @State private var signUp: SignUpModel
    /// Bumps when the shopper signs in, for the success haptic.
    @State private var signedIn = 0

    init(api: AisleAPI, location: LocationProviding, auth: AuthService, signInOnly: Bool = false,
         onFinish: @escaping () -> Void) {
        self.api = api
        self.location = location
        self.signInOnly = signInOnly
        self.onFinish = onFinish
        _signUp = State(initialValue: SignUpModel(auth: auth))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if signInOnly {
                    accountScreen(.method(returning: true))
                } else {
                    LiveOnboarding(
                        api: api,
                        location: location,
                        onCreateAccount: createAccount,
                        onSignIn: { path.append(.method(returning: true)) },
                        // Skipping or finishing the tour still leads to an account.
                        onFinish: createAccount
                    )
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AccountFlowStep.self) { step in
                destination(step)
            }
        }
        .tint(Theme.ink)
        .font(.aisleBody)
        .environment(\.pressHaptics, true)
        .sensoryFeedback(.selection, trigger: path.count)
        .sensoryFeedback(.success, trigger: signedIn)
    }

    /// Replaying the intro from You while signed in just ends it.
    private func createAccount() {
        if accounts.isSignedIn { onFinish() } else { path.append(.method(returning: false)) }
    }

    private func accountScreen(_ step: AccountFlowStep) -> some View {
        AccountFlowScreen(
            step: step, model: signUp, path: $path,
            onSignedIn: { session in
                signedIn += 1
                accounts.signIn(session)
                // New accounts see the Aisle+ offer once; returning ones go straight in.
                if path.contains(.name) && !plus.isPlus {
                    path.append(.plus)
                } else {
                    onFinish()
                }
            }
        )
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    @ViewBuilder
    private func destination(_ step: AccountFlowStep) -> some View {
        if step == .plus {
            OnboardingPlusOffer(firstName: accounts.account?.firstName, storeName: storeSelection.current?.name, onDone: onFinish)
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)
        } else {
            accountScreen(step)
        }
    }
}

// MARK: - Shared layout

/// Top bar, scrolling content and a pinned footer, on the Aisle page background.
struct OnboardingPage<Content: View, Footer: View>: View {
    var onBack: (() -> Void)?
    var progress: String?
    var trailingLabel: String?
    var onTrailing: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let progress {
                    Text(progress)
                        .font(Theme.font(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondaryInk)
                }
                HStack {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 44, height: 44)
                                .background(Theme.surface, in: Circle())
                                .shadow(color: Theme.ink.opacity(0.08), radius: 12, y: 6)
                        }
                        .accessibilityLabel("Back")
                    } else {
                        AisleMark(size: 30)
                    }
                    Spacer()
                    if let trailingLabel, let onTrailing {
                        Button(trailingLabel, action: onTrailing)
                            .font(Theme.font(15, .medium, relativeTo: .subheadline))
                            .foregroundStyle(Theme.secondaryInk)
                            .frame(minHeight: 44)
                    }
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 24)
            .padding(.top, 8)

            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 10) { footer() }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
        .background(AisleBackground())
    }
}

/// Big title whose last words carry the gradient.
struct GradientHeadline: View {
    let lead: String
    let accent: String
    var size: CGFloat = 36
    /// Lets the accent's gradient drift slowly. Needs the accent on its own line
    /// (`lead` ending in "\n"), since it's drawn as a separate text to be animated.
    var flowing = false

    var body: some View {
        Group {
            if flowing {
                VStack(spacing: 0) {
                    Text(lead.trimmingCharacters(in: .newlines))
                    FlowingGradientText(text: accent)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(lead) + Text(accent).foregroundStyle(Theme.accentInk)
            }
        }
        .font(Theme.font(size, .bold, relativeTo: .largeTitle))
        .tracking(-1)
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Text filled with the accent gradient, its colours slowly drifting back and forth.
/// The gradient is twice the text's width with mirrored stops (purple, pink, orange,
/// pink, purple), and its window eases between two positions, so the motion never
/// jumps. Still under Reduce Motion.
private struct FlowingGradientText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds for one full drift there and back.
    private let period = 7.0
    /// How far the window travels, in text widths. Small keeps it subtle.
    private let travel = 0.3
    private let colors = [0x9A6BD6, 0xDC6F9C, 0xEC9560, 0xDC6F9C, 0x9A6BD6].map { Color(hex: UInt32($0)) }

    var body: some View {
        if reduceMotion {
            Text(text).foregroundStyle(Theme.accentInk)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate / period
                // 0 → 1 → 0 on a sine curve, so it slows at each end.
                let offset = (1 - cos(t * 2 * .pi)) / 2 * travel
                Text(text).foregroundStyle(
                    LinearGradient(
                        colors: colors,
                        startPoint: UnitPoint(x: -offset, y: 0.5),
                        endPoint: UnitPoint(x: 2 - offset, y: 0.5)
                    )
                )
            }
        }
    }
}

struct OnboardingBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.font(17, relativeTo: .body))
            .foregroundStyle(Theme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Dark button for "Continue with Apple" (inverts in dark mode).
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InkButtonBody(configuration: configuration)
    }
}

private struct InkButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.pressHaptics) private var pressHaptics

    var body: some View {
        configuration.label
            .font(.aisleHeadline)
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .pressHaptic(configuration.isPressed, enabled: pressHaptics, weight: .medium)
    }
}

/// Text field with the gradient ring used across sign-up.
struct OnboardingFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.aisleBody)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 18)
            .frame(minHeight: 58)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accentRing, lineWidth: 1.5))
            .shadow(color: Theme.glow.opacity(0.10), radius: 14, y: 8)
    }
}
