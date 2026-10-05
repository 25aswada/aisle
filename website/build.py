"""Builds shopaisle.app into website/public/.

The Terms, Privacy Policy and support answers come from backend/app/legal.py, the same
text the server and the app use, so the website never drifts from them.
Run: python3 website/build.py
"""
from __future__ import annotations

import importlib.util
import json
import re
import shutil
from html import escape
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = HERE / "public"
ICONS = ROOT / "ios/Aisle/Assets.xcassets/ItemIcons"

spec = importlib.util.spec_from_file_location("legal", ROOT / "backend/app/legal.py")
legal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legal)

DOMAIN = "shopaisle.app"
EMAIL = legal.CONTACT_EMAIL
DESC = "Ask for any item and Aisle tells you the aisle. Snap a photo, sort your list by department, and walk straight to what you need."


def ic(d: str, size: int = 20, w: float = 2) -> str:
    return (f'<svg class="icon" width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
            f'stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{d}</svg>')


CHECK = '<path d="M5 12l5 5L20 7"></path>'
SEARCH = '<circle cx="11" cy="11" r="7"></circle><path d="M20 20l-3.5-3.5"></path>'
UP = '<path d="M12 19V5M6 11l6-6 6 6"></path>'
CAMERA = '<path d="M4 8h3l2-3h6l2 3h3v11H4z"></path><circle cx="12" cy="13" r="3.5"></circle>'
PHONE = '<rect x="7" y="2" width="10" height="20" rx="2.5"></rect><path d="M11 18h2"></path>'
ARROW = '<path d="M5 12h14M13 6l6 6-6 6"></path>'


def icon_img(slug: str, size: int, extra: str = "") -> str:
    return f'<img src="/assets/icons/{slug}.png" alt="" width="{size}" height="{size}" {extra}>'


def soon(small: bool = False) -> str:
    return f'<span class="soon{" small" if small else ""}">{ic(PHONE, 17 if small else 19)}Coming soon to iPhone</span>'


def header(active: str = "") -> str:
    links = [("How it works", "/#how"), ("Aisle+", "/#pricing"), ("Privacy", "/privacy/"), ("Terms", "/terms/"), ("Support", "/support/")]
    cur = ' aria-current="page"'
    nav = "".join(f'<a href="{h}"{cur if t == active else ""}>{t}</a>' for t, h in links)
    return f'''<header class="top"><div class="wrap">
  <a class="brand" href="/" aria-label="Aisle home"><img src="/assets/logo.png" alt="" width="30" height="30"><span aria-hidden="true">aisle</span></a>
  <nav class="links" aria-label="Main">{nav}</nav>
  {soon(True)}
  <button class="menu" type="button" aria-label="Menu" aria-expanded="false">{ic('<path d="M4 7h16M4 12h16M4 17h16"></path>', 18)}</button>
</div></header>'''


def footer() -> str:
    return f'''<footer><div class="wrap">
  <div class="cols">
    <div class="about"><a class="brand" href="/"><img src="/assets/logo.png" alt="" width="28" height="28">aisle</a><span>Find anything inside any store.</span></div>
    <div class="lists">
      <div><b>Product</b><a href="/#how">How it works</a><a href="/#pricing">Aisle+</a><a href="/support/">FAQ</a></div>
      <div><b>Legal</b><a href="/privacy/">Privacy Policy</a><a href="/terms/">Terms of Service</a></div>
      <div><b>Help</b><a href="/support/">Support</a><a href="mailto:{EMAIL}">{EMAIL}</a></div>
    </div>
  </div>
  <div class="legal"><span>© 2026 Aisle. All rights reserved.</span><span>Aisle isn’t affiliated with the stores it covers. Store names and logos belong to their owners.</span></div>
</div></footer>'''


