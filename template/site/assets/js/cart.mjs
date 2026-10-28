// The cart drawer: keeps the cart in localStorage under rulebook-cart:<repository>, listens for "rulebook:choose"
// (matrix.js), shows the before and after of every change from rulebook.json and opens the prefilled issue form. The
// drawer is a modal dialog: it opens on an added change and on the Cart button, closes on its close button, Escape
// and the overlay, holds the focus while open (Tab wraps inside) and gives it back to the Cart button.
// Every decision is in cart-core.mjs and drawer-core.mjs; this file only reads and writes the page.
import * as core from './cart-core.mjs';
import * as drawer from './drawer-core.mjs';

// The body of every page carries the repository, the issue form and the data file (baseof.html).
const config = document.querySelector('[data-rulebook-json]');
const panel = document.getElementById('cart');
const toggle = document.querySelector('.cart-toggle');
const overlay = document.querySelector('.cart-overlay');

if (config && panel && toggle && overlay) {
  const repository = config.dataset.repository || '';
  const issueTemplate = config.dataset.issueTemplate || '';
  const key = core.storageKey(repository);
  const list = panel.querySelector('.cart-list');
  const note = panel.querySelector('.cart-note textarea');
  const meter = panel.querySelector('meter');
  const size = panel.querySelector('.cart-size');
  const bytesText = panel.querySelector('.cart-bytes');
  const status = panel.querySelector('.cart-status');
  const submit = panel.querySelector('[data-cart="submit"]');
  const parts = panel.querySelector('[data-cart="parts"]');
  const closeButton = panel.querySelector('.cart-close');
  const hasCells = document.querySelector('td[data-level]') !== null;
  let data = null;
  let pendingParts = null;
  let drawerState = drawer.initialState();

  // The textareas grow with their content: CSS field-sizing where the browser has it, else the height follows the
  // scroll height on every input and whenever the drawer opens (a hidden textarea has no scroll height).
  const sizesItself = typeof CSS !== 'undefined' && typeof CSS.supports === 'function' && CSS.supports('field-sizing', 'content');
  const grow = (area) => {
    if (sizesItself || panel.hidden) return;
    area.style.height = 'auto';
    area.style.height = `${area.scrollHeight + area.offsetHeight - area.clientHeight}px`;
  };
  const growAll = () => panel.querySelectorAll('textarea').forEach(grow);
  // A narrower window wraps the text onto more lines.
  if (!sizesItself) window.addEventListener('resize', growAll);

  // Whatever is stored goes through sanitize: every page of the same host shares localStorage.
  const load = () => {
    try {
      return core.sanitize(JSON.parse(localStorage.getItem(key) || 'null'));
    } catch (error) {
      return core.emptyCart();
    }
  };
  let cart = load();

  const save = () => {
    try { localStorage.setItem(key, JSON.stringify(cart)); } catch (error) { /* private mode: the cart lives until the page closes */ }
  };

  // Fetched once; a failed fetch is not kept, so the next action tries again.
  const loadData = () => {
    if (!data) {
      data = fetch(config.dataset.rulebookJson).then((response) => {
        if (!response.ok) throw new Error(`rulebook.json answered HTTP ${response.status}`);
        return response.json();
      });
      data.catch(() => { data = null; });
    }
    return data;
  };

  const fail = (error) => { status.textContent = error && error.message ? error.message : String(error); };

  const element = (tag, text, className) => {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  };

  const selector = (values) => (values.includes('*') ? 'every' : values.join(', '));

  const describe = (change) => {
    if (change.op === 'set') return `${change.id}: set ${change.action} on level ${selector(change.levels)}, stage ${selector(change.stages)}`;
    if (change.op === 'remove') return `${change.id}: remove the override of level ${selector(change.levels)}, stage ${selector(change.stages)}`;
    return `${change.id}: release from the quarantine of stage ${selector(change.stages)}`;
  };

  const update = (next) => {
    cart = next;
    pendingParts = null;
    status.textContent = '';
    save();
    render();
  };

  const axisToggle = (row, axis, label) => {
    const box = element('input');
    box.type = 'checkbox';
    box.checked = row.change[axis].includes('*');
    box.addEventListener('change', () => {
      const before = cart.changes.length;
      update(box.checked ? core.widen(cart, row.index, axis) : core.narrow(cart, row.index, axis));
      if (cart.changes.length < before) status.textContent = `${row.change.id}: merged with an equal change of the cart, which this one replaces.`;
    });
    const wrap = element('label', undefined);
    wrap.append(box, ` ${label}`);
    return wrap;
  };

  const renderRow = (row) => {
    const item = element('li');
    item.append(element('p', describe(row.change)));
    if (row.unknownId) item.append(element('p', 'This id is not in the published data; the change may be refused.', 'cart-nochange'));
    else if (row.noChange) item.append(element('p', 'No action changes: the change would be a no-op.', 'cart-nochange'));
    if (row.cells.length > 0) {
      const table = element('table');
      const head = table.createTHead().insertRow();
      for (const title of ['Endpoint', 'Before', 'After']) head.append(element('th', title));
      const body = table.createTBody();
      for (const cell of row.cells) {
        const tr = body.insertRow();
        // In the 24rem drawer the endpoint may break after its dot and the source sits under the action.
        const endpoint = element('td');
        endpoint.append(`${cell.level}.`, document.createElement('wbr'), cell.stage);
        const decided = (action, source) => {
          const td = element('td', action ?? 'unset');
          td.append(' ', element('small', `(${source})`));
          return td;
        };
        tr.append(endpoint, decided(cell.before, cell.beforeSource), decided(cell.after, cell.afterSource));
      }
      item.append(table);
    }
    const controls = element('p');
    if (row.change.op === 'set') controls.append(axisToggle(row, 'levels', 'all levels'), ' ');
    if (row.change.op !== 'remove') controls.append(axisToggle(row, 'stages', 'all stages'), ' ');
    const drop = element('button', 'Remove');
    drop.type = 'button';
    drop.addEventListener('click', () => update(core.removeChange(cart, row.index)));
    controls.append(drop);
    item.append(controls);
    if (row.change.op === 'set') {
      // Several lines are fine: a line end travels as \n in the JSON of the change set. Typing updates the cart and
      // the size without drawing the list again, so the focus stays in the field.
      const label = element('label', 'Justification (optional) ', 'cart-justification');
      const area = element('textarea');
      area.rows = 1;
      area.value = row.change.justification || '';
      area.addEventListener('input', () => {
        cart = core.setJustification(cart, row.index, area.value);
        pendingParts = null;
        status.textContent = '';
        save();
        measure();
        grow(area);
      });
      label.append(area);
      item.append(label);
    }
    return item;
  };

  // The count of the Cart button, the size of the issue link and the Submit buttons; the list is not drawn again.
  const measure = () => {
    const count = cart.changes.length;
    // On a page without cells (a level page) the toggle shows only when the cart holds something.
    toggle.hidden = !hasCells && count === 0;
    toggle.querySelector('.cart-count').textContent = String(count);
    panel.querySelector('.cart-empty').hidden = count > 0;
    // The link can fail (a data file without repository, a broken character): the list still renders, so every
    // change can be seen and removed.
    try {
      const fit = core.fits(core.issueUrl(repository, issueTemplate, cart));
      meter.value = Math.min(fit.bytes, fit.limit);
      bytesText.textContent = `${fit.bytes} of ${fit.limit} bytes of the issue link`;
      size.classList.toggle('over', !fit.ok);
      submit.disabled = count === 0 || !fit.ok;
      parts.hidden = fit.ok || count === 0;
    } catch (error) {
      meter.value = 0;
      bytesText.textContent = '';
      size.classList.remove('over');
      submit.disabled = true;
      parts.hidden = true;
      fail(error);
    }
    if (!pendingParts) parts.textContent = 'Submit in parts';
  };

  const show = () => {
    const count = cart.changes.length;
    if (document.activeElement !== note) { note.value = cart.note; grow(note); }
    measure();
    if (count === 0) { list.replaceChildren(); return; }
    const plain = () => list.replaceChildren(...cart.changes.map((change) => element('li', describe(change))));
    loadData().then((loaded) => {
      try {
        list.replaceChildren(...core.rows(cart, loaded).map(renderRow));
        growAll();
        // Remove or an axis checkbox drew the list again and took the focused element with it: back into the drawer.
        if (drawerState.open && !panel.contains(document.activeElement)) closeButton.focus();
      } catch (error) {
        plain();
        fail(error);
      }
    }, () => {
      plain();
      status.textContent = 'rulebook.json could not be read, so the before and after are not shown.';
    });
  };

  // A throw (a repository the data file does not name, a broken character) shows in the status, never a dead cart.
  const render = () => {
    try {
      show();
    } catch (error) {
      submit.disabled = true;
      fail(error);
    }
  };

  // The drawer: shown or hidden with its overlay, aria-expanded on the Cart button, the is-open class on <body> (the
  // page behind does not scroll), and the focus where drawer-core.mjs says. The focus moves after the current event:
  // matrix.js puts it back on the cell once its popover has dispatched the choice that opens the drawer.
  const focusables = () => [...panel.querySelectorAll('button, [href], input, textarea, select, [tabindex]:not([tabindex="-1"])')]
    .filter((node) => !node.disabled && node.getClientRects().length > 0);

  // On a page without cells Clear hides the Cart button while the drawer is open; the focus then goes to the main
  // content instead of a hidden button.
  const focusBadge = () => {
    const main = document.getElementById('content');
    if (!toggle.hidden || !main) { toggle.focus(); return; }
    main.tabIndex = -1;
    main.focus();
  };

  const drawerEvent = (event) => {
    const result = drawer.transition(drawerState, event);
    drawerState = { open: result.open };
    panel.hidden = !result.open;
    overlay.hidden = !result.open;
    document.body.classList.toggle('is-open', result.open);
    toggle.setAttribute('aria-expanded', String(result.open));
    if (result.open) growAll();
    if (result.focus === drawer.FOCUS_CLOSE_BUTTON) queueMicrotask(() => closeButton.focus());
    else if (result.focus === drawer.FOCUS_BADGE) queueMicrotask(() => focusBadge());
  };

  const confirmClear = () => {
    if (window.confirm('Did GitHub open the filled form? Clear the cart?')) update(core.clearCart());
  };

  document.addEventListener('rulebook:choose', (event) => {
    const { id, level, stage, action } = event.detail;
    if (action === 'reset') {
      loadData().then((loaded) => {
        const rule = loaded.rules.find((candidate) => candidate.id === id);
        const cell = rule && rule.cells[`${level}.${stage}`];
        const entry = cell && cell.source === 'override' ? loaded.overrides[cell.override] : null;
        if (!entry) { status.textContent = `No override decides ${id} on ${level}.${stage}.`; return; }
        update(core.addChange(cart, { op: 'remove', id, levels: entry.levels, stages: entry.stages }));
      }).catch(fail);
    } else if (action === 'release') {
      update(core.addChange(cart, { op: 'release', id, stages: [stage] }));
    } else {
      update(core.addChange(cart, { op: 'set', id, action, levels: [level], stages: [stage] }));
    }
    drawerEvent('add');
  });

  toggle.addEventListener('click', () => drawerEvent('badge'));
  closeButton.addEventListener('click', () => drawerEvent('close'));
  overlay.addEventListener('click', () => drawerEvent('overlay'));

  // In the capture phase, before matrix.js and shell.js see the key: Escape while a cell's popover or the menu below
  // 768 px is open belongs to that (matrix.js and shell.js close it, the drawer stays), and Tab stays inside the open
  // drawer. Escape that ends an input method composition is the composition's.
  document.addEventListener('keydown', (event) => {
    if (!drawerState.open) return;
    if (event.key === 'Escape') {
      if (event.isComposing || document.querySelector('.popover, .site-nav.is-open')) return;
      event.preventDefault();
      drawerEvent('escape');
    } else if (event.key === 'Tab' && !event.altKey && !event.ctrlKey && !event.metaKey) {
      const items = focusables();
      const at = drawer.tabTarget(items.length, items.indexOf(document.activeElement), event.shiftKey);
      if (at >= 0) {
        event.preventDefault();
        items[at].focus();
      }
    }
  }, true);

  // Typing updates the cart and the size; the list is not drawn again.
  note.addEventListener('input', () => {
    cart = core.setNote(cart, note.value);
    pendingParts = null;
    status.textContent = '';
    save();
    measure();
    grow(note);
  });

  submit.addEventListener('click', () => {
    try {
      window.open(core.issueUrl(repository, issueTemplate, cart), '_blank', 'noopener');
    } catch (error) {
      fail(error);
      return;
    }
    confirmClear();
  });

  // One click per part: a browser opens one new tab per click.
  parts.addEventListener('click', () => {
    try {
      if (!pendingParts) pendingParts = { list: core.splitParts(repository, issueTemplate, cart), next: 0 };
    } catch (error) {
      fail(error);
      return;
    }
    const part = pendingParts.list[pendingParts.next];
    if (part.oversize) {
      pendingParts.skipped = (pendingParts.skipped || 0) + part.indices.length;
      status.textContent = `Part ${pendingParts.next + 1}: the note and this change are too large for a link; use Copy change set and paste it into the empty form.`;
    } else {
      window.open(part.url, '_blank', 'noopener');
      pendingParts.opened = (pendingParts.opened || 0) + 1;
      pendingParts.sent = [...(pendingParts.sent || []), ...part.indices];
      status.textContent = `Opened part ${pendingParts.next + 1} of ${pendingParts.list.length}.`;
    }
    pendingParts.next++;
    if (pendingParts.next >= pendingParts.list.length) {
      const { opened = 0, skipped = 0, sent = [] } = pendingParts;
      pendingParts = null;
      // Every part opened: ask to clear. Some too large: the opened changes leave the cart, the large ones stay for
      // Copy change set, so a later Submit does not send the opened ones twice.
      if (skipped > 0) {
        update(core.withoutChanges(cart, sent));
        status.textContent = `${opened} part(s) opened and removed from the cart; ${skipped} change(s) too large for a link stay: use Copy change set.`;
      } else if (opened > 0) {
        confirmClear();
      }
    } else {
      parts.textContent = `Submit part ${pendingParts.next + 1} of ${pendingParts.list.length}`;
    }
  });

  panel.querySelector('[data-cart="copy"]').addEventListener('click', () => {
    navigator.clipboard.writeText(core.copyPayload(cart)).then(
      () => { status.textContent = 'The change set is on the clipboard; paste it into the Changes field of the empty form.'; },
      () => { status.textContent = 'The clipboard is not available here.'; });
  });

  panel.querySelector('[data-cart="clear"]').addEventListener('click', () => {
    if (cart.changes.length === 0 || window.confirm('Remove every change from the cart?')) update(core.clearCart());
  });

  // Another tab of the same site changed the cart.
  window.addEventListener('storage', (event) => {
    if (event.key === key) { cart = load(); pendingParts = null; render(); }
  });

  render();
}
