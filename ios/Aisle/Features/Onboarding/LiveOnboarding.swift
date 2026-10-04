import SwiftUI

/// First launch, as a short interactive story: the logo assembles, Aisle answers a
/// question on its own, the shopper asks one, then learns the confidence levels and
/// taps "Found it". Then lists: one sorts itself, the shopper builds one, a paper list
/// is photographed and read, and the list becomes a walk. Last, they pick a store and
/// make an account, which Aisle requires.
/// "Skip" skips the tour, not the account.
struct LiveOnboarding: View {
    enum Step: Int, CaseIterable {
        case intro, demo, tryIt, confidence, found
        case listDemo, listTry, listPhoto, listRoute
        case location, done
    }

    let api: AisleAPI
    let location: LocationProviding
    let onCreateAccount: () -> Void
    let onSignIn: () -> Void
    let onFinish: () -> Void

    @State private var step: Step = .intro
    @State private var chosenStore: Store?
    /// The list made in the list steps. Practice only: it isn't saved to the real list.
    @State private var practiceList: [ListItem] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LiveBackground()
            VStack(spacing: 0) {
                if step != .intro {
                    ProgressHeader(current: step.rawValue, total: Step.allCases.count - 1,
                                   showsSkip: step != .done, onSkip: onFinish)
                        .transition(.opacity)
                }
                stage
                    .id(step)
                    .transition(stageTransition)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.aisleBody)
        .foregroundStyle(Theme.ink)
    }

    @ViewBuilder
    private var stage: some View {
        switch step {
        case .intro:
            IntroStage(onNext: { go(.demo) }, onSignIn: onSignIn)
        case .demo:
            DemoStage { go(.tryIt) }
        case .tryIt:
            TryStage(api: api) { go(.confidence) }
        case .confidence:
            ConfidenceStage { go(.found) }
        case .found:
            FoundStage { go(.listDemo) }
        case .listDemo:
            ListDemoStage { go(.listTry) }
        case .listTry:
            ListTryStage(api: api, items: $practiceList) { go(.listPhoto) }
        case .listPhoto:
            ListPhotoStage { go(.listRoute) }
        case .listRoute:
            ListRouteStage(items: practiceList) { go(.location) }
        case .location:
            LocationStage(api: api, location: location, onPicked: { store in
                chosenStore = store
                go(.done)
            }, onLater: { go(.done) })
        case .done:
            DoneStage(store: chosenStore, onCreateAccount: onCreateAccount, onSignIn: onSignIn, onFinish: onFinish)
        }
    }

    private var stageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: 40)),
                removal: .opacity.combined(with: .offset(x: -40))
            )
    }

    private func go(_ next: Step) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.88)) {
            step = next
        }
    }
}

// MARK: - Shared pieces

/// One gradient segment per step, and a Skip button.
private struct ProgressHeader: View {
    let current: Int
    let total: Int
    let showsSkip: Bool
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            AisleMark(size: 26)
            HStack(spacing: 5) {
                ForEach(1...total, id: \.self) { index in
                    Capsule()
                        .fill(index <= current ? AnyShapeStyle(Theme.accentInk) : AnyShapeStyle(Theme.hairline))
                        .frame(height: 5)
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: current)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(current) of \(total)")
            Button("Skip", action: onSkip)
                .font(Theme.font(15, .medium, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
                .frame(minWidth: 44, minHeight: 44)
                .opacity(showsSkip ? 1 : 0)
                .disabled(!showsSkip)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }
}

/// The page background with two soft glows that drift slowly.
private struct LiveBackground: View {
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AisleBackground()
            Circle()
                .fill(Theme.glow.opacity(0.16))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(x: drift ? 120 : 60, y: drift ? -300 : -240)
            Circle()
                .fill(Color(hex: 0xFFD872).opacity(0.16))
                .frame(width: 300, height: 300)
                .blur(radius: 70)
                .offset(x: drift ? -110 : -150, y: drift ? 300 : 340)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

/// Fades a view in while it rises a little, after `delay` seconds.
private struct Rise: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 18)
            .onAppear {
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.6, dampingFraction: 0.85).delay(delay)
                withAnimation(animation) { shown = true }
            }
    }
}

private extension View {
    func rise(_ delay: Double = 0) -> some View { modifier(Rise(delay: delay)) }
}

/// Title, body text, flexible content and pinned buttons.
private struct Stage<Content: View, Footer: View>: View {
    let lead: String
    let accent: String
    let message: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    GradientHeadline(lead: lead, accent: accent, size: 34)
                        .rise(0.05)
                    OnboardingBody(text: message)
                        .padding(.top, 10)
                        .rise(0.12)
                    content()
                        .padding(.top, 26)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 10) { footer() }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
    }
}

/// Sleeps unless the task was cancelled; returns false when it was.
private func pause(_ milliseconds: Int) async -> Bool {
    do {
        try await Task.sleep(for: .milliseconds(milliseconds))
        return true
    } catch {
        return false
    }
}

/// Builds a result for the demo cards. Department-level only; aisle numbers appear
/// only in the clearly scripted demo.
private func sampleResult(
    _ item: String, department: String?, aisle: String? = nil, section: String? = nil,
    neighbors: [String] = [], confidence: Confidence
) -> ItemSearchResult {
    ItemSearchResult(
        searchID: nil, query: item, item: item, modifiers: [], quantity: nil, storeID: nil,
        concept: nil, category: nil,
        location: ItemLocation(department: department, zoneID: nil, aisle: aisle, section: section, neighbors: neighbors),
        availability: .likely, confidence: confidence, source: .fallback, reports: nil
    )
}

// MARK: - 1. Intro: the logo assembles

private struct IntroStage: View {
    let onNext: () -> Void
    let onSignIn: () -> Void

