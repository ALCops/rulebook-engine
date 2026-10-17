// Cart suite for WP14 (#16): template/site/assets/js/cart-core.mjs, the pure functions of the dashboard cart, against
// the committed site data fixture tests/fixtures/site-data/rulebook.json (the export of valid-minimal: AA0072 has an
// override on every level and stage, LC0029 one on recommended.ci, LC0099 is quarantined in default and ci).
// Run with: node --test tests/site/ (Node 20 or later, no npm, no package.json).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as core from '../../template/site/assets/js/cart-core.mjs';

const data = JSON.parse(readFileSync(fileURLToPath(new URL('../fixtures/site-data/rulebook.json', import.meta.url)), 'utf8'));
const repository = 'contoso/rulebook';
const template = data.issueTemplate;
const rule = (id) => data.rules.find((candidate) => candidate.id === id);
const set = (id, action, levels, stages, justification) => ({ op: 'set', id, action, levels, stages, ...(justification ? { justification } : {}) });

test('the fixture is the export the cart reads', () => {
  assert.equal(data.repository, repository);
  assert.equal(template, 'rulebook-change.yml');
  assert.deepEqual(data.levels.map((level) => level.slug), ['essential', 'recommended', 'strict', 'complete']);
  assert.deepEqual(data.stages.map((stage) => stage.slug), ['default', 'ci', 'vnext']);
});

test('storageKey and emptyCart', () => {
  assert.equal(core.storageKey('contoso/rulebook'), 'rulebook-cart:contoso/rulebook');
  assert.equal(core.storageKey(undefined), 'rulebook-cart:');
  assert.deepEqual(core.emptyCart(), { version: 1, note: '', changes: [] });
  assert.equal(core.LIMIT_BYTES, 7372);
});

test('addChange appends, replaces an equal selection in place and never changes its input', () => {
  const empty = core.emptyCart();
  let cart = core.addChange(empty, set('LC0015', 'None', ['strict'], ['ci']));
  cart = core.addChange(cart, set('AA0001', 'Error', ['strict'], ['ci']));
  cart = core.addChange(cart, set('LC0015', 'Warning', ['strict'], ['ci']));
  assert.deepEqual(empty.changes, []);
  assert.equal(cart.changes.length, 2);
  assert.equal(cart.changes[0].id, 'LC0015');
  assert.equal(cart.changes[0].action, 'Warning');
  // Another op or another selection is another change.
  cart = core.addChange(cart, set('LC0015', 'Warning', ['strict'], ['default']));
  cart = core.addChange(cart, { op: 'remove', id: 'LC0015', levels: ['strict'], stages: ['ci'] });
  assert.equal(cart.changes.length, 4);
});

test('widen merges an equal change and narrow restores the selection it was added with', () => {
  let cart = core.addChange(core.emptyCart(), set('AA0001', 'Error', ['strict'], ['ci']));
  cart = core.addChange(cart, set('AA0001', 'Error', ['strict'], ['vnext']));
  const before = cart;
  cart = core.widen(cart, 0, 'stages');
  assert.deepEqual(cart.changes[0].stages, ['*']);
  assert.equal(cart.changes.length, 2);
  cart = core.widen(cart, 1, 'stages');
  assert.equal(cart.changes.length, 1, 'the second change widened to every stage equals the first one');
  assert.deepEqual(before.changes[1].stages, ['vnext']);
  cart = core.narrow(cart, 0, 'stages');
  assert.deepEqual(cart.changes[0].stages, ['ci']);
  cart = core.widen(cart, 0, 'levels');
  assert.deepEqual(cart.changes[0].levels, ['*']);
  assert.deepEqual(core.narrow(cart, 0, 'levels').changes[0].levels, ['strict']);
});

test('a remove is never widened, and a release has no levels', () => {
  let cart = core.addChange(core.emptyCart(), { op: 'remove', id: 'LC0029', levels: ['recommended'], stages: ['ci'] });
  assert.deepEqual(core.widen(cart, 0, 'levels').changes[0].levels, ['recommended']);
  cart = core.addChange(cart, { op: 'release', id: 'LC0099', levels: ['strict'], stages: ['ci'] });
  assert.equal('levels' in cart.changes[1], false);
  assert.deepEqual(core.widen(cart, 1, 'stages').changes[1].stages, ['*']);
});

