"""Aisle's Terms of Service and Privacy Policy as web pages (/terms, /privacy), plus a
support page (/support). The App Store needs public links to these.

The app shows the same text from ios/Aisle/Account/LegalText.swift; a test checks the
two copies match, so change both together.
"""
from __future__ import annotations

from html import escape

EFFECTIVE_DATE = "October 4, 2026"
CONTACT_EMAIL = "support@shopaisle.app"

SUMMARY = [
    "Your location is only used to find stores near you. We don't keep it.",
    "We never sell your data or show ads.",
    "Your searches and photos go to an AI provider (Anthropic or OpenAI) to find answers. They can't train on them.",
    "Aisle's answers are best guesses. Always check the shelf.",
    "Aisle+ is billed by Apple. Cancel anytime in Settings.",
    "Delete your account anytime from the You tab.",
]

TERMS = [
    ("1. Using Aisle", """These terms are an agreement between you and Aisle ("Aisle", "we", "us") for the Aisle app and its related services. By creating an account or using Aisle, you agree to them. If you don't agree, please don't use Aisle. You must be at least 13 years old to use Aisle."""),
    ("2. What Aisle does, and its limits", """Aisle helps you find items in stores. Locations come from store data where we have it, from other shoppers' confirmations, from typical layouts for each kind of store, and from AI estimates. Store locations come from OpenStreetMap. Stores change their shelves often, so any answer can be wrong. Aisle shows how sure it is with each answer; treat "Likely here" and "Best guess" answers as starting points. Aisle isn't affiliated with or endorsed by the stores it covers, and store names and logos belong to their owners."""),
    ("3. Your account", """You need a free account to use Aisle. Give accurate information and keep access to your email, phone or Apple or Google account secure. You're responsible for activity on your account. You can delete your account at any time from the You tab."""),
    ("4. Aisle+", """Aisle+ is an optional, auto-renewing subscription sold through Apple's App Store. Prices are shown before you buy. Payment is charged to your Apple ID at confirmation of purchase, and the subscription renews automatically unless you turn off auto-renew at least 24 hours before the end of the current period. If a free trial is offered, you'll be charged when it ends unless you cancel before then. You can manage or cancel your subscription in your iPhone's Settings. Refunds are handled by Apple under its policies. The free plan has daily limits on some features, which we may change with notice."""),
    ("5. Things you share", """When you tell Aisle an item was found, wasn't there, or was somewhere else, you let us use that information to improve answers for everyone, including showing it to other shoppers in an anonymous form. Items on shared lists are visible to everyone on that list. Don't submit anything unlawful, misleading or harmful, and don't share other people's private information. If something on a shared list is abusive, report it from the list's Sharing screen: reports go to Aisle and we review them. A list's owner can also remove people from it."""),
    ("6. Fair use", """Don't misuse Aisle: no attempts to break, overload or reverse-engineer the service, scrape it, create accounts in bulk, get around the free plan's limits, or use it to harass others. Aisle limits how often features can be used, to keep the service running for everyone. We may suspend or close accounts that misuse it."""),
    ("7. Disclaimers", """Aisle is provided "as is" and "as available". To the fullest extent the law allows, we make no warranties about accuracy, availability or fitness for a particular purpose, and we aren't responsible for an item not being where Aisle said, being out of stock, or its price."""),
    ("8. Limitation of liability", """To the fullest extent the law allows, Aisle won't be liable for indirect, incidental or consequential damages, and our total liability for any claim relating to Aisle is limited to the amount you paid us for Aisle+ in the 12 months before the claim, or $10 if you haven't paid anything. Some places don't allow these limits, so they may not apply to you."""),
    ("9. Changes and ending", """We may update Aisle and these terms. If we make an important change, we'll tell you in the app and ask you to agree again. You can stop using Aisle at any time. We may stop offering Aisle or parts of it; if that affects an active Aisle+ subscription, we'll tell you in advance."""),
    ("10. Law and contact", f"""These terms are governed by the laws of the Commonwealth of Pennsylvania, USA, except where the law where you live says otherwise. Apple isn't a party to these terms and isn't responsible for Aisle, but Apple may enforce them as a third-party beneficiary as required by its App Store rules. Questions? Email {CONTACT_EMAIL}."""),
]

