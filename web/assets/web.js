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
