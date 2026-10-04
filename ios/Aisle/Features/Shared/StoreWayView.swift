import SwiftUI

/// Full-screen "show me the way" for one result, three ways:
/// a top-down map, a 3D model of the floor, and step-by-step directions.
struct StoreWayView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case map, model, steps
        var id: String { rawValue }
        var title: String {
            switch self {
            case .map: return "Map"
            case .model: return "3D"
            case .steps: return "Steps"
            }
        }
    }

    static let modeKey = "aisle.storeViewMode"

    let layout: StoreLayout
    let zoneID: Int
    let result: ItemSearchResult
    let retailer: String?

    @AppStorage(StoreWayView.modeKey) private var mode: Mode = .model
    @State private var yaw: Double = 0
    @State private var dragStartYaw: Double = 0
    @State private var stepIndex = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var target: FloorTile? {
        FloorTile.tiles(for: layout).first { $0.id == zoneID }
    }

    private var steps: [WayStep] {
        guard let target else { return [] }
        return StoreDirections.steps(layout: layout, target: target, result: result)
    }

    private var placeTitle: String {
        result.aisleLabel ?? result.placeInStore ?? target?.name ?? "Here"
    }

    private var caption: String {
        layout.approximate ? "Typical \(retailer ?? "store") layout · approximate" : "This store's layout"
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            ModePicker(mode: Binding(get: { mode }, set: { newMode in switchTo(newMode) }))
            ZStack {
                if mode == .steps {
                    StepsMode(
                        result: result, placeTitle: placeTitle, steps: steps, caption: caption,
                        index: $stepIndex, onShowMap: { switchTo(.map) }, onDone: { dismiss() }
                    )
                    .transition(.opacity.combined(with: .offset(y: 12)))
                } else {
                    floorMode
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 12)
        .background(AisleBackground())
        .font(.aisleBody)
        .foregroundStyle(Theme.ink)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Theme.surface, in: Circle())
                    .shadow(color: Theme.ink.opacity(0.08), radius: 12, y: 6)
            }
            .accessibilityLabel("Close")
            Spacer()
            AisleWordmark()
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 20)
    }

    // MARK: - Map and 3D share one floor, so switching swings it between the two

    private var floorMode: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottom) {
                FloorPlanView(
                    layout: layout, targetZoneID: zoneID, pinTitle: placeTitle,
                    tilt: mode == .model ? 1 : 0, yaw: mode == .model ? yaw : 0
                )
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .gesture(rotateGesture, including: mode == .model ? .all : .none)

                Label(caption, systemImage: "map")
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.bottom, 4)
            }
            .frame(maxHeight: .infinity)

            if mode == .map {
                mapSheet
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                modelCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var rotateGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                yaw = min(max(dragStartYaw + value.translation.width * 0.25, -40), 40)
            }
            .onEnded { _ in dragStartYaw = yaw }
    }

    /// Map mode: item, confidence and the turns as a short list.
    private var mapSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            itemRow
            VStack(alignment: .leading, spacing: 12) {
                ForEach(steps) { step in
                    HStack(spacing: 12) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(
                                step.kind == .arrive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fill),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title).font(Theme.font(15, .semibold, relativeTo: .subheadline))
                            Text(step.detail)
                                .font(.aisleFootnote)
                                .foregroundStyle(Theme.secondaryInk)
                                .lineLimit(2)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.ink.opacity(0.08), radius: 20, y: -6)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// 3D mode: the place big, plus Steps and Done.
    private var modelCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                PlaceTile(result: result, fallback: placeTitle)
                VStack(alignment: .leading, spacing: 4) {
                    ConfidenceBadge(confidence: result.confidence)
                    Text(result.item.prefix(1).uppercased() + result.item.dropFirst())
                        .font(Theme.font(20, .bold, relativeTo: .title3))
                        .lineLimit(1)
                    Text(steps.last?.detail ?? "")
                        .font(.aisleFootnote)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button("Steps") { switchTo(.steps) }
                    .buttonStyle(.aisleSoftFilled)
                Button("Done") { dismiss() }
                    .buttonStyle(.aisleAccent)
            }
            Text("Drag the map to turn it")
                .font(Theme.font(12, .medium, relativeTo: .caption))
                .foregroundStyle(Theme.secondaryInk)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.10), radius: 22, y: 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var itemRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.item.prefix(1).uppercased() + result.item.dropFirst())
                    .font(Theme.font(21, .bold, relativeTo: .title3))
                    .tracking(-0.4)
                Text([result.placeInStore, result.aisleLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
            }
            Spacer(minLength: 8)
            ConfidenceBadge(confidence: result.confidence)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.accentSoft, in: Capsule())
        }
    }

    private func switchTo(_ newMode: Mode) {
        guard newMode != mode else { return }
        if newMode != .model { yaw = 0; dragStartYaw = 0 }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.8, dampingFraction: 0.86)) {
            mode = newMode
        }
    }
}

