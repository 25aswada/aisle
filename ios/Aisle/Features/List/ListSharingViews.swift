import SwiftUI

/// The invite for a shared list: the code, a share button, and who's on it.
struct ShareListSheet: View {
    @Environment(ShoppingListStore.self) private var list
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingStop = false
    @State private var error: String?

    private var shared: SharedInfo? { list.current.shared }

    private var inviteMessage: String {
        let code = shared?.inviteCode ?? ""
        return "Join my Aisle list “\(list.current.name)”: aisle://join/\(code)\n\nOr open Aisle → List → ••• → Join a shared list, and enter \(code)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Share “\(list.current.name)”")
                .font(Theme.font(26, .bold, relativeTo: .title))
                .tracking(-0.6)
                .padding(.top, 28)
            Text("Everyone on the list sees what's added and checked off, as it happens. Joining is free.")
                .font(.aisleSubheadline)
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            if let shared {
                VStack(spacing: 6) {
                    Text("Invite code")
                        .font(Theme.font(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondaryInk)
                    Text(Self.spaced(shared.inviteCode))
                        .font(Theme.font(40, .bold, relativeTo: .largeTitle).monospaced())
                        .tracking(4)
                        .foregroundStyle(Theme.accentInk)
                        .textSelection(.enabled)
                        .accessibilityLabel("Invite code \(shared.inviteCode.map(String.init).joined(separator: " "))")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                ShareLink(item: inviteMessage) {
                    Label("Send invite", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.aisleAccent)

                VStack(alignment: .leading, spacing: 10) {
                    Text("On this list")
                        .font(Theme.font(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(Theme.secondaryInk)
                    ForEach(Array(shared.members.enumerated()), id: \.offset) { _, member in
                        HStack(spacing: 10) {
                            Text(member.firstName.first.map { String($0).uppercased() } ?? "?")
                                .font(Theme.font(14, .bold, relativeTo: .subheadline))
                                .foregroundStyle(Theme.onAccent)
                                .frame(width: 32, height: 32)
                                .background(Theme.accent, in: Circle())
                            Text(member.isYou ? "\(member.firstName) (you)" : member.firstName)
                                .font(.aisleBody)
                            Spacer()
                            if member.isOwner {
                                Text("Owner")
                                    .font(.aisleFootnote)
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                    }
                }
            }

            if let error {
                Text(error).font(.aisleFootnote).foregroundStyle(Theme.warning)
            }
            Spacer(minLength: 0)
            Button(shared?.isOwner == true ? "Stop sharing" : "Leave this list", role: .destructive) {
                confirmingStop = true
            }
            .font(.aisleSubheadline.weight(.semibold))
            .foregroundStyle(Color(hex: 0xE0607E))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(AisleBackground())
        .confirmationDialog(
            shared?.isOwner == true ? "Stop sharing this list?" : "Leave this list?",
            isPresented: $confirmingStop, titleVisibility: .visible
        ) {
            Button(shared?.isOwner == true ? "Stop sharing" : "Leave list", role: .destructive) {
                Task {
                    do {
                        try await list.stopSharingCurrent()
                        dismiss()
                    } catch {
                        self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't do that. Try again."
                    }
                }
            }
        } message: {
            Text(shared?.isOwner == true
                 ? "Everyone else loses the list. You keep it on this phone."
                 : "The list leaves this phone. The others keep it.")
        }
    }

    /// "K7Q2MXRT" as "K7Q2 MXRT" (and older six-letter codes as "K7Q 2MX"), easier to read out.
    static func spaced(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let half = code.count / 2
        return String(code.prefix(half)) + " " + String(code.suffix(half))
    }
}

/// Join a shared list with an invite code.
struct JoinListSheet: View {
    @Environment(ShoppingListStore.self) private var list
    @Environment(\.dismiss) private var dismiss
    @State var code: String
    @State private var isJoining = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Join a shared list")
                .font(Theme.font(26, .bold, relativeTo: .title))
                .tracking(-0.6)
                .padding(.top, 28)
            Text("Enter the code from your invite. You'll see the list and can add to it right away.")
                .font(.aisleSubheadline)
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Invite code", text: $code)
                .font(Theme.font(28, .bold, relativeTo: .title).monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.join)
                .onSubmit(join)
                .modifier(OnboardingFieldStyle())
                .accessibilityIdentifier("joinCodeField")
            if let error {
                Text(error).font(.aisleFootnote).foregroundStyle(Theme.warning)
            }
            Spacer(minLength: 0)
            Button(action: join) {
                if isJoining { ProgressView() } else { Text("Join list") }
            }
            .buttonStyle(.aisleAccent)
            .disabled(code.filter(\.isLetter).count + code.filter(\.isNumber).count < 4 || isJoining)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(AisleBackground())
        .onAppear { focused = code.isEmpty }
    }

    private func join() {
        guard !isJoining else { return }
        isJoining = true
        error = nil
        Task {
            defer { isJoining = false }
            do {
                try await list.join(code: code)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't join. Try again."
            }
        }
    }
}

/// Rename the current list.
struct RenameListSheet: View {
    @Environment(ShoppingListStore.self) private var list
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename list")
                .font(Theme.font(24, .bold, relativeTo: .title))
                .padding(.top, 24)
            TextField("List name", text: $name)
                .submitLabel(.done)
                .onSubmit(save)
                .modifier(OnboardingFieldStyle())
            Spacer(minLength: 0)
            Button("Save", action: save)
                .buttonStyle(.aisleAccent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .background(AisleBackground())
        .onAppear { name = list.current.name }
    }

    private func save() {
        list.renameCurrent(to: name)
        dismiss()
    }
}