test('setJustification on a set only, setNote, removeChange and clearCart', () => {
  let cart = core.addChange(core.emptyCart(), set('AA0001', 'Error', ['strict'], ['ci']));
  cart = core.addChange(cart, { op: 'release', id: 'LC0099', stages: ['ci'] });
  cart = core.setJustification(cart, 0, 'Tracked in DEV-1');
  cart = core.setJustification(cart, 1, 'not stored');
  assert.equal(cart.changes[0].justification, 'Tracked in DEV-1');
  assert.equal('justification' in cart.changes[1], false);
  cart = core.setNote(cart, 'Agreed today');
  assert.equal(cart.note, 'Agreed today');
  cart = core.removeChange(cart, 0);
  assert.deepEqual(cart.changes.map((change) => change.id), ['LC0099']);
  assert.deepEqual(core.clearCart(cart), core.emptyCart());
});

test('a set row has the before of every matching cell and the chosen action after', () => {
  const cart = core.addChange(core.emptyCart(), set('AL0432', 'Error', ['*'], ['ci']));
  const [row] = core.rows(cart, data);
  assert.equal(row.unknownId, false);
  assert.equal(row.noChange, false);
  assert.deepEqual(row.cells.map((cell) => `${cell.level}.${cell.stage} ${cell.before} ${cell.beforeSource} ${cell.after} ${cell.afterSource}`), [
    'essential.ci None level:essential Error override',
    'recommended.ci Info stage:ci Error override',
    'strict.ci Info stage:ci Error override',
    'complete.ci Info stage:ci Error override',
  ]);
});

test('a set to the action every matching cell already has is noChange', () => {
  const cart = core.addChange(core.emptyCart(), set('AL0001', 'Error', ['*'], ['*']));
  const [row] = core.rows(cart, data);
  assert.equal(row.cells.length, 12);
  assert.equal(row.noChange, true);
});

test('a remove row has the fallback of every cell the entry decides: AA0072 on 12 cells, LC0029 on 1', () => {
  let cart = core.addChange(core.emptyCart(), { op: 'remove', id: 'AA0072', levels: ['*'], stages: ['*'] });
  cart = core.addChange(cart, { op: 'remove', id: 'LC0029', levels: ['recommended'], stages: ['ci'] });
  const [aa, lc] = core.rows(cart, data);
  assert.equal(aa.cells.length, 12);
  for (const cell of aa.cells) {
    const exported = rule('AA0072').cells[`${cell.level}.${cell.stage}`];
    assert.equal(cell.before, 'Info');
    assert.equal(cell.beforeSource, 'override');
    assert.equal(cell.after, exported.fallback);
    assert.equal(cell.afterSource, exported.fallbackSource);
  }
  assert.deepEqual(lc.cells, [{ level: 'recommended', stage: 'ci', before: 'None', beforeSource: 'override', after: 'Warning', afterSource: 'level:recommended' }]);
  // Selectors that name no entry touch nothing.
  const [none] = core.rows(core.addChange(core.emptyCart(), { op: 'remove', id: 'LC0029', levels: ['strict'], stages: ['ci'] }), data);
  assert.deepEqual(none.cells, []);
  assert.equal(none.noChange, true);
  assert.equal(core.overrideIndex({ id: 'LC0029', levels: ['recommended'], stages: ['ci'] }, data), 1);
});

test('a release row of LC0099 in ci has the fallback of its quarantine cells in ci only', () => {
  const [row] = core.rows(core.addChange(core.emptyCart(), { op: 'release', id: 'LC0099', stages: ['ci'] }), data);
  assert.deepEqual(row.cells.map((cell) => `${cell.level}.${cell.stage}`), ['essential.ci', 'recommended.ci', 'strict.ci', 'complete.ci']);
  for (const cell of row.cells) {
    assert.equal(cell.beforeSource, 'quarantine');
    assert.equal(cell.after, rule('LC0099').cells[`${cell.level}.${cell.stage}`].fallback);
  }
  const [every] = core.rows(core.addChange(core.emptyCart(), { op: 'release', id: 'LC0099', stages: ['*'] }), data);
  assert.equal(every.cells.length, 8, 'default and ci; vnext has no quarantine');
});

test('an id the data file does not have is unknownId with no cells', () => {
  const [row] = core.rows(core.addChange(core.emptyCart(), set('ZZ9999', 'None', ['strict'], ['ci'])), data);
  assert.equal(row.unknownId, true);
  assert.deepEqual(row.cells, []);
});

