// The cart of the dashboard site, as pure functions: no DOM, no storage, no network. cart.mjs wires them to the page
// and tests/site/cart-core.test.mjs (node --test) runs them against a data file.
//
// A cart is { version: 1, note, changes: [...] }; a change is one item of the change set the rulebook-change issue
// form takes: { op: 'set', id, action, levels, stages, justification }, { op: 'remove', id, levels, stages } or
// { op: 'release', id, stages }. Functions return a new cart and never change the one they get.
//
// The before and after of a change come from the data file (rulebook.json): the action of a cell, and for an override
// or a quarantine cell the fallback the engine exported. Nothing here repeats the precedence of the generator. One
// known limit: a set widened to every level or stage shows the chosen action on every matching cell, but a more
// specific override that already decides a cell still wins there after the change.

export const LIMIT_BYTES = 7372;
export const ACTIONS = ['Error', 'Warning', 'Info', 'Hidden', 'None'];
const ALL = '*';

export function storageKey(repository) {
  return 'rulebook-cart:' + (repository || '');
}

export function emptyCart() {
  return { version: 1, note: '', changes: [] };
}

function copyChange(change) {
  const copy = { ...change };
  if (change.levels) copy.levels = [...change.levels];
  if (change.stages) copy.stages = [...change.stages];
  if (change.origin) copy.origin = { ...change.origin };
  return copy;
}

function copyCart(cart) {
  const source = cart || emptyCart();
  return {
    version: 1,
    note: typeof source.note === 'string' ? source.note : '',
    changes: (source.changes || []).map(copyChange),
  };
}

function sameList(a, b) {
  const left = [...(a || [])].sort();
  const right = [...(b || [])].sort();
  return left.length === right.length && left.every((value, i) => value === right[i]);
}

function sameSelection(a, b) {
  return a.op === b.op && a.id === b.id && sameList(a.levels, b.levels) && sameList(a.stages, b.stages);
}

function matches(selector, slug) {
  return (selector || []).includes(ALL) || (selector || []).includes(slug);
}

// Adds a change, or replaces the change with the same op, id, levels and stages in its place.
export function addChange(cart, change) {
  const next = copyCart(cart);
  const item = copyChange(change);
  if (item.op === 'release') delete item.levels;
  item.origin = { stages: [...item.stages] };
  if (item.levels) item.origin.levels = [...item.levels];
  const at = next.changes.findIndex((existing) => sameSelection(existing, item));
  if (at >= 0) {
    next.changes[at] = item;
  } else {
    next.changes.push(item);
  }
  return next;
}

// Widens change i to every level or every stage (axis 'levels' or 'stages'). A remove names one override entry
// exactly and is never widened. When the widened change equals another one, the two become one: the other one, in
// its place, keeps its action, justification and the selection it was added with.
export function widen(cart, i, axis) {
  const next = copyCart(cart);
  const change = next.changes[i];
  if (!change || change.op === 'remove' || !change[axis]) return next;
  change[axis] = [ALL];
  const twin = next.changes.findIndex((other, j) => j !== i && sameSelection(other, change));
  if (twin >= 0) next.changes.splice(i, 1);
  return next;
}

// Narrows change i back to the levels or stages it had when it was added.
export function narrow(cart, i, axis) {
  const next = copyCart(cart);
  const change = next.changes[i];
  if (!change || !change.origin || !change.origin[axis]) return next;
  change[axis] = [...change.origin[axis]];
  return next;
}

// Only a set carries a justification (the schema refuses one on remove and release).
export function setJustification(cart, i, text) {
  const next = copyCart(cart);
  if (next.changes[i] && next.changes[i].op === 'set') next.changes[i].justification = text || '';
  return next;
}

export function setNote(cart, text) {
  const next = copyCart(cart);
  next.note = text || '';
  return next;
}

export function removeChange(cart, i) {
  const next = copyCart(cart);
  next.changes.splice(i, 1);
  return next;
}

export function clearCart() {
  return emptyCart();
}

// The position in data.overrides of the entry a remove names: same id, same levels, same stages; -1 when none.
export function overrideIndex(change, data) {
  return (data.overrides || []).findIndex((entry) =>
    entry.id === change.id && sameList(entry.levels, change.levels) && sameList(entry.stages, change.stages));
}

