# Turning on real Aisle+ payments

The app and server side of Aisle+ is built: StoreKit 2 purchase and restore, server-side
verification of every transaction, the free tier's limits, and every Aisle+ feature.
What's left happens in App Store Connect and needs the account holder.

## 1. Paid Apps Agreement (you, ~10 min)

App Store Connect → Business. The Paid Apps Agreement says **Pending User Info**:

- Add a bank account.
- Fill in the U.S. W-9 tax form.

Apple won't sell subscriptions, even in the sandbox, until it's **Active**.

## 2. The app record (one click)

Apps → + → New App, already filled in a Chrome tab: iOS, name **Aisle**, English (U.S.),
bundle ID `app.shopaisle.aisle`, SKU `aisle-ios`, Full Access. Click **Create**. If
"Aisle" is taken on the App Store, try "Aisle: Find It In Store".

## 3. The subscription group and the two plans

In the new app: Monetization → Subscriptions → Create a group named **Aisle+**, then
two auto-renewable subscriptions in it. The product IDs must match exactly:

| Reference name | Product ID | Duration | Price | Intro offer |
| --- | --- | --- | --- | --- |
| Aisle+ Yearly | `app.shopaisle.plus.yearly` | 1 year | $29.99 | Free trial, 1 week |
| Aisle+ Monthly | `app.shopaisle.plus.monthly` | 1 month | $3.99 | none |

Give each one a display name ("Aisle+ Yearly", "Aisle+ Monthly"), a description ("Unlimited
photo search and follow-ups, shared family lists, multi-store trips and offline store
maps."), and the review screenshot (a screenshot of the Aisle+ tab). Put yearly at a higher
level than monthly in the group so switching works as an upgrade.

## 4. Test with a sandbox account

Users and Access → Sandbox → Test Accounts → add one (any unused email). On the iPhone:
Settings → App Store → Sandbox Account → sign in with it. Then buy from the Aisle+ tab.
Sandbox renewals are fast (a year renews every hour).

Local testing without App Store Connect still works when running from Xcode: the scheme
uses `ios/Aisle/Aisle.storekit`, and the server accepts those purchases only with
`AISLE_PLUS_ALLOW_XCODE=true` in `backend/.env` (never in production).

## 5. Before launch

- The server must run somewhere public over HTTPS, not this Mac.
- App Store review needs a privacy policy URL and terms of use (EULA) for subscriptions,
  linked in the app's description. The Aisle+ page already shows Restore and the renewal terms.
- Optional: App Store Server Notifications V2 for instant refund/renewal updates. Today
  the app re-sends its current transactions on every launch and after each purchase,
  which covers renewals and refunds within a day.
