// The cart panel: keeps the cart in localStorage under rulebook-cart:<repository>, listens for "rulebook:choose"
// (matrix.js), shows the before and after of every change from rulebook.json and opens the prefilled issue form.
// Every decision is in cart-core.mjs; this file only reads and writes the page.
import * as core from './cart-core.mjs';

// The body of every page carries the repository, the issue form and the data file (baseof.html).
const config = document.querySelector('[data-rulebook-json]');
const panel = document.getElementById('cart');
const toggle = document.querySelector('.cart-toggle');

if (config && panel && toggle) {
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
  const hasCells = document.querySelector('td[data-level]') !== null;
  let data = null;
  let pendingParts = null;

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
        tr.append(element('td', `${cell.level}.${cell.stage}`), element('td', `${cell.before ?? 'unset'} (${cell.beforeSource})`), element('td', `${cell.after ?? 'unset'} (${cell.afterSource})`));
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
      const label = element('label', 'Justification (optional) ');
      const input = element('input');
      input.type = 'text';
      input.value = row.change.justification || '';
      input.addEventListener('change', () => update(core.setJustification(cart, row.index, input.value)));
      label.append(input);
      item.append(label);
    }
    return item;
  };

  const show = () => {
    const count = cart.changes.length;
    // On a page without cells (a level page) the toggle shows only when the cart holds something.
    toggle.hidden = !hasCells && count === 0;
    toggle.querySelector('.cart-count').textContent = String(count);
    panel.querySelector('.cart-empty').hidden = count > 0;
    if (document.activeElement !== note) note.value = cart.note;
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
    if (count === 0) { list.replaceChildren(); return; }
    const plain = () => list.replaceChildren(...cart.changes.map((change) => element('li', describe(change))));
    loadData().then((loaded) => {
      try {
        list.replaceChildren(...core.rows(cart, loaded).map(renderRow));
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
    panel.hidden = false;
    toggle.setAttribute('aria-expanded', 'true');
  });

  toggle.addEventListener('click', () => {
    panel.hidden = !panel.hidden;
    toggle.setAttribute('aria-expanded', String(!panel.hidden));
  });

  note.addEventListener('input', () => {
    cart = core.setNote(cart, note.value);
    pendingParts = null;
    save();
    render();
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