    @State private var assembled = false
    @State private var bloom = false
    @State private var letters = 0
    @State private var showRest = false
    @State private var thump = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let logoSize: CGFloat = 140
    private let word = Array("aisle")

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.glow.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 170))
                    .frame(width: 340, height: 340)
                    .scaleEffect(bloom ? 1 : 0.3)
                    .opacity(bloom ? 1 : 0)
                // The walls swing in as if you'd stepped into the aisle, then follow the phone's tilt.
                WalkInLogo(size: logoSize, walkedIn: assembled)
            }
            .frame(height: 180)
            .accessibilityHidden(true)

            HStack(spacing: 0) {
                ForEach(Array(word.enumerated()), id: \.offset) { index, letter in
                    Text(String(letter))
                        .opacity(letters > index ? 1 : 0)
                        .offset(y: letters > index ? 0 : 10)
                }
            }
            .font(Theme.font(26, .bold, relativeTo: .title))
            .tracking(-0.8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Aisle")

            VStack(spacing: 14) {
                GradientHeadline(lead: "Find anything,\n", accent: "in any store.", size: 40, flowing: true)
                    .multilineTextAlignment(.center)
                Text("Ask for an item the way you'd say it. Aisle points you to the right spot, and tells you how sure it is.")
                    .font(Theme.font(17, relativeTo: .body))
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .opacity(showRest ? 1 : 0)
            .offset(y: showRest || reduceMotion ? 0 : 16)

            Spacer(minLength: 24)

            VStack(spacing: 12) {
                Button("Show me", action: onNext)
                    .buttonStyle(.aisleAccent)
                Button(action: onSignIn) {
                    (Text("Already have an account? ").foregroundStyle(Theme.secondaryInk)
                        + Text("Sign in").fontWeight(.semibold).foregroundStyle(Theme.ink))
                        .font(Theme.font(14, relativeTo: .subheadline))
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .opacity(showRest ? 1 : 0)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: thump)
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            assembled = true; bloom = true; letters = word.count; showRest = true
            return
        }
        guard await pause(250) else { return }
        withAnimation(.spring(response: 0.7, dampingFraction: 0.72)) { assembled = true }
        // Let the walk-in mostly land before the glow, haptic and letters.
        guard await pause(1500) else { return }
        thump.toggle()
        withAnimation(.easeOut(duration: 0.8)) { bloom = true }
        for index in 1...word.count {
            guard await pause(70) else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { letters = index }
        }
        guard await pause(200) else { return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { showRest = true }
    }
}

// MARK: - 2. Demo: Aisle answers on its own

private struct DemoStage: View {
    let onNext: () -> Void

    private static let question = "where is maple syrup?"
    private static let reply = "Found it! With the breakfast syrups, halfway down on your left."

    @State private var typed = ""
    @State private var sent = false
    @State private var showCard = false
    @State private var aisleNumber = 1
    @State private var revealed = 0
    @State private var finished = false
    @State private var run = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var words: [String] { Self.reply.split(separator: " ").map(String.init) }

    var body: some View {
        Stage(lead: "Just ask, ", accent: "like you'd ask a person.", message: "Watch. Aisle reads the question, finds the spot and says it plainly.") {
            VStack(alignment: .leading, spacing: 14) {
                fakeField
                if sent {
                    QueryBubble(text: Self.question)
                        .transition(.scale(scale: 0.9, anchor: .trailing).combined(with: .opacity))
                }
                if showCard {
                    AisleReply {
                        HStack(alignment: .center, spacing: 14) {
                            answerCard
                            streamedReply
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .padding(18)
            .background(Theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Theme.ink.opacity(0.06), radius: 18, y: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Example: you ask where is maple syrup. Aisle answers: Aisle 7. \(Self.reply)")
        } footer: {
            if finished {
                Button("Now you try", action: onNext)
                    .buttonStyle(.aisleAccent)
                    .transition(.opacity.combined(with: .offset(y: 10)))
                Button("Watch again") { run += 1 }
                    .font(Theme.font(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(minHeight: 44)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: showCard)
        .task(id: run) { await play() }
    }

    private var fakeField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
            Text(typed.isEmpty ? "What are you looking for?" : typed)
                .foregroundStyle(typed.isEmpty ? Theme.secondaryInk : Theme.ink)
                .lineLimit(1)
            if !sent && !typed.isEmpty {
                Capsule().fill(Theme.accentInk).frame(width: 2, height: 18)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.font(16, relativeTo: .body))
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accentRing, lineWidth: 1.5))
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Aisle")
                .font(Theme.font(11, .semibold, relativeTo: .caption))
            Text("\(aisleNumber)")
                .font(Theme.font(32, .bold, relativeTo: .largeTitle))
                .tracking(-1)
                .contentTransition(.numericText(value: Double(aisleNumber)))
        }
        .foregroundStyle(Theme.onAccent)
        .frame(width: 88, height: 76, alignment: .leading)
        .padding(.leading, 12)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var streamedReply: some View {
        words.enumerated().reduce(Text("")) { text, pair in
            text + Text(pair.element + " ").foregroundStyle(pair.offset < revealed ? Theme.ink : Color.clear)
        }
        .font(Theme.font(15, relativeTo: .callout))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func play() async {
        typed = ""; sent = false; showCard = false; aisleNumber = 1; revealed = 0; finished = false
        if reduceMotion {
            typed = Self.question; sent = true; showCard = true; aisleNumber = 7; revealed = words.count
            finished = true
            return
        }
        guard await pause(500) else { return }
        for character in Self.question {
            typed.append(character)
            guard await pause(55) else { return }
        }
        guard await pause(250) else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { sent = true; typed = "" }
        guard await pause(450) else { return }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.8)) { showCard = true }
        for number in 2...7 {
            guard await pause(70) else { return }
            withAnimation(.snappy) { aisleNumber = number }
        }
        for index in 1...words.count {
            guard await pause(80) else { return }
            withAnimation(.easeOut(duration: 0.2)) { revealed = index }
        }
        guard await pause(300) else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { finished = true }
    }
}

// MARK: - 3. Try it: a real question

private struct TryStage: View {
    let api: AisleAPI
    let onNext: () -> Void

    enum Phase: Equatable {
        case idle
        case thinking(String)
        case answered(ItemSearchResult, offline: Bool)
    }

    private static let chips = ["paper towels", "birthday candles", "oat milk"]

    @State private var query = ""
    @State private var phase: Phase = .idle
    @State private var answered = false
    @FocusState private var focused: Bool

    var body: some View {
        Stage(lead: "Your turn. ", accent: "Ask for anything.", message: "Type it, or tap one of these.") {
            VStack(alignment: .leading, spacing: 16) {
                field
                if case .idle = phase {
                    HStack(spacing: 8) {
                        ForEach(Array(Self.chips.enumerated()), id: \.element) { index, chip in
                            Button(chip) { ask(chip) }
                                .font(Theme.font(14, .medium, relativeTo: .subheadline))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 40)
                                .background(Theme.surface, in: Capsule())
                                .rise(0.2 + Double(index) * 0.07)
                        }
                    }
                }
                switch phase {
                case .idle:
                    EmptyView()
                case .thinking(let text):
                    QueryBubble(text: text)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    ThinkingDots()
                        .transition(.opacity)
                case .answered(let result, let offline):
                    QueryBubble(text: result.query)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    AisleReply { Text(result.replyText(at: nil)) }
                        .transition(.opacity.combined(with: .offset(y: 10)))
                    ConfidenceHero(result: result)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                    if offline {
                        AisleNote(text: "You're offline, so this is a sample answer. Real answers come from the store's map.", systemImage: "wifi.slash")
                    }
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: phase)
        } footer: {
            if case .answered = phase {
                Button("Nice. What else?", action: onNext)
                    .buttonStyle(.aisleAccent)
                Button("Ask something else") {
                    withAnimation { phase = .idle; query = "" }
                    focused = true
                }
                .font(Theme.font(15, .medium, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
                .frame(minHeight: 44)
            }
        }
        .sensoryFeedback(.success, trigger: answered)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityHidden(true)
            TextField("Where is…", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { ask(query) }
                .textInputAutocapitalization(.never)
            Button {
                ask(query)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Theme.accent, in: Circle())
            }
            .accessibilityLabel("Ask")
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .font(Theme.font(17, relativeTo: .body))
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 52)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accentRing, lineWidth: 1.5))
        .shadow(color: Theme.glow.opacity(0.10), radius: 14, y: 8)
    }

    private func ask(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        focused = false
        query = text
        phase = .thinking(text)
        Task { @MainActor in
            let started = Date()
            var result: ItemSearchResult
            var offline = false
            do {
                result = try await api.searchItem(query: text, storeID: nil)
            } catch {
                result = Self.offlineAnswer(for: text)
                offline = true
            }
            // Give the dots a moment so the answer feels considered, not instant.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.9 { _ = await pause(Int((0.9 - elapsed) * 1000)) }
            guard case .thinking(let pending) = phase, pending == text else { return }
            phase = .answered(result, offline: offline)
            answered.toggle()
        }
    }

    /// Low-confidence stand-in when the server can't be reached. Never names an aisle.
    private static func offlineAnswer(for text: String) -> ItemSearchResult {
        let department: String?
        switch text.lowercased() {
        case "paper towels": department = "Household paper"
        case "birthday candles": department = "Baking"
        case "oat milk": department = "Dairy & plant milk"
        default: department = nil
        }
        return sampleResult(text, department: department, confidence: .low)
    }
}

/// Aisle logo with three pulsing dots while a question is answered.
private struct ThinkingDots: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            AisleMark(size: 16)
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Theme.accentInk)
                        .frame(width: 7, height: 7)
                        .scaleEffect(on ? 1 : 0.5)
                        .opacity(on ? 1 : 0.35)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.15),
                            value: on
                        )
                }
            }
        }
        .onAppear { on = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aisle is looking")
    }
}

