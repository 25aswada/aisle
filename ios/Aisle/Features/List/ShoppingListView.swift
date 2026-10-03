import SwiftUI

struct ShoppingListView: View {
    let api: AisleAPI
    let analytics: AnalyticsTracking

    @Environment(ShoppingListStore.self) private var list
    @Environment(StoreSelection.self) private var storeSelection
    @State private var composer: ListComposerModel
    @State private var trip: ShoppingTripModel?
    @State private var showNeedsStore = false
    @FocusState private var composerFocused: Bool

    init(api: AisleAPI, analytics: AnalyticsTracking) {
        self.api = api
        self.analytics = analytics
        _composer = State(initialValue: ListComposerModel(api: api, analytics: analytics))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ListComposer(composer: composer, focused: $composerFocused) {
                        Task { await composer.add(to: list) }
                    }
                } footer: {
                    if let notice = composer.notice {
                        Label(notice, systemImage: "wifi.slash")
                    } else {
                        Text("Type or paste several items at once, like “milk eggs bananas toothpaste”.")
                    }
                }

                if list.items.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Your list is empty",
                            systemImage: "checklist",
                            description: Text("Add items above.")
                        )
                    }
                } else {
                    Section {
                        ForEach(list.items) { item in
                            ListItemRow(item: item)
                        }
                        .onDelete { list.remove(atOffsets: $0) }
                        .onMove { list.move(fromOffsets: $0, toOffset: $1) }
                    } header: {
                        Text("\(list.remaining.count) of \(list.items.count) left")
                    }
                }
            }
            .aislePage()
            .tint(Theme.ink)
            .safeAreaInset(edge: .bottom) {
                if !list.remaining.isEmpty {
                    Button(action: startShopping) {
                        Label("Start Shopping", systemImage: "cart")
                    }
                    .buttonStyle(.aisleAccent)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("startShoppingButton")
                }
            }
            .fullScreenCover(item: $trip) { trip in
                ShoppingModeView(model: trip)
            }
            .alert("Choose a store first", isPresented: $showNeedsStore) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Pick your store on the Find tab, then start shopping.")
            }
            .navigationTitle("List")
            .toolbar {
                if !list.items.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Clear checked items", systemImage: "checkmark.circle") { list.clearCompleted() }
                                .disabled(list.items.allSatisfy { !$0.isDone })
                            Button("Clear all", systemImage: "trash", role: .destructive) { list.clearAll() }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
        }
    }
}

extension ShoppingListView {
    private func startShopping() {
        composerFocused = false
        guard let store = storeSelection.current else {
            showNeedsStore = true
            return
        }
        trip = ShoppingTripModel(api: api, store: store, list: list, analytics: analytics)
    }
}

extension ShoppingTripModel: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

private struct ListComposer: View {
    @Bindable var composer: ListComposerModel
    var focused: FocusState<Bool>.Binding
    let onAdd: () -> Void

    var body: some View {
        // Centered: a vertical-axis field doesn't report a baseline that lines up with the pill.
        HStack(alignment: .center, spacing: 8) {
            TextField("Add items", text: $composer.draft, axis: .vertical)
                .lineLimit(1...4)
                .focused(focused)
                .submitLabel(.done)
                .textInputAutocapitalization(.never)
                .onSubmit(onAdd)
                .accessibilityIdentifier("listComposerField")
            if composer.isAdding {
                ProgressView()
            } else {
                Button("Add", action: onAdd)
                    .buttonStyle(.aisleAccentPill)
                    .disabled(composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("listAddButton")
            }
        }
    }
}

/// A list row whose text is edited in place.
struct ListItemRow: View {
    let item: ListItem

    @Environment(ShoppingListStore.self) private var list
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                list.setDone(item.id, !item.isDone)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isDone ? AnyShapeStyle(Theme.accentInk) : AnyShapeStyle(Theme.secondaryInk))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark \(item.text) as not done" : "Mark \(item.text) as done")

            VStack(alignment: .leading, spacing: 2) {
                TextField("Item", text: $text)
                    .focused($editing)
                    .strikethrough(item.isDone)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .submitLabel(.done)
                    .onSubmit { list.rename(item.id, to: text) }
                    .accessibilityLabel("Item name")
                if let detail {
                    Text(detail)
                        .font(.aisleCaption)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
        }
        .onAppear { text = item.text }
        .onChange(of: item.text) { text = item.text }
        .onChange(of: editing) { _, isEditing in
            if !isEditing { list.rename(item.id, to: text) }
        }
    }

    private var detail: String? {
        // Skip the category when it just repeats the item ("cheese" / "Cheese").
        let category = item.categoryName.flatMap { $0.caseInsensitiveCompare(item.text) == .orderedSame ? nil : $0 }
        let parts = [item.quantity.map { "Qty \($0)" }, category].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
