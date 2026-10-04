import MapKit
import SwiftUI

/// A store at a glance: name, address and distance, directions, setting it as your
/// store, its floor plan and where each department is.
struct StoreDetailView: View {
    let store: Store
    let layout: StoreLayout?

    @Environment(StoreSelection.self) private var storeSelection
    @State private var showingMap = false

    private var isCurrent: Bool { storeSelection.current?.id == store.id }

    var body: some View {
        MoreScreen(title: nil, trailing: {
            ShareLink(item: "\(store.name), \(store.address)") {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .background(Theme.surface.opacity(0.92), in: Circle())
            }
            .accessibilityLabel("Share store")
        }) {
            header.padding(.top, 18)
            actions.padding(.top, 18)
            if let layout, !layout.placedZones.isEmpty {
                MoreSectionTitle(text: "Floor plan")
                Button { showingMap = true } label: {
                    ZStack(alignment: .bottom) {
                        FloorPlanView(layout: layout, targetZoneID: nil, pinTitle: "", tilt: 1)
                            .frame(height: 210)
                            .allowsHitTesting(false)
                        HStack {
                            Label("Open map", systemImage: "chevron.right")
                                .labelStyle(TrailingIconLabelStyle())
                                .font(Theme.font(12, .bold, relativeTo: .caption))
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(Theme.surface, in: Capsule())
                            Spacer()
                            Text(layout.approximate ? "Typical layout · approximate" : "This store's layout")
                                .font(Theme.font(11, relativeTo: .caption2))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .padding(12)
                    }
                    .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
                }
                .buttonStyle(PressableCardStyle())
                .foregroundStyle(Theme.ink)

                MoreSectionTitle(text: "Departments")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(layout.placedZones) { zone in
                        HStack(spacing: 10) {
                            ItemIconView(text: zone.name, size: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(zone.name)
                                    .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                                    .lineLimit(2)
                                Text(Self.whereIn(zone))
                                    .font(Theme.font(12, relativeTo: .caption))
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingMap) {
            if let layout { StoreGlanceMap(layout: layout, storeName: store.name, logoURL: store.retailerLogoURL) }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            SmallStoreLogo(url: store.retailerLogoURL, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.name)
                    .font(Theme.font(26, .bold, relativeTo: .title))
                    .tracking(-0.8)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Text([store.address, store.distanceMiles.map { StoreRow.format(miles: $0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.font(14, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(2)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            action("Directions", systemImage: "location.fill") {
                let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: store.latitude, longitude: store.longitude)))
                item.name = store.name
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
            }
            Button {
                storeSelection.select(store)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: isCurrent ? "checkmark" : "storefront").font(.system(size: 18, weight: .semibold))
                    Text(isCurrent ? "My store" : "Shop here").font(Theme.font(12, .bold, relativeTo: .caption))
                }
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Theme.glow.opacity(0.2), radius: 11, y: 8)
            }
            .buttonStyle(PressableCardStyle())
            .disabled(isCurrent)
            .sensoryFeedback(.success, trigger: isCurrent)
        }
    }

    private func action(_ title: String, systemImage: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 18, weight: .semibold))
                Text(title).font(Theme.font(12, .bold, relativeTo: .caption))
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Theme.ink.opacity(0.06), radius: 12, y: 6)
        }
        .buttonStyle(PressableCardStyle())
    }

    /// "Back wall", "Front left"… from the zone's spot on the floor plan.
    static func whereIn(_ zone: StoreLayout.Zone) -> String {
        guard let p = zone.point else { return "In the store" }
        if p.y > 0.8 { return p.x < 0.33 ? "Back left" : p.x > 0.67 ? "Back right" : "Back wall" }
        if p.y < 0.2 { return p.x < 0.33 ? "Front left" : p.x > 0.67 ? "Front right" : "Front" }
        if p.x < 0.15 { return "Left wall" }
        if p.x > 0.85 { return "Right wall" }
        return "Middle aisles"
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon }
    }
}
