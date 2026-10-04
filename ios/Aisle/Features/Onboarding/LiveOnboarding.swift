import SwiftUI

/// First launch, as a short interactive story: the logo assembles, Aisle answers a
/// question on its own, the shopper asks one, then learns the confidence levels,
/// taps "Found it", picks a store and is offered (never forced into) an account.
struct LiveOnboarding: View {
    enum Step: Int, CaseIterable {
        case intro, demo, tryIt, confidence, found, location, done
    }

    let api: AisleAPI
    let location: LocationProviding
    let onCreateAccount: () -> Void
    let onSignIn: () -> Void
    let onFinish: () -> Void

    @State private var step: Step = .intro
    @State private var chosenStore: Store?
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
            FoundStage { go(.location) }
        case .location:
            LocationStage(api: api, location: location, onPicked: { store in
                chosenStore = store
                go(.done)
            }, onLater: { go(.done) })
        case .done:
            DoneStage(store: chosenStore, onCreateAccount: onCreateAccount, onFinish: onFinish)
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

/// Six gradient segments and a Skip button.
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
                // Shelves stock from the vanishing point outward, then follow the phone's tilt.
                StockingLogo(size: logoSize, stocked: assembled)
            }
            .frame(height: 220)
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
        guard await pause(450) else { return }
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

// MARK: - 7. Done: optional account

private struct DoneStage: View {
    let store: Store?
    let onCreateAccount: () -> Void
    let onFinish: () -> Void

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
                Text("Want your lists and recent finds on every device? Make a free account. It's optional, and you can do it later in You.")
                    .font(Theme.font(17, relativeTo: .body))
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .rise(0.25)

            Spacer(minLength: 24)

            VStack(spacing: 10) {
                Button("Create free account", action: onCreateAccount)
                    .buttonStyle(.aisleAccent)
                Button("Maybe later", action: onFinish)
                    .buttonStyle(.aisleSoft)
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
