// The matrix pages: filters in the URL hash, the row counter, the stage links that keep the filters, the keyboard
// route through a grid (one Tab stop, the arrow keys move between the cells, #113) and the popover of a cell. A choice in the popover (or a Release button of the stage page) is sent as the event
// "rulebook:choose" with { id, level, stage, action }, action being one of the five actions, 'reset' or 'release';
// cart.mjs listens for it. Without JavaScript the pages show the full grid and nothing here is needed.
(function () {
  'use strict';

  var root = document.querySelector('[data-rulebook-matrix]');
  var form = document.querySelector('form.filters');

  function readHash() {
    var params = new URLSearchParams(location.hash.replace(/^#/, ''));
    return {
      analyzer: params.get('analyzer') || '',
      action: params.get('action') || '',
      source: params.get('source') || '',
      q: params.get('q') || '',
    };
  }

  function writeHash(filters) {
    var params = new URLSearchParams();
    Object.keys(filters).forEach(function (key) { if (filters[key]) params.set(key, filters[key]); });
    var hash = params.toString();
    history.replaceState(null, '', hash ? '#' + hash : location.pathname + location.search);
    return hash;
  }

  // 'stage' and 'level' match every stage or level file (source stage:<slug>, level:<slug>).
  function sourceMatches(source, filter) {
    return source === filter || source.indexOf(filter + ':') === 0;
  }

  function rowMatches(row, filters) {
    if (filters.analyzer && row.dataset.analyzer !== filters.analyzer) return false;
    if (filters.q) {
      var text = (row.dataset.id + ' ' + (row.dataset.title || '')).toLowerCase();
      if (text.indexOf(filters.q.toLowerCase()) < 0) return false;
    }
    if (!filters.action && !filters.source) return true;
    var cells = row.querySelectorAll('td[data-level]');
    for (var i = 0; i < cells.length; i++) {
      var cell = cells[i];
      if ((!filters.action || cell.dataset.action === filters.action) &&
          (!filters.source || sourceMatches(cell.dataset.source, filters.source))) return true;
    }
    return false;
  }

  function apply(filters) {
    if (!root) return;
    var rows = root.querySelectorAll('tbody tr');
    var shown = 0;
    var total = 0;
    var group = null;
    var groupShown = false;
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      if (row.classList.contains('group')) {
        if (group) group.hidden = !groupShown;
        group = row;
        groupShown = false;
        continue;
      }
      total++;
      var visible = rowMatches(row, filters);
      row.hidden = !visible;
      if (visible) { shown++; groupShown = true; }
    }
    if (group) group.hidden = !groupShown;
    keepTabStop(root.querySelector('table[role="grid"]'));
    var counter = form && form.querySelector('.row-count');
    if (counter) counter.textContent = shown === total ? total + ' rules' : shown + ' of ' + total + ' rules';
  }

  function updateStageLinks(hash) {
    var links = document.querySelectorAll('a[data-stage-link]');
    for (var i = 0; i < links.length; i++) {
      var link = links[i];
      link.href = link.href.split('#')[0] + (hash ? '#' + hash : '');
    }
  }

  function readForm() {
    var filters = {};
    ['analyzer', 'action', 'source', 'q'].forEach(function (name) { filters[name] = form.elements[name].value.trim(); });
    return filters;
  }

  function fillForm(filters) {
    ['analyzer', 'action', 'source', 'q'].forEach(function (name) { form.elements[name].value = filters[name]; });
  }

  if (root && form) {
    form.hidden = false;
    form.addEventListener('submit', function (event) { event.preventDefault(); });
    form.addEventListener('input', function () {
      var filters = readForm();
      updateStageLinks(writeHash(filters));
      apply(filters);
    });
    window.addEventListener('hashchange', function () {
      var filters = readHash();
      fillForm(filters);
      updateStageLinks(location.hash.replace(/^#/, ''));
      apply(filters);
    });
    var initial = readHash();
    fillForm(initial);
    updateStageLinks(location.hash.replace(/^#/, ''));
    apply(initial);
  }

  // The keyboard route: a grid (table[role=grid]) has one cell with tabindex 0, the Tab stop; the arrow keys move it
  // within the rows the filters show, Home and End to the ends of a row, Ctrl+Home and Ctrl+End to the first and the
  // last cell of the grid. Without JavaScript the first cell is the only one in the tab order.
  function rowsOf(grid) {
    var rows = [];
    var all = grid.querySelectorAll('tbody tr');
    for (var i = 0; i < all.length; i++) {
      if (all[i].hidden) continue;
      var cells = all[i].querySelectorAll('td[data-level]');
      if (cells.length) rows.push(Array.prototype.slice.call(cells));
    }
    return rows;
  }

  function moveTabStop(grid, cell) {
    var current = grid.querySelectorAll('td[tabindex="0"]');
    for (var i = 0; i < current.length; i++) { if (current[i] !== cell) current[i].tabIndex = -1; }
    if (cell) cell.tabIndex = 0;
  }

  // After filtering: the Tab stop moves to the first shown cell when its row is hidden.
  function keepTabStop(grid) {
    if (!grid) return;
    var stop = grid.querySelector('td[tabindex="0"]');
    if (stop && !stop.closest('tr').hidden) return;
    var rows = rowsOf(grid);
    moveTabStop(grid, rows.length ? rows[0][0] : null);
  }

  function navigate(event, cell) {
    if (event.altKey || event.metaKey) return false;
    var grid = cell.closest('table[role="grid"]');
    if (!grid) return false;
    var rows = rowsOf(grid);
    var r = -1;
    var c = -1;
    for (var i = 0; i < rows.length && r < 0; i++) {
      c = rows[i].indexOf(cell);
      if (c >= 0) r = i;
    }
    if (r < 0) return false;
    var last = rows.length - 1;
    switch (event.key) {
      case 'ArrowUp': r = Math.max(0, r - 1); break;
      case 'ArrowDown': r = Math.min(last, r + 1); break;
      case 'ArrowLeft': c = Math.max(0, c - 1); break;
      case 'ArrowRight': c = Math.min(rows[r].length - 1, c + 1); break;
      case 'Home': if (event.ctrlKey) r = 0; c = 0; break;
      case 'End': if (event.ctrlKey) r = last; c = rows[r].length - 1; break;
      default: return false;
    }
    var target = rows[r][Math.min(c, rows[r].length - 1)];
    moveTabStop(grid, target);
    target.focus();
    return true;
  }

  // The popover of a cell.
  var template = document.getElementById('cell-popover');
  var open = null;

  // refocus: back to the cell after Escape or a choice; an outside click leaves the focus where the user put it.
  function close(refocus) {
    if (!open) return;
    open.popover.remove();
    if (refocus) open.cell.focus();
    open = null;
  }

  function choose(detail) {
    document.dispatchEvent(new CustomEvent('rulebook:choose', { detail: detail }));
  }

  function show(cell) {
    close();
    var popover = template.content.firstElementChild.cloneNode(true);
    var data = cell.dataset;
    popover.querySelector('.popover-title').textContent = data.id + ' on ' + data.level + '.' + data.stage + ': ' + (data.action || 'unset');
    popover.querySelector('[data-choose="reset"]').hidden = data.source !== 'override';
    popover.querySelector('[data-choose="release"]').hidden = data.source !== 'quarantine';
    popover.addEventListener('click', function (event) {
      var button = event.target.closest('button[data-choose]');
      if (!button) return;
      choose({ id: data.id, level: data.level, stage: data.stage, action: button.dataset.choose });
      close(true);
    });
    document.body.appendChild(popover);
    var box = cell.getBoundingClientRect();
    popover.style.left = Math.max(0, Math.min(box.left + window.scrollX, document.documentElement.scrollWidth - popover.offsetWidth - 8)) + 'px';
    popover.style.top = (box.bottom + window.scrollY + 2) + 'px';
    open = { cell: cell, popover: popover };
    popover.querySelector('button:not([hidden])').focus();
  }

  if (template) {
    document.addEventListener('click', function (event) {
      var cell = event.target.closest('td[data-level]');
      if (cell) {
        var grid = cell.closest('table[role="grid"]');
        if (grid) moveTabStop(grid, cell);
        show(cell);
        return;
      }
      if (open && !open.popover.contains(event.target)) close();
    });
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape') { close(true); return; }
      var cell = event.target.closest && event.target.closest('td[data-level]');
      if (!cell) return;
      if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); show(cell); return; }
      if (navigate(event, cell)) event.preventDefault();
    });
  }

  // The Release buttons of the stage page.
  var releases = document.querySelectorAll('button[data-release]');
  for (var i = 0; i < releases.length; i++) {
    releases[i].hidden = false;
    releases[i].addEventListener('click', function (event) {
      var data = event.currentTarget.dataset;
      choose({ id: data.id, level: null, stage: data.stage, action: 'release' });
    });
  }
})();