// MARK: - 4. Confidence: slide through the three levels

private struct ConfidenceStage: View {
    let onNext: () -> Void

    @State private var value: Double = 3

    private var level: Confidence {
        switch Int(value.rounded()) {
        case 3: return .high
        case 2: return .medium
        default: return .low
        }
    }

    private var sample: ItemSearchResult {
        switch level {
        case .high:
            return sampleResult("maple syrup", department: "Breakfast", aisle: "7", section: "Syrups",
                                neighbors: ["Pancake mix"], confidence: .high)
        case .medium:
            return sampleResult("oat milk", department: "Dairy & plant milk", neighbors: ["Almond milk"], confidence: .medium)
        case .low:
            return sampleResult("birthday candles", department: "Baking", neighbors: ["Cake mix"], confidence: .low)
        }
    }

    private var explanation: String {
        switch level {
        case .high: return "Confident: shoppers or the store's own map confirm this exact spot."
        case .medium: return "Likely here: we know the section, not the exact shelf."
        case .low: return "Best guess: based on similar stores. We'll say so, and suggest who to ask."
        }
    }

    var body: some View {
        Stage(lead: "Honest answers, ", accent: "always.", message: "The card changes with how sure Aisle is. Slide to see.") {
            VStack(alignment: .leading, spacing: 18) {
                ConfidenceHero(result: sample)
                    .id(level)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .rise(0.2)
                Text(explanation)
                    .font(Theme.font(15, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                VStack(spacing: 6) {
                    Slider(value: $value, in: 1...3, step: 1)
                        .tint(Theme.glow)
                        .accessibilityLabel("Confidence")
                        .accessibilityValue(level.label)
                    HStack {
                        Text("Best guess"); Spacer(); Text("Likely"); Spacer(); Text("Confident")
                    }
                    .font(Theme.font(12, .medium, relativeTo: .caption))
                    .foregroundStyle(Theme.secondaryInk)
                    .accessibilityHidden(true)
                }
                .rise(0.3)
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: level)
        } footer: {
            Button("Got it", action: onNext)
                .buttonStyle(.aisleAccent)
        }
        .sensoryFeedback(.selection, trigger: level)
    }
}

// MARK: - 5. Found it: the shopper makes Aisle smarter

private struct FoundStage: View {
    let onNext: () -> Void

    @State private var found = false
    @State private var burst = false

    private var sample: ItemSearchResult {
        sampleResult("oat milk", department: "Dairy & plant milk", aisle: found ? "12" : nil,
                     neighbors: ["Almond milk"], confidence: found ? .high : .medium)
    }

    var body: some View {
        Stage(lead: "Spot it? ", accent: "Tell us.", message: "Tap Found it when you find the item. Every tap makes Aisle more sure for the next shopper.") {
            VStack(alignment: .leading, spacing: 18) {
                ConfidenceHero(result: sample)
                    .id(found)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .rise(0.2)
                ZStack {
                    Burst(fired: burst)
                    Button {
                        guard !found else { return }
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { found = true }
                        withAnimation(.easeOut(duration: 0.8)) { burst = true }
                    } label: {
                        Label(found ? "Thanks! Marked as found" : "Found it", systemImage: found ? "checkmark" : "mappin.and.ellipse")
                    }
                    .buttonStyle(.aisleAccent)
                }
                .rise(0.3)
                if found {
                    Text("That's how a guess becomes a confident answer.")
                        .font(Theme.font(15, relativeTo: .subheadline))
                        .foregroundStyle(Theme.secondaryInk)
                        .transition(.opacity)
                }
            }
        } footer: {
            if found {
                Button("Continue", action: onNext)
                    .buttonStyle(.aisleSoft)
                    .transition(.opacity)
            }
        }
        .sensoryFeedback(.success, trigger: found)
    }
}

/// A ring of gradient dots that flies outward once.
private struct Burst: View {
    let fired: Bool
    private let count = 14

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                let angle = Double(index) / Double(count) * 2 * .pi
                let distance: CGFloat = fired ? (index.isMultiple(of: 2) ? 110 : 80) : 0
                Circle()
                    .fill(Theme.accentColors[index % Theme.accentColors.count].opacity(0.9))
                    .overlay(Circle().strokeBorder(Theme.glow.opacity(0.4), lineWidth: 1))
                    .frame(width: index.isMultiple(of: 3) ? 10 : 7)
                    .offset(x: cos(angle) * distance, y: sin(angle) * distance * 0.55)
                    .opacity(fired ? 0 : 1)
                    .scaleEffect(fired ? 1 : 0.2)
            }
        }
        .opacity(fired ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 6. Location: pick the store you're in

private struct LocationStage: View {
    let api: AisleAPI
    let location: LocationProviding
    let onPicked: (Store) -> Void
    let onLater: () -> Void

    @Environment(StoreSelection.self) private var storeSelection
    @State private var picker: StorePickerModel?
    @State private var dropped = false
    @State private var asking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Stage(lead: "Which store ", accent: "are you in?", message: "Aisle works best when it knows the store. Your location is only used to find stores near you.") {
            VStack(alignment: .leading, spacing: 18) {
                pin
                    .frame(maxWidth: .infinity)
                storeList
            }
        } footer: {
            if !hasStores {
                Button {
                    Task { await askForLocation() }
                } label: {
                    if asking { ProgressView().tint(Theme.onAccent) } else { Text("Use my location") }
                }
                .buttonStyle(.aisleAccent)
                .disabled(asking || picker?.isLocationBlocked == true)
            }
            Button(hasStores ? "My store isn't here" : "Not now", action: onLater)
                .font(Theme.font(15, .medium, relativeTo: .subheadline))
                .foregroundStyle(Theme.secondaryInk)
                .frame(minHeight: 44)
        }
        .task {
            if picker == nil { picker = StorePickerModel(api: api, location: location) }
            await picker?.start()
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.55).delay(0.25)) {
                dropped = true
            }
        }
    }

    private var pin: some View {
        ZStack {
            Ellipse()
                .fill(Theme.ink.opacity(0.08))
                .frame(width: dropped ? 46 : 12, height: 10)
                .offset(y: 46)
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 64, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.onAccent, Theme.accent)
                .offset(y: dropped ? 0 : -160)
                .opacity(dropped ? 1 : 0)
        }
        .frame(height: 110)
        .accessibilityHidden(true)
    }

    private var stores: [Store] {
        if case .loaded(let stores) = picker?.nearby { return Array(stores.prefix(4)) }
        return []
    }

    private var hasStores: Bool { !stores.isEmpty }

    @ViewBuilder
    private var storeList: some View {
        switch picker?.nearby {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Finding stores near you…").foregroundStyle(Theme.secondaryInk)
            }
            .font(Theme.font(15, relativeTo: .subheadline))
        case .failed(let message):
            AisleNote(text: message, systemImage: "exclamationmark.triangle")
        case .loaded(let all) where all.isEmpty:
            AisleNote(text: "No stores nearby yet. You can search for one in the app.", systemImage: "mappin.slash")
        default:
            if picker?.isLocationBlocked == true {
                AisleNote(text: "Location is off for Aisle. You can turn it on in Settings, or search for a store later.", systemImage: "location.slash")
            }
        }

        if hasStores {
            VStack(spacing: 10) {
                ForEach(Array(stores.enumerated()), id: \.element.id) { index, store in
                    Button {
                        storeSelection.select(store)
                        onPicked(store)
                    } label: {
                        HStack(spacing: 12) {
                            RetailerLogo(url: store.retailerLogoURL, size: 40) {
                                Image(systemName: "storefront")
                                    .font(.system(size: 17, weight: .semibold))
                                    .frame(width: 40, height: 40)
                                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.name)
                                    .font(Theme.font(16, .semibold, relativeTo: .body))
                                    .lineLimit(1)
                                Text(store.address)
                                    .font(Theme.font(13, relativeTo: .footnote))
                                    .foregroundStyle(Theme.secondaryInk)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if let miles = store.distanceMiles {
                                Text(StoreRow.format(miles: miles))
                                    .font(Theme.font(13, .medium, relativeTo: .footnote))
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .rise(Double(index) * 0.08)
                }
            }
        }
    }

    private func askForLocation() async {
        guard let picker else { return }
        asking = true
        await picker.requestLocationAndLoadNearby()
        asking = false
    }
}

// MARK: - 7. Done: make an account

private struct DoneStage: View {
    let store: Store?
    let onCreateAccount: () -> Void
    let onSignIn: () -> Void
    /// Only when already signed in (replaying the intro from You).
    let onFinish: () -> Void

    @Environment(AccountStore.self) private var accounts
    @State private var burst = false
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ZStack {
                Burst(fired: burst)
                AisleMark(size: 96)
                    .scaleEffect(landed ? 1 : 0.6)
                    .opacity(landed ? 1 : 0)
            }
            .frame(height: 200)

            VStack(spacing: 12) {
                GradientHeadline(
                    lead: "You're all set",
                    accent: store.map { " at \($0.retailerDisplayName)." } ?? ".",
                    size: 36
                )
                .multilineTextAlignment(.center)
                Text(accounts.isSignedIn
                     ? "That's the tour. Happy shopping."
                     : "Last step: make your free account. Then you're ready to shop.")
                    .font(Theme.font(17, relativeTo: .body))
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .rise(0.25)

            Spacer(minLength: 24)

            VStack(spacing: 10) {
                if accounts.isSignedIn {
                    Button("Start shopping", action: onFinish)
                        .buttonStyle(.aisleAccent)
                } else {
                    Button("Create free account", action: onCreateAccount)
                        .buttonStyle(.aisleAccent)
                    Button("I already have an account", action: onSignIn)
                        .buttonStyle(.aisleSoft)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            .rise(0.4)
        }
        .sensoryFeedback(.success, trigger: landed)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.6)) { landed = true }
            if !reduceMotion {
                withAnimation(.easeOut(duration: 0.9).delay(0.15)) { burst = true }
            }
        }
    }
}

