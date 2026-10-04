import SwiftUI

struct FindView: View {
    let api: AisleAPI
    let location: LocationProviding
    let analytics: AnalyticsTracking

    @Environment(StoreSelection.self) private var storeSelection
    @Environment(HealthMonitor.self) private var health
    @State private var isPickingStore = false
    /// Opens the picker already asking for location ("Find stores near me").
    @State private var pickerStartsWithLocation = false
    /// The user searched before choosing a store; run it once they pick one.
    @State private var searchAfterPicking = false
    @State private var model: FindModel
    @State private var isCorrecting = false
    @State private var layout: StoreLayout?
    @FocusState private var searchFocused: Bool
    @FocusState private var followUpFocused: Bool
    @State private var isTakingPhoto = false
    /// How far the page has scrolled up under the status bar, in points.
    @State private var scrolledUnderStatusBar: CGFloat = 0
    @State private var isShowingStoreMap = false

    init(api: AisleAPI, location: LocationProviding, analytics: AnalyticsTracking, recents: RecentSearches) {
        self.api = api
        self.location = location
        self.analytics = analytics
        _model = State(initialValue: FindModel(api: api, analytics: analytics, recents: recents))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        AisleWordmark()
                            .trackingScrollUnderStatusBar($scrolledUnderStatusBar)

                        CurrentStoreCard(store: storeSelection.current) {
                            isPickingStore = true
                        }

                        if model.phase == .idle {
                            title
                        }
                        // Once there's an answer, the ask bar moves to the bottom for follow-ups.
                        if !isConversing {
                            ItemSearchField(
                                query: $model.query, photo: model.photo, focused: $searchFocused,
                                onSubmit: submitSearch, onClear: { model.clear() },
                                onCamera: openCamera, onRemovePhoto: { model.photo = nil }
                            )
                        }
                        if let store = storeSelection.current {
                            resultSection(store: store)
                        } else {
                            StoreChooserCard(
                                onNearby: { pickStore(startWithLocation: true) },
                                onSearch: { pickStore(startWithLocation: false) }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .animation(.easeInOut(duration: 0.25), value: model.phase)
                    .animation(.easeInOut(duration: 0.25), value: model.turns)
                    .animation(.easeInOut(duration: 0.25), value: model.isReplying)
                }
                .safeAreaInset(edge: .top, spacing: 0) { StatusBarBackdrop(scrolled: scrolledUnderStatusBar) }
                .background(AisleBackground())
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if health.status == .unreachable {
                            ServerStatusNote { Task { await health.check() } }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(.bar)
                        }
                        if isConversing, let store = storeSelection.current {
                            FollowUpBar(
                                text: $model.followUp, photo: model.photo, focused: $followUpFocused,
                                isReplying: model.isReplying,
                                onSend: { sendFollowUp(store: store) },
                                onNewSearch: startNewSearch,
                                onCamera: openCamera, onRemovePhoto: { model.photo = nil }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.86), value: isConversing)
                }
                .onChange(of: model.turns.count) { scrollToEnd(scroller) }
                .onChange(of: model.isReplying) { scrollToEnd(scroller) }
            }
            .cameraOverlay(isPresented: $isTakingPhoto) { photo in model.photo = photo }
            .onReceive(NotificationCenter.default.publisher(for: .aisleOpenCamera)) { _ in openCamera() }
            .plusUpgradeSheet(reason: $model.upgradePrompt)
            .onChange(of: isTakingPhoto) { _, taking in
                // Photo in: open the keyboard in its composer, ready for a note or send.
                guard !taking, model.photo != nil else { return }
                if isConversing { followUpFocused = true } else { searchFocused = true }
            }
            .navigationTitle("Find")
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: storeSelection.current?.id) { model.clear() }
            .task { await refreshSelectedStore() }
            .task(id: storeSelection.current?.id) {
                layout = nil
                guard let id = storeSelection.current?.id else { return }
                layout = try? await api.storeLayout(storeID: id)
            }
            .sheet(isPresented: $isPickingStore) {
                StorePickerView(
                    model: StorePickerModel(api: api, location: location),
                    selected: storeSelection.current,
                    startsWithLocation: pickerStartsWithLocation
                ) { store in
                    storeSelection.select(store)
                    analytics.track(.storeSelected, ["nearby": .bool(store.distanceMiles != nil)])
                    isPickingStore = false
                    if searchAfterPicking {
                        searchAfterPicking = false
                        runSearch(store: store)
                    }
                }
            }
            .onChange(of: isPickingStore) { _, picking in
                if !picking { pickerStartsWithLocation = false }
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimeGreeting()
            (Text("What are you ") + Text("looking for?").foregroundStyle(Theme.accentInk))
                .font(Theme.font(36, .bold, relativeTo: .largeTitle))
                .tracking(-1)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

extension FindView {
    /// Picks up server-side changes (like a new logo) to the saved store. Silent on failure.
    private func refreshSelectedStore() async {
        guard let id = storeSelection.current?.id,
              let fresh = try? await api.store(id: id) else { return }
        storeSelection.refresh(fresh)
    }

    private func pickStore(startWithLocation: Bool) {
        pickerStartsWithLocation = startWithLocation
        isPickingStore = true
    }

    /// Searches the current store, or asks for one first and searches once it's picked.
    private func submitSearch() {
        if let store = storeSelection.current {
            runSearch(store: store)
        } else if !model.trimmedQuery.isEmpty || model.photo != nil {
            searchFocused = false
            searchAfterPicking = true
            pickStore(startWithLocation: false)
        }
    }

    private func runSearch(store: Store) {
        searchFocused = false
        Task { await model.search(storeID: store.id) }
    }

    /// A result is showing, so the screen reads as a conversation with the ask bar at the bottom.
    private var isConversing: Bool {
        storeSelection.current != nil && model.currentResult != nil
    }

    private func sendFollowUp(store: Store) {
        Task { await model.sendFollowUp(storeID: store.id, retailer: store.retailerDisplayName) }
    }

    private func openCamera() {
        searchFocused = false
        followUpFocused = false
        // The overlay slides its own card up, so skip the cover's full-screen slide.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { isTakingPhoto = true }
    }

    /// Back to an empty search at the top.
    private func startNewSearch() {
        followUpFocused = false
        model.clear()
        searchFocused = true
    }

    private func scrollToEnd(_ scroller: ScrollViewProxy) {
        guard isConversing, !model.turns.isEmpty || model.isReplying else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            scroller.scrollTo(Self.conversationEnd, anchor: .bottom)
        }
    }

    private static let conversationEnd = "conversationEnd"

    @ViewBuilder
    private func resultSection(store: Store) -> some View {
        switch model.phase {
        case .idle:
            if model.recents.queries.isEmpty {
                Text("Ask for any item and Aisle will tell you where it usually is in \(store.name).")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                RecentAnswerGrid(recents: model.recents, storeID: store.id) { query in
                    searchFocused = false
                    Task { await model.searchRecent(query, storeID: store.id) }
                }
            }
            if let layout, !layout.placedZones.isEmpty {
                StoreGlanceCard(
                    layout: layout, storeName: store.name, retailer: store.retailerDisplayName,
                    onOpenMap: { isShowingStoreMap = true },
                    onDepartment: { department in
                        // Ask where the department itself is.
                        model.query = department
                        runSearch(store: store)
                    }
                )
                .padding(.top, 8)
                .fullScreenCover(isPresented: $isShowingStoreMap) {
                    StoreGlanceMap(layout: layout, storeName: store.name, logoURL: store.retailerLogoURL)
                }
            }
        case .loading:
            SearchingView(
                query: model.trimmedQuery, photo: model.searchPhoto,
                storeName: store.name, retailer: store.retailerDisplayName
            )
                .transition(.opacity)
        case .loaded(let result):
            QueryBubble(text: result.query.isEmpty ? result.item : result.query, photo: model.searchPhoto)
            AisleReply {
                Text(result.reply(at: store.retailerDisplayName))
            }
            SearchResultCard(result: result, retailer: store.retailerDisplayName, layout: layout)
            if model.latestResult == result {
                feedbackBar(store: store)
            }
            conversation(store: store)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                Button("Try again") { runSearch(store: store) }
                    .buttonStyle(.aisleSoft)
            }
        }
    }
}