PRIVACY = [
    ("What we collect", """• What you search for, the store you searched in, and the answer Aisle gave, linked to a random ID for your phone and, while you're signed in, to your account. Signing out or deleting your account gives your phone a new ID, so later searches aren't linked to the old account.
• Feedback you give, like "Found it", "Not here" or a corrected spot, linked to your account so repeat reports count once.
• Your account: your first name, and your email, phone number, or Apple or Google sign-in ID.
• If you share a list: its name, its items, and the first names of the people on it. If you report a shared list, your report and a copy of the list, so we can review it.
• If you subscribe: a confirmation from Apple that your Aisle+ subscription is active. We never see your card details.
• To prevent abuse, how many requests your account and your network (IP address) made recently, and the email or phone number each sign-in code was sent to.
• If usage sharing is on: anonymous counts like "a search happened" or "a trip finished". Never what you searched for. You can turn this off in the You tab."""),
    ("Location", """When you ask for stores near you, your phone sends its location, rounded to about a city block, to find them. We use it for that request only. It isn't saved to your account or our database, though our host's short-lived request logs can include it. Aisle doesn't track where you go."""),
    ("Photos", """When you search with a photo, it's sent to our AI provider to work out what the item is. We don't keep the photo after answering. A few small thumbnails of your recent photo searches are kept on your phone only, for the Aisle+ tab."""),
    ("What stays on your phone", """Your lists (unless shared), recent searches and their answers, saved offline maps, and your Aisle+ activity charts live on your phone. Deleting the app removes them. Our servers only count today's uses of the free plan's limited features."""),
    ("Who helps us run Aisle", """We use a few service providers, only for running Aisle: a cloud host for our servers and database; Anthropic and/or OpenAI to understand searches and photos; Twilio to text sign-in codes; Resend to email sign-in codes, and reports of shared lists to us; Apple for purchases and Sign in with Apple; Google for Google sign-in; logo.dev for store logos; Sentry for error reports, which never include your searches, photos or contact details; and OpenStreetMap for store locations. They may only use your information to provide their service to us."""),
    ("What we never do", """We don't sell your personal information, share it for advertising, or show ads. We don't use your data to train third-party AI models."""),
    ("How long we keep things", """Account details are kept until you delete your account. When you do, we delete your name, contact details and sign-in records, end your sign-in with Apple, and unlink your searches and feedback from you. Your phone also gets a new random ID, and everything Aisle kept on it for your account is erased. Searches are deleted after a year and anonymous usage counts after six months. Records of sign-in codes, which keep only a scrambled form of your phone number or email, are deleted after two days, and the counts behind daily limits after about a week. Those counts stay with a scrambled form of how you signed in for that week even if you delete your account, so deleting doesn't reset them. Sign-in codes themselves expire within minutes."""),
    ("Your choices and rights", """You can turn off usage sharing, change your name, or delete your account in the You tab. You can also email us to ask for a copy of your data or for it to be deleted, and we'll respond within 30 days. Depending on where you live, you may have more rights under laws like the CCPA or GDPR; email us and we'll help."""),
    ("Children", """Aisle isn't meant for children under 13, and we don't knowingly collect their information. If you think a child has given us information, email us and we'll delete it."""),
    ("Changes and contact", f"""If we change this policy in an important way, we'll tell you in the app first. Questions or requests: {CONTACT_EMAIL}."""),
]

SUPPORT = [
    ("Get help", f"""Email {CONTACT_EMAIL} and we'll get back to you within two business days. Tell us your store and what you searched for if an answer was wrong."""),
    ("Aisle+", """Aisle+ is billed by Apple. To cancel or change your plan, open Settings on your iPhone, tap your name, then Subscriptions. For a refund, visit reportaproblem.apple.com. To move Aisle+ to a new account, tap Restore purchases on the Aisle+ tab."""),
    ("Your account", """To delete your account and its data, open the You tab and tap Delete account. You can also email us to ask for a copy of your data."""),
    ("Wrong answers", """Store layouts change. Tap "Not here" or correct the spot after a search; when shoppers agree, Aisle's answer updates for everyone."""),
]

_STYLE = """
:root { color-scheme: light dark; --ink: #1F1B24; --muted: #4E544F; --bg: #F3F4F1; --card: #FFFFFF; --accent: #B05C9C; }
@media (prefers-color-scheme: dark) { :root { --ink: #F4F1F6; --muted: #B9B3BF; --bg: #131115; --card: #1F1C22; --accent: #E59BC6; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 17px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
main { max-width: 720px; margin: 0 auto; padding: 40px 16px 64px; }
h1 { font-size: 34px; letter-spacing: -0.02em; margin: 0 0 4px; }
.date { color: var(--muted); margin: 0 0 28px; }
section { background: var(--card); border-radius: 20px; padding: 20px 22px; margin: 0 0 14px; }
h2 { font-size: 19px; margin: 0 0 8px; }
p { margin: 0 0 8px; white-space: pre-line; }
ul { margin: 0 0 24px; padding-left: 20px; }
nav { margin-top: 28px; color: var(--muted); }
a { color: var(--accent); }
"""


def _page(title: str, sections: list[tuple[str, str]], summary: list[str] | None = None) -> str:
    items = "".join(f"<li>{escape(line)}</li>" for line in summary or [])
    body = "".join(f"<section><h2>{escape(t)}</h2><p>{escape(text)}</p></section>" for t, text in sections)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)} · Aisle</title><style>{_STYLE}</style></head>
<body><main><h1>{escape(title)}</h1><p class="date">Effective {EFFECTIVE_DATE}</p>
{f"<ul>{items}</ul>" if items else ""}{body}
<nav><a href="/terms">Terms of Service</a> · <a href="/privacy">Privacy Policy</a> · <a href="/support">Support</a></nav>
</main></body></html>"""


def terms_page() -> str:
    return _page("Terms of Service", TERMS)


def privacy_page() -> str:
    return _page("Privacy Policy", PRIVACY, SUMMARY)


def support_page() -> str:
    return _page("Aisle Support", SUPPORT)