def page(title: str, path: str, body: str, desc: str = DESC, active: str = "", index: bool = True) -> str:
    url = f"https://{DOMAIN}{path}"
    robots = "" if index else '<meta name="robots" content="noindex">\n'
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)}</title>
<meta name="description" content="{escape(desc)}">
{robots}<link rel="canonical" href="{url}">
<meta property="og:title" content="{escape(title)}">
<meta property="og:description" content="{escape(desc)}">
<meta property="og:url" content="{url}">
<meta property="og:type" content="website">
<meta name="theme-color" content="#F5F5F2">
<link rel="icon" href="/assets/favicon.png" type="image/png">
<link rel="apple-touch-icon" href="/assets/favicon.png">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/assets/site.css">
</head>
<body>
{header(active)}
<main>
{body}
</main>
{footer()}
<script src="/assets/demo.js" defer></script>
</body>
</html>
'''


OFF = ' class="off"'


def qty(q: str) -> str:
    return f'<span class="qty">{q}</span>' if q else ""


def bars(level: int, h: int = 14) -> str:
    hs = [round(h * .43), round(h * .71), h]
    return '<span class="bars" style="height:%dpx">' % h + "".join(
        f'<i style="height:{x}px"{OFF if i >= level else ""}></i>' for i, x in enumerate(hs)) + "</span>"


# ---------------- home ----------------
def phone() -> str:
    tab = lambda d: f"<span>{ic(d, 16)}</span>"
    return f'''<div class="phone" role="img" aria-label="The Aisle app finding sunscreen in Aisle 12">
  <div class="screen" aria-hidden="true">
    <span class="island"></span><div class="status"><span>9:41</span><span>●●● ▮</span></div>
    <div class="app" id="demo">
      <span class="brand"><img src="/assets/logo.png" alt="" width="22" height="22">aisle</span>
      <span class="storerow"><span class="storelogo">F</span><span style="display:flex;flex-direction:column"><span style="font-size:10px;color:var(--sec)">You’re shopping at</span><span style="font-size:13px;font-weight:700">Fairfield Market ⌄</span></span></span>
      <div class="field">{ic(SEARCH, 15, 2.2)}<span class="t"></span><span class="send">{ic(UP, 14, 2.4)}</span></div>
      <div class="area" style="display:flex;flex-direction:column;gap:14px"></div>
    </div>
    <div class="tabs">{tab(SEARCH)}{tab('<path d="M10 6h10M10 12h10M10 18h10"></path><path d="M4 6l1 1 2-2M4 12l1 1 2-2M4 18l1 1 2-2"></path>')}{tab('<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"></path>')}{tab('<circle cx="12" cy="8" r="4"></circle><path d="M4 21a8 8 0 0 1 16 0"></path>')}</div>
  </div>
</div>'''


def home() -> str:
    mini = "".join(f'<div class="mini"><span class="ring"></span>{icon_img(s, 22)}<span style="flex:1">{t}</span><span class="sec" style="font-size:12px">{d}</span></div>'
                   for s, t, d in [("glass-of-milk", "Oat milk", "Dairy"), ("bread", "Sourdough", "Bakery"), ("battery", "AA batteries", "Electronics")])
    hero = f'''<div class="wrap hero">
  <div>
    <span class="pill"><b>New</b>An AI shopping companion for iPhone</span>
    <h1>Find anything<br>inside <span class="g">any store.</span></h1>
    <p class="lede">{DESC}</p>
    <div class="ctas">{soon()}<a class="ghostbtn" href="#how">See how it works {ic('<path d="M12 5v14M6 13l6 6 6-6"></path>', 16, 2.2)}</a></div>
    <div class="checks"><span>{ic(CHECK, 16, 2.4)}Free to use</span><span>{ic(CHECK, 16, 2.4)}No ads, ever</span><span>{ic(CHECK, 16, 2.4)}Never sells your data</span></div>
  </div>
  <div class="stage">
    <div class="blob" aria-hidden="true"></div>
    <div class="phonewrap">{phone()}</div>
    <div class="float f1" aria-hidden="true"><div style="display:flex;align-items:center;gap:10px">{bars(3)}<span style="display:flex;flex-direction:column"><span class="sec" style="font-size:12px">Confirmed by shoppers</span><span style="font-size:15px;font-weight:700">Confident · Aisle 12</span></span></div></div>
    <div class="float f2" aria-hidden="true"><div style="display:flex;justify-content:space-between;align-items:baseline"><span style="font-size:15px;font-weight:700">Your list</span><span class="g" style="font-size:12px;font-weight:600">By department</span></div><div style="margin-top:6px">{mini}</div></div>
    <div class="float f3" aria-hidden="true"><div style="display:flex;align-items:center;gap:10px"><span style="color:var(--pink);display:flex">{ic(CAMERA, 20)}</span><span style="font-size:14px;font-weight:600">Snap it, find it</span></div></div>
  </div>