// MARK: - Lists: shared logic

/// The practice list's logic, kept apart from the views so it can be tested.
enum PracticeList {
    struct Department: Identifiable, Equatable {
        let name: String
        var items: [ListItem]
        var id: String { name }
    }

    /// Items grouped by department the way the List tab groups them: in the order they
    /// were added, with "Other" last.
    static func departments(_ items: [ListItem]) -> [Department] {
        var groups: [Department] = []
        for item in items {
            let name = item.categoryName?.trimmingCharacters(in: .whitespaces) ?? ""
            let department = name.isEmpty ? "Other" : name
            if let index = groups.firstIndex(where: { $0.name == department }) {
                groups[index].items.append(item)
            } else {
                groups.append(Department(name: department, items: [item]))
            }
        }
        return groups.filter { $0.name != "Other" } + groups.filter { $0.name == "Other" }
    }

    /// List items for parsed text, skipping any already on the list or repeated in the text.
    static func newItems(from parsed: [ParsedListItem], existing: [ListItem]) -> [ListItem] {
        var seen = Set(existing.map { $0.text.lowercased() })
        return parsed.compactMap { item in
            guard seen.insert(item.text.lowercased()).inserted else { return nil }
            return ListItem(text: item.text, quantity: item.quantity, categoryName: item.category?.name)
        }
    }

