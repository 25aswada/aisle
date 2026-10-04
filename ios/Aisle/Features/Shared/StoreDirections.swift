import Foundation

/// Plain turn-by-turn steps from the entrance to a department, built from the layout's
/// positions. It only uses what the layout and the result contain: departments to pass,
/// which side they're on, and the aisle or section when the result has one on file.
struct WayStep: Equatable, Identifiable {
    enum Kind { case enter, turnLeft, turnRight, ahead, arrive }

    let id: Int
    let kind: Kind
    /// One word for the progress track, e.g. "Front" or "Aisle 7".
    let short: String
    let title: String
    let detail: String

    var symbol: String {
        switch kind {
        case .enter, .ahead: return "arrow.up"
        case .turnLeft: return "arrow.turn.up.left"
        case .turnRight: return "arrow.turn.up.right"
        case .arrive: return "mappin.and.ellipse"
        }
    }
}

enum StoreDirections {
    static func steps(layout: StoreLayout, target: FloorTile, result: ItemSearchResult) -> [WayStep] {
        let tiles = FloorTile.tiles(for: layout)
        let others = tiles.filter { $0.id != target.id }
        let entrance = layout.entrance ?? StoreLayout.Point(x: 0.5, y: 0.0)
        let department = result.placeInStore ?? target.name
        var steps: [WayStep] = []

        // 1. Walk in, naming the department right by the door.
        let byDoor = others
            .map { ($0, hypot($0.rect.midX - entrance.x, $0.rect.midY - entrance.y)) }
            .filter { $0.1 < 0.35 }
            .min { $0.1 < $1.1 }?.0
        let enterDetail = byDoor.map { "\($0.name) is just inside, on your \(side(of: $0.rect.midX, from: entrance.x))." }
            ?? "Head in through the main doors."
        steps.append(WayStep(id: 0, kind: .enter, short: "Enter", title: "Walk in", detail: enterDetail))

        // 2. Along the front, if the target is off to one side.
        let dx = target.rect.midX - entrance.x
        let turnedRight = dx > 0
        if abs(dx) > 0.1 {
            let lo = min(entrance.x, target.rect.midX), hi = max(entrance.x, target.rect.midX)
            let passed = others
                .filter { $0.rect.midY < 0.4 && $0.rect.midX > lo && $0.rect.midX < hi && $0.id != byDoor?.id }
                .sorted { abs($0.rect.midX - entrance.x) < abs($1.rect.midX - entrance.x) }
                .prefix(2)
                .map(\.name)
            let detail = passed.isEmpty
                ? "Walk along the front of the store."
                : "You'll pass \(list(passed))."
            steps.append(WayStep(id: steps.count, kind: turnedRight ? .turnRight : .turnLeft, short: "Front",
                                 title: "Turn \(turnedRight ? "right" : "left") along the front", detail: detail))
        }

        // 3. Toward the back, up the aisle when there is one on file.
        if target.rect.midY > 0.3 {
            let turned = abs(dx) > 0.1
            let kind: WayStep.Kind = turned ? (turnedRight ? .turnLeft : .turnRight) : .ahead
            let verb = turned ? "Turn \(turnedRight ? "left" : "right")" : "Keep going"
            let title: String
            let short: String
            if let aisle = result.aisleLabel {
                title = "\(verb) up \(aisle)"
                short = aisle
            } else {
                title = target.isWall && target.rect.midY > 0.8 ? "\(verb) toward the back wall" : "\(verb) toward \(department)"
                short = "Back"
            }
            let alongside = others
                .filter { abs($0.rect.midX - target.rect.midX) < 0.15 && $0.rect.midY < target.rect.midY && $0.rect.midY > entrance.y + 0.12 }
                .sorted { $0.rect.midY < $1.rect.midY }
                .prefix(1)
                .map(\.name)
            let detail = alongside.first.map { "Go past \($0)." } ?? "Head into \(department)."
            steps.append(WayStep(id: steps.count, kind: kind, short: short, title: title, detail: detail))
        }

        // 4. Arrive, with only the details the result has.
        var detailParts: [String] = []
        if let section = result.sectionLabel { detailParts.append("\(section).") }
        let near = result.location.neighbors.prefix(2).map { $0.lowercased() }
        if !near.isEmpty { detailParts.append("Look near \(list(Array(near))).") }
        if result.confidence == .low { detailParts.append("If it's not there, ask a team member.") }
        if detailParts.isEmpty { detailParts.append("Look along the shelves in \(department).") }
        steps.append(WayStep(id: steps.count, kind: .arrive, short: "Look",
                             title: "Look in \(department)", detail: detailParts.joined(separator: " ")))
        return steps
    }

    /// Facing the back of the store, x grows to the right.
    private static func side(of x: Double, from entranceX: Double) -> String {
        x < entranceX ? "left" : "right"
    }

    private static func list(_ items: [String]) -> String {
        items.count == 2 ? "\(items[0]) and \(items[1])" : items.joined(separator: ", ")
    }
}
