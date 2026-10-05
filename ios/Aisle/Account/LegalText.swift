import Foundation

/// Aisle's Terms of Service and Privacy Policy, shown in sign-up and from the You tab.
/// The server serves the same text at /terms and /privacy (backend/app/legal.py); a backend
/// test checks the two match. Have a lawyer review before launch.
enum Legal {
    /// Bump when either document changes in a way people should re-accept.
    static let version = "2026-10-04"
    static let effectiveDate = "October 4, 2026"
    static let contactEmail = "support@shopaisle.app"
    /// Public copies of these documents and the support page on shopaisle.app (built from
    /// backend/app/legal.py by website/build.py), for the App Store listing and links in the app.
    static let websiteBase = URL(string: "https://shopaisle.app")!
    static var privacyURL: URL { websiteBase.appending(path: "privacy") }
    static var termsURL: URL { websiteBase.appending(path: "terms") }
    static var supportURL: URL { websiteBase.appending(path: "support") }

    /// "By continuing you agree to the Terms and Privacy Policy." with both as links.
    static var agreementLine: AttributedString {
        let markdown = "By continuing you agree to the [Terms](\(termsURL.absoluteString)) and [Privacy Policy](\(privacyURL.absoluteString))."
        return (try? AttributedString(markdown: markdown)) ?? AttributedString("By continuing you agree to the Terms and Privacy Policy.")
    }

    static let acceptedVersionKey = "aisle.legal.acceptedVersion"
    static let acceptedAtKey = "aisle.legal.acceptedAt"