test('serialize writes the schema shape minified and drops an empty note and justification', () => {
  let cart = core.addChange(core.emptyCart(), set('AA0072', 'Info', ['*'], ['ci'], 'House style'));
  cart = core.addChange(cart, set('LC0015', 'None', ['strict'], ['ci']));
  cart = core.setJustification(cart, 1, '');
  cart = core.addChange(cart, { op: 'remove', id: 'LC0029', levels: ['recommended'], stages: ['ci'] });
  cart = core.addChange(cart, { op: 'release', id: 'LC0099', stages: ['ci'] });
  assert.equal(core.serialize(cart),
    '{"version":1,"changes":[{"op":"set","id":"AA0072","action":"Info","levels":["*"],"stages":["ci"],"justification":"House style"},' +
    '{"op":"set","id":"LC0015","action":"None","levels":["strict"],"stages":["ci"]},' +
    '{"op":"remove","id":"LC0029","levels":["recommended"],"stages":["ci"]},' +
    '{"op":"release","id":"LC0099","stages":["ci"]}]}');
  cart = core.setNote(cart, 'From the cart');
  assert.match(core.serialize(cart), /^\{"version":1,"note":"From the cart","changes":\[/);
  assert.equal(core.serialize(cart).includes('origin'), false);
});

test('issueUrl encodes the change set and the note, and leaves out an empty note', () => {
  const cart = core.addChange(core.emptyCart(), set('LC0015', 'None', ['strict'], ['ci'], 'A & B'));
  const url = core.issueUrl(repository, template, cart);
  assert.equal(url, 'https://github.com/contoso/rulebook/issues/new?template=rulebook-change.yml&changes=' + encodeURIComponent(core.serialize(cart)));
  assert.equal(url.includes('&note='), false);
  const noted = core.setNote(cart, 'Why: é');
  assert.ok(core.issueUrl(repository, template, noted).endsWith('&note=Why%3A%20%C3%A9'));
  assert.equal(new URL(core.issueUrl(repository, template, noted)).searchParams.get('changes'), core.serialize(noted));
  assert.equal(core.emptyFormUrl(repository, template), 'https://github.com/contoso/rulebook/issues/new?template=rulebook-change.yml');
});

test('byteLength counts UTF-8 bytes and fits flips at 7372 bytes', () => {
  assert.equal(core.byteLength('é'), 2);
  assert.equal(core.byteLength('abc'), 3);
  assert.deepEqual(core.fits('x'.repeat(7372)), { bytes: 7372, limit: 7372, ok: true });
  assert.deepEqual(core.fits('x'.repeat(7373)), { bytes: 7373, limit: 7372, ok: false });
  assert.equal(core.fits('x'.repeat(11), 10).ok, false);
});

test('splitParts packs changes greedily in order, keeps the note in every part and marks a change too large alone', () => {
  let cart = core.setNote(core.emptyCart(), 'Batch');
  const ids = data.rules.slice(0, 20).map((candidate) => candidate.id);
  for (const id of ids) cart = core.addChange(cart, set(id, 'None', ['strict'], ['ci'], 'x'.repeat(200)));
  const whole = core.fits(core.issueUrl(repository, template, cart));
  assert.equal(whole.ok, false);
  const parts = core.splitParts(repository, template, cart);
  assert.ok(parts.length > 1);
  assert.deepEqual(parts.flatMap((part) => part.cart.changes.map((change) => change.id)), ids);
  for (const part of parts) {
    assert.equal(part.oversize, false);
    assert.ok(part.bytes <= core.LIMIT_BYTES);
    assert.equal(part.cart.note, 'Batch');
    assert.equal(part.url, core.issueUrl(repository, template, part.cart));
  }
  // Greedy: the first change of each next part would not have fitted into the part before it.
  for (let i = 1; i < parts.length; i++) {
    const grown = { ...parts[i - 1].cart, changes: [...parts[i - 1].cart.changes, parts[i].cart.changes[0]] };
    assert.equal(core.fits(core.issueUrl(repository, template, grown)).ok, false);
  }
  let big = core.addChange(core.emptyCart(), set('AL0001', 'None', ['strict'], ['ci'], 'y'.repeat(8000)));
  big = core.addChange(big, set('AL0200', 'None', ['strict'], ['ci']));
  const split = core.splitParts(repository, template, big);
  assert.deepEqual(split.map((part) => [part.cart.changes.length, part.oversize]), [[1, true], [1, false]]);
  assert.deepEqual(core.splitParts(repository, template, core.emptyCart()), []);
});

test('copyPayload is the same change set, pretty-printed', () => {
  let cart = core.addChange(core.emptyCart(), set('AA0072', 'Info', ['*'], ['ci']));
  cart = core.setNote(cart, 'Note');
  const payload = core.copyPayload(cart);
  assert.ok(payload.includes('\n  "changes": [\n'));
  assert.deepEqual(JSON.parse(payload), JSON.parse(core.serialize(cart)));
});