extension FindView {
    /// Follow-ups after the result, then Aisle typing, then anything that went wrong. A reply
    /// that found a new item gets that item's card, like a first search.
    @ViewBuilder
    private func conversation(store: Store) -> some View {
        let newestFind = model.turns.last { $0.result != nil }?.id
        ForEach(model.turns) { turn in
            switch turn.role {
            case .shopper:
                QueryBubble(text: turn.text, photo: turn.photo)
                    .padding(.top, 8)
            case .aisle:
                AisleReply {
                    Text(AttributedString.aisleReply(markdown: turn.text) ?? AttributedString(turn.text))
                }
                if let result = turn.result {
                    SearchResultCard(result: result, retailer: store.retailerDisplayName, layout: layout)
                    if turn.id == newestFind {
                        feedbackBar(store: store)
                    }
                }
            }
        }
        if model.isReplying {
            // No "Aisle" header while thinking; the indicator carries the mark itself.
            ReplyingIndicator()
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
        if let error = model.followUpError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.aisleSubheadline)
                .foregroundStyle(Theme.secondaryInk)
        }
        Color.clear.frame(height: 1).id(Self.conversationEnd)
    }

    /// "Was it there?" for the newest result; only one is on screen at a time.
    private func feedbackBar(store: Store) -> some View {
        FeedbackBar(
            state: model.feedback,
            onFound: { Task { await model.confirmFound(storeID: store.id) } },
            onNotHere: { Task { await model.reportNotHere(storeID: store.id) } },
            onCorrect: { isCorrecting = true }
        )
        .sheet(isPresented: $isCorrecting) {
            if let result = model.latestResult {
                CorrectionSheet(api: api, storeID: store.id, item: result.item) { zone, aisle in
                    Task { await model.submitCorrection(storeID: store.id, zone: zone, aisle: aisle) }
                }
            }
        }
    }
}