// MARK: - Pieces

/// Capsule segmented control: Map · 3D · Steps, or just some of them.
struct ModePicker: View {
    @Binding var mode: StoreWayView.Mode
    var modes: [StoreWayView.Mode] = StoreWayView.Mode.allCases
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes) { item in
                Button { mode = item } label: {
                    Text(item.title)
                        .font(Theme.font(13, .semibold, relativeTo: .footnote))
                        .foregroundStyle(mode == item ? Theme.background : Theme.secondaryInk)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background {
                            if mode == item {
                                Capsule().fill(Theme.ink).matchedGeometryEffect(id: "pill", in: selection)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == item ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.surface.opacity(0.92), in: Capsule())
        .shadow(color: Theme.ink.opacity(0.08), radius: 12, y: 6)
        .sensoryFeedback(.selection, trigger: mode)
    }
}

/// The big gradient square: the aisle number, or the department when there's no aisle.
private struct PlaceTile: View {
    let result: ItemSearchResult
    let fallback: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let aisle = result.location.aisle, !aisle.isEmpty, aisle.first?.isNumber == true {
                Text("Aisle").font(Theme.font(12, .semibold, relativeTo: .caption))
                Spacer(minLength: 0)
                Text(aisle)
                    .font(Theme.font(42, .bold, relativeTo: .largeTitle))
                    .tracking(-2)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            } else {
                Image(systemName: "mappin.and.ellipse").font(.system(size: 18, weight: .semibold))
                Spacer(minLength: 0)
                Text(fallback)
                    .font(Theme.font(14, .bold, relativeTo: .subheadline))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(Theme.onAccent)
        .padding(12)
        .frame(width: 84, height: 84, alignment: .leading)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Steps mode: one big instruction at a time with a progress track.
private struct StepsMode: View {
    let result: ItemSearchResult
    let placeTitle: String
    let steps: [WayStep]
    let caption: String
    @Binding var index: Int
    let onShowMap: () -> Void
    let onDone: () -> Void

    @State private var found = false

    private var current: WayStep? { steps.indices.contains(index) ? steps[index] : nil }
    private var isLast: Bool { index >= steps.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(result.item.prefix(1).uppercased() + result.item.dropFirst())
                        .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                    Spacer()
                    ConfidenceBadge(confidence: result.confidence)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.accentSoft, in: Capsule())
                }
                Text(placeTitle)
                    .font(Theme.font(56, .bold, relativeTo: .largeTitle))
                    .tracking(-2)
                    .foregroundStyle(Theme.accentInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 24)

            ProgressTrack(labels: steps.map(\.short), index: index)
                .padding(.horizontal, 32)
                .padding(.top, 22)

            stepCard
                .padding(.horizontal, 16)
                .padding(.top, 22)

            Button(action: onShowMap) {
                HStack(spacing: 12) {
                    Image(systemName: "map")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("See it on the map").font(Theme.font(15, .semibold, relativeTo: .subheadline))
                        Text(caption).font(Theme.font(12, relativeTo: .caption)).foregroundStyle(Theme.secondaryInk)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryInk)
                }
                .padding(10)
                .background(Theme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                Button("Back") {
                    if found { found = false } else if index > 0 { advance(-1) }
                }
                .buttonStyle(.aisleSoftFilled)
                .disabled(index == 0 && !found)
                Button(nextLabel) {
                    if !isLast { advance(1) } else if found { onDone() } else { withAnimation(.spring) { found = true } }
                }
                .buttonStyle(.aisleAccent)
                .layoutPriority(1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .sensoryFeedback(.selection, trigger: index)
        .sensoryFeedback(.success, trigger: found)
    }

    private var nextLabel: String {
        if !isLast { return "Next step" }
        return found ? "Done" : "I found it"
    }

    private var stepCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: found ? "checkmark" : (current?.symbol ?? "arrow.up"))
                    .font(.system(size: 28, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 64, height: 64)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Theme.glow.opacity(0.25), radius: 10, y: 6)
                Spacer()
                Text("Step \(index + 1) of \(steps.count)")
                    .font(Theme.font(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(Theme.secondaryInk)
            }
            Group {
                Text(found ? "Nice, you found it!" : (current?.title ?? ""))
                    .font(Theme.font(28, .bold, relativeTo: .title))
                    .tracking(-0.8)
                    .padding(.top, 18)
                Text(found ? "Glad Aisle could help. Tap Found it on the result to make it more sure for the next shopper." : (current?.detail ?? ""))
                    .font(Theme.font(15, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
            .id("\(index)-\(found)")
            .transition(.opacity.combined(with: .offset(y: 8)))

            if !found, steps.indices.contains(index + 1) {
                Divider().overlay(Theme.hairline).padding(.top, 16)
                (Text("Then ").fontWeight(.semibold).foregroundStyle(Theme.ink)
                    + Text(steps[index + 1].title.prefix(1).lowercased() + steps[index + 1].title.dropFirst()))
                    .font(Theme.font(13, relativeTo: .footnote))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.top, 12)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                Theme.surface
                Circle()
                    .fill(RadialGradient(colors: [Theme.glow.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 110))
                    .frame(width: 220, height: 220)
                    .offset(x: 60, y: -60)
            }
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        )
        .shadow(color: Theme.ink.opacity(0.08), radius: 20, y: 10)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: index)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: found)
    }

    private func advance(_ delta: Int) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            index = min(max(index + delta, 0), steps.count - 1)
        }
    }
}

