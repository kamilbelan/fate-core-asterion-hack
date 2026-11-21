/* Fate Core: Asterion Hack – web edition: navigation drawer and theme toggle.
 * The page works without this script: the navigation is then a section at the end of the page
 * (the "Obsah" link jumps to it) and the colours follow the system setting. */
(function () {
  "use strict";

  var root = document.documentElement;
  var THEME_KEY = "asterion-theme";

  /* ---- theme: auto -> light -> dark ---- */
  var THEMES = ["auto", "light", "dark"];
  var THEME_NAMES = { auto: "automatický (podle systému)", light: "světlý", dark: "tmavý" };
  var themeButton = document.getElementById("theme-button");
  var themeLabel = document.getElementById("theme-label");

  function currentTheme() {
    var t = root.getAttribute("data-theme");
    return THEMES.indexOf(t) > 0 ? t : "auto";
  }
  function showTheme(t) {
    var next = THEMES[(THEMES.indexOf(t) + 1) % THEMES.length];
    var text = "Barevný režim: " + THEME_NAMES[t] + ". Přepnout na " + THEME_NAMES[next] + ".";
    themeLabel.textContent = text;
    themeButton.title = "Barevný režim: " + THEME_NAMES[t];
  }
  function setTheme(t) {
    if (t === "auto") root.removeAttribute("data-theme");
    else root.setAttribute("data-theme", t);
    try {
      if (t === "auto") localStorage.removeItem(THEME_KEY);
      else localStorage.setItem(THEME_KEY, t);
    } catch (e) { /* storage blocked: the choice lasts for this page only */ }
    showTheme(t);
  }
  if (themeButton && themeLabel) {
    themeButton.hidden = false;
    showTheme(currentTheme());
    themeButton.addEventListener("click", function () {
      setTheme(THEMES[(THEMES.indexOf(currentTheme()) + 1) % THEMES.length]);
    });
  }

  /* ---- navigation ---- */
  var drawer = document.getElementById("navigace");
  var menuButton = document.getElementById("menu-button");
  var closeButton = document.getElementById("drawer-close");
  if (!drawer || !menuButton) return;

  // put this page's headings under the current chapter in the chapter list
  var toc = document.getElementById("page-toc");
  var current = drawer.querySelector('.book-nav a[aria-current="page"]');
  if (toc && current) current.parentNode.appendChild(toc);

  var wide = window.matchMedia("(min-width: 76rem)");   // persistent sidebar, see web.css
  var backdrop = document.createElement("div");
  backdrop.className = "drawer-backdrop";
  drawer.parentNode.insertBefore(backdrop, drawer);
  var outside = document.querySelectorAll("body > header, main, .pager, .site-footer, .skip-link");

  // switch to the overlay layout without animating the drawer out of its static place
  drawer.style.transition = "none";
  root.classList.add("has-drawer");
  void drawer.offsetWidth;
  drawer.style.transition = "";
  menuButton.hidden = false;
  if (closeButton) closeButton.hidden = false;

  // scroll the drawer (never the page) so that the current chapter is in view
  function showCurrent() {
    if (!current) return;
    var top = current.getBoundingClientRect().top - drawer.getBoundingClientRect().top + drawer.scrollTop;
    if (top > drawer.clientHeight * 0.6) drawer.scrollTop = top - drawer.clientHeight / 3;
  }

  function isOpen() { return root.classList.contains("drawer-open"); }

  function setOutsideInert(on) {
    for (var i = 0; i < outside.length; i++) {
      if (on) outside[i].setAttribute("inert", "");
      else outside[i].removeAttribute("inert");
    }
  }

  function open() {
    root.classList.add("drawer-open");
    menuButton.setAttribute("aria-expanded", "true");
    setOutsideInert(true);
    var target = drawer.querySelector('[aria-current="page"]') || closeButton;
    if (target) target.focus({ preventScroll: true });
    showCurrent();
  }

  function close(restoreFocus) {
    if (!isOpen()) return;
    root.classList.remove("drawer-open");
    menuButton.setAttribute("aria-expanded", "false");
    setOutsideInert(false);
    if (restoreFocus) menuButton.focus();
  }

  menuButton.addEventListener("click", function () {
    if (isOpen()) close(true); else open();
  });
  if (closeButton) closeButton.addEventListener("click", function () { close(true); });
  backdrop.addEventListener("click", function () { close(true); });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && isOpen()) close(true);
  });
  // following a link closes the drawer; focus then goes where the link points
  drawer.addEventListener("click", function (e) {
    if (e.target.closest && e.target.closest("a")) close(false);
  });
  // growing into the sidebar layout: drop the overlay state
  function onWideChange() { if (wide.matches) close(false); }
  if (wide.addEventListener) wide.addEventListener("change", onWideChange);
  else if (wide.addListener) wide.addListener(onWideChange);

  if (wide.matches) showCurrent();
})();