    /// A typical store's walk, for before a store is picked: fresh food first, then the
    /// middle aisles, then frozen and dairy so they stay cold. Names match the server's.
    static let typicalWalk = [
        "Flowers & Plants", "Fruit", "Vegetables", "Bread & Bakery", "Deli & Prepared Foods",
        "Meat & Poultry", "Seafood", "Cereal & Breakfast", "Coffee & Tea", "Syrups & Sweeteners",
        "Peanut Butter & Spreads", "Baking", "Spices & Seasonings", "Oils & Vinegar",
        "Condiments & Dressings", "Pasta & Sauce", "Rice, Grains & Beans", "Canned Goods & Soup",
        "International Foods", "Chips & Snacks", "Nuts & Dried Fruit", "Cookies & Candy", "Drinks",
        "Beer & Wine", "Paper Goods", "Cleaning & Laundry", "Pet Supplies", "Baby", "Oral Care",
        "Hair Care", "Bath & Body", "Beauty & Cosmetics", "Medicine & First Aid",
        "Vitamins & Supplements", "Frozen Foods", "Ice Cream & Frozen Desserts",
        "Milk & Dairy", "Eggs", "Cheese",
    ]

    /// Departments in walking order. Ones the typical walk doesn't know come after the
    /// known ones, in their own order; "Other" stays last.
    static func walkingOrder(_ departments: [Department]) -> [Department] {
        func rank(_ name: String) -> Int {
            if name == "Other" { return typicalWalk.count + 1 }
            return typicalWalk.firstIndex(of: name) ?? typicalWalk.count
        }
        return departments.enumerated()
            .sorted { (rank($0.element.name), $0.offset) < (rank($1.element.name), $1.offset) }
            .map(\.element)
    }
}

// MARK: - Lists: shared pieces

/// The List tab's add-bar outline: white capsule, gradient ring, soft glow.
private struct ComposerChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.leading, 18)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .frame(minHeight: 58)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 29, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 29, style: .continuous).strokeBorder(Theme.accentRing, lineWidth: 1.5))
            .shadow(color: Theme.glow.opacity(0.10), radius: 14, y: 8)
    }
}

/// The List tab's add bar, drawn for the scripted steps, showing `text` as if being typed.
private struct ComposerPreview: View {
    var text = ""
    var showsCaret = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
            Group {
                if text.isEmpty {
                    Text("Add items, like milk, eggs, bread")
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                } else {
                    Text(text) + Text(showsCaret ? "|" : "").foregroundStyle(Color(hex: 0xDC6F9C))
                }
            }
            .font(.aisleBody)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            Image(systemName: "camera")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 38)
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 44, height: 44)
                .background(Theme.accent, in: Circle())
                .opacity(text.isEmpty ? 0.5 : 1)
        }
        .foregroundStyle(Theme.ink)
        .modifier(ComposerChrome())
    }
}

/// A department heading (picture, name, count) over a white card of rows, like the List tab.
private struct PracticeSection<Rows: View>: View {
    let name: String
    let count: Int
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DepartmentIconView(department: name, size: 18)
                Text(name.uppercased()).fontWeight(.bold)
                Text("· \(count)")
            }
            .font(Theme.font(13, .medium, relativeTo: .footnote))
            .tracking(0.3)
            .foregroundStyle(Theme.secondaryInk)
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { rows() }
                .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
        }
    }
}

private struct PracticeDivider: View {
    var body: some View {
        Divider().overlay(Theme.hairline).padding(.leading, 54)
    }
}