</div>'''

    store = lambda n, d, first: (f'<div style="display:flex;align-items:center;gap:10px;padding:10px 12px;border-radius:16px;background:{"#fff" if first else "rgba(255,255,255,.55)"};{"box-shadow:0 6px 16px rgba(31,27,36,.08)" if first else ""}">'
                                 f'<span class="storelogo" style="width:30px;height:30px;font-size:13px;{"" if first else "opacity:.6;background:#7A5C9E"}">{n[0]}</span><span style="flex:1;display:flex;flex-direction:column"><span style="font-size:13px;font-weight:600">{n}</span><span class="sec" style="font-size:11px">{d}</span></span>'
                                 + ('<span class="g" style="font-size:11px;font-weight:600">Nearest</span>' if first else '') + '</div>')
    art1 = f'<div style="width:100%;display:flex;flex-direction:column;gap:8px">{store("Fairfield Market", "0.3 mi · Chestnut St", True)}{store("Harbor Foods", "1.1 mi · Spring Garden", False)}</div>'
    chips = "".join(f'<span style="height:30px;padding:0 12px;border-radius:999px;background:rgba(255,255,255,.7);display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:600">{icon_img(s, 16)}{t}</span>'
                    for s, t in [("glass-of-milk", "oat milk"), ("birthday-cake", "candles"), ("bread", "bread")])
    art2 = f'''<div style="width:100%;display:flex;flex-direction:column;gap:10px"><div style="height:46px;display:flex;align-items:center;gap:8px;padding:0 6px 0 16px;border-radius:999px;background:#fff;box-shadow:0 6px 16px rgba(31,27,36,.08);font-size:15px">{ic(SEARCH, 16, 2.2)}<span style="flex:1;white-space:nowrap;overflow:hidden">where are the AA batteries?</span><span class="send">{ic(UP, 14, 2.4)}</span></div><div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap">{chips}</div></div>'''
    art3 = f'''<div class="hero-card" style="width:100%;animation:none"><span class="col"><small>Confident</small><span class="place" style="font-size:38px">Aisle 15</span><small>Electronics · Batteries</small></span>{icon_img("battery", 56)}</div>'''
    steps = "".join(f'<div class="card step"><div class="art">{a}</div><span class="num">{n}</span><h3>{t}</h3><p>{p}</p></div>' for n, t, p, a in [
        (1, "Pick your store", "Aisle finds stores near you, or search by name. It knows how each kind of store is laid out.", art1),
        (2, "Ask for anything", "Type it the way you’d ask a person, or snap a photo of the item.", art2),
        (3, "Walk straight there", "Get the aisle and department, with an honest read on how sure Aisle is.", art3)])

    groups = [("Dairy &amp; Eggs", [("glass-of-milk", "Oat milk", "2")]), ("Bakery", [("bread", "Sourdough", "")]),
              ("Party", [("birthday-cake", "Birthday candles", ""), ("battery", "AA batteries", "1 pack")])]
    gl = "".join(f'<div class="dept">{g}</div>' + "".join(
        f'<div class="li"><span class="ring"></span>{icon_img(s, 26)}<span>{t}</span>{qty(q)}</div>' for s, t, q in items) for g, items in groups)
    aisles = "".join(f'<rect x="{40 + i * 44}" y="40" width="24" height="120" rx="8"></rect>' for i in range(8))
    stops = "".join(f'<circle cx="{x}" cy="{y}" r="9" fill="#1F1B24"></circle><text x="{x}" y="{y + 4}" font-size="10" font-weight="700" fill="#fff" text-anchor="middle" font-family="Geist, sans-serif">{n}</text>'
                    for n, (x, y) in enumerate([(118, 100), (206, 100), (338, 60)], 1))
    route = f'''<svg width="100%" viewBox="0 0 420 200" style="margin-top:14px" aria-hidden="true"><defs><linearGradient id="rg" x1="0" x2="1"><stop offset="0" stop-color="#C4A6F2"></stop><stop offset=".5" stop-color="#F48FB8"></stop><stop offset="1" stop-color="#F2A673"></stop></linearGradient></defs><rect x="0" y="0" width="420" height="26" rx="9" fill="#EFF1EC"></rect><g fill="#EFF1EC">{aisles}</g><path d="M30 190 L30 175 L118 175 L118 30 L206 30 L206 175 L338 175 L338 30" fill="none" stroke="url(#rg)" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="2 9"></path>{stops}</svg>'''
    conf = "".join(f'<div style="background:{bg}">{bars(l)}{t}<em>{d}</em></div>' for l, t, d, bg in [
        (3, "Confident", "Confirmed spot", "var(--grad)"), (2, "Likely here", "From the layout", "var(--soft)"), (1, "Best guess", "Ask to be sure", "var(--fill)")])
    small = lambda d, t, p: f'<div class="card small"><span style="color:var(--pink);display:flex">{ic(d, 28, 1.8)}</span><h3>{t}</h3><p>{p}</p></div>'
    bento = f'''<div class="bento">
  <div class="card b-list"><h3>A list that sorts itself</h3><p>Paste a whole list. Aisle groups it by department so you never double back.</p>{gl}<div class="add">{ic('<path d="M12 5v14M5 12h14"></path>', 16, 2.2)}Add items or paste a whole list…</div></div>
  <div class="card b-route"><h3>Start Shopping</h3><p>The shortest walk through the store, stop by stop.</p>{route}</div>
  {small(CAMERA, "Photo search", "Don’t know the name? Snap it.")}
  {small('<circle cx="9" cy="8" r="3.5"></circle><circle cx="17" cy="9" r="2.5"></circle><path d="M2.5 19a6.5 6.5 0 0 1 13 0M15 14.5a5 5 0 0 1 6.5 4.5"></path>', "Shared lists", "The whole family, one list.")}
  <div class="card b-wide"><div><h3 style="font-size:30px">Honest about how sure it is</h3><p style="font-size:17px;line-height:1.55">Every answer shows its confidence. When shoppers confirm a spot, Aisle gets more certain. It never invents an aisle number that isn’t on file.</p></div><div class="conf">{conf}</div></div>
</div>'''

    trio = "".join(f'<div><span style="color:#F48FB8;display:flex">{ic(d, 22)}</span><h3>{t}</h3><p>{p}</p></div>' for d, t, p in [
        ('<path d="M12 3l7 3v6c0 4.5-3 8-7 9-4-1-7-4.5-7-9V6z"></path>', "No ads. No data selling.", "We don’t sell your information, share it for advertising, or use it to train other companies’ AI."),
        ('<path d="M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21z"></path><circle cx="12" cy="9.5" r="2.5"></circle>', "Location for one request", "Rounded to about a city block, used to find stores near you, and not saved to your account."),
        (PHONE, "Your lists live on your phone", "Unless you share one. Delete your account anytime from the You tab.")])

    plan = lambda name, price, per, sub, items, plus: f'''<div class="plan{" plus" if plus else ""}">{'<span class="tag">7-day free trial on yearly</span>' if plus else ''}
  <span style="font-size:20px;font-weight:700">{name}</span>
  <div class="price"><b>{price}</b><span class="sec">{per}</span></div><span class="sec" style="font-size:14px">{sub}</span>
  <ul>{"".join(f'<li><span style="display:flex;color:{"var(--pink)" if plus else "var(--sec)"}">{ic(CHECK, 18, 2.6)}</span>{t}</li>' for t in items)}</ul></div>'''
    plans = plan("Free", "$0", "forever", "Everything you need for a quick run.",
                 ["Find items in any store", "A shopping list, sorted by department", "Start Shopping routes",
                  "5 searches a day", "1 photo search a day", "1 follow-up question per search"], False) + \
        plan("Aisle+", "$5.99", "/ month", "or $39.99 a year · billed by Apple, cancel anytime",
             ["Unlimited search and follow-ups", "Shared family lists", "Unlimited lists", "Multi-store trips", "Offline store maps"], True)

    faqs = [("Which stores does Aisle work in?", "Grocery, pharmacy, big-box and hardware stores you can find on the map. Aisle uses what it knows about each store and tells you how sure it is."),
            ("How does Aisle know where things are?", "From store data where it has it, shoppers’ confirmations like “Found it”, typical layouts for each kind of store, and AI estimates. Confirmed spots count most."),
            ("Do I need an account?", "Yes, a free one. Sign in with Apple, Google, your email or your phone number."),
            ("How do I cancel Aisle+?", "Open Settings on your iPhone, tap your name, then Subscriptions. You keep Aisle+ until the end of the period you paid for.")]
    faq = "".join(f'<details><summary>{q}</summary><p>{a}</p></details>' for q, a in faqs)

    body = f'''{hero}
<section class="block" id="how"><div class="wrap">
  <span class="eyebrow g">How it works</span>
  <h2 class="h2" style="margin-top:10px">Three taps from<br>“where is it?” to “got it.”</h2>
  <div class="steps">{steps}</div>
</div></section>
<section class="block" style="padding-top:20px"><div class="wrap">
  <span class="eyebrow g">Everything in one place</span>
  <h2 class="h2" style="margin-top:10px">Less wandering.<br>More done.</h2>
  {bento}
</div></section>
<section class="dark"><div class="glow" aria-hidden="true"></div><div class="wrap">
  <span class="eyebrow g">Privacy, plainly</span>
  <h2 class="h2" style="margin-top:10px">Built to help you shop.<br>Not to watch you shop.</h2>
  <div class="trio">{trio}</div>
  <a class="more" href="/privacy/">Read the privacy policy {ic(ARROW, 16, 2.2)}</a>
</div></section>
<section class="block" id="pricing"><div class="wrap">
  <div style="text-align:center"><span class="eyebrow g">Pricing</span><h2 class="h2" style="margin-top:10px">Free to find. Plus for more.</h2></div>
  <div class="plans">{plans}</div>
  <p class="sec" style="text-align:center;font-size:13px;margin:22px 0 0">Prices in US dollars. The price for your country is shown in the app before you buy.</p>
</div></section>
<section class="block" style="padding-top:20px"><div class="wrap">
  <h2 class="h2" style="font-size:44px">Questions</h2>
  <div class="faq">{faq}</div>
</div></section>
<div class="wrap"><div class="cta">
  <img class="wm" src="/assets/logo.png" alt="" aria-hidden="true">
  <h2>Your next errand,<br>a little shorter.</h2>
  <div class="row">{soon()}<a href="mailto:{EMAIL}">Questions? {EMAIL}</a></div>
</div></div>'''
    return page("Aisle — Find anything inside any store", "/", body)


