// The cart panel: keeps the cart in localStorage under rulebook-cart:<repository>, listens for "rulebook:choose"
// (matrix.js), shows the before and after of every change from rulebook.json and opens the prefilled issue form.
// Every decision is in cart-core.mjs; this file only reads and writes the page.
import * as core from './cart-core.mjs';

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
  let data = null;
  let pendingParts = null;

  const load = () => {
    try {
      const stored = JSON.parse(localStorage.getItem(key) || 'null');
      if (stored && Array.isArray(stored.changes)) return stored;
    } catch (error) {
      // A cart that cannot be read starts empty.
    }
    return core.emptyCart();
  };
  let cart = load();

  const save = () => {
    try { localStorage.setItem(key, JSON.stringify(cart)); } catch (error) { /* private mode: the cart lives until the page closes */ }
  };

  const loadData = () => {
    if (!data) data = fetch(config.dataset.rulebookJson).then((response) => response.json());
    return data;
  };

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
    save();
    render();
  };

  const axisToggle = (row, axis, label) => {
    const box = element('input');
    box.type = 'checkbox';
    box.checked = row.change[axis].includes('*');
    box.addEventListener('change', () => update(box.checked ? core.widen(cart, row.index, axis) : core.narrow(cart, row.index, axis)));
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

  const render = () => {
    const count = cart.changes.length;
    toggle.hidden = false;
    toggle.querySelector('.cart-count').textContent = String(count);
    panel.querySelector('.cart-empty').hidden = count > 0;
    if (document.activeElement !== note) note.value = cart.note;
    const url = core.issueUrl(repository, issueTemplate, cart);
    const fit = core.fits(url);
    meter.value = Math.min(fit.bytes, fit.limit);
    bytesText.textContent = `${fit.bytes} of ${fit.limit} bytes of the issue link`;
    size.classList.toggle('over', !fit.ok);
    submit.disabled = count === 0 || !fit.ok || !repository;
    parts.hidden = fit.ok || count === 0;
    if (!pendingParts) parts.textContent = 'Submit in parts';
    if (count === 0) { list.replaceChildren(); return; }
    loadData().then((loaded) => {
      list.replaceChildren(...core.rows(cart, loaded).map(renderRow));
    }).catch(() => {
      list.replaceChildren(...cart.changes.map((change) => element('li', describe(change))));
      status.textContent = 'rulebook.json could not be read, so the before and after are not shown.';
    });
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
      });
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
    save();
    render();
  });

  submit.addEventListener('click', () => {
    window.open(core.issueUrl(repository, issueTemplate, cart), '_blank', 'noopener');
    confirmClear();
  });

  // One click per part: a browser opens one new tab per click.
  parts.addEventListener('click', () => {
    if (!pendingParts) pendingParts = { list: core.splitParts(repository, issueTemplate, cart), next: 0 };
    const part = pendingParts.list[pendingParts.next];
    if (part.oversize) {
      status.textContent = `Part ${pendingParts.next + 1} is one change too large for a link: copy the change set and paste it into the empty form.`;
    } else {
      window.open(part.url, '_blank', 'noopener');
      status.textContent = `Opened part ${pendingParts.next + 1} of ${pendingParts.list.length}.`;
    }
    pendingParts.next++;
    if (pendingParts.next >= pendingParts.list.length) {
      pendingParts = null;
      confirmClear();
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
    if (event.key === key) { cart = load(); render(); }
  });

  render();
}
