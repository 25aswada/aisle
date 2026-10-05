import Foundation
import Observation

/// Drives item search on the Find screen.
@MainActor
@Observable
final class FindModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(ItemSearchResult)
        case failed(String)
    }

    enum FeedbackState: Equatable {
        case none
        case sending
        /// The shopper confirmed the suggested location.
        case confirmed
        /// The shopper said "Not here"; offer to tell us where it was.
        case reportedMissing
        /// A correction with the real location was saved.
        case corrected(String)
        case failed(String)
    }

    var query = ""
    /// A photo attached to whichever ask bar is showing (downsized JPEG).
    var photo: Data?
    /// The photo the current result was searched from, shown in the question bubble.
    private(set) var searchPhoto: Data?
    private(set) var phase: Phase = .idle
    /// Bumped by `clear()`, so a search or reply still on its way when the shopper starts
    /// over is dropped instead of bringing the old conversation back.
    @ObservationIgnored private var generation = 0
    private(set) var feedback: FeedbackState = .none

    /// The follow-up being typed once a result is showing.
    var followUp = ""
    /// The conversation after the result: the shopper's follow-ups and Aisle's replies.
    private(set) var turns: [ChatTurn] = []
    private(set) var isReplying = false
    private(set) var followUpError: String?
    /// Set when a free-tier limit is hit, to open the Aisle+ sheet saying why.
    var upgradePrompt: String?
    /// Set when a guest is out of today's searches, to offer a free account.
    var signUpPrompt: SignUpReason?

    /// Where recents go when no shared `RecentSearches` is passed in.
    static let ephemeralSuite = "aisle.ephemeral"

    @ObservationIgnored private let api: AisleAPI
    @ObservationIgnored private let analytics: AnalyticsTracking
    @ObservationIgnored let recents: RecentSearches
    @ObservationIgnored private let cache: SearchCache

    init(
        api: AisleAPI,
        analytics: AnalyticsTracking? = nil,
        recents: RecentSearches? = nil,
        cache: SearchCache? = nil
    ) {
        self.api = api
        self.analytics = analytics ?? NoopAnalytics()
        self.recents = recents ?? RecentSearches(defaults: UserDefaults(suiteName: Self.ephemeralSuite) ?? .standard)
        self.cache = cache ?? SearchCache()
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(storeID: String?) async {
        let text = trimmedQuery
        let photo = photo
        guard !text.isEmpty || photo != nil else {
            phase = .idle
            return
        }
        feedback = .none
        resetConversation()
        searchPhoto = photo
        self.photo = nil
        let started = generation
        guard let photo else {
            await find(text, storeID: storeID)
            return
        }
        // A photo: name what's in it, then search for that like any other item.
        phase = .loading
        do {
            let item = try await api.identify(photo: photo, note: text.isEmpty ? nil : text, storeID: storeID)
            try Task.checkCancellation()
            guard generation == started else { return }
            guard let item else {
                self.photo = photo
                phase = .failed("Aisle couldn't tell what's in that photo. Try a closer shot, or type what you're looking for.")
                return
            }
            query = item
            MemberActivity.recordPhotoSearch(photo)
            await find(item, storeID: storeID)
        } catch is CancellationError {
            // A newer search replaced this one.
        } catch {
            guard generation == started else { return }
            self.photo = photo
            fail(with: error)
        }
    }

    private func find(_ text: String, storeID: String?) async {
        if let cached = cache.result(query: text, storeID: storeID) {
            phase = .loaded(cached)
            recents.record(text, result: cached, storeID: storeID)
            trackResult(cached, storeID: storeID, cached: true)
            return
        }
        phase = .loading
        let started = generation
        do {
            let result = try await api.searchItem(query: text, storeID: storeID)
            try Task.checkCancellation()
            guard generation == started else { return }
            cache.store(result, query: text, storeID: storeID)
            recents.record(text, result: result, storeID: storeID)
            ShopperStats.recordSearch(storeID: storeID)
            phase = .loaded(result)
            trackResult(result, storeID: storeID, cached: false)
        } catch is CancellationError {
            // A newer search replaced this one.
        } catch {
            guard generation == started else { return }
            fail(with: error)
        }
    }

    private func fail(with error: Error) {
        if case APIError.plusRequired(_, let message) = error {
            phase = .failed(message)
            upgradePrompt = message
            return
        }
        if case APIError.signInRequired(_, let message) = error {
            phase = .failed(message)
            signUpPrompt = .searchLimit
            return
        }
        if case APIError.httpStatus(404) = error {
            phase = .failed("This store is no longer available. Choose another store.")
            analytics.track(.searchFailed, ["error": "store_not_found"])
        } else {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong.")
            analytics.track(.searchFailed, ["error": .string((error as? APIError)?.kind ?? "unknown")])
        }
    }

    /// Runs a recent search again.
    func searchRecent(_ query: String, storeID: String?) async {
        self.query = query
        photo = nil
        analytics.track(.recentSearchTapped)
        await search(storeID: storeID)
    }

    private func trackResult(_ result: ItemSearchResult, storeID: String?, cached: Bool) {
        analytics.track(.searchSubmitted, [
            "source": .string(result.source.rawValue),
            "confidence": .string(result.confidence.rawValue),
            "has_store": .bool(storeID != nil),
            "has_aisle": .bool(result.location.aisle != nil),
            "cached": .bool(cached),
        ])
    }

    func clear() {
        generation += 1
        query = ""
        photo = nil
        searchPhoto = nil
        phase = .idle
        feedback = .none
        resetConversation()
    }

    // MARK: - Follow-ups

    var trimmedFollowUp: String {
        followUp.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends the typed follow-up with the whole conversation so far: the search, Aisle's
    /// answer to it, then every turn since. On failure the message goes back in the field.
    func sendFollowUp(storeID: String, retailer: String?) async {
        let text = trimmedFollowUp
        let photo = photo
        guard !text.isEmpty || photo != nil, !isReplying, let result = currentResult else { return }
        followUp = ""
        self.photo = nil
        followUpError = nil
        let turn = ChatTurn(role: .shopper, text: text, photo: photo)
        turns.append(turn)
        isReplying = true
        let started = generation
        defer { if generation == started { isReplying = false } }

        let question = result.query.isEmpty ? result.item : result.query
        // Aisle's answer goes back exactly as the server signed it; the app's own wording
        // has no signature, so the server leaves it out of what the AI sees.
        let explanation = result.explanationSignature != nil ? result.explanation : nil
        var messages = [
            ChatMessage(role: .shopper, content: searchPhoto == nil ? question : "(a photo of \(question))"),
            ChatMessage(
                role: .aisle, content: explanation ?? String(result.reply(at: retailer).characters),
                signature: explanation != nil ? result.explanationSignature : nil
            ),
        ]
        // Only the newest photo goes along; Aisle's earlier replies already describe the rest.
        messages += turns.map { past in
            let content = past.photo != nil && past.id != turn.id && past.text.isEmpty ? "(sent a photo)" : past.text
            return ChatMessage(
                role: past.role, content: content, photo: past.id == turn.id ? past.photo : nil, signature: past.signature
            )
        }
        do {
            let answer = try await api.chat(storeID: storeID, messages: messages)
            try Task.checkCancellation()
            guard generation == started else { return }
            // A new item's search can stand in for a missing reply with the app's own wording.
            let reply = answer.reply.flatMap { $0.isEmpty ? nil : $0 }
                ?? answer.search.map { String($0.reply(at: retailer).characters) }
            guard let reply else {
                throw APIError.invalidResponse
            }
            let signature = reply == answer.reply ? answer.replySignature : nil
            turns.append(ChatTurn(role: .aisle, text: reply, result: answer.search, signature: signature))
            MemberActivity.recordFollowUp(question: text, answer: reply)
            if let found = answer.search {
                // "Was it there?" now asks about this item.
                feedback = .none
                recents.record(found.item, result: found, storeID: storeID)
            }
            analytics.track(.followUpSent, ["turns": .int(turns.count / 2), "found_item": .bool(answer.search != nil)])
        } catch is CancellationError {
            // A new search started; the conversation was reset.
        } catch {
            guard generation == started else { return }
            turns.removeAll { $0.id == turn.id }
            if followUp.isEmpty { followUp = text }
            if self.photo == nil { self.photo = photo }
            if case APIError.plusRequired(_, let message) = error {
                followUpError = message
                upgradePrompt = message
                return
            }
            followUpError = error as? APIError == .invalidResponse
                ? "Aisle couldn't answer that right now. Try again in a moment."
                : (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }

    private func resetConversation() {
        followUp = ""
        searchPhoto = nil
        turns = []
        isReplying = false
        followUpError = nil
    }

    // MARK: - Feedback

    /// The result the conversation started from.
    var currentResult: ItemSearchResult? {
        if case .loaded(let result) = phase { return result }
        return nil
    }

    /// The newest result on screen: a follow-up's new item, or the first search. Feedback
    /// ("Was it there?") is about this one.
    var latestResult: ItemSearchResult? {
        turns.last { $0.result != nil }?.result ?? currentResult
    }

    /// "Found it": confirms the suggested zone.
    func confirmFound(storeID: String) async {
        guard let result = latestResult else { return }
        await send(storeID: storeID, verdict: .found, zoneID: result.location.zoneID, aisle: nil) {
            .confirmed
        }
    }

    /// "Not here": the item wasn't in the suggested zone.
    func reportNotHere(storeID: String) async {
        guard let result = latestResult else { return }
        await send(storeID: storeID, verdict: .notHere, zoneID: result.location.zoneID, aisle: nil) {
            .reportedMissing
        }
    }

    /// Correction entry: where the shopper actually found it.
    func submitCorrection(storeID: String, zone: StoreZone, aisle: String) async {
        let aisleText = aisle.trimmingCharacters(in: .whitespacesAndNewlines)
        await send(storeID: storeID, verdict: .found, zoneID: zone.id, aisle: aisleText.isEmpty ? nil : aisleText) {
            .corrected(zone.name)
        }
    }

    private func send(
        storeID: String, verdict: FeedbackVerdict, zoneID: Int?, aisle: String?,
        onSuccess: () -> FeedbackState
    ) async {
        guard let result = latestResult, let store = Int(storeID) else { return }
        let previous = feedback
        feedback = .sending
        let body = FeedbackBody(
            storeID: store, item: result.item, verdict: verdict,
            searchID: result.searchID, zoneID: zoneID, aisle: aisle
        )
        do {
            _ = try await api.sendFeedback(body)
            feedback = onSuccess()
            if verdict == .found { ShopperStats.recordConfirmation() }
            // The next search for this item should show the updated report counts.
            cache.invalidate(item: result.item, storeID: storeID)
            analytics.track(.feedbackSent, [
                "verdict": .string(verdict.rawValue),
                "correction": .bool(verdict == .found && zoneID != result.location.zoneID),
            ])
        } catch is CancellationError {
            feedback = previous
        } catch {
            feedback = .failed("Couldn't send that. Check your connection and try again.")
        }
    }
}