// The cells of one rule a change touches, in level and stage order, with the action before and after.
// set: every matching cell, after = the chosen action. remove: the cells the named override decides, after = the
// fallback of the cell. release: the quarantine cells of the stages, after = the fallback of the cell.
export function affectedCells(change, rule, data) {
  const result = [];
  if (!rule) return result;
  const index = change.op === 'remove' ? overrideIndex(change, data) : -1;
  for (const level of data.levels) {
    for (const stage of data.stages) {
      const cell = rule.cells[level.slug + '.' + stage.slug];
      if (!cell) continue;
      let after;
      let afterSource;
      if (change.op === 'set') {
        if (!matches(change.levels, level.slug) || !matches(change.stages, stage.slug)) continue;
        after = change.action;
        afterSource = 'override';
      } else if (change.op === 'remove') {
        if (index < 0 || cell.override !== index) continue;
        after = cell.fallback;
        afterSource = cell.fallbackSource;
      } else if (change.op === 'release') {
        if (cell.source !== 'quarantine' || !matches(change.stages, stage.slug)) continue;
        after = cell.fallback;
        afterSource = cell.fallbackSource;
      } else {
        continue;
      }
      result.push({ level: level.slug, stage: stage.slug, before: cell.action, beforeSource: cell.source, after, afterSource });
    }
  }
  return result;
}

// One row per change for the cart panel: the affected cells, noChange when no action changes (or no cell is
// touched), unknownId when the data file has no rule of that id.
export function rows(cart, data) {
  const byId = new Map(data.rules.map((rule) => [rule.id, rule]));
  return (cart.changes || []).map((change, index) => {
    const rule = byId.get(change.id);
    const cells = affectedCells(change, rule, data);
    return { index, change, cells, noChange: cells.every((cell) => cell.before === cell.after), unknownId: !rule };
  });
}

// The change set as the issue form takes it: keys in the order of the schema, an empty note and an empty
// justification left out, nothing the cart keeps for itself.
export function changeSet(cart) {
  const result = { version: 1 };
  if (cart.note) result.note = cart.note;
  result.changes = (cart.changes || []).map((change) => {
    const item = { op: change.op, id: change.id };
    if (change.op === 'set') item.action = change.action;
    if (change.op !== 'release') item.levels = [...change.levels];
    item.stages = [...change.stages];
    if (change.op === 'set' && change.justification) item.justification = change.justification;
    return item;
  });
  return result;
}

// Minified: a pretty-printed set costs twice the bytes in the URL, every indent space becomes %20.
export function serialize(cart) {
  return JSON.stringify(changeSet(cart));
}

// The address of the empty issue form of the repository.
export function emptyFormUrl(repository, issueTemplate) {
  return 'https://github.com/' + repository + '/issues/new?template=' + encodeURIComponent(issueTemplate);
}

// The address of the form with the change set and the note filled in; the note parameter only when there is one.
export function issueUrl(repository, issueTemplate, cart) {
  let url = emptyFormUrl(repository, issueTemplate) + '&changes=' + encodeURIComponent(serialize(cart));
  if (cart.note) url += '&note=' + encodeURIComponent(cart.note);
  return url;
}

export function byteLength(text) {
  return new TextEncoder().encode(text).length;
}

// Whether a full issue URL stays within the limit: GitHub answers 414 from 8192 bytes, 7372 is 90 % of that.
export function fits(url, limit = LIMIT_BYTES) {
  const bytes = byteLength(url);
  return { bytes, limit, ok: bytes <= limit };
}

// Splits a cart into carts whose issue URL fits, greedily in the order of the changes; every part keeps the note. A
// change too large on its own is a part with oversize true: copy it into the empty form instead.
export function splitParts(repository, issueTemplate, cart, limit = LIMIT_BYTES) {
  const parts = [];
  const note = cart.note || '';
  let changes = [];
  const close = () => {
    if (changes.length === 0) return;
    const part = { version: 1, note, changes };
    const url = issueUrl(repository, issueTemplate, part);
    parts.push({ cart: part, url, bytes: byteLength(url), oversize: !fits(url, limit).ok });
    changes = [];
  };
  for (const change of cart.changes || []) {
    const candidate = { version: 1, note, changes: [...changes, change] };
    if (changes.length > 0 && !fits(issueUrl(repository, issueTemplate, candidate), limit).ok) {
      close();
      changes = [change];
    } else {
      changes = candidate.changes;
    }
  }
  close();
  return parts;
}

// The change set to paste into the empty form: the same content, pretty-printed.
export function copyPayload(cart) {
  return JSON.stringify(changeSet(cart), null, 2) + '\n';
}
