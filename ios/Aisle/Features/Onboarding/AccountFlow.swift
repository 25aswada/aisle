import SwiftUI

/// The sign-in screens, in a navigation path: method, then phone or email, the code,
/// and for new accounts a check that they don't already have one, the terms and a first name. Apple and Google skip straight to the name step
/// (or finish, for an account that already has one). Terms the phone already agreed to (as
/// a guest) aren't asked again.
enum AccountFlowStep: Hashable {
    case method(returning: Bool)
    case phone, email, code, newAccount, terms, name
    /// The Aisle+ offer after a new account is made. Shown by OnboardingFlow.
    case plus
    /// The terms before using Aisle as a guest. Shown by OnboardingFlow.
    case guestTerms
}

/// One sign-in screen, wired to push the next. In onboarding the method screen also offers
/// "Continue as guest"; in the sign-up sheet, "Not now".
struct AccountFlowScreen: View {
    let step: AccountFlowStep
    let model: SignUpModel
    @Binding var path: [AccountFlowStep]
    /// Why a guest is being asked, in the sign-up sheet.
    var reason: SignUpReason? = nil
    var onGuest: (() -> Void)? = nil
    var onNotNow: (() -> Void)? = nil
    let onSignedIn: (AuthSession) -> Void

    var body: some View {
        switch step {
        case .method(let returning):
            SignUpMethodStep(
                // As the first screen (signed out after the intro) there's nothing to go back to.
                model: model, isReturning: returning, reason: reason, onBack: path.isEmpty ? nil : back,
                onGuest: onGuest, onNotNow: onNotNow,
                onPhone: { path.append(.phone) },
                onEmail: { path.append(.email) },
                onProviderSuccess: signedIn
            )
        case .phone:
            PhoneStep(model: model, onBack: back) { path.append(.code) }
        case .email:
            EmailStep(model: model, onBack: back) { path.append(.code) }
        case .code:
            CodeStep(model: model, onBack: back, onVerified: signedIn)
        case .newAccount:
            NewAccountStep(model: model, onBack: back, onCreate: { path.append(termsOrName) }, onUseExisting: backToMethods)
        case .terms:
            TermsStep(onBack: back) {
                Legal.recordAcceptance()
                path.append(.name)
            }
        case .name:
            NameStep(model: model, onBack: back, onCreate: onSignedIn)
        case .plus, .guestTerms:
            EmptyView()
        }
    }

    /// The terms, unless this phone already agreed to them (as a guest), then a name.
    private var termsOrName: AccountFlowStep {
        Legal.hasAccepted() ? .name : .terms
    }

    /// New accounts agree to the terms and pick a name; returning ones are done. A code
    /// that made a new account first checks the shopper doesn't already have one.
    private func signedIn() {
        if model.shouldConfirmNewAccount {
            path.append(.newAccount)
        } else if model.needsName {
            path.append(termsOrName)
        } else if let session = model.session {
            onSignedIn(session)
        }
    }

    /// Back to choosing how to sign in, wherever that screen sits in the path.
    private func backToMethods() {
        if let index = path.firstIndex(where: { if case .method = $0 { true } else { false } }) {
            path = Array(path[...index])
        } else {
            path.removeAll()
        }
    }

    private func back() {
        if !path.isEmpty { path.removeLast() }
    }
}