/// The ask bar once there's an answer: follow up, or start a new search.
private struct FollowUpBar: View {
    @Binding var text: String
    let photo: Data?
    var focused: FocusState<Bool>.Binding
    let isReplying: Bool
    let onSend: () -> Void
    let onNewSearch: () -> Void
    let onCamera: () -> Void
    let onRemovePhoto: () -> Void

    private var canSend: Bool {
        !isReplying && (photo != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        Group {
            if let photo {
                PhotoComposer(
                    photo: photo, text: $text, placeholder: "Ask about this photo", focused: focused,
                    canSend: canSend, onRemovePhoto: onRemovePhoto, onCamera: onCamera, onSend: onSend,
                    onNewSearch: onNewSearch
                )
            } else {
                bar
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [Theme.background.opacity(0), Theme.background.opacity(0.92), Theme.background],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Button(action: onNewSearch) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Theme.surface))
                    .shadow(color: Theme.ink.opacity(0.08), radius: 10, y: 4)
            }
            .accessibilityLabel("New search")
            .accessibilityIdentifier("newSearchButton")

            HStack(spacing: 10) {
                TextField("Ask a follow-up", text: $text, axis: .vertical)
                    .font(.aisleBody)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1...4)
                    .focused(focused)
                    .submitLabel(.send)
                    .onSubmit { if canSend { onSend() } }
                    .accessibilityIdentifier("followUpField")
                CameraButton(action: onCamera)
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 38, height: 38)
                        .background(Theme.accent, in: Circle())
                        .opacity(canSend ? 1 : 0.45)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 25, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).strokeBorder(Theme.accentRing, lineWidth: 1.5))
            .shadow(color: Theme.glow.opacity(0.12), radius: 14, y: 6)
        }
    }
}

