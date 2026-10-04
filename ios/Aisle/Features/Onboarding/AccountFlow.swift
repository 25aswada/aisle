import SwiftUI

/// The sign-in screens, in a navigation path: method, then phone or email, the code,
/// and a first name for new accounts. Apple and Google skip straight to the name step
/// (or finish, for an account that already has one).
enum AccountFlowStep: Hashable {
    case method(returning: Bool)
    case phone, email, code, name
}

/// One sign-in screen, wired to push the next. Shared by onboarding and the You tab.
struct AccountFlowScreen: View {
    let step: AccountFlowStep
    let model: SignUpModel
    @Binding var path: [AccountFlowStep]
    /// Leaving the method screen when it's the root (the You tab sheet).
    let onLeave: () -> Void
    let onSkip: () -> Void
    let onSignedIn: (AuthSession) -> Void

    var body: some View {
        switch step {
        case .method(let returning):
            SignUpMethodStep(
                model: model, isReturning: returning, onBack: back,
                onPhone: { path.append(.phone) },
                onEmail: { path.append(.email) },
                onProviderSuccess: signedIn,
                onSkip: onSkip
            )
        case .phone:
            PhoneStep(model: model, onBack: back) { path.append(.code) }
        case .email:
            EmailStep(model: model, onBack: back) { path.append(.code) }
        case .code:
            CodeStep(model: model, onBack: back, onVerified: signedIn)
        case .name:
            NameStep(model: model, onBack: back, onCreate: onSignedIn)
        }
    }

    /// New accounts pick a name; returning ones are done.
    private func signedIn() {
        if model.needsName {
            path.append(.name)
        } else if let session = model.session {
            onSignedIn(session)
        }
    }

    private func back() {
        if path.isEmpty { onLeave() } else { path.removeLast() }
    }
}

/// Sign in or create an account from the You tab, without replaying the intro.
struct AccountSheet: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(\.dismiss) private var dismiss
    @State private var model: SignUpModel
    @State private var path: [AccountFlowStep] = []

    init(auth: AuthService) {
        _model = State(initialValue: SignUpModel(auth: auth))
    }

    var body: some View {
        NavigationStack(path: $path) {
            screen(.method(returning: false))
                .navigationDestination(for: AccountFlowStep.self) { step in
                    screen(step)
                }
        }
        .tint(Theme.ink)
        .font(.aisleBody)
    }

    private func screen(_ step: AccountFlowStep) -> some View {
        AccountFlowScreen(
            step: step, model: model, path: $path,
            onLeave: { dismiss() }, onSkip: { dismiss() },
            onSignedIn: { session in
                accounts.signIn(session)
                dismiss()
            }
        )
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }
}