/// Dots on a line; the gradient fills up to the current step.
private struct ProgressTrack: View {
    let labels: [String]
    let index: Int

    var body: some View {
        GeometryReader { geo in
            let count = max(labels.count - 1, 1)
            let usable = geo.size.width - 16
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.hairline).frame(height: 3).padding(.horizontal, 8).offset(y: 7)
                Capsule().fill(Theme.accentInk)
                    .frame(width: usable * CGFloat(index) / CGFloat(count), height: 3)
                    .offset(x: 8, y: 7)
                ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                    VStack(spacing: 6) {
                        Circle()
                            .fill(i < index ? AnyShapeStyle(Color(hex: 0xDC6F9C)) : AnyShapeStyle(Theme.surface))
                            .overlay {
                                if i == index {
                                    Circle().strokeBorder(Color(hex: 0xDC6F9C), lineWidth: 5)
                                } else if i > index {
                                    Circle().strokeBorder(Theme.hairline, lineWidth: 2)
                                }
                            }
                            .frame(width: i == index ? 18 : 12, height: i == index ? 18 : 12)
                            .shadow(color: i == index ? Theme.glow.opacity(0.35) : .clear, radius: 6)
                            .frame(height: 18)
                        Text(label)
                            .font(Theme.font(11, i == index ? .bold : .medium, relativeTo: .caption2))
                            .foregroundStyle(i == index ? Theme.ink : Theme.secondaryInk)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(width: 70)
                    .position(x: 8 + usable * CGFloat(i) / CGFloat(count), y: 20)
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: index)
        }
        .frame(height: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(labels.count)")
    }
}

/// Full-width filled button for the quieter action next to an accent one.
struct SoftFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SoftFilledBody(configuration: configuration)
    }
}

private struct SoftFilledBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.aisleHeadline)
            .foregroundStyle(isEnabled ? Theme.ink : Theme.secondaryInk)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == SoftFilledButtonStyle {
    static var aisleSoftFilled: SoftFilledButtonStyle { SoftFilledButtonStyle() }
}
