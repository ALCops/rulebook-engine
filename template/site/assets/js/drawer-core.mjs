// The cart drawer as pure functions: no DOM. cart.mjs shows and hides the drawer, moves the focus and traps Tab as
// these functions say, and tests/site/drawer-core.test.mjs (node --test) runs them.
//
// The drawer is a modal dialog: closed or open. It opens when a change is added (a cell's popover, a Release button)
// and on the Cart button of the header; it closes on its close button, on Escape and on a click on the overlay. The
// Cart button closes an open drawer too. On open the focus goes to the close button of the drawer, on close back to
// the Cart button; an event that changes nothing moves no focus.

export const EVENTS = ['add', 'badge', 'close', 'escape', 'overlay'];

// Where the focus goes after a transition: the close button inside the drawer, the Cart button of the header, or
// nowhere (null: the focus stays where it is).
export const FOCUS_CLOSE_BUTTON = 'close-button';
export const FOCUS_BADGE = 'badge';

export function initialState() {
  return { open: false };
}

// The next state of the drawer and the focus target for one event. Throws on an unknown event, so a typo in cart.mjs
// fails loudly instead of leaving the drawer stuck.
export function transition(state, event) {
  if (!EVENTS.includes(event)) throw new Error('Unknown drawer event: ' + event);
  const open = Boolean(state && state.open);
  let next;
  if (event === 'add') next = true;
  else if (event === 'badge') next = !open;
  else next = false;
  if (next === open) return { open, focus: null };
  return { open: next, focus: next ? FOCUS_CLOSE_BUTTON : FOCUS_BADGE };
}

// The Tab trap: given the number of focusable elements in the drawer (in document order), the position of the
// focused one (-1 when the focus is outside the drawer or on nothing) and whether Shift is held, the position to
// focus instead of the browser's own move, or -1 to let the browser move. Tab on the last element wraps to the first,
// Shift+Tab on the first wraps to the last, and a focus outside the drawer comes back in at the first (Tab) or the
// last (Shift+Tab).
export function tabTarget(count, index, backwards) {
  if (!Number.isInteger(count) || count <= 0) return -1;
  if (!Number.isInteger(index) || index < 0 || index >= count) return backwards ? count - 1 : 0;
  if (backwards && index === 0) return count - 1;
  if (!backwards && index === count - 1) return 0;
  return -1;
}