/// One list row: a check circle, the item and its quantity. With handlers, the circle
/// checks the item off and an × removes it; without, it's a picture of a row.
private struct PracticeRow: View {
    let item: ListItem
    var onToggle: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if let onToggle {
                Button(action: onToggle) { check }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.isDone ? "Mark \(item.text) as not done" : "Mark \(item.text) as done")
            } else {
                check
            }
            Text(item.text)
                .font(Theme.font(17, relativeTo: .body))
                .strikethrough(item.isDone, color: Color(hex: 0xDC6F9C).opacity(0.7))
                .foregroundStyle(item.isDone ? Theme.secondaryInk : Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let quantity = item.quantity, !quantity.isEmpty {
                Text(quantity)
                    .font(Theme.font(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 9)
                    .frame(minWidth: 28, minHeight: 26)
                    .background(Theme.fill, in: Capsule())
                    .accessibilityLabel("Quantity \(quantity)")
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondaryInk.opacity(0.7))
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(item.text)")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(minHeight: onToggle == nil ? 46 : 56)
    }

    /// The List tab's check: an empty ring, or the gradient with a tick.
    private var check: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.secondaryInk.opacity(0.45), lineWidth: 2)
                .opacity(item.isDone ? 0 : 1)
            Circle()
                .fill(Theme.accent)
                .scaleEffect(item.isDone ? 1.05 : 0.3)
                .opacity(item.isDone ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Theme.onAccent)
                .scaleEffect(item.isDone ? 1 : 0.4)
                .opacity(item.isDone ? 1 : 0)
        }
        .frame(width: 26, height: 26)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
}

/// Departments of rows, each section and row easing in as it appears.
private struct PracticeDepartments: View {
    let items: [ListItem]
    var onToggle: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?

    var body: some View {
        ForEach(PracticeList.departments(items)) { department in
            PracticeSection(name: department.name, count: department.items.count) {
                ForEach(Array(department.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { PracticeDivider() }
                    PracticeRow(
                        item: item,
                        onToggle: onToggle.map { toggle in { () -> Void in toggle(item.id) } },
                        onRemove: onRemove.map { remove in { () -> Void in remove(item.id) } }
                    )
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .transition(.opacity.combined(with: .offset(y: 14)))
        }
    }
}

/// "Watch again" under a scripted step.
private struct WatchAgainButton: View {
    let action: () -> Void

    var body: some View {
        Button("Watch again", action: action)
            .font(Theme.font(15, .medium, relativeTo: .subheadline))
            .foregroundStyle(Theme.secondaryInk)
            .frame(minHeight: 44)
    }
}

// MARK: - 6. Lists: a whole list sorts itself

private struct ListDemoStage: View {
    let onNext: () -> Void

    private static let typedList = "bananas, milk, bread, apples, yogurt"
    private static let items = [
        ListItem(text: "bananas", categoryName: "Fruit"),
        ListItem(text: "milk", categoryName: "Milk & Dairy"),
        ListItem(text: "bread", categoryName: "Bread & Bakery"),
        ListItem(text: "apples", categoryName: "Fruit"),
        ListItem(text: "yogurt", categoryName: "Milk & Dairy"),
    ]

    @State private var typed = ""
    @State private var revealed = 0
    @State private var finished = false
    @State private var run = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Stage(lead: "Got a list? ", accent: "Paste the whole thing.", message: "Watch. Aisle splits it into items and sorts them by department.") {
            VStack(alignment: .leading, spacing: 18) {
                ComposerPreview(text: typed, showsCaret: !typed.isEmpty)
                PracticeDepartments(items: Array(Self.items.prefix(revealed)))
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: revealed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Example: you paste bananas, milk, bread, apples and yogurt. Aisle sorts them into Fruit, Milk and Dairy, and Bread and Bakery.")
        } footer: {
            if finished {
                Button("Now you try", action: onNext)
                    .buttonStyle(.aisleAccent)
                    .transition(.opacity.combined(with: .offset(y: 10)))
                WatchAgainButton { run += 1 }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: revealed)
        .task(id: run) { await play() }
    }

    private func play() async {
        typed = ""; revealed = 0; finished = false
        if reduceMotion {
            revealed = Self.items.count; finished = true
            return
        }
        guard await pause(600) else { return }
        for character in Self.typedList {
            typed.append(character)
            guard await pause(45) else { return }
        }
        guard await pause(350) else { return }
        typed = ""
        guard await pause(250) else { return }
        // Items land one by one, each joining its department, so "apples" jumps up beside "bananas".
        for index in 1...Self.items.count {
            revealed = index
            guard await pause(220) else { return }
        }
        guard await pause(300) else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { finished = true }
    }
}

// MARK: - 7. Lists: your turn

/// A real add bar on a practice list. Uses the server's parser, like the List tab, and
/// splits on commas when it can't be reached. Nothing here is saved to the real list.
private struct ListTryStage: View {
    let api: AisleAPI
    @Binding var items: [ListItem]
    let onNext: () -> Void

    @State private var draft = ""
    @State private var isAdding = false
    @State private var checkedAny = false
    @FocusState private var focused: Bool

    var body: some View {
        Stage(lead: "Your turn. ", accent: "Start a list.", message: "Type a few things with commas between them, or tap a starter.") {
            VStack(alignment: .leading, spacing: 18) {
                composer
                if items.isEmpty {
                    starters
                } else if checkedAny {
                    AisleNote(text: "Checked off. On your list, it moves to Done.")
                        .padding(.leading, 4)
                        .transition(.opacity)
                } else {
                    Text("Tap a circle when it’s in your cart.")
                        .font(.aisleSubheadline)
                        .foregroundStyle(Theme.secondaryInk)
                        .padding(.leading, 4)
                        .transition(.opacity)
                }
                PracticeDepartments(items: items, onToggle: { toggle($0) }, onRemove: { remove($0) })
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: items)
            .animation(.easeOut(duration: 0.2), value: checkedAny)
        } footer: {
            Button("Looks good") {
                focused = false
                onNext()
            }
            .buttonStyle(.aisleAccent)
            .disabled(items.isEmpty || isAdding)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: items.count)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityHidden(true)
            TextField("Add items, like milk, eggs, bread", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.aisleBody)
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .submitLabel(.done)
                .textInputAutocapitalization(.never)
                .onSubmit(submit)
            if isAdding {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(Theme.accent, in: Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add")
            }
        }
        .modifier(ComposerChrome())
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Or start from")
                .font(Theme.font(12, .semibold, relativeTo: .caption))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.leading, 4)
            FlowLayout(spacing: 8) {
                ForEach(Array(ListStarter.all.enumerated()), id: \.element.id) { index, starter in
                    Button(starter.title) { add(starter.items, fromDraft: false) }
                        .font(Theme.font(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(Theme.surface, in: Capsule())
                        .disabled(isAdding)
                        .rise(0.2 + Double(index) * 0.07)
                }
            }
        }
        .transition(.opacity)
    }

    private func submit() {
        add(draft, fromDraft: true)
    }

    private func add(_ raw: String, fromDraft: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAdding else { return }
        isAdding = true
        Task { @MainActor in
            let parsed: [ParsedListItem]
            do {
                parsed = try await api.parseList(text: text)
            } catch {
                parsed = LocalListParser.parse(text)
            }
            items.append(contentsOf: PracticeList.newItems(from: parsed, existing: items))
            if fromDraft { draft = "" }
            isAdding = false
        }
    }

    private func toggle(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone.toggle()
        checkedAny = true
    }

    private func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}

// MARK: - 8. Lists: snap a handwritten list

/// Scripted: the camera frames a paper list, the shutter fires, the lines light up as
/// they're read, then the items land on the list sorted, with the List tab's
/// "Added 4 items from your photo" line.
private struct ListPhotoStage: View {
    let onNext: () -> Void

    enum Phase { case camera, reading, done }

    /// What's written on the note. Its title, "taco night", is left off, as the real scan does.
    private static let items = [
        ListItem(text: "avocados", categoryName: "Fruit"),
        ListItem(text: "limes", categoryName: "Fruit"),
        ListItem(text: "onions", categoryName: "Vegetables"),
        ListItem(text: "tortillas", categoryName: "Bread & Bakery"),
    ]

    @State private var phase: Phase = .camera
    @State private var pressed = false
    @State private var flash = 0.0
    @State private var shots = 0
    @State private var highlighted = 0
    @State private var revealed = 0
    @State private var finished = false
    @State private var run = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Stage(lead: "On paper? ", accent: "Snap it.", message: "Take a photo of a handwritten list. Aisle reads every line and adds it, sorted.") {
            VStack(alignment: .leading, spacing: 18) {
                if phase == .done {
                    VStack(alignment: .leading, spacing: 10) {
                        ComposerPreview()
                        photoNotice
                    }
                    .transition(.opacity.combined(with: .offset(y: 12)))
                    PracticeDepartments(items: Array(Self.items.prefix(revealed)))
                } else {
                    viewfinder
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: revealed)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Example: you photograph a handwritten list. Aisle reads avocados, limes, onions and tortillas, and sorts them into Fruit, Vegetables, and Bread and Bakery.")
        } footer: {
            if finished {
                Button("Continue", action: onNext)
                    .buttonStyle(.aisleAccent)
                    .transition(.opacity.combined(with: .offset(y: 10)))
                WatchAgainButton { run += 1 }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: shots)
        .sensoryFeedback(.impact(weight: .light), trigger: revealed)
        .task(id: run) { await play() }
    }

    private var viewfinder: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(RadialGradient(
                    colors: [Color(hex: 0x4A403A), Color(hex: 0x2A2420), Color(hex: 0x1C1815)],
                    center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 320
                ))
            HandwrittenNote(items: Self.items.map(\.text), highlighted: highlighted)
                .rotationEffect(.degrees(-4))
                .padding(.top, 30)
            ViewfinderCorners()
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .padding(EdgeInsets(top: 14, leading: 34, bottom: 86, trailing: 34))
            if phase == .reading {
                ScanLine(travel: 212)
                    .padding(.horizontal, 44)
                    .padding(.top, 34)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            Group {
                if phase == .camera {
                    shutter
                } else {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white).controlSize(.small)
                        Text("Reading your list…")
                    }
                    .font(Theme.font(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(.white)
                    .frame(height: 66)
                }
            }
            .padding(.bottom, 14)
        }
        .overlay { Color.white.opacity(flash).allowsHitTesting(false) }
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    /// The camera's shutter button, as drawn by the List tab's camera.
    private var shutter: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.25))
            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 3)
            Circle().fill(Color.white).padding(7).scaleEffect(pressed ? 0.86 : 1)
        }
        .frame(width: 66, height: 66)
    }

