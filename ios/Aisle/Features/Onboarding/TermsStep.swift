import SwiftUI

/// Sign-up's "fine print" step: a plain-English summary, then the full Terms of Service
/// and Privacy Policy in one scroll. "Agree and continue" unlocks once you reach the end
/// (or tap "Skip to the end", which scrolls there).
struct TermsStep: View {
    let onBack: () -> Void
    let onAgree: () -> Void

    @State private var reachedEnd = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .background(Theme.surface, in: Circle())
                        .shadow(color: Theme.ink.opacity(0.08), radius: 12, y: 6)
                }
                .accessibilityLabel("Back")
                Spacer()
                Text("Almost done")
                    .font(Theme.font(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header
                        summaryCard.padding(.top, 20)
                        HStack {
                            Spacer()
                            Button("Skip to the end") {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) {
                                    proxy.scrollTo("end", anchor: .bottom)
                                }
                            }
                            .font(Theme.font(13, .semibold, relativeTo: .footnote))
                            .foregroundStyle(Theme.secondaryInk)
                            .frame(minHeight: 44)
                        }
                        document(Legal.terms).padding(.top, 8)
                        document(Legal.privacy).padding(.top, 28)
                        Text("Effective \(Legal.effectiveDate). Questions: \(Legal.contactEmail)")
                            .font(Theme.font(12, relativeTo: .caption))
                            .foregroundStyle(Theme.secondaryInk)
                            .padding(.top, 22)
                        Color.clear
                            .frame(height: 1)
                            .id("end")
                            .onAppear {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { reachedEnd = true }
                            }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            VStack(spacing: 8) {
                Button(action: onAgree) {
                    Label(reachedEnd ? "Agree and continue" : "Scroll to the end to continue",
                          systemImage: reachedEnd ? "checkmark" : "arrow.down")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.aisleAccent)
                .disabled(!reachedEnd)
                .accessibilityIdentifier("agreeTermsButton")
                Text("By continuing, you agree to the Terms of Service and Privacy Policy.")
                    .font(Theme.font(12, relativeTo: .caption))
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(alignment: .top) {
                LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .offset(y: -28)
                    .allowsHitTesting(false)
            }
            .sensoryFeedback(.success, trigger: reachedEnd)
        }
        .background(AisleBackground())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            GradientHeadline(lead: "The fine print, ", accent: "in plain English.", size: 32)
            OnboardingBody(text: "Here's the short version. The full terms and privacy policy follow below.")
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Legal.summary, id: \.text) { point in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: point.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 30, height: 30)
                        .background(Theme.accent, in: Circle())
                        .accessibilityHidden(true)
                    Text(point.text)
                        .font(Theme.font(15, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
    }

    private func document(_ doc: Legal.Document) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(doc.title)
                .font(Theme.font(22, .bold, relativeTo: .title2))
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(doc.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                    Text(section.body)
                        .font(Theme.font(14, relativeTo: .subheadline))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The same documents to read later, from the You tab.
struct LegalDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach([Legal.terms, Legal.privacy]) { doc in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(doc.title)
                                .font(Theme.font(24, .bold, relativeTo: .title))
                                .foregroundStyle(Theme.ink)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(doc.sections) { section in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(section.title)
                                        .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                                        .foregroundStyle(Theme.ink)
                                    Text(section.body)
                                        .font(Theme.font(14, relativeTo: .subheadline))
                                        .foregroundStyle(Theme.secondaryInk)
                                        .lineSpacing(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    Text("Effective \(Legal.effectiveDate). Questions: \(Legal.contactEmail)")
                        .font(Theme.font(12, relativeTo: .caption))
                        .foregroundStyle(Theme.secondaryInk)
                }
                .padding(24)
            }
            .background(AisleBackground())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
