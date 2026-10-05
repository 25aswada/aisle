import SwiftUI

/// A shared list's sheet: who's on it and, for the owner, the invite (link, code, and a way
/// to make a new one) and taking people off. Everyone else can leave it or report it.
struct ShareListSheet: View {
    @Environment(ShoppingListStore.self) private var list
    @Environment(\.dismiss) private var dismiss
    /// The list this opened for, so the sheet stays on it even if the current list changes.
    @State private var listID: UUID?
    @State private var confirmingStop = false
    @State private var confirmingNewLink = false
    @State private var removing: SharedMember?
    @State private var reporting = false
    @State private var isWorking = false
    @State private var notice: String?
    @State private var error: String?

    private var id: UUID { listID ?? list.currentID }
    private var shown: ShoppingList? { list.lists.first { $0.id == id } }
    private var shared: SharedInfo? { shown?.shared }
    private var isOwner: Bool { shared?.isOwner == true }
    private var name: String { shown?.name ?? "" }

    private var inviteMessage: String {
        guard let code = shared?.inviteCode, let url = shared?.inviteURL else { return "" }
        return "Join my Aisle list “\(name)”: \(url.absoluteString)\n\nOr open Aisle → List → ••• → Join a shared list, and enter \(code)."
    }

    private var subtitle: String {
        if isOwner || shared == nil {
            return "Everyone on the list sees what's added and checked off, as it happens. Joining is free."
        }
        let owner = shared?.owner?.firstName ?? "Someone"
        return "\(owner) shared this list with you. Everyone on it sees what's added and checked off, as it happens."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(isOwner ? "Share “\(name)”" : "“\(name)”")
                    .font(Theme.font(26, .bold, relativeTo: .title))
                    .tracking(-0.6)
                    .padding(.top, 28)
                Text(subtitle)
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                if let shared {
                    if isOwner, let code = shared.inviteCode {
                        invite(code)
                    }
                    members(shared)
                }

                if let notice {
                    AisleNote(text: notice)
                }
                if let error {
                    Text(error).font(.aisleFootnote).foregroundStyle(Theme.warning)
                }
                footer
                    .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .foregroundStyle(Theme.ink)
        .background(AisleBackground())
        .onAppear { listID = listID ?? list.currentID }
        .confirmationDialog(
            isOwner ? "Stop sharing this list?" : "Leave this list?",
            isPresented: $confirmingStop, titleVisibility: .visible
        ) {
            Button(isOwner ? "Stop sharing" : "Leave list", role: .destructive) {
                run {
                    try await list.stopSharingCurrent()
                    dismiss()
                }
            }
        } message: {
            Text(isOwner
                 ? "Everyone else loses the list. You keep it on this phone."
                 : "The list leaves this phone. The others keep it.")
        }
        .confirmationDialog("Reset the invite link?", isPresented: $confirmingNewLink, titleVisibility: .visible) {
            Button("Reset invite link", role: .destructive) {
                run {
                    try await list.newInviteLink(for: id)
                    notice = "New link ready. The old link and code don't work anymore."
                }
            }
        } message: {
            Text("The old link and code stop working. Everyone already on the list stays on it.")
        }
        .confirmationDialog(
            removing.map { "Remove \($0.firstName)?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible, presenting: removing
        ) { member in
            Button("Remove", role: .destructive) {
                run {
                    try await list.removeMember(member, from: id)
                    notice = "\(member.firstName) is off the list."
                }
            }
        } message: { member in
            Text("\(member.firstName) loses the list and can't join it again, even with a new invite link.")
        }
        .sheet(isPresented: $reporting, onDismiss: {
            // Reporting can leave the list; then there's nothing left to show here.
            if shared == nil { dismiss() }
        }) {
            ReportListSheet(listID: id, listName: name)
                .presentationDetents([.large])
        }
    }

    @ViewBuilder
    private func invite(_ code: String) -> some View {
        VStack(spacing: 6) {
            Text("Invite code")
                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(Theme.secondaryInk)
            Text(Self.spaced(code))
                .font(Theme.font(40, .bold, relativeTo: .largeTitle).monospaced())
                .tracking(4)
                .foregroundStyle(Theme.accentInk)
                .textSelection(.enabled)
                .accessibilityLabel("Invite code \(code.map(String.init).joined(separator: " "))")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

        ShareLink(item: inviteMessage) {
            Label("Send invite", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.aisleAccent)

        VStack(alignment: .leading, spacing: 8) {
            Button { confirmingNewLink = true } label: {
                Label("Reset invite link", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.aisleSoft)
            .disabled(isWorking)
            Text("Sent it to the wrong person? A new link and code stop the old ones from working.")
                .font(.aisleFootnote)
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func members(_ shared: SharedInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On this list")
                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(Theme.secondaryInk)
            ForEach(Array(shared.members.enumerated()), id: \.offset) { _, member in
                HStack(spacing: 10) {
                    Text(member.firstName.first.map { String($0).uppercased() } ?? "?")
                        .font(Theme.font(20, .bold, relativeTo: .title3))
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: 32, height: 32)
                    Text(member.isYou ? "\(member.firstName) (you)" : member.firstName)
                        .font(.aisleBody)
                    Spacer()
                    if member.isOwner {
                        Text("Owner")
                            .font(.aisleFootnote)
                            .foregroundStyle(Theme.secondaryInk)
                    } else if isOwner, member.id != nil {
                        Button("Remove") { removing = member }
                            .buttonStyle(.plain)
                            .font(Theme.font(13, .semibold, relativeTo: .footnote))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 32)
                            .background(Theme.fill, in: Capsule())
                            .disabled(isWorking)
                            .accessibilityLabel("Remove \(member.firstName)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if shared != nil && !isOwner {
            Button { reporting = true } label: {
                Label("Report list", systemImage: "flag")
            }
            .buttonStyle(.aisleSoft)
            .disabled(isWorking)
        }
        Button(isOwner ? "Stop sharing" : "Leave this list", role: .destructive) {
            confirmingStop = true
        }
        .font(.aisleSubheadline.weight(.semibold))
        .foregroundStyle(Color(hex: 0xE0607E))
        .frame(maxWidth: .infinity, minHeight: 44)
        .disabled(shared == nil || isWorking)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await action()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't do that. Try again."
            }
        }
    }

    /// "K7Q2MXRT" as "K7Q2 MXRT" (and older six-letter codes as "K7Q 2MX"), easier to read out.
    static func spaced(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let half = code.count / 2
        return String(code.prefix(half)) + " " + String(code.suffix(half))
    }
}

/// Report a shared list to Aisle: why, an optional note, and whether to leave it too.
struct ReportListSheet: View {
    @Environment(ShoppingListStore.self) private var list
    @Environment(\.dismiss) private var dismiss
    let listID: UUID
    let listName: String
    @State private var reason: SharedListReportReason?
    @State private var note = ""
    @State private var alsoLeave = true
    @State private var isSending = false
    @State private var sent = false
    @State private var error: String?

    var body: some View {
        Group {
            if sent { confirmation } else { form }
        }
        .foregroundStyle(Theme.ink)
        .background(AisleBackground())
        .interactiveDismissDisabled(isSending)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Report “\(listName)”")
                    .font(Theme.font(24, .bold, relativeTo: .title))
                    .padding(.top, 24)
                Text("Reports go to the Aisle team, and we review every one. Nobody on the list is told.")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    ForEach(SharedListReportReason.allCases) { option in
                        Button { reason = option } label: {
                            HStack {
                                Text(option.label)
                                    .font(.aisleBody)
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Image(systemName: reason == option ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(reason == option
                                                     ? AnyShapeStyle(Theme.accentInk)
                                                     : AnyShapeStyle(Theme.secondaryInk.opacity(0.4)))
                            }
                            .aisleCard(padding: 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableCardStyle())
                        .accessibilityAddTraits(reason == option ? .isSelected : [])
                    }
                }

                TextField("Add a note (optional)", text: $note, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(.vertical, 16)
                    .modifier(OnboardingFieldStyle())
                    .onChange(of: note) { if note.count > 500 { note = String(note.prefix(500)) } }

                Toggle("Also leave this list", isOn: $alsoLeave)
                    .font(.aisleBody)
                    .tint(Theme.glow)

                if let error {
                    Text(error).font(.aisleFootnote).foregroundStyle(Theme.warning)
                }
                Button(action: send) {
                    if isSending { ProgressView() } else { Text("Send report") }
                }
                .buttonStyle(.aisleAccent)
                .disabled(reason == nil || isSending)
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var confirmation: some View {
        VStack(spacing: 0) {
            Spacer()
            AisleEmptyState(
                title: "Thanks for telling us",
                systemImage: "checkmark.seal",
                message: alsoLeave
                    ? "We'll look into it. You've left the list, so it's gone from this phone."
                    : "We'll look into it. You can still leave the list anytime."
            )
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.aisleAccent)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private func send() {
        guard let reason, !isSending else { return }
        isSending = true
        error = nil
        Task {
            defer { isSending = false }
            do {
                try await list.report(listID, reason: reason, note: note, alsoLeave: alsoLeave)
                withAnimation(.easeOut(duration: 0.2)) { sent = true }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't send that. Try again."
            }
        }
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
                // The server says why: a wrong code, a full list, or one you were removed from.
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