/* ---- full-text search -------------------------------------------------------------------
 * The index (assets/search.json, built by web/build.sh) is one entry per section and per box:
 * {p: page, c: chapter, a: anchor, t: title, x: text}. It is loaded the first time the search
 * opens. Matching ignores case and diacritics ("cit pro potize" finds "Cit pro potíže"); every
 * word must occur. Scope: the whole text, or only the chapter of this page. A result links to
 * its section with ?hl=<words>, and the words are highlighted on arrival. */
(function () {
  "use strict";

  var root = document.documentElement;
  var panel = document.getElementById("search");
  var button = document.getElementById("search-button");
  if (!panel || !button) return;
  var input = document.getElementById("search-input");
  var results = document.getElementById("search-results");
  var status = document.getElementById("search-status");
  var closeButton = document.getElementById("search-close");
  var scopes = panel.querySelectorAll('input[name="search-scope"]');
  var page = document.body.getAttribute("data-page") || "";
  var SCOPE_KEY = "asterion-search-scope";
  var MAX = 50;
  var index = null, loading = null, timer = null, active = -1;

  // "Tato kapitola" makes no sense on the contents page
  if (!page) for (var i = 0; i < scopes.length; i++) if (scopes[i].value === "page") scopes[i].disabled = true;
  try {
    var saved = localStorage.getItem(SCOPE_KEY);
    if (saved && page) for (var j = 0; j < scopes.length; j++) scopes[j].checked = scopes[j].value === saved;
  } catch (e) {}

  // lower case without diacritics; the text is precomposed (NFC), so positions stay aligned
  function norm(s) { return s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase(); }
  function words(q) { return norm(q).split(/\s+/).filter(function (w) { return w.length > 0; }); }
  function scope() {
    for (var i = 0; i < scopes.length; i++) if (scopes[i].checked) return scopes[i].value;
    return "all";
  }
  function esc(s) { return s.replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }

  function load() {
    if (index) return Promise.resolve(index);
    if (!loading) {
      status.textContent = "Načítám rejstřík…";
      loading = fetch("assets/search.json").then(function (r) {
        if (!r.ok) throw new Error(r.status);
        return r.json();
      }).then(function (data) {
        index = data.map(function (e) { e.nt = norm(e.t); e.nx = norm(e.x); return e; });
        return index;
      }).catch(function () {
        loading = null;
        status.textContent = "Rejstřík pro hledání se nepodařilo načíst.";
        throw new Error("search index");
      });
    }
    return loading;
  }

  // the original text around the first match, with all words highlighted
  function snippet(e, ws) {
    var at = -1;
    for (var i = 0; i < ws.length && at < 0; i++) at = e.nx.indexOf(ws[i]);
    var start = Math.max(0, at - 60), end = Math.min(e.x.length, (at < 0 ? 0 : at) + 140);
    if (start > 0) start = e.x.indexOf(" ", start) + 1 || start;
    return (start > 0 ? "… " : "") + highlight(e.x.slice(start, end), e.nx.slice(start, end), ws) + (end < e.x.length ? " …" : "");
  }
  function highlight(text, normText, ws) {
    var marks = [];
    ws.forEach(function (w) {
      for (var at = normText.indexOf(w); at >= 0; at = normText.indexOf(w, at + w.length)) marks.push([at, at + w.length]);
    });
    marks.sort(function (a, b) { return a[0] - b[0]; });
    var out = "", pos = 0;
    marks.forEach(function (m) {
      if (m[0] < pos) return;
      out += esc(text.slice(pos, m[0])) + "<mark>" + esc(text.slice(m[0], m[1])) + "</mark>";
      pos = m[1];
    });
    return out + esc(text.slice(pos));
  }

  function run() {
    var q = input.value.trim(), ws = words(q);
    results.innerHTML = ""; active = -1;
    if (!ws.length) { status.textContent = ""; return; }
    load().then(function (idx) {
      var here = scope() === "page";
      var found = [];
      idx.forEach(function (e) {
        if (here && e.p !== page) return;
        var score = 0;
        for (var i = 0; i < ws.length; i++) {
          var inTitle = e.nt.indexOf(ws[i]) >= 0, inText = e.nx.indexOf(ws[i]) >= 0;
          if (!inTitle && !inText) return;
          score += (inTitle ? 10 : 0) + (inText ? 1 : 0);
        }
        found.push({ e: e, score: score });
      });
      found.sort(function (a, b) { return b.score - a.score; });
      status.textContent = found.length
        ? (found.length > MAX ? "Zobrazeno " + MAX + " z " + found.length + " výsledků." : "Výsledků: " + found.length + ".")
        : "Nic nenalezeno" + (here ? " v této kapitole." : ".");
      var hl = "?hl=" + encodeURIComponent(q);
      found.slice(0, MAX).forEach(function (f) {
        var e = f.e, li = document.createElement("li");
        var href = e.p + ".html" + hl + (e.a ? "#" + encodeURIComponent(e.a) : "");
        li.innerHTML = '<a href="' + esc(href) + '"><span class="search__title">' + highlight(e.t, e.nt, ws) + "</span>"
          + (here ? "" : '<span class="search__chapter">' + esc(e.c) + "</span>")
          + '<span class="search__snippet">' + snippet(e, ws) + "</span></a>";
        results.appendChild(li);
      });
    }).catch(function () {});
  }

  function links() { return results.querySelectorAll("a"); }
  function setActive(n) {
    var ls = links();
    if (!ls.length) return;
    if (active >= 0 && ls[active]) ls[active].classList.remove("is-active");
    active = (n + ls.length) % ls.length;
    ls[active].classList.add("is-active");
    ls[active].scrollIntoView({ block: "nearest" });
  }

  function open() {
    panel.hidden = false;
    root.classList.add("search-open");
    button.setAttribute("aria-expanded", "true");
    input.focus();
    input.select();
    load().catch(function () {});
  }
  function close() {
    if (panel.hidden) return;
    panel.hidden = true;
    root.classList.remove("search-open");
    button.setAttribute("aria-expanded", "false");
    button.focus();
  }

  button.hidden = false;
  button.addEventListener("click", open);
  closeButton.addEventListener("click", close);
  panel.addEventListener("click", function (e) { if (e.target === panel) close(); });   // backdrop
  input.addEventListener("input", function () { clearTimeout(timer); timer = setTimeout(run, 120); });
  for (var k = 0; k < scopes.length; k++) scopes[k].addEventListener("change", function () {
    try { localStorage.setItem(SCOPE_KEY, scope()); } catch (e) {}
    run();
    input.focus();
  });
  input.addEventListener("keydown", function (e) {
    if (e.key === "ArrowDown") { e.preventDefault(); setActive(active + 1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setActive(active - 1); }
    else if (e.key === "Enter") {
      var ls = links();
      if (ls.length) { e.preventDefault(); (ls[active >= 0 ? active : 0]).click(); }
    }
  });
  // a result on this very page only changes the hash: close the panel and highlight
  results.addEventListener("click", function (e) {
    var a = e.target.closest && e.target.closest("a");
    if (!a) return;
    var url = new URL(a.href, location.href);
    if (url.pathname === location.pathname) {
      e.preventDefault();
      close();
      history.replaceState(null, "", url.search + url.hash);
      markWords(url.searchParams.get("hl"));
      var target = url.hash && document.getElementById(decodeURIComponent(url.hash.slice(1)));
      (target || document.querySelector(".search-hit") || document.body).scrollIntoView();
    }
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && !panel.hidden) { close(); return; }
    var t = e.target, typing = t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));
    if (e.key === "/" && !typing && panel.hidden) { e.preventDefault(); open(); }
  });

  // ---- highlight the searched words on arrival (?hl=…) ----
  function markWords(q) {
    var old = document.querySelectorAll("mark.search-hit");
    for (var i = 0; i < old.length; i++) old[i].replaceWith(document.createTextNode(old[i].textContent));
    var main = document.getElementById("text");
    var ws = q ? words(q) : [];
    if (!main || !ws.length) return;
    main.normalize();
    // the whole phrase if it occurs ("cit pro potize"), otherwise the single words from 3 letters
    // up; either only at the start of a word, so "pro" does not light up inside "protivník"
    var phrase = ws.join(" ");
    if (ws.length > 1 && norm(main.textContent).indexOf(phrase) >= 0) ws = [phrase];
    else ws = ws.filter(function (w) { return w.length > 2; });
    if (!ws.length) return;
    var letter = /[\p{L}\p{N}]/u;
    var walker = document.createTreeWalker(main, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        return n.parentNode.closest("script, style, .sidenote-number") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      }
    });
    var nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(function (node) {
      var text = node.nodeValue, nt = norm(text), hits = [];
      ws.forEach(function (w) {
        for (var at = nt.indexOf(w); at >= 0; at = nt.indexOf(w, at + w.length)) {
          if (at > 0 && letter.test(nt.charAt(at - 1))) continue;          // inside a word
          hits.push([at, at + w.length]);
        }
      });
      if (!hits.length) return;
      hits.sort(function (a, b) { return a[0] - b[0]; });
      var frag = document.createDocumentFragment(), pos = 0;
      hits.forEach(function (h) {
        if (h[0] < pos) return;
        frag.appendChild(document.createTextNode(text.slice(pos, h[0])));
        var m = document.createElement("mark");
        m.className = "search-hit";
        m.textContent = text.slice(h[0], h[1]);
        frag.appendChild(m);
        pos = h[1];
      });
      frag.appendChild(document.createTextNode(text.slice(pos)));
      node.parentNode.replaceChild(frag, node);
    });
  }
  var hl = new URLSearchParams(location.search).get("hl");
  if (hl) markWords(hl);
  // The browser jumps to #target before the web fonts are in; their swap (and the marks) move
  // the text, so scroll again once the fonts are ready: to the target, or to the first hit.
  if (location.hash || hl) {
    (document.fonts && document.fonts.ready ? document.fonts.ready : Promise.resolve()).then(function () {
      var target = location.hash && document.getElementById(decodeURIComponent(location.hash.slice(1)));
      if (target) target.scrollIntoView();
      else if (hl) { var first = document.querySelector(".search-hit"); if (first) first.scrollIntoView({ block: "center" }); }
    });
  }
})();
