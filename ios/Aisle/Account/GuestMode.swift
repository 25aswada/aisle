import Foundation

/// Using Aisle without an account: searching a store, maps, one list, shopping mode and
/// history on this phone. Photo search, follow-ups, reports, shared lists and Aisle+ need
/// a free account, and ask for one (`SignUpReason`). Signing up keeps what the guest made
/// here (`LocalAccountData.adopt`).
enum GuestMode {
    /// Chose "Continue as guest", so launches go straight into the app. Cleared on sign-in,
    /// so signing out leads back to the sign-in screen (which offers guest again).
    static let key = "aisle.guest"
}

/// Why a guest is being asked to make a free account: a feature that needs one, a nudge,
/// or the You tab. Sent with the sign-up prompt analytics events.
enum SignUpReason: String, Identifiable {
    case photoSearch = "photo_search"
    case followUp = "follow_up"
    case feedback
    case scanList = "scan_list"
    case shareList = "share_list"
    case joinList = "join_list"
    case plus
    /// Out of today's guest searches (the server's `sign_in_required`).
    case searchLimit = "search_limit"
    /// The gentle nudge after a few searches (`GuestNudge`).
    case searches
    /// "Sign in" or the card on the You tab.
    case you

    var id: String { rawValue }

    /// The headline, its last words in the gradient.
    var headline: (lead: String, accent: String) {
        switch self {
        case .photoSearch: return ("Search with ", "a photo.")
        case .followUp: return ("Ask a ", "follow-up.")
        case .feedback: return ("Help the ", "next shopper.")
        case .scanList: return ("Snap your ", "paper list.")
        case .shareList: return ("Shop together, ", "on one list.")
        case .joinList: return ("Join the ", "family list.")
        case .plus: return ("Aisle+ stays ", "with you.")
        case .searchLimit: return ("Keep ", "searching.")
        case .searches: return ("Enjoying ", "Aisle?")
        case .you: return ("One free account, ", "and you're in.")
        }
    }

    var message: String {
        switch self {
        case .photoSearch: return "Snap anything and Aisle finds where it is in the store. Photo search comes with a free account."
        case .followUp: return "Keep the conversation going, like what's next to it or where the candles are. Follow-ups come with a free account."
        case .feedback: return "Telling Aisle what you found makes the next answer surer. Reports need a free account, so each one counts once."
        case .scanList: return "Aisle reads a handwritten list and adds every item for you. It comes with a free account."
        case .shareList: return "Everyone sees what's added and checked off, as it happens. Sharing starts with a free account."
        case .joinList: return "Make a free account to join the list someone shared with you. Joining is free."
        case .plus: return "Aisle+ belongs to your account, so it comes with you to a new phone. Make your free account, then pick a plan."
        case .searchLimit: return "You've used today's guest searches. A free account gets more every day, plus photo search and follow-ups."
        case .searches: return "A free account gets you more searches every day, photo search and follow-up questions."
        case .you: return "Everything you've made here comes with you. It takes a few seconds, and it's free."
        }
    }

    /// What a free account adds, this reason's own benefit first.
    var benefits: [(symbol: String, text: String)] {
        let all = Self.allBenefits
        let first: Int? = switch self {
        case .searchLimit, .searches: 0
        case .photoSearch, .followUp, .scanList: 1
        case .shareList, .joinList: 2
        case .plus: 3
        case .feedback, .you: nil
        }
        guard let first else { return all }
        return [all[first]] + all.enumerated().filter { $0.offset != first }.map(\.element)
    }

    static let allBenefits: [(symbol: String, text: String)] = [
        ("magnifyingglass", "More free searches every day"),
        ("camera", "Search with a photo and ask follow-ups"),
        ("person.2", "Share lists with your family"),
        ("sparkles", "Aisle+ comes with you to a new phone"),
    ]
}

/// The gentle "make a free account" nudge after a guest's searches, at most once a day.
/// Guests get 3 searches a day (the server's `aisle_guest_searches`), so it comes after
/// the second, before running out asks anyway.
enum GuestNudge {
    static let afterSearches = 2
    static let dayKey = "aisle.guest.searchDay"
    static let countKey = "aisle.guest.searchCount"
    static let shownKey = "aisle.guest.nudgedDay"

    /// Counts a guest's answered search. True when it's time for the nudge, which then
    /// counts as shown for today.
    static func recordSearch(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        let day = Self.day(now)
        let count = (defaults.string(forKey: dayKey) == day ? defaults.integer(forKey: countKey) : 0) + 1
        defaults.set(day, forKey: dayKey)
        defaults.set(count, forKey: countKey)
        guard count >= afterSearches, defaults.string(forKey: shownKey) != day else { return false }
        markShown(now: now, defaults: defaults)
        return true
    }

    /// The guest was already asked today (e.g. they ran out of searches): no nudge as well.
    static func markShown(now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(day(now), forKey: shownKey)
    }

    /// The phone's calendar day, e.g. "2026-10-04".
    private static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
