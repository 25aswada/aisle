import SwiftUI

enum OnboardingStep: Hashable {
    case signUp, email, code, name, ask, honest, location
}

/// First launch: welcome → optional sign-up → two tips → location → app.
struct OnboardingFlow: View {
    static let completedKey = "aisle.onboardingComplete"

    let location: LocationProviding
    let onFinish: () -> Void

    @Environment(AccountStore.self) private var accounts
    @State private var path: [OnboardingStep] = []
    @State private var signUp: SignUpModel

    init(location: LocationProviding, auth: AuthService, onFinish: @escaping () -> Void) {
        self.location = location
        self.onFinish = onFinish
        _signUp = State(initialValue: SignUpModel(auth: auth))
    }

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeStep(
                onStart: { path.append(.signUp) },
                onSignIn: { path.append(.signUp) }
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: OnboardingStep.self) { step in
                destination(step)
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
            }
        }
        .tint(Theme.ink)
        .font(.aisleBody)
    }

    @ViewBuilder
    private func destination(_ step: OnboardingStep) -> some View {
        switch step {
        case .signUp:
            SignUpMethodStep(
                model: signUp,
                onBack: back,
                onEmail: { path.append(.email) },
                onProviderSuccess: { path.append(.name) },
                onSkip: { path.append(.ask) }
            )
        case .email:
            EmailStep(model: signUp, onBack: back) { path.append(.code) }
        case .code:
            CodeStep(model: signUp, onBack: back) { path.append(.name) }
        case .name:
            NameStep(model: signUp, onBack: back) {
                if let account = signUp.makeAccount() {
                    accounts.signIn(account)
                }
                path.append(.ask)
            }
        case .ask:
            AskTipStep(onSkip: onFinish) { path.append(.honest) }
        case .honest:
            HonestTipStep(onSkip: onFinish) { path.append(.location) }
        case .location:
            LocationStep(location: location, onFinish: onFinish)
        }
    }

    private func back() {
        if !path.isEmpty { path.removeLast() }
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

    var body: some View {
        (Text(lead) + Text(accent).foregroundStyle(Theme.accentInk))
            .font(Theme.font(size, .bold, relativeTo: .largeTitle))
            .tracking(-1)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
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
        configuration.label
            .font(.aisleHeadline)
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
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

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(Theme.accentInk) : AnyShapeStyle(Theme.hairline))
                    .frame(width: index == current ? 22 : 8, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