    static func recordAcceptance(defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: acceptedVersionKey)
        defaults.set(Date().timeIntervalSince1970, forKey: acceptedAtKey)
    }

    /// Agreed to these versions already, e.g. as a guest who now makes an account.
    static func hasAccepted(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: acceptedVersionKey) == version
    }

    struct Section: Identifiable {
        let title: String
        let body: String
        var id: String { title }
    }

    struct Document: Identifiable {
        let title: String
        let sections: [Section]
        var id: String { title }
    }

    /// The plain-English version, shown above the full text.
    static let summary: [(symbol: String, text: String)] = [
        ("location.slash", "Your location is only used to find stores near you. We don't keep it."),
        ("hand.raised", "We never sell your data or show ads."),
        ("sparkle.magnifyingglass", "Your searches and photos go to an AI provider (Anthropic or OpenAI) to find answers. They can't train on them."),
        ("questionmark.circle", "Aisle's answers are best guesses. Always check the shelf."),
        ("creditcard", "Aisle+ is billed by Apple. Cancel anytime in Settings."),
        ("trash", "Delete your account anytime from the You tab."),
    ]

    static let terms = Document(title: "Terms of Service", sections: [
        Section(title: "1. Using Aisle", body: """
        These terms are an agreement between you and Aisle ("Aisle", "we", "us") for the Aisle app and its related services. By creating an account or using Aisle, you agree to them. If you don't agree, please don't use Aisle. You must be at least 13 years old to use Aisle.
        """),
        Section(title: "2. What Aisle does, and its limits", body: """
        Aisle helps you find items in stores. Locations come from store data where we have it, from other shoppers' confirmations, from typical layouts for each kind of store, and from AI estimates. Store locations come from OpenStreetMap. Stores change their shelves often, so any answer can be wrong. Aisle shows how sure it is with each answer; treat "Likely here" and "Best guess" answers as starting points. Aisle isn't affiliated with or endorsed by the stores it covers, and store names and logos belong to their owners.
        """),
        Section(title: "3. Your account", body: """
        You can use Aisle as a guest, without an account. Some features, like photo search, follow-up questions, shared lists and Aisle+, need a free account. If you make one, give accurate information and keep access to your email, phone or Apple or Google account secure. You're responsible for activity on your account. You can delete your account at any time from the You tab.
        """),
        Section(title: "4. Aisle+", body: """
        Aisle+ is an optional, auto-renewing subscription sold through Apple's App Store. Prices are shown before you buy. Payment is charged to your Apple ID at confirmation of purchase, and the subscription renews automatically unless you turn off auto-renew at least 24 hours before the end of the current period. If a free trial is offered, you'll be charged when it ends unless you cancel before then. You can manage or cancel your subscription in your iPhone's Settings. Refunds are handled by Apple under its policies. The free plan has daily limits on some features, which we may change with notice.
        """),
        Section(title: "5. Things you share", body: """
        When you tell Aisle an item was found, wasn't there, or was somewhere else, you let us use that information to improve answers for everyone, including showing it to other shoppers in an anonymous form. Items on shared lists are visible to everyone on that list. Don't submit anything unlawful, misleading or harmful, and don't share other people's private information. If something on a shared list is abusive, report it from the list's Sharing screen: reports go to Aisle and we review them. A list's owner can also remove people from it.
        """),
        Section(title: "6. Fair use", body: """
        Don't misuse Aisle: no attempts to break, overload or reverse-engineer the service, scrape it, create accounts in bulk, get around the free plan's limits, or use it to harass others. Aisle limits how often features can be used, to keep the service running for everyone. We may suspend or close accounts that misuse it.
        """),
        Section(title: "7. Disclaimers", body: """
        Aisle is provided "as is" and "as available". To the fullest extent the law allows, we make no warranties about accuracy, availability or fitness for a particular purpose, and we aren't responsible for an item not being where Aisle said, being out of stock, or its price.
        """),
        Section(title: "8. Limitation of liability", body: """
        To the fullest extent the law allows, Aisle won't be liable for indirect, incidental or consequential damages, and our total liability for any claim relating to Aisle is limited to the amount you paid us for Aisle+ in the 12 months before the claim, or $10 if you haven't paid anything. Some places don't allow these limits, so they may not apply to you.
        """),
        Section(title: "9. Changes and ending", body: """
        We may update Aisle and these terms. If we make an important change, we'll tell you in the app and ask you to agree again. You can stop using Aisle at any time. We may stop offering Aisle or parts of it; if that affects an active Aisle+ subscription, we'll tell you in advance.
        """),
        Section(title: "10. Law and contact", body: """
        These terms are governed by the laws of the Commonwealth of Pennsylvania, USA, except where the law where you live says otherwise. Apple isn't a party to these terms and isn't responsible for Aisle, but Apple may enforce them as a third-party beneficiary as required by its App Store rules. Questions? Email \(contactEmail).
        """),
    ])

    static let privacy = Document(title: "Privacy Policy", sections: [
        Section(title: "What we collect", body: """
        • What you search for, the store you searched in, and the answer Aisle gave, linked to a random ID for your phone and, while you're signed in, to your account. Signing out or deleting your account gives your phone a new ID, so later searches aren't linked to the old account.
        • Feedback you give, like "Found it", "Not here" or a corrected spot, linked to your account so repeat reports count once.
        • Your account: your first name, and your email, phone number, or Apple or Google sign-in ID.
        • If you share a list: its name, its items, and the first names of the people on it. If you report a shared list, your report and a copy of the list, so we can review it.
        • If you subscribe: a confirmation from Apple that your Aisle+ subscription is active. We never see your card details.
        • To prevent abuse, how many requests your account, your phone's random ID and your network (IP address) made recently, and the email or phone number each sign-in code was sent to.
        • If usage sharing is on: anonymous counts like "a search happened" or "a trip finished". Never what you searched for. You can turn this off in the You tab.
        """),
        Section(title: "Location", body: """
        When you ask for stores near you, your phone sends its location, rounded to about a city block, to find them. We use it for that request only. It isn't saved to your account or our database, though our host's short-lived request logs can include it. Aisle doesn't track where you go.
        """),
        Section(title: "Photos", body: """
        When you search with a photo, it's sent to our AI provider to work out what the item is. We don't keep the photo after answering. A few small thumbnails of your recent photo searches are kept on your phone only, for the Aisle+ tab.
        """),
        Section(title: "What stays on your phone", body: """
        Your lists (unless shared), recent searches and their answers, saved offline maps, and your Aisle+ activity charts live on your phone. Deleting the app removes them. Our servers only count today's uses of the free plan's limited features.
        """),
        Section(title: "Who helps us run Aisle", body: """
        We use a few service providers, only for running Aisle: a cloud host for our servers and database; Anthropic and/or OpenAI to understand searches and photos; Twilio to text sign-in codes; Resend to email sign-in codes, and reports of shared lists to us; Apple for purchases and Sign in with Apple; Google for Google sign-in; logo.dev for store logos; Sentry for error reports, which never include your searches, photos or contact details; and OpenStreetMap for store locations. They may only use your information to provide their service to us.
        """),
        Section(title: "What we never do", body: """
        We don't sell your personal information, share it for advertising, or show ads. We don't use your data to train third-party AI models.
        """),
        Section(title: "How long we keep things", body: """
        Account details are kept until you delete your account. When you do, we delete your name, contact details and sign-in records, end your sign-in with Apple, and unlink your searches and feedback from you. Your phone also gets a new random ID, and everything Aisle kept on it for your account is erased. Searches are deleted after a year and anonymous usage counts after six months. Records of sign-in codes, which keep only a scrambled form of your phone number or email, are deleted after two days, and the counts behind daily limits after about a week. Those counts stay with a scrambled form of how you signed in for that week even if you delete your account, so deleting doesn't reset them. Sign-in codes themselves expire within minutes.
        """),
        Section(title: "Your choices and rights", body: """
        You can turn off usage sharing, change your name, or delete your account in the You tab. You can also email us to ask for a copy of your data or for it to be deleted, and we'll respond within 30 days. Depending on where you live, you may have more rights under laws like the CCPA or GDPR; email us and we'll help.
        """),
        Section(title: "Children", body: """
        Aisle isn't meant for children under 13, and we don't knowingly collect their information. If you think a child has given us information, email us and we'll delete it.
        """),
        Section(title: "Changes and contact", body: """
        If we change this policy in an important way, we'll tell you in the app first. Questions or requests: \(contactEmail).
        """),
    ])
}
