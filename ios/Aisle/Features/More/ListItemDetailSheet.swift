import SwiftUI

/// Details for one list item: how many, which brand, a note, and where it was last time.
struct ListItemDetailSheet: View {
    let itemID: UUID

    @Environment(ShoppingListStore.self) private var list
    @Environment(RecentSearches.self) private var recents
    @Environment(StoreSelection.self) private var storeSelection
    @Environment(\.dismiss) private var dismiss

    @State private var count = 1
    @State private var unit = ""
    @State private var brand = ""
    @State private var note = ""
    @State private var department = ""
    @State private var loaded = false

    private static let units = ["", "lb", "oz", "pack", "bag", "box", "dozen"]

    private var item: ListItem? { list.items.first { $0.id == itemID } }

    var body: some View {
        MoreScreen(title: nil) {
            Button("Done") { save(); dismiss() }
                .font(Theme.font(16, .semibold, relativeTo: .body))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Theme.surface.opacity(0.92), in: Capsule())
        } content: {
            if let item {
                header(item).padding(.top, 14)
                quantityCard.padding(.top, 20)
                fields.padding(.top, 12)
                whereItIs(item)
                Button(role: .destructive) {
                    list.remove(item.id)
                    dismiss()
                } label: {
                    Label("Remove from list", systemImage: "trash")
                        .font(Theme.font(16, .semibold, relativeTo: .body))
                        .foregroundStyle(Color(hex: 0xE0607E))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .padding(.top, 20)
            } else {
                Text("This item isn't on your list anymore.")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 30)
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    private func header(_ item: ListItem) -> some View {
        HStack(spacing: 14) {
            ItemIconView(text: item.text, size: 64, tile: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text.capitalizedFirst)
                    .font(Theme.font(28, .bold, relativeTo: .title))
                    .tracking(-0.8)
                    .lineLimit(2)
                if let category = item.categoryName {
                    Text(category)
                        .font(.aisleSubheadline)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
        }
    }

    private var quantityCard: some View {
        MoreCard(padding: 16) {
            HStack {
                Text("Quantity")
                    .font(Theme.font(16, .semibold, relativeTo: .body))
                Spacer()
                HStack(spacing: 0) {
                    stepButton("minus") { count = max(1, count - 1) }
                        .disabled(count <= 1)
                    Text("\(count)")
                        .font(Theme.font(20, .bold, relativeTo: .title3))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(minWidth: 36)
                    stepButton("plus") { count = min(99, count + 1) }
                }
                .background(Theme.fill, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Quantity")
                .accessibilityValue("\(count)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: count = min(99, count + 1)
                    case .decrement: count = max(1, count - 1)
                    @unknown default: break
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.units, id: \.self) { option in
                        Button(option.isEmpty ? "each" : option) {
                            withAnimation(.snappy(duration: 0.2)) { unit = option }
                        }
                        .font(Theme.font(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(unit == option ? Theme.onAccent : Theme.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background {
                            if unit == option { Capsule().fill(Theme.accent) } else { Capsule().fill(Theme.fill) }
                        }
                        .accessibilityAddTraits(unit == option ? .isSelected : [])
                    }
                }
            }
            .padding(.top, 14)
        }
        .sensoryFeedback(.selection, trigger: count)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 40, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fields: some View {
        MoreCard(padding: 0) {
            field("Brand", text: $brand, prompt: "Any brand")
            Divider().overlay(Theme.hairline).padding(.leading, 16)
            field("Note", text: $note, prompt: "e.g. lactose-free, ripe ones")
            Divider().overlay(Theme.hairline).padding(.leading, 16)
            field("Department", text: $department, prompt: "Sorted automatically")
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                .frame(width: 96, alignment: .leading)
            TextField(prompt, text: text)
                .font(Theme.font(16, relativeTo: .body))
                .submitLabel(.done)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    /// Where Aisle found it last time at this store, if it's been searched here.
    @ViewBuilder
    private func whereItIs(_ item: ListItem) -> some View {
        if let store = storeSelection.current, let answer = recents.answer(for: item.text, storeID: store.id) {
            MoreSectionTitle(text: "Where it is")
            MoreCard(padding: 16) {
                HStack(spacing: 12) {
                    SmallStoreLogo(url: store.retailerLogoURL, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(answer.place)
                            .font(Theme.font(22, .bold, relativeTo: .title2))
                            .tracking(-0.5)
                            .foregroundStyle(answer.confidence == .high ? AnyShapeStyle(Theme.accentInk) : AnyShapeStyle(Theme.ink))
                        Text([answer.detail, store.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(Theme.font(12, relativeTo: .caption))
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    ConfidenceBars(level: answer.confidence.level, height: 13)
                        .foregroundStyle(Theme.ink)
                }
                Text("From your last search here. \(answer.confidence.shortLabel).")
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 10)
            }
        }
    }

    // MARK: Load / save

    private func load() {
        guard !loaded, let item else { return }
        loaded = true
        let parts = (item.quantity ?? "").split(separator: " ", maxSplits: 1).map(String.init)
        if let first = parts.first, let number = Int(first) {
            count = max(1, min(99, number))
            unit = parts.count > 1 ? parts[1] : ""
        } else if let quantity = item.quantity, !quantity.isEmpty {
            // Something like "a dozen": keep it as the unit text.
            unit = quantity
        }
        brand = item.brand ?? ""
        note = item.note ?? ""
        department = item.categoryName ?? ""
    }

    private func save() {
        guard loaded, item != nil else { return }
        let quantity: String? = {
            if count == 1 && unit.isEmpty { return nil }
            return unit.isEmpty ? "\(count)" : "\(count) \(unit)"
        }()
        list.updateDetails(itemID, quantity: quantity, brand: brand, note: note, categoryName: department)
    }
}