/// An ask bar with a photo attached, like a chat composer: the photo large at the top, the
/// message under it, then the camera (and new search) on the left and send on the right.
struct PhotoComposer: View {
    let photo: Data
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    let canSend: Bool
    let onRemovePhoto: () -> Void
    let onCamera: () -> Void
    let onSend: () -> Void
    var onNewSearch: (() -> Void)? = nil

    @Environment(PlusStore.self) private var plus

    /// "3 of 5 free photo searches left today", for free shoppers.
    private var allowance: String? {
        guard !plus.isPlus, let usage = plus.serverStatus?.photoSearch, usage.limit > 0 else { return nil }
        return usage.left == 0
            ? "No free photo searches left today"
            : "\(usage.left) of \(usage.limit) free photo searches left today"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = UIImage(data: photo) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 124, height: 124)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button(action: onRemovePhoto) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .padding(7)
                        .accessibilityLabel("Remove photo")
                    }
                    .accessibilityLabel("Attached photo")
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .font(.aisleBody)
                .foregroundStyle(Theme.ink)
                .lineLimit(1...4)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit { if canSend { onSend() } }
                .accessibilityIdentifier("photoComposerField")
            if let allowance {
                Label(allowance, systemImage: "sparkles")
                    .font(.aisleFootnote)
                    .foregroundStyle(Theme.secondaryInk)
            }
            HStack(spacing: 4) {
                if let onNewSearch {
                    Button(action: onNewSearch) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 38, height: 38)
                    }
                    .accessibilityLabel("New search")
                }
                CameraButton(action: onCamera)
                Spacer()
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 38, height: 38)
                        .background(Theme.accent, in: Circle())
                        .opacity(canSend ? 1 : 0.45)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.accentRing, lineWidth: 1.5))
        .shadow(color: Theme.glow.opacity(0.12), radius: 14, y: 6)
        .task { await plus.refreshUsage() }
    }
}

/// Opens the pop-up camera from an ask bar.
struct CameraButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "camera")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 38)
        }
        .accessibilityLabel("Take a photo")
        .accessibilityIdentifier("cameraButton")
    }
}

/// While Aisle writes a reply: the Aisle mark, shining and breathing, beside a status line
/// with the same light sweep as the search screen.
private struct ReplyingIndicator: View {
    private static let statuses = ["Thinking", "Checking the store", "Writing your answer"]