    private var photoNotice: some View {
        HStack(spacing: 10) {
            Label("Added \(Self.items.count) items from your photo", systemImage: "text.viewfinder")
                .font(.aisleFootnote)
                .foregroundStyle(Theme.secondaryInk)
            Spacer(minLength: 0)
            Text("Undo")
                .font(Theme.font(13, .semibold, relativeTo: .footnote))
                .foregroundStyle(Theme.ink)
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: 28, height: 28)
        }
        .padding(.leading, 6)
    }

    private func play() async {
        phase = .camera; pressed = false; flash = 0; highlighted = 0; revealed = 0; finished = false
        if reduceMotion {
            phase = .done; highlighted = Self.items.count; revealed = Self.items.count; finished = true
            return
        }
        guard await pause(1000) else { return }
        withAnimation(.easeOut(duration: 0.12)) { pressed = true }
        guard await pause(150) else { return }
        shots += 1
        withAnimation(.easeOut(duration: 0.1)) { pressed = false; flash = 0.9 }
        guard await pause(200) else { return }
        withAnimation(.easeIn(duration: 0.3)) { flash = 0; phase = .reading }
        guard await pause(400) else { return }
        for index in 1...Self.items.count {
            highlighted = index
            guard await pause(420) else { return }
        }
        guard await pause(250) else { return }
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { phase = .done }
        guard await pause(300) else { return }
        for index in 1...Self.items.count {
            revealed = index
            guard await pause(220) else { return }
        }
        guard await pause(300) else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { finished = true }
    }
}

/// A note on ruled paper, in handwriting, its lines lighting up as Aisle reads them.
private struct HandwrittenNote: View {
    let items: [String]
    let highlighted: Int

