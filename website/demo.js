// Header shadow, mobile menu, and the looping phone demo on the home page.
(function () {
  var top = document.querySelector('.top');
  if (top) {
    var onScroll = function () { top.classList.toggle('scrolled', window.scrollY > 8); };
    window.addEventListener('scroll', onScroll, { passive: true }); onScroll();
  }
  var menu = document.querySelector('.menu'), links = document.querySelector('.links');
  if (menu && links) menu.addEventListener('click', function () {
    var open = links.classList.toggle('open'); menu.setAttribute('aria-expanded', open ? 'true' : 'false');
  });

  // Highlight the section you're reading in the legal pages' contents.
  var toc = document.querySelectorAll('.toc nav a');
  if (toc.length && 'IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        toc.forEach(function (a) { a.classList.toggle('on', a.getAttribute('href') === '#' + e.target.id); });
      });
    }, { rootMargin: '-20% 0px -70% 0px' });
    document.querySelectorAll('article section[id]').forEach(function (s) { io.observe(s); });
  }

  var app = document.getElementById('demo');
  if (!app) return;
  var DEMO = [
    { q: 'sunscreen', icon: '/assets/icons/lotion-bottle.png', place: 'Aisle 12', detail: 'Sun care · Health & Beauty', level: 3, reply: 'Found it! Sunscreen is in Aisle 12, with sun care.' },
    { q: 'oat milk', icon: '/assets/icons/glass-of-milk.png', place: 'Dairy', detail: 'Back wall · No aisle number on file', level: 2, reply: 'Oat milk is usually along the back wall, in dairy.' },
    { q: 'birthday candles', icon: '/assets/icons/birthday-cake.png', place: 'Aisle 8', detail: 'Baking · Party supplies', level: 3, reply: 'Found it! Birthday candles are in Aisle 8, with baking.' }
  ];
  var LABEL = { 3: 'Confident', 2: 'Likely here', 1: 'Best guess' };
  var typed = app.querySelector('.t'), area = app.querySelector('.area');
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var timers = [];
  function later(fn, ms) { timers.push(setTimeout(fn, ms)); }
  function esc(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;'); }
  function bars(l) { return '<span class="bars" style="height:10px">' + [6, 8, 10].map(function (h, i) { return '<i style="width:3px;height:' + h + 'px" class="' + (i < l ? '' : 'off') + '"></i>'; }).join('') + '</span>'; }
  function answer(d) {
    return '<div class="bubble">' + esc(d.q) + '</div><div class="answer"><p>' + esc(d.reply) + '</p>' +
      '<div class="hero-card' + (d.level === 3 ? '' : ' mid') + '"><span class="col"><small style="display:flex;align-items:center;gap:6px">' + bars(d.level) + LABEL[d.level] + '</small>' +
      '<span class="place">' + esc(d.place) + '</span><small>' + esc(d.detail) + '</small></span>' +
      '<img src="' + d.icon + '" alt="" width="52" height="52"></div></div>';
  }
  function run(i) {
    var d = DEMO[i];
    if (reduce) { typed.textContent = ''; area.innerHTML = answer(d); return; }
    var n = 0; area.innerHTML = '';
    typed.innerHTML = '<span class="caret"></span>';
    var typer = setInterval(function () {
      n++; typed.innerHTML = esc(d.q.slice(0, n)) + '<span class="caret"></span>';
      if (n >= d.q.length) clearInterval(typer);
    }, 70);
    var t0 = d.q.length * 70 + 400;
    var statuses = ['Reading “' + d.q + '”', 'Checking the store’s layout', 'Finding the aisle'];
    later(function () {
      typed.textContent = '';
      area.innerHTML = '<div class="bubble">' + esc(d.q) + '</div><div class="ghost"><span class="col">' +
        '<span style="display:flex;align-items:center;gap:7px;height:16px"><span class="mark"></span><span class="shim">' + statuses[0] + '</span></span>' +
        '<span class="skel" style="width:120px;height:30px;border-radius:9px"></span><span class="skel" style="width:92px;height:10px;border-radius:5px"></span></span>' +
        '<img src="' + d.icon + '" alt="" width="50" height="50" style="animation:breathe 2.2s ease-in-out infinite"></div>';
    }, t0);
    later(function () { var s = area.querySelector('.shim'); if (s) s.textContent = statuses[1]; }, t0 + 900);
    later(function () { var s = area.querySelector('.shim'); if (s) s.textContent = statuses[2]; }, t0 + 1800);
    later(function () { area.innerHTML = answer(d); }, t0 + 2500);
    later(function () { run((i + 1) % DEMO.length); }, t0 + 6200);
  }
  run(0);
})();
