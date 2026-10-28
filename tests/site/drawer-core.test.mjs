// Drawer suite for WP16 (#140): template/site/assets/js/drawer-core.mjs, the state machine of the cart drawer (open,
// close, the focus target) and its Tab trap. cart.mjs wires it to the page.
// Run with: node --test tests/site/*.test.mjs (Node 20 or later, no npm, no package.json).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as drawer from '../../template/site/assets/js/drawer-core.mjs';

const closed = { open: false };
const opened = { open: true };

test('the drawer starts closed', () => {
  assert.deepEqual(drawer.initialState(), closed);
  assert.deepEqual(drawer.EVENTS, ['add', 'badge', 'close', 'escape', 'overlay']);
});

test('an added change opens a closed drawer and moves the focus to its close button', () => {
  assert.deepEqual(drawer.transition(closed, 'add'), { open: true, focus: drawer.FOCUS_CLOSE_BUTTON });
  assert.equal(drawer.FOCUS_CLOSE_BUTTON, 'close-button');
});

test('an added change keeps an open drawer open and leaves the focus where it is', () => {
  assert.deepEqual(drawer.transition(opened, 'add'), { open: true, focus: null });
});

test('the Cart button opens a closed drawer and closes an open one, with the focus back on the button', () => {
  assert.deepEqual(drawer.transition(closed, 'badge'), { open: true, focus: drawer.FOCUS_CLOSE_BUTTON });
  assert.deepEqual(drawer.transition(opened, 'badge'), { open: false, focus: drawer.FOCUS_BADGE });
  assert.equal(drawer.FOCUS_BADGE, 'badge');
});

test('the close button, Escape and the overlay close an open drawer and return the focus to the Cart button', () => {
  for (const event of ['close', 'escape', 'overlay']) {
    assert.deepEqual(drawer.transition(opened, event), { open: false, focus: drawer.FOCUS_BADGE }, event);
  }
});

test('closing a closed drawer changes nothing and moves no focus', () => {
  for (const event of ['close', 'escape', 'overlay']) {
    assert.deepEqual(drawer.transition(closed, event), { open: false, focus: null }, event);
  }
});

test('a round trip: add, Escape, Cart button, overlay', () => {
  let state = drawer.initialState();
  const focus = [];
  for (const event of ['add', 'escape', 'badge', 'overlay']) {
    const result = drawer.transition(state, event);
    focus.push(result.focus);
    state = { open: result.open };
  }
  assert.deepEqual(state, closed);
  assert.deepEqual(focus, ['close-button', 'badge', 'close-button', 'badge']);
});

test('a missing state counts as closed, and the input state is never changed', () => {
  assert.deepEqual(drawer.transition(undefined, 'add'), { open: true, focus: 'close-button' });
  assert.deepEqual(drawer.transition(null, 'escape'), { open: false, focus: null });
  const state = { open: true };
  drawer.transition(state, 'close');
  assert.deepEqual(state, { open: true });
});

test('an unknown event throws', () => {
  assert.throws(() => drawer.transition(closed, 'open'), /Unknown drawer event: open/);
  assert.throws(() => drawer.transition(closed, undefined), /Unknown drawer event/);
});

test('Tab wraps from the last element to the first, Shift+Tab from the first to the last', () => {
  assert.equal(drawer.tabTarget(5, 4, false), 0);
  assert.equal(drawer.tabTarget(5, 0, true), 4);
});

test('Tab inside the drawer is left to the browser', () => {
  assert.equal(drawer.tabTarget(5, 0, false), -1);
  assert.equal(drawer.tabTarget(5, 2, false), -1);
  assert.equal(drawer.tabTarget(5, 2, true), -1);
  assert.equal(drawer.tabTarget(5, 4, true), -1);
});

test('a focus outside the drawer comes back in at the first element (Tab) or the last (Shift+Tab)', () => {
  assert.equal(drawer.tabTarget(5, -1, false), 0);
  assert.equal(drawer.tabTarget(5, -1, true), 4);
  assert.equal(drawer.tabTarget(5, 7, false), 0);
});

test('one focusable element keeps the focus on itself, none leaves Tab to the browser', () => {
  assert.equal(drawer.tabTarget(1, 0, false), 0);
  assert.equal(drawer.tabTarget(1, 0, true), 0);
  assert.equal(drawer.tabTarget(0, -1, false), -1);
  assert.equal(drawer.tabTarget(undefined, 0, false), -1);
});
