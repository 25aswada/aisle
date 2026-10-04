import SwiftUI

/// Every list in one place: what's on each, which one is open, and a new one. Free
/// shoppers have one list of their own; Aisle+ has no limit.
struct AllListsSheet: View {
    let isPlus: Bool
    /// Makes a new list current; the List tab then puts the cursor in its add bar.
    let onNewList: () -> Void

    @Environment(ShoppingListStore.self) private var list
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: ShoppingList?
    @State private var newName = ""
    @State private var deleting: ShoppingList?
    @State private var problem: String?
    @State private var upgradeReason: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your lists")
                        .font(Theme.font(30, .bold, relativeTo: .largeTitle))
                        .tracking(-0.8)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(Theme.font(16, .semibold, relativeTo: .body))
                }
                .padding(.top, 28)
                Text(planLine)
                    .font(Theme.font(14, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 4)

                VStack(spacing: 12) {
                    ForEach(list.lists) { item in
                        Button {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { list.select(item.id) }
                            dismiss()
                        } label: {
                            ListCard(list: item, isCurrent: item.id == list.currentID)
                        }
                        .buttonStyle(PressableCardStyle())
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") {
                                newName = item.name
                                renaming = item
                            }
                            Button(deleteAction(for: item), systemImage: "xmark.bin", role: .destructive) {
                                deleting = item
                            }
                        }
                        .accessibilityHint(item.id == list.currentID ? "The list that's open" : "Opens this list")
                        .accessibilityIdentifier("listCard-\(item.name)")
                    }
                }
                .padding(.top, 22)

                newListButton.padding(.top, 18)

                if !isPlus && list.ownLists.count > ShoppingListStore.freeListLimit {
                    Text("Your lists from Aisle+ are all kept. Making another one needs Aisle+.")
                        .font(.aisleFootnote)
                        .foregroundStyle(Theme.secondaryInk)
                        .padding(.top, 10)
                }
                Text("Touch and hold a list to rename or delete it.")
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 14)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: list.lists)
        }
        .background(AisleBackground())
        .accessibilityIdentifier("allListsSheet")
        .plusUpgradeSheet(reason: $upgradeReason)
        .alert("Rename list", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("List name", text: $newName)
            Button("Save") {
                if let renaming { list.renameList(renaming.id, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deleting.map(deleteTitle) ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { item in
            Button(deleteAction(for: item), role: .destructive) {
                Task {
                    do { try await list.deleteList(item.id) } catch {
                        problem = (error as? LocalizedError)?.errorDescription ?? "Couldn't do that. Try again."
                    }
                }
            }
        } message: { item in
            Text(deleteMessage(for: item))
        }
        .alert("Couldn't delete the list", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var planLine: String {
        let count = list.lists.count
        let lists = "\(count) \(count == 1 ? "list" : "lists")"
        return isPlus ? "\(lists) · As many as you like with Aisle+" : "\(lists) · The free plan has 1 list of your own"
    }

    private var newListButton: some View {
        let canCreate = list.canCreateList(isPlus: isPlus)
        return Button {
            if canCreate {
                onNewList()
                dismiss()
            } else {
                upgradeReason = "Make as many lists as you like with Aisle+: one for every store, week or occasion."
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("New list")
                if !canCreate {
                    Text("Aisle+")
                        .font(Theme.font(11, .bold, relativeTo: .caption2))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.fill, in: Capsule())
                }
            }
            .font(.aisleHeadline)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                    .strokeBorder(Theme.accentRing, lineWidth: 1.5)
            )
        }
        .buttonStyle(PressableCardStyle())
        .accessibilityHint(canCreate ? "" : "Unlimited lists are part of Aisle+")
        .accessibilityIdentifier("allListsNewListButton")
    }

    private func deleteTitle(_ item: ShoppingList) -> String {
        guard let shared = item.shared else { return "Delete “\(item.name)”?" }
        return shared.isOwner ? "Delete “\(item.name)” for everyone?" : "Leave “\(item.name)”?"
    }

    private func deleteAction(for item: ShoppingList) -> String {
        guard let shared = item.shared else { return "Delete list" }
        return shared.isOwner ? "Delete for everyone" : "Leave list"
    }

    private func deleteMessage(for item: ShoppingList) -> String {
        guard let shared = item.shared else {
            return list.lists.count == 1 ? "Its items are removed and you start with an empty list." : "Its items are removed from this phone."
        }
        return shared.isOwner ? "Everyone on the list loses it." : "The others keep the list."
    }
}

/// One list on the All lists page: name, progress, what's on it, and who it's shared with.
private struct ListCard: View {
    let list: ShoppingList
    let isCurrent: Bool

    private var left: [ListItem] { list.items.filter { !$0.isDone } }
    private var fraction: Double {
        list.items.isEmpty ? 0 : Double(list.items.count - left.count) / Double(list.items.count)
    }

    private var countLine: String {
        let total = list.items.count
        if total == 0 { return "Empty" }
        if left.isEmpty { return "\(total) \(total == 1 ? "item" : "items") · All done" }
        return "\(total) \(total == 1 ? "item" : "items") · \(left.count) left"
    }

    private var preview: String? {
        let names = left.prefix(4).map(\.text)
        guard !names.isEmpty else { return nil }
        return names.joined(separator: ", ") + (left.count > names.count ? "…" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(list.name)
                    .font(Theme.font(20, .bold, relativeTo: .title3))
                    .tracking(-0.4)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isCurrent {
                    Label("Open", systemImage: "checkmark")
                        .font(Theme.font(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(Theme.accentInk)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            Text(countLine)
                .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
            if let preview {
                Text(preview)
                    .font(Theme.font(14, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            if !list.items.isEmpty {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill)
                        if fraction > 0 {
                            Capsule().fill(Theme.accent).frame(width: max(6, proxy.size.width * fraction))
                        }
                    }
                }
                .frame(height: 6)
                .padding(.top, 2)
                .accessibilityHidden(true)
            }
            if let with = list.shared?.withLabel ?? (list.shared != nil ? "Shared" : nil) {
                Label(with, systemImage: "person.2")
                    .font(Theme.font(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(Theme.accentInk)
            }
        }
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(isCurrent ? AnyShapeStyle(Theme.accentWash) : AnyShapeStyle(Theme.surface))
        }
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accentRing, lineWidth: 1.5)
            }
        }
        .shadow(color: Theme.ink.opacity(0.05), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
    }
}
