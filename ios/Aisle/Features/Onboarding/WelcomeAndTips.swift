import SwiftUI

struct WelcomeStep: View {
    let onStart: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 14) {
                        AisleMark(size: 76)
                        Text("aisle")
                            .font(Theme.font(22, .bold, relativeTo: .title3))
                            .tracking(-0.6)
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(.top, 48)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Aisle")

                    GradientHeadline(lead: "Find anything,\n", accent: "in any store.", size: 40)
                        .multilineTextAlignment(.center)
                        .padding(.top, 28)

                    OnboardingBody(text: "Ask for an item the way you'd say it. Aisle points you to the right spot.")
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)

                    WelcomePreview()
                        .padding(.top, 32)
                }
                .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 6) {
                Button("Get started", action: onStart)
                    .buttonStyle(.aisleAccent)
                    .accessibilityIdentifier("getStartedButton")
                Button(action: onSignIn) {
                    (Text("Already have an account? ").foregroundStyle(Theme.secondaryInk)
                        + Text("Sign in").font(Theme.font(15, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.ink))
                        .font(.aisleSubheadline)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("signInButton")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(AisleBackground())
    }
}

/// A sample exchange so the first screen shows what Aisle does.
private struct WelcomePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QueryBubble(text: "where is maple syrup?")
            AisleReply {
                Text("Found it! Maple syrup is in **Aisle 7**, halfway down on your left.")
            }
        }
        .padding(18)
        .background(Theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 18, y: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: asking where maple syrup is, and Aisle answering Aisle 7.")
    }
}

struct AskTipStep: View {
    let onSkip: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingPage(trailingLabel: "Skip", onTrailing: onSkip) {
            VStack(alignment: .leading, spacing: 12) {
                GradientHeadline(lead: "Ask like you'd ask ", accent: "a friend.")
                OnboardingBody(text: "No need for exact product names. Aisle works out what you mean.")
                VStack(alignment: .leading, spacing: 14) {
                    ExampleExchange(question: "something to unclog my sink", symbol: "drop", item: "Drain cleaner", place: "Household")
                    ExampleExchange(question: "candles for a birthday cake", symbol: "birthday.cake", item: "Birthday candles", place: "Baking")
                    ExampleExchange(question: "the good maple syrup", symbol: "waterbottle", item: "Maple syrup", place: "Breakfast")
                }
                .padding(.top, 20)
            }
        } footer: {
            PageDots(count: 3, current: 0)
                .padding(.bottom, 8)
            Button("Continue", action: onContinue)
                .buttonStyle(.aisleAccent)
        }
    }
}

private struct ExampleExchange: View {
    let question: String
    let symbol: String
    let item: String
    let place: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            QueryBubble(text: question)
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentSoft, in: Circle())
                (Text(item).font(Theme.font(15, .semibold, relativeTo: .subheadline)) + Text(" · \(place)"))
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.ink)
            }
            .padding(.vertical, 6)
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .background(Theme.surface, in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Asking \(question) finds \(item) in \(place).")
    }
}

struct HonestTipStep: View {
    let onSkip: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingPage(trailingLabel: "Skip", onTrailing: onSkip) {
            VStack(alignment: .leading, spacing: 12) {
                GradientHeadline(lead: "Honest about ", accent: "every answer.")
                OnboardingBody(text: "Aisle shows how sure it is, so you never wander the wrong aisle.")
                VStack(spacing: 12) {
                    ConfidenceExample(confidence: .high, detail: "Exact aisle, from the store's own data")
                    ConfidenceExample(confidence: .medium, detail: "The right department, shelf not mapped")
                    ConfidenceExample(confidence: .low, detail: "Based on how similar stores are laid out")
                }
                .padding(.top, 20)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.accentInk)
                        .accessibilityHidden(true)
                    Text("Tap **Found it** or **Not here** after a search. Every tap makes Aisle more exact for the next shopper.")
                        .font(.aisleSubheadline)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.top, 10)
            }
        } footer: {
            PageDots(count: 3, current: 1)
                .padding(.bottom, 8)
            Button("Continue", action: onContinue)
                .buttonStyle(.aisleAccent)
        }
    }
}

/// Mini version of the result card in each confidence style.
private struct ConfidenceExample: View {
    let confidence: Confidence
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            ConfidenceBars(level: confidence.level, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(confidence.shortLabel)
                    .font(Theme.font(16, .bold, relativeTo: .headline))
                Text(detail)
                    .font(.aisleFootnote)
                    .opacity(0.8)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(confidence == .high ? Theme.onAccent : Theme.ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background { background }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        switch confidence {
        case .high:
            shape.fill(Theme.accent)
        case .medium:
            shape.fill(Theme.section)
        case .low:
            shape.fill(Theme.surface)
                .overlay(shape.strokeBorder(Theme.secondaryInk.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
    }
}

struct LocationStep: View {
    let location: LocationProviding
    let onFinish: () -> Void

    @State private var isAsking = false

    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: 12) {
                NearbyPreview()
                    .padding(.bottom, 20)
                GradientHeadline(lead: "Find your store ", accent: "in a tap.")
                OnboardingBody(text: "Aisle uses your location only to show stores near you. It's optional: you can always search for your store instead.")
            }
        } footer: {
            PageDots(count: 3, current: 2)
                .padding(.bottom, 8)
            Button {
                isAsking = true
                Task {
                    _ = await location.requestAuthorization()
                    isAsking = false
                    onFinish()
                }
            } label: {
                Label("Use my location", systemImage: "location.fill")
            }
            .buttonStyle(.aisleAccent)
            .disabled(isAsking)
            .accessibilityIdentifier("allowLocationButton")
            Button("Search for a store instead", action: onFinish)
                .font(.aisleHeadline)
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 44)
        }
    }
}

/// Abstract store list: shows the idea without inventing real stores.
private struct NearbyPreview: View {
    var body: some View {
        VStack(spacing: 4) {
            row(isHere: true, width: 120)
            row(isHere: false, width: 96)
            row(isHere: false, width: 108)
        }
        .padding(8)
        .background(Theme.surface.opacity(0.88), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 18, y: 10)
        .accessibilityHidden(true)
    }

    private func row(isHere: Bool, width: CGFloat) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "storefront")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 42, height: 42)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Theme.ink.opacity(0.75)).frame(width: width, height: 9)
                Capsule().fill(Theme.secondaryInk.opacity(0.3)).frame(width: width * 0.55, height: 7)
            }
            Spacer(minLength: 0)
            if isHere {
                Label("You're here", systemImage: "location.fill")
                    .font(Theme.font(11, .semibold, relativeTo: .caption))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .padding(10)
        .background(isHere ? AnyShapeStyle(Theme.accentSoft) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
