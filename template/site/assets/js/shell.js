// The shell: the colour scheme toggle, the menu below 768 px and --header-h, the height of the sticky header that
// the cart and the matrix container are placed against. The has-js class is set by the inline script of head.html.
// Without JavaScript the system setting decides the colour scheme (the prefers-color-scheme block of site.css), the
// navigation is shown in full and --header-h keeps its value of site.css.
(function () {
  'use strict';

  var html = document.documentElement;
  var key = 'rulebook-theme';
  var media = window.matchMedia('(prefers-color-scheme: dark)');

  function isDark() {
    return html.dataset.theme ? html.dataset.theme === 'dark' : media.matches;
  }

  var toggle = document.querySelector('.theme-toggle');
  if (toggle) {
    var sync = function () { toggle.setAttribute('aria-pressed', String(isDark())); };
    toggle.hidden = false;
    sync();
    media.addEventListener('change', sync);
    toggle.addEventListener('click', function () {
      var next = isDark() ? 'light' : 'dark';
      // Back to the system setting when the choice equals it, so a later change of the system setting applies.
      if ((next === 'dark') === media.matches) { delete html.dataset.theme; } else { html.dataset.theme = next; }
      try {
        if (html.dataset.theme) { localStorage.setItem(key, next); } else { localStorage.removeItem(key); }
      } catch (e) { /* storage blocked: the choice lasts for this page */ }
      sync();
    });
  }

  var menu = document.querySelector('.menu-toggle');
  var nav = document.getElementById('site-nav');
  var narrow = window.matchMedia('(max-width: 767px)');

  // The header wraps (a long organization, many levels), so its height is measured, not assumed. The open menu below
  // 768 px is left out: it lies over the page, and its own height limit is the screen below the folded header.
  var header = document.querySelector('.site-header');
  if (header) {
    var measure = function () {
      if (nav && nav.classList.contains('is-open') && narrow.matches) return;
      html.style.setProperty('--header-h', header.offsetHeight + 'px');
    };
    measure();
    if (window.ResizeObserver) { new ResizeObserver(measure).observe(header); } else { window.addEventListener('resize', measure); }
    // The browser jumped to the anchor of the address before the height was known: jump again with the real one.
    var target = null;
    try { target = location.hash.length > 1 ? document.getElementById(decodeURIComponent(location.hash.slice(1))) : null; } catch (e) { /* not an id */ }
    if (target) target.scrollIntoView();
  }

  if (menu && nav) {
    // Wider than 768 px the navigation is always shown: an open menu closes, so the header is measured again.
    narrow.addEventListener('change', function () {
      if (!narrow.matches && nav.classList.contains('is-open')) {
        menu.setAttribute('aria-expanded', 'false');
        nav.classList.remove('is-open');
      }
    });
    menu.addEventListener('click', function () {
      var open = menu.getAttribute('aria-expanded') !== 'true';
      menu.setAttribute('aria-expanded', String(open));
      nav.classList.toggle('is-open', open);
    });
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && nav.classList.contains('is-open')) {
        menu.setAttribute('aria-expanded', 'false');
        nav.classList.remove('is-open');
        menu.focus();
      }
    });
  }
})();
