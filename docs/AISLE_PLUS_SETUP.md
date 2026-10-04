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

- The server runs on Heroku over HTTPS (done).
- **Server notifications (required):** App Store Connect → the app → App Information →
  App Store Server Notifications. Set both the Production and Sandbox URLs to
  `https://aisle-api-db30672cd6aa.herokuapp.com/plus/notifications`, Version 2. That's
  how the server learns about refunds, lapses and renewals even if the app is never opened
  again. Without it a refunded subscription keeps working until it would have expired.
- **Privacy policy, terms and support URLs:** the server serves them at `/privacy`,
  `/terms` and `/support` on the same address. Enter those in the app's App Store listing
  (or host the same text on shopaisle.app and use those URLs). Subscriptions use Apple's
  standard EULA; link it in the description.
- **Sign in with Apple key (required for account deletion):** Certificates, Identifiers &
  Profiles → Keys → + → Sign in with Apple (primary App ID `app.shopaisle.aisle`). Download
  the .p8 once, then set `APPLE_TEAM_ID=983N58VUTZ`, `APPLE_SIGNIN_KEY_ID` (the key's ID)
  and `APPLE_SIGNIN_PRIVATE_KEY` (the file's contents) on Heroku. Apple requires apps to
  revoke a user's Apple sign-in when they delete their account; without the key the server
  can't.