# ---------------- legal ----------------
def slug(t: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", t.lower()).strip("-")


def fmt(text: str) -> str:
    lines = [l for l in text.split("\n") if l.strip()]
    linkify = lambda s: escape(s).replace(EMAIL, f'<a href="mailto:{EMAIL}">{EMAIL}</a>')
    if all(l.startswith("•") for l in lines):
        return "<ul>" + "".join(f"<li><span>{linkify(l[1:].strip())}</span></li>" for l in lines) + "</ul>"
    return "".join(f"<p>{linkify(l)}</p>" for l in lines)


def doc(kind: str) -> str:
    secs = legal.PRIVACY if kind == "privacy" else legal.TERMS
    title = "Privacy Policy" if kind == "privacy" else "Terms of Service"
    first, rest = title.split(" ", 1)
    lede = ("What Aisle collects, why, and what it never does, written so you can actually read it."
            if kind == "privacy" else "The rules for using Aisle and Aisle+, in plain English.")
    summary = ""
    if kind == "privacy":
        summary = '<div class="summary">' + "".join(f"<div>{ic(CHECK, 22, 2.6)}<div>{escape(s)}</div></div>" for s in legal.SUMMARY) + "</div>"
    toc = "".join(f'<a href="#{slug(t)}">{escape(t)}</a>' for t, _ in secs)
    article = "".join(f'<section id="{slug(t)}"><h2>{escape(t)}</h2><div class="body">{fmt(b)}</div></section>' for t, b in secs)
    body = f'''<div class="wrap dochead"><span class="date">Effective {legal.EFFECTIVE_DATE}</span>
  <h1>{first} <span class="g">{rest}</span></h1><p>{lede}</p>{summary}</div>
<div class="wrap doc">
  <aside class="toc"><nav aria-label="On this page"><span>On this page</span>{toc}</nav>
    <div class="ask"><b>Questions?</b>Email <a href="mailto:{EMAIL}" style="color:var(--ink);font-weight:600">{EMAIL}</a>.</div></aside>
  <article>{article}</article>
</div>'''
    return page(f"{title} · Aisle", f"/{kind}/", body, f"Aisle’s {title}.", "Privacy" if kind == "privacy" else "Terms")


def support() -> str:
    cards = [('<path d="M4 6h16v12H4z"></path><path d="M4 7l8 6 8-6"></path>', "Email us", f'<a href="mailto:{EMAIL}">{EMAIL}</a>', "We get back to you within two business days."),
             ('<path d="M3 12a9 9 0 1 0 3-6.7L3 8"></path><path d="M3 3v5h5"></path>', "Cancel or manage Aisle+", "Settings → your name → Subscriptions", 'Apple handles billing. For a refund, visit <a href="https://reportaproblem.apple.com" style="color:var(--pink);font-weight:600">reportaproblem.apple.com</a>.'),
             ('<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"></path>', "Delete your account", "You tab → Delete account", "Deletes your name, contact details and sign-in records.")]
    c = "".join(f'<div class="card">{ic(d, 28, 1.8)}<h3>{t}</h3><b>{v}</b><p>{p}</p></div>' for d, t, v, p in cards)
    extra = [("Aisle sent me to the wrong spot.", "Tap “Not here” on the answer, and tell Aisle where it actually was if you can. When shoppers agree, the answer updates for everyone."),
             ("My store isn’t showing up.", f"Search for it by name or address in the store picker. If it still isn’t there, email {EMAIL} with the store’s address."),
             ("I didn’t get my sign-in code.", "Codes can take a minute. Check your spam folder for codes@shopaisle.app, or sign in with your phone number, Apple or Google instead.")]
    qa = [(t, b) for t, b in legal.SUPPORT if t != "Get help"] + extra
    faq = "".join(f'<details{" open" if i < 2 else ""}><summary>{escape(q)}</summary><p>{escape(a)}</p></details>' for i, (q, a) in enumerate(qa))
    body = f'''<div class="wrap dochead" style="padding-bottom:100px">
  <h1>How can we <span class="g">help?</span></h1><p>Answers to common questions, and a real person at {EMAIL}.</p>
  <div class="helpcards">{c}</div>
  <h2 class="h2" style="font-size:36px;margin-top:64px">Common questions</h2>
  <div class="faq" style="margin-top:24px">{faq}</div>
</div>'''
    return page("Support · Aisle", "/support/", body, "Help with Aisle and Aisle+.", "Support")


def join() -> str:
    """/join/CODE, a shared-list invite opened without Aisle (with it, iOS opens the app
    instead; see APP_SITE_ASSOCIATION). vercel.json sends every /join/CODE here, and the
    page reads the code from the address to show it."""
    cards = [(PHONE, "Get Aisle", "Coming soon to iPhone", "Aisle is free, and so is joining a shared list."),
             ('<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"></path><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"></path>',
              "Tap the invite again", "On your iPhone", "With Aisle installed, the link opens the list in the app."),
             ('<path d="M4 7h16M4 12h16M4 17h10"></path>', "Or enter the code", "List → ••• → Join a shared list",
              "Type the invite code, shown above.")]
    c = "".join(f'<div class="card">{ic(d, 28, 1.8)}<h3>{t}</h3><b>{v}</b><p>{p}</p></div>' for d, t, v, p in cards)
    body = f'''<div class="wrap dochead" style="padding-bottom:100px">
  <span class="date">Shared list invite</span>
  <h1>You’re invited to <span class="g">a shared list.</span></h1>
  <p>Someone wants to shop with you in Aisle. Everyone on the list sees what’s added and checked off, as it happens.</p>
  <div class="card" id="invite" hidden style="margin-top:36px;max-width:420px;text-align:center">
    <span class="sec" style="font-size:14px;font-weight:600">Invite code</span>
    <b id="code" class="g" style="display:block;margin-top:6px;font-size:40px;letter-spacing:.12em;font-family:ui-monospace,SFMono-Regular,Menlo,monospace"></b>
  </div>
  <div class="helpcards">{c}</div>
</div>
<script>
(function () {{
  var m = location.pathname.match(/^[/]join[/]([A-Za-z0-9]{{4,20}})[/]?$/);
  if (!m) return;
  var code = m[1].toUpperCase();
  document.getElementById('code').textContent = code.length === 8 ? code.slice(0, 4) + ' ' + code.slice(4) : code;
  document.getElementById('invite').hidden = false;
}})();
</script>'''
    return page("Join a shared list · Aisle", "/join/", body, "Open a shared Aisle list.", index=False)


# Universal links: with Aisle installed, iOS opens https://shopaisle.app/join/CODE in the app.
APP_SITE_ASSOCIATION = {"applinks": {"details": [{
    "appIDs": ["983N58VUTZ.app.shopaisle.aisle"],
    "components": [{"/": "/join/*", "comment": "Shared-list invites"}],
}]}}


def notfound() -> str:
    body = f'''<div class="wrap dochead" style="padding:120px 24px 160px;text-align:center"><h1>Not in <span class="g">this aisle.</span></h1>
<p style="margin:18px auto 0">That page doesn’t exist. Try the <a href="/" style="font-weight:600">home page</a> or <a href="/support/" style="font-weight:600">support</a>.</p></div>'''
    return page("Page not found · Aisle", "/404", body)


def main() -> None:
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "assets/icons").mkdir(parents=True)
    shutil.copy(HERE / "site.css", OUT / "assets/site.css")
    shutil.copy(HERE / "demo.js", OUT / "assets/demo.js")
    logo = ROOT / "ios/Aisle/Assets.xcassets/AisleLogo.imageset/aisle-logo.png"
    shutil.copy(logo, OUT / "assets/logo.png")
    shutil.copy(HERE / "favicon.png", OUT / "assets/favicon.png")
    for s in ["lotion-bottle", "glass-of-milk", "birthday-cake", "battery", "bread"]:
        shutil.copy(ICONS / f"{s}.imageset/{s}.png", OUT / f"assets/icons/{s}.png")
    pages = {"index.html": home(), "privacy/index.html": doc("privacy"), "terms/index.html": doc("terms"),
             "support/index.html": support(), "join/index.html": join(), "404.html": notfound()}
    for path, html in pages.items():
        target = OUT / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(html, encoding="utf-8")
    # Apple fetches /.well-known/apple-app-site-association (no extension); saved as .json so
    # Vercel serves it as JSON, and vercel.json rewrites Apple's path to it without a redirect.
    (OUT / ".well-known").mkdir()
    (OUT / ".well-known/apple-app-site-association.json").write_text(json.dumps(APP_SITE_ASSOCIATION, indent=2) + "\n")
    (OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: https://{DOMAIN}/sitemap.xml\n")
    urls = "".join(f"<url><loc>https://{DOMAIN}{p}</loc></url>" for p in ["/", "/privacy/", "/terms/", "/support/"])
    (OUT / "sitemap.xml").write_text(f'<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{urls}</urlset>\n')
    print(f"Built {len(pages)} pages into {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