    @State private var stage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0.6 : timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 10) {
                mark(time: time)
                ZStack(alignment: .leading) {
                    ForEach(Self.statuses.indices, id: \.self) { index in
                        if index == stage {
                            Text(Self.statuses[index])
                                .font(Theme.font(15, .semibold, relativeTo: .subheadline))
                                .foregroundStyle(Theme.secondaryInk)
                                .lineLimit(1)
                                .shimmer(time: time)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 8)),
                                    removal: .opacity.combined(with: .offset(y: -8))
                                ))
                        }
                    }
                }
                .frame(height: 22, alignment: .leading)
                .clipped()
            }
        }
        .task { await pace() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aisle is writing a reply")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The bare Aisle mark, shining and breathing like the logo on the search screen.
    private func mark(time: TimeInterval) -> some View {
        let breathe = reduceMotion ? 1 : 1 + 0.05 * (1 + sin(time * 2 * .pi / 1.8))
        return AisleMark(size: 20)
            .shimmer(time: time)
            .scaleEffect(breathe)
            .frame(width: 24, height: 22)
    }

    private func pace() async {
        for next in Self.statuses.indices.dropFirst() {
            do { try await Task.sleep(for: .milliseconds(1600)) } catch { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { stage = next }
        }
    }
}

struct RecentSearchList: View {
    let recents: RecentSearches
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent")
                    .font(Theme.font(22, .bold, relativeTo: .title2))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button("Clear") { recents.clear() }
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .accessibilityLabel("Clear recent searches")
            }
            VStack(spacing: 0) {
                ForEach(Array(recents.queries.enumerated()), id: \.element) { index, query in
                    Button { onSelect(query) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.secondaryInk)
                                .frame(width: 22)
                            Text(query)
                                .font(.aisleBody)
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Searches again")
                    .contextMenu { Button("Remove", systemImage: "trash", role: .destructive) { recents.remove(query) } }
                    if index < recents.queries.count - 1 {
                        Divider().overlay(Theme.ink.opacity(0.08)).padding(.leading, 50)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .accessibilityIdentifier("recentSearches")
    }
}

struct ItemSearchField: View {
    @Binding var query: String
    var photo: Data? = nil
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onClear: () -> Void
    var onCamera: () -> Void = {}
    var onRemovePhoto: () -> Void = {}

    private var canSubmit: Bool {
        photo != nil || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if let photo {
            PhotoComposer(
                photo: photo, text: $query, placeholder: "Ask about this, or just send", focused: focused,
                canSend: canSubmit, onRemovePhoto: onRemovePhoto, onCamera: onCamera, onSend: onSubmit
            )
        } else {
            bar
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.ink)
            TextField("", text: $query)
                .overlay(alignment: .leading) {
                    if query.isEmpty { RotatingSearchHint() }
                }
                .accessibilityLabel("Ask Aisle")
                .font(.aisleBody)
                .foregroundStyle(Theme.ink)
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("itemSearchField")
            if !query.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondaryInk)
                }
                .accessibilityLabel("Clear search")
            }
            CameraButton(action: onCamera)
            Button(action: onSubmit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: Circle())
            }
            .disabled(!canSubmit)
            .accessibilityLabel("Search")
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(minHeight: 58)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.accentRing, lineWidth: 1.5))
        .shadow(color: Theme.glow.opacity(0.10), radius: 14, y: 8)
    }
}

private struct CurrentStoreCard: View {
    let store: Store?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                RetailerLogo(url: store?.retailerLogoURL, size: 46) {
                    Image(systemName: "storefront")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 46, height: 46)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store == nil ? "No store selected" : "You're shopping at")
                        .font(.aisleCaption)
                        .foregroundStyle(Theme.secondaryInk)
                    HStack(spacing: 4) {
                        Text(store?.name ?? "Choose a store")
                            .font(Theme.font(20, .bold, relativeTo: .title3))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.ink)
                    }
                    if let address = store?.address {
                        Text(address)
                            .font(.aisleFootnote)
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("currentStoreButton")
        .accessibilityHint("Opens the store picker")
    }
}

/// Shown in place of results until a store is chosen: the one thing to do next.
private struct StoreChooserCard: View {
    let onNearby: () -> Void
    let onSearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pick your store")
                    .font(Theme.font(22, .bold, relativeTo: .title2))
                    .foregroundStyle(Theme.ink)
                Text("Aisle learns each store's layout, so it can tell you the aisle, not just “somewhere in the store.”")
                    .font(.aisleSubheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                Button(action: onNearby) {
                    Label("Find stores near me", systemImage: "location.fill")
                }
                .buttonStyle(.aisleAccent)
                .accessibilityIdentifier("findNearbyStoresButton")
                Button("Search by name or address", action: onSearch)
                    .font(.aisleSubheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("searchStoresButton")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A low-key notice when `/health` fails. Never blocks the UI.
private struct ServerStatusNote: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text("Can't reach the Aisle server.")
            Spacer(minLength: 0)
            Button("Retry", action: onRetry)
                .foregroundStyle(Theme.ink)
        }
        .font(.aisleFootnote)
        .foregroundStyle(Theme.secondaryInk)
        .accessibilityIdentifier("serverStatusNote")
    }
}
