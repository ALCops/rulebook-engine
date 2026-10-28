// The shell: the colour scheme toggle and the menu below 768 px. Without JavaScript the system setting decides the
// colour scheme (the prefers-color-scheme block of site.css) and the navigation is shown in full.
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
  if (menu && nav) {
    menu.hidden = false;
    document.documentElement.classList.add('has-menu');
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
