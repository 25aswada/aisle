import SwiftUI

struct SignUpMethodStep: View {
    @Bindable var model: SignUpModel
    let onBack: () -> Void
    let onEmail: () -> Void
    let onProviderSuccess: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingPage(onBack: onBack, trailingLabel: "Not now", onTrailing: onSkip) {
            VStack(alignment: .leading, spacing: 12) {
                AisleMark(size: 44)
                    .padding(.bottom, 10)
                GradientHeadline(lead: "Your lists, ", accent: "on every device.")
                OnboardingBody(text: "Create a free account to keep your shopping lists, usual stores and recent searches in sync.")
                VStack(alignment: .leading, spacing: 12) {
                    Benefit(symbol: "checklist", text: "Lists that follow you to any phone")
                    Benefit(symbol: "mappin.and.ellipse", text: "Your usual stores, remembered")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.top, 16)
            }
        } footer: {
            if let error = model.errorMessage {
                Text(error)
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { provider(.apple) } label: {
                Label("Continue with Apple", systemImage: "apple.logo")
            }
            .buttonStyle(InkButtonStyle())
            .accessibilityIdentifier("appleSignUpButton")
            Button { provider(.google) } label: {
                Label {
                    Text("Continue with Google")
                } icon: {
                    // Google's multicolour "G", kept in its own colours as their brand rules require.
                    Image(decorative: "GoogleG")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.aisleSoft)
            .accessibilityIdentifier("googleSignUpButton")
            Button("Continue with email") {
                model.clearError()
                onEmail()
            }
            .buttonStyle(.aisleAccent)
            .accessibilityIdentifier("emailSignUpButton")
            Text("By continuing you agree to the Terms and Privacy Policy.")
                .font(.aisleCaption)
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .disabled(model.isWorking)
    }

    private func provider(_ provider: AuthProvider) {
        Task {
            if await model.continueWith(provider) { onProviderSuccess() }
        }
    }
}

private struct Benefit: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accentInk)
                .frame(width: 24)
            Text(text)
                .font(.aisleSubheadline)
                .foregroundStyle(Theme.ink)
        }
    }
}

struct EmailStep: View {
    @Bindable var model: SignUpModel
    let onBack: () -> Void
    let onSent: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        OnboardingPage(onBack: onBack, progress: "Step 1 of 3") {
            VStack(alignment: .leading, spacing: 12) {
                Text("What's your email?")
                    .font(Theme.font(34, .bold, relativeTo: .largeTitle))
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                OnboardingBody(text: "We'll send you a 6-digit code. No password to remember.")
                Text("Email")
                    .font(Theme.font(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 20)
                TextField("you@example.com", text: $model.email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($focused)
                    .onSubmit(send)
                    .modifier(OnboardingFieldStyle())
                    .accessibilityLabel("Email")
                    .accessibilityIdentifier("emailField")
                if let error = model.errorMessage {
                    Text(error)
                        .font(.aisleFootnote)
                        .foregroundStyle(Theme.warning)
                }
            }
        } footer: {
            Button(action: send) {
                if model.isWorking { ProgressView() } else { Text("Send code") }
            }
            .buttonStyle(.aisleAccent)
            .disabled(!model.isEmailValid || model.isWorking)
            .accessibilityIdentifier("sendCodeButton")
        }
        .onAppear { focused = true }
    }

    private func send() {
        guard model.isEmailValid, !model.isWorking else { return }
        Task {
            if await model.sendCode() { onSent() }
        }
    }
}

struct CodeStep: View {
    @Bindable var model: SignUpModel
    let onBack: () -> Void
    let onVerified: () -> Void

    @FocusState private var focused: Bool
    @State private var secondsLeft = 30

    var body: some View {
        OnboardingPage(onBack: onBack, progress: "Step 2 of 3") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Check your email")
                    .font(Theme.font(34, .bold, relativeTo: .largeTitle))
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                (Text("Enter the 6-digit code we sent to ")
                    + Text(model.trimmedEmail).font(Theme.font(17, .semibold)).foregroundStyle(Theme.ink)
                    + Text("."))
                    .font(Theme.font(17, relativeTo: .body))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                codeBoxes
                    .padding(.top, 20)

                if let error = model.errorMessage {
                    Text(error)
                        .font(.aisleFootnote)
                        .foregroundStyle(Theme.warning)
                }

                HStack(spacing: 4) {
                    Text("Didn't get it?")
                        .foregroundStyle(Theme.secondaryInk)
                    if secondsLeft > 0 {
                        Text("Resend in 0:\(String(format: "%02d", secondsLeft))")
                            .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(Theme.ink)
                            .monospacedDigit()
                    } else {
                        Button("Resend code", action: resend)
                            .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(Theme.ink)
                    }
                }
                .font(.aisleSubheadline)
                .padding(.top, 8)
            }
        } footer: {
            Button(action: verify) {
                if model.isWorking { ProgressView() } else { Text("Verify") }
            }
            .buttonStyle(.aisleAccent)
            .disabled(!model.isCodeComplete || model.isWorking)
            .accessibilityIdentifier("verifyCodeButton")
        }
        .onAppear { focused = true }
        .task(id: secondsLeft == 30) {
            while secondsLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                secondsLeft -= 1
            }
        }
        .onChange(of: model.code) {
            if model.isCodeComplete { verify() }
        }
    }

    /// One hidden field drives six boxes, so paste and the one-time-code keyboard suggestion work.
    private var codeBoxes: some View {
        let digits = Array(model.code)
        return ZStack {
            TextField("", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityLabel("Verification code")
                .accessibilityIdentifier("codeField")
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    let isActive = focused && index == min(digits.count, 5)
                    Text(index < digits.count ? String(digits[index]) : "")
                        .font(Theme.font(24, .semibold, relativeTo: .title2))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            if isActive {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Theme.accentRing, lineWidth: 1.5)
                            }
                        }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private func verify() {
        guard model.isCodeComplete, !model.isWorking else { return }
        Task {
            if await model.verifyCode() { onVerified() }
        }
    }

    private func resend() {
        model.code = ""
        Task {
            if await model.sendCode() { secondsLeft = 30 }
        }
    }
}

struct NameStep: View {
    @Bindable var model: SignUpModel
    let onBack: () -> Void
    let onCreate: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        OnboardingPage(onBack: onBack, progress: "Step 3 of 3") {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.trimmedName.first.map { String($0).uppercased() } ?? "?")
                    .font(Theme.font(26, .bold, relativeTo: .title))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 64, height: 64)
                    .background(Theme.accent, in: Circle())
                    .accessibilityHidden(true)
                    .padding(.bottom, 10)
                Text("What should we call you?")
                    .font(Theme.font(34, .bold, relativeTo: .largeTitle))
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                OnboardingBody(text: "Just a first name is fine.")
                Text("First name")
                    .font(Theme.font(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 16)
                TextField("First name", text: $model.firstName)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { if model.canFinish { onCreate() } }
                    .modifier(OnboardingFieldStyle())
                    .accessibilityIdentifier("firstNameField")
                Toggle(isOn: $model.wantsTips) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shopping tips by email")
                            .font(.aisleHeadline)
                            .foregroundStyle(Theme.ink)
                        Text("Occasional, never more than monthly")
                            .font(.aisleFootnote)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                .tint(Theme.toggleOn)
                .padding(16)
                .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.top, 8)
            }
        } footer: {
            Button("Create account", action: onCreate)
                .buttonStyle(.aisleAccent)
                .disabled(!model.canFinish)
                .accessibilityIdentifier("createAccountButton")
        }
        .onAppear { focused = true }
    }
}
