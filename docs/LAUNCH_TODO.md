# Launch to-do

Where Aisle stands after submitting 1.0.0 (build 2) to App Review on October 5, 2026, and
what's next. Check items off as they're done.

## Now: App Review
- [ ] Wait for review (usually 1–2 days). If Apple sends feedback or a rejection, fix and resubmit with build 3 or higher.
- [ ] Watch the Paid Apps Agreement turn **Active** (Business tab), once the bank account clears. Subscriptions can't be bought until it does.
- [ ] Release is set to automatic after approval. Switch it to manual on the 1.0.0 page if you want to pick the launch moment.
- [ ] Keep Heroku (`aisle-api`) and shopaisle.app up during review.
- [ ] Close the GitHub Support ticket about the Pages certificate (no longer needed).

## Before marketing
- [ ] OpenAI billing: turn on auto-recharge and a low-balance alert. $45 covers roughly 90k–130k AI answers.
- [ ] Raise `AISLE_AI_BUDGET_USD_PER_DAY` on Heroku before a big push (it's $25 a day; free users stop at 70% of it).
- [ ] Shared AI answer cache in the database, so repeated searches (same item, same chain) don't each pay for a call. Cuts free-user AI cost by about half or more.
- [ ] Paywall timing: show Aisle+ at the moment of need (daily limit hit, follow-up asked) and lead with the 7-day trial. Target 5%+ conversion.
- [ ] Test prices of $7.99/month and $49.99/year. The current yearly discount (44%) is steep.
- [ ] Paywall wording: drop "Unlimited" for photo search and follow-ups (Aisle+ caps them at 50 and 100 a day), and lead the yearly headline with the billed price ($39.99) rather than $3.33/mo. Both are App Review risks.
- [ ] Move shopaisle.app off Vercel Hobby (non-commercial only) to Cloudflare Pages or GitHub Pages, or pay for Vercel Pro.
- [ ] Ad measurement: Apple Search Ads works with App Store Connect alone. TikTok or Meta ads need their SDK or a measurement partner, plus App Tracking Transparency and a privacy label update.

## Marketing
- [ ] UGC: film in-store "I asked where the X is and it walked me right to it" clips. Post 1–3 a day on TikTok, Reels and Shorts for 6–8 weeks, then double down on what works.
- [ ] Label AI-generated videos clearly; don't present them as real customer testimonials (FTC rules).
- [ ] Don't use store logos or branding in ads; naming a store in passing is fine.
- [ ] Ask happy users for ratings, which helps App Store search.
- [ ] Hold off on paid ads until real conversion and retention numbers are in; start with Apple Search Ads.
- [ ] After 3–4 weeks live, bring downloads, conversion and churn from App Store Connect back for a new estimate.

## Goals
- Break-even: about 460 monthly users, about 14 subscribers (costs are about $30 a month today).
- $1,000/month profit: about 18,000 monthly users as the app is today, or about 6,000 with the conversion, pricing and AI cache changes. Realistically 3–6 months of consistent UGC.

## Later
- [ ] Sign in with Apple key on Heroku (`APPLE_TEAM_ID`, `APPLE_SIGNIN_KEY_ID`, `APPLE_SIGNIN_PRIVATE_KEY`) and the server-to-server notification URL, so account deletion revokes Apple sign-in. Steps in `backend/README.md`.
- [ ] RevenueCat: add the App Store app in RevenueCat, put its `appl_` key in `AISLE_REVENUECAT_API_KEY` (`ios/project.yml`), upload an App Store Connect In-App Purchase key to RevenueCat, and add RevenueCat to the privacy policy and manifest.
- [ ] Billing grace period: handle `gracePeriodExpiresDate` on the server before turning it on in App Store Connect.
- [ ] Refunds without notifications: add an App Store Server API key and a periodic status check.
- [ ] Rate limits that still need attention from the audit: the global sign-in code cap (abuse and account probing), per-target lockout after repeated wrong codes, HMAC instead of SHA-256 for stored phone and code hashes.
- [ ] Expand beyond the US once there's store data for other countries.
- [ ] Other revenue (retailer partnerships, affiliate links, aggregated layout data) only with a privacy policy update first.
