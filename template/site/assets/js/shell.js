// The shell: the colour scheme toggle, the menu below 768 px, --header-h (the height of the sticky header that the
// cart and the matrix container are placed against) and the copy buttons of the setup page. The has-js class is set
// by the inline script of head.html.
// Without JavaScript the system setting decides the colour scheme (the prefers-color-scheme block of site.css), the
// navigation is shown in full, --header-h keeps its value of site.css and the copy buttons stay hidden.
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

  // Copy buttons: data-copy holds the text, data-copy-target the selector of the element whose text is copied. The
  // Clipboard API where the page may use it, else a selected textarea and execCommand. The button says "Copied" (or
  // "Copy failed") and the one live region p.copy-status announces it; both reset after two seconds.
  var status = document.querySelector('.copy-status');
  var copyButtons = document.querySelectorAll('button[data-copy], button[data-copy-target]');
  var resetTimer = null;

  function copyByTextarea(text) {
    var area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.top = '0';
    area.style.left = '-9999px';
    document.body.appendChild(area);
    var focused = document.activeElement;
    area.select();
    area.setSelectionRange(0, text.length);
    var done = false;
    try { done = document.execCommand('copy'); } catch (e) { done = false; }
    document.body.removeChild(area);
    if (focused && focused.focus) focused.focus();
    return done;
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).then(
        function () { return true; },
        function () { return copyByTextarea(text); });
    }
    return Promise.resolve(copyByTextarea(text));
  }

  function report(button, done) {
    var message = done ? 'Copied' : 'Copy failed: select the text and copy it';
    copyButtons.forEach(function (other) { other.textContent = other.dataset.label; });
    button.textContent = done ? 'Copied' : 'Copy failed';
    // Emptied first and written a moment later, so a second click announces the message again.
    if (status) {
      status.textContent = '';
      setTimeout(function () { status.textContent = message; }, 50);
    }
    if (resetTimer) clearTimeout(resetTimer);
    resetTimer = setTimeout(function () {
      button.textContent = button.dataset.label;
      if (status) status.textContent = '';
      resetTimer = null;
    }, 2000);
  }

  copyButtons.forEach(function (button) {
    button.dataset.label = button.textContent;
    button.hidden = false;
    button.addEventListener('click', function () {
      var text = button.getAttribute('data-copy');
      if (text === null) {
        var target = null;
        try { target = document.querySelector(button.getAttribute('data-copy-target')); } catch (e) { /* not a selector */ }
        // A target that is not on the page is a failure, never an empty clipboard.
        if (!target) { report(button, false); return; }
        text = target.textContent;
      }
      copyText(text).then(function (done) { report(button, done); });
    });
  });
})();