    private let lineHeight: CGFloat = 34
    private let top: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("taco night")
                .font(.custom("Noteworthy-Bold", fixedSize: 24))
                .underline()
                .frame(height: lineHeight, alignment: .bottomLeading)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Text(item)
                    .font(.custom("Noteworthy-Light", fixedSize: 23))
                    .padding(.horizontal, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.accent)
                            .opacity(index < highlighted ? 0.85 : 0)
                    )
                    .padding(.leading, -5)
                    .frame(height: lineHeight, alignment: .bottomLeading)
            }
        }
        .foregroundStyle(Color(hex: 0x2B3A67))
        .padding(.leading, 36)
        .padding(.top, top)
        .frame(width: 220, height: 226, alignment: .topLeading)
        .background {
            Canvas { context, size in
                var rules = Path()
                var y = top + lineHeight + 0.5
                while y < size.height {
                    rules.move(to: CGPoint(x: 0, y: y))
                    rules.addLine(to: CGPoint(x: size.width, y: y))
                    y += lineHeight
                }
                context.stroke(rules, with: .color(Color(hex: 0xDCE6F2)), lineWidth: 1)
                var margin = Path()
                margin.move(to: CGPoint(x: 26, y: 0))
                margin.addLine(to: CGPoint(x: 26, y: size.height))
                context.stroke(margin, with: .color(Color(hex: 0xDC6F9C).opacity(0.4)), lineWidth: 1.5)
            }
            .background(Color(hex: 0xFFFDF6))
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 18)
        .animation(.easeOut(duration: 0.25), value: highlighted)
    }
}

/// Four rounded corner marks, like a camera framing a document.
private struct ViewfinderCorners: Shape {
    var length: CGFloat = 24
    var radius: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        ]
        // Each mark runs down the side, rounds the corner and runs along the edge.
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * radius))
            path.addQuadCurve(to: CGPoint(x: corner.x + dx * radius, y: corner.y), control: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}

/// The gradient bar that sweeps the note while it's read. Still under Reduce Motion.
private struct ScanLine: View {
    let travel: CGFloat

    @State private var down = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(Theme.accentRing)
            .frame(height: 3)
            .shadow(color: Color(hex: 0xF6C2D7).opacity(0.8), radius: 8)
            .offset(y: down ? travel : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { down = true }
            }
    }
}

// MARK: - 9. Lists: the walk

/// The practice list as the List tab's progress card, then as numbered stops in a
/// typical store's order. The real route waits until a store is picked (next step).
private struct ListRouteStage: View {
    let items: [ListItem]
    let onNext: () -> Void

    @State private var shown = 0
    @State private var run = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var remaining: [ListItem] { items.filter { !$0.isDone } }

    /// Everything checked off already? Walk the whole list anyway.
    private var stops: [PracticeList.Department] {
        PracticeList.walkingOrder(PracticeList.departments(remaining.isEmpty ? items : remaining))
    }

    var body: some View {
        Stage(lead: "One list, ", accent: "the shortest walk.", message: "Start shopping turns your list into stops, in the order you’ll pass them.") {
            VStack(alignment: .leading, spacing: 22) {
                summaryCard
                    .rise(0.15)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("YOUR ROUTE").fontWeight(.bold)
                        Text("· \(stops.count) \(stops.count == 1 ? "stop" : "stops")")
                    }
                    .font(Theme.font(13, .medium, relativeTo: .footnote))
                    .tracking(0.3)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.leading, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(Array(stops.prefix(shown).enumerated()), id: \.element.id) { index, stop in
                            StopRow(number: index + 1, stop: stop, isLast: index == stops.count - 1)
                                .transition(.opacity.combined(with: .offset(y: 12)))
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .top)
                    .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Theme.ink.opacity(0.06), radius: 14, y: 8)
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: shown)
        } footer: {
            Button("Pick my store", action: onNext)
                .buttonStyle(.aisleAccent)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: shown)
        .task(id: run) { await play() }
    }

    /// The List tab's progress card. Its button plays the stops again.
    private var summaryCard: some View {
        let total = items.count
        let left = remaining.count
        let fraction = total == 0 ? 0 : Double(total - left) / Double(total)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(Theme.onAccent.opacity(0.12), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Theme.onAccent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Theme.font(15, .bold, relativeTo: .subheadline))
                }
                .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(left == 0 ? "All done!" : "\(left) \(left == 1 ? "item" : "items") left")
                        .font(Theme.font(22, .bold, relativeTo: .title2))
                        .tracking(-0.4)
                    Text("\(stops.count) \(stops.count == 1 ? "department" : "departments")")
                        .font(Theme.font(13, relativeTo: .footnote))
                        .opacity(0.75)
                }
            }
            .accessibilityElement(children: .combine)

            Button { run += 1 } label: {
                Label("Start shopping · best route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.aisleHeadline)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color(hex: 0x1F1B24), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableCardStyle())
            .accessibilityHint("Shows the stops again")
        }
        .foregroundStyle(Theme.onAccent)
        .padding(18)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.glow.opacity(0.22), radius: 18, y: 12)
    }

    private func play() async {
        shown = 0
        let count = stops.count
        if reduceMotion || count == 0 {
            shown = count
            return
        }
        guard await pause(500) else { return }
        for index in 1...count {
            shown = index
            guard await pause(260) else { return }
        }
    }
}

/// One stop: its number (the first in the gradient), the department and what to get there,
/// joined to the next stop by a dotted line.
private struct StopRow: View {
    let number: Int
    let stop: PracticeList.Department
    let isLast: Bool

    private var itemList: String { stop.items.map(\.text).joined(separator: ", ") }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(Theme.font(14, .bold, relativeTo: .subheadline))
                .foregroundStyle(number == 1 ? Theme.onAccent : Theme.ink)
                .frame(width: 30, height: 30)
                .background(number == 1 ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fill), in: Circle())
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    DepartmentIconView(department: stop.name, size: 20)
                    Text(stop.name)
                        .font(Theme.font(16, .semibold, relativeTo: .body))
                        .foregroundStyle(Theme.ink)
                }
                Text(itemList)
                    .font(Theme.font(14, relativeTo: .subheadline))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 16)
        .background(alignment: .topLeading) {
            if !isLast {
                VerticalLine()
                    .stroke(Theme.secondaryInk.opacity(0.3), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5]))
                    .frame(width: 2)
                    .padding(.leading, 30)
                    .padding(.top, 44)
                    .padding(.bottom, -8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stop \(number), \(stop.name): \(itemList)")
    }
}

private struct VerticalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
