// lib/controller.mjs - key and mouse handling shared by the interactive app
// and the --render-once --keys / --mouse test driver. keyAction() and
// mouseAction() are pure: they map a key, or a mouse event on the last drawn
// frame, to one action object. handleKey() and handleMouse() apply that action
// to the view through one applyAction() and call back into the host for
// anything that touches the outside world (herdr focus, the browser opener,
// the report viewer, a refresh, saving view state, quitting), so a test can
// drive the same code with fakes and read the resulting frame.
//
// Mouse (lib/tui-blessed.mjs translates the terminal's events; --mouse feeds
// the same objects): a left click selects the row under the pointer and
// focuses its pane, a click on a pane title or its empty space focuses the
// pane; two left clicks on one row within DBLCLICK_MS are a double-click and
// do what enter does there, and once a row has acted that way no further
// press on it within DBLCLICK_MS acts again, whatever else the terminal
// delivers for the gesture (a third press, or a release or drag report that
// arrives shaped as a press); the wheel moves the selection WHEEL_ROWS rows in
// the focused pane. Only the left button acts: herdr keeps the right button
// for its own pane menu, so nothing here is bound to it.
//
// Column widths: a left press on a pane's column-header line within a cell of
// the gutter between two columns (lib/layout.mjs boundaryAt) starts a drag of
// that boundary; each motion report with the button held moves the fixed
// column beside it by the pointer's travel, clamped between its label width
// plus one and what the flexible column can spare; the release ends the drag
// and saves the width (view.columns, by pane id and column key, in the
// board's view-state file). While it lasts, view.drag names the boundary and
// the renderer draws a bar there on the header and every row. A second press
// on the same boundary within DBLCLICK_MS is a double-click and resets that
// column to its automatic width; the = key, and the Settings page's `Reset
// column widths` entry, reset every column of every pane. A key pressed
// mid-drag ends the drag first.
//
// Actions on a row:
//   enter   group row: expand or collapse; a row with a hold card (row.card,
//           lib/model.mjs: Needs you's hold, decide and blocked rows, a
//           delegate's decision rows, and any In flight or Landed row whose
//           task is a captain hold): show the card in the viewer; My PRs,
//           Teammates' PRs or Needs you row with a PR URL: open it; In flight
//           worker or Needs you worker: herdr focus; Findings row: open its
//           report in the viewer; Landed row: the first target it has
//           (landedTarget): its PR, else its report on this host, else its
//           worker pane while herdr lists it, else a footer notice
//   F       focus the row's herdr pane, whatever the pane (a row without one
//           gets a notice): the secondary action on a card row, whose enter
//           shows the card (f through 0.6.6; f is the search now)
//   d       discard the row's captain hold (row.hold): the footer asks
//           `y to discard, esc to cancel`, then the host runs firstmate's
//           fm-captain-hold.sh answer in the hold's home (lib/hold.mjs)
//   D       defer the row's captain hold: the footer takes a YYYY-MM-DD date,
//           prefilled with today plus 14 days (digits and dashes edit it,
//           backspace deletes, enter defers, esc cancels), then the host runs
//           fm-captain-hold.sh hold --until with the hold's full reason
//           While either prompt is up (view.prompt, lib/card.mjs) every other
//           key is ignored and the mouse does nothing; ctrl-c still quits.
//           A row without a captain hold in a readable home gets a notice.
//           When the command succeeds the host drops every row of that task
//           from the frame at once (view.dismissed, a session-only set
//           lib/model.mjs reads beside view.hidden; never view state, never
//           shown by H) and starts a refresh; a failure leaves the row.
//   l/right expand the selected group      h/left collapse it (from the group
//           row or from one of its children; the selection lands on the group)
//   x       hide the row (view state); on a hidden row shown by H: unhide it
//   X       unhide every row of the current pane
// Board-wide:
//   f       search every pane's rows at once (the landing page too): the
//           footer takes a query (view.prompt kind 'search', lib/card.mjs)
//           and the frame becomes one results list, PANE first, ranked by
//           lib/search.mjs over model.search (every row of every pane: hidden
//           rows marked, rows beyond a pane's height, the children of
//           collapsed groups, the rows of hidden panes). Printable keys and
//           space type, backspace deletes, up/down, pageup/pagedown and
//           tab/S-tab move through the matches (j and k type, since a query
//           may need them), esc closes with the selection as it was, enter
//           jumps: the prompt closes, the row's pane is focused and shown if
//           it was hidden, its group expanded if collapsed, H switched on for
//           the session if the row is hidden, and the row selected, so the
//           next enter acts on it as usual. A click on a result selects it,
//           a double-click jumps, the wheel moves. Session state only: never
//           in the view-state file
//   H       toggle showing hidden rows (greyed, marked "(hidden)")
//   1-6     show or hide one pane, in screen order (In flight .. Landed;
//           lib/layout.mjs PANES); 0 shows all six.
//           Any pane may go, the last one too: with all six hidden the frame
//           is the landing page (lib/render.mjs) and only 0-6, r, ., ? and q
//           act (LANDING_KEYS below)
//   r       refresh (the snapshot and the PR checks, unless --no-prs)
//   =       reset every column width to its automatic size (view state)
//   .       the Settings page (lib/settings.mjs): installed version, latest
//           release, upgrade and betas through the launcher, read-only flags;
//           while it is open every key goes to settingsKeyAction and every
//           mouse event to settingsMouseAction; . / esc / q bring the board
//           back with its selection intact
//   ?       help       q / ctrl-c  quit

import { boundaryAt, hitTest, PANES } from './layout.mjs';
import { allPanesHidden } from './render.mjs';
import { confirmText, settingsKeyAction, settingsMouseAction, upgradeArgs } from './settings.mjs';
import { checkDeferDate, deferPrompt, discardPrompt, holdActionProblem, localDate, promptKeyAction, searchPrompt } from './card.mjs';
import { rankRows } from './search.mjs';

const OPEN_PANES = new Set(['mine', 'toreview', 'needs']);
const FOCUS_PANES = new Set(['inflight', 'needs']);
const VIEW_PANES = new Set(['findings']);
const LANDED_PANE = 'landed';

export const DBLCLICK_MS = 400;
export const WHEEL_ROWS = 3;

function paneCount(model, i) {
  const pane = model.panes[i];
  return !pane || pane.hidden ? 0 : pane.rows.length;
}

// Move the selection: pure on (model, view). Returns { pane, row }. Hidden
// panes count as empty, so tab and j/k skip them; a selection left on a pane
// that was just hidden lands on the next shown pane.
export function moveSelection(model, view, key) {
  const v = { pane: view.pane, row: view.row };
  const count = (i) => paneCount(model, i);
  const shown = (i) => !(model.panes[i] && model.panes[i].hidden);
  const nextPane = (from, dir) => {
    let i = from;
    for (let n = 0; n < PANES.length; n += 1) {
      i = (i + dir + PANES.length) % PANES.length;
      if (count(i) > 0) return i;
    }
    return from;
  };
  switch (key) {
    case 'j':
    case 'down':
      if (v.row + 1 < count(v.pane)) v.row += 1;
      else if (nextPane(v.pane, 1) !== v.pane && nextPane(v.pane, 1) > v.pane) {
        v.pane = nextPane(v.pane, 1);
        v.row = 0;
      }
      break;
    case 'k':
    case 'up':
      if (v.row > 0) v.row -= 1;
      else if (nextPane(v.pane, -1) !== v.pane && nextPane(v.pane, -1) < v.pane) {
        v.pane = nextPane(v.pane, -1);
        v.row = Math.max(0, count(v.pane) - 1);
      }
      break;
    case 'tab':
      v.pane = nextPane(v.pane, 1);
      v.row = 0;
      break;
    case 'S-tab':
      v.pane = nextPane(v.pane, -1);
      v.row = 0;
      break;
    case 'pagedown':
      v.row = Math.max(0, Math.min(count(v.pane) - 1, v.row + 10));
      break;
    case 'pageup':
      v.row = Math.max(0, v.row - 10);
      break;
    default:
      break;
  }
  if (!shown(v.pane)) {
    // Prefer a shown pane with rows (cycling forward), else any shown pane.
    const withRows = nextPane(v.pane, 1);
    if (withRows !== v.pane && shown(withRows)) v.pane = withRows;
    else {
      const any = PANES.map((_, i) => i).find((i) => shown(i));
      if (any !== undefined) v.pane = any;
    }
    v.row = 0;
  }
  if (count(v.pane) === 0) v.row = 0;
  else v.row = Math.min(v.row, count(v.pane) - 1);
  return v;
}

export function selectedRow(model, view) {
  const pane = model.panes[view.pane];
  return pane && !pane.hidden ? pane.rows[view.row] || null : null;
}

// The selection as the view-state file keeps it (lib/viewstate.mjs `focus`):
// the pane id, the selected row's hide key (the one stable id a row has; null
// on an empty pane) and its index, the fallback when the row is gone.
export function savedFocus(model, view) {
  const pane = model.panes[view.pane];
  if (!pane) return null;
  const row = pane.rows[view.row] || null;
  return { pane: pane.id, row: row ? row.hideKey : null, index: row ? view.row : 0 };
}

// A saved selection back onto the current model: the row with that hide key
// in that pane, else the saved index clamped to the pane's rows. null when
// the pane is unknown, or still loading its first data (the caller waits and
// asks again once the rows are there).
export function focusFromSaved(model, saved) {
  if (!saved || !saved.pane) return null;
  const idx = model.panes.findIndex((p) => p.id === saved.pane);
  if (idx < 0) return null;
  const pane = model.panes[idx];
  if (pane.loading) return null;
  const byKey = saved.row ? pane.rows.findIndex((r) => r.hideKey === saved.row) : -1;
  const row = byKey >= 0 ? byKey : Math.max(0, Math.min(Number.isInteger(saved.index) ? saved.index : 0, pane.rows.length - 1));
  return { pane: idx, row };
}

// The scroll offsets as the file keeps them (by pane id) from the renderer's
// list (by pane index), and back. Zero offsets are left out.
export function savedScroll(scroll) {
  const out = {};
  PANES.forEach((p, i) => {
    const n = Array.isArray(scroll) ? scroll[i] : null;
    if (Number.isInteger(n) && n > 0) out[p.id] = n;
  });
  return out;
}

export function scrollFromSaved(saved) {
  return PANES.map((p) => (saved && Number.isInteger(saved[p.id]) && saved[p.id] > 0 ? saved[p.id] : 0));
}

// Why a row cannot be focused right now, or null when `herdr agent focus` may
// run. Shared so the app and the --render-once driver report the same reasons.
// A lost pane is reported before the herdr-off check: the fixture overlay can
// prove the pane gone even when the live client is off, and "pane lost" is the
// more useful answer. `any` is the f key: a row in any pane may be focused,
// and one without a pane is told so first.
export function focusProblem(pane, row, herdrOn, { any = false } = {}) {
  if (!row) return 'nothing selected';
  if (any && !row.paneId) return `${row.name}: no herdr pane to focus${row.extra === 'tmux' ? ' (tmux-backed task)' : ''}`;
  if (!any && !FOCUS_PANES.has(pane.id) && !(pane.id === LANDED_PANE && row.paneId)) return 'enter focuses a worker: pick a row in In flight';
  if (row.lost) return `${row.name}: pane ${row.paneId} is gone from herdr (pane lost); nothing to focus`;
  if (!herdrOn) return 'herdr is off (--no-herdr); cannot focus';
  if (!row.paneId) return `${row.name}: no herdr pane to focus${row.extra === 'tmux' ? ' (tmux-backed task)' : ''}`;
  if (!row.focusable) return `${row.name}: pane lives in another host (${row.home})`;
  return null;
}

// Why a Findings row (or a Landed row that records a report) cannot be
// viewed, or null.
export function viewProblem(pane, row) {
  if (!row) return 'nothing selected';
  if (!VIEW_PANES.has(pane.id) && !(pane.id === LANDED_PANE && (row.reportPath || row.reportRemote))) return 'enter views a report: pick a row in Findings';
  if (row.reportRemote) return `${row.name}: report lives on another host (${row.home}); not reachable from here`;
  if (!row.reportPath) return `${row.name}: no report path on this row`;
  return null;
}

// What enter does on a Landed row: the first target the row has that this
// board can reach, as an action type, or null when there is none. A PR URL
// opens; else a report on this host is viewed (a remote home's report is
// skipped, not refused: nothing here can show it); else the task's worker pane
// is focused while herdr still lists it (a lost pane is skipped the same way,
// and so is every pane under --no-herdr, when herdrOn is false). Pure, so the
// double-click path (mouseAction -> keyAction) follows it without a case of
// its own.
export function landedTarget(row, herdrOn) {
  if (!row) return null;
  if (row.url) return 'open';
  if (row.reportPath && !row.reportRemote) return 'view';
  if (herdrOn && row.paneId && !row.lost && row.focusable) return 'focus';
  return null;
}

export function paneForKey(key) {
  const i = Number(key) - 1;
  return Number.isInteger(i) && i >= 0 && i < PANES.length ? PANES[i].id : null;
}

// Keys that still mean something on the landing page (every pane hidden). A
// key that would otherwise move the selection or act on a row nobody can see
// only reminds the captain how to bring a pane back; a key the board does not
// bind stays the silent no-op it is everywhere else.
const LANDING_KEYS = new Set(['0', '1', '2', '3', '4', '5', '6', 'f', 'r', '.', '?', 'q', 'ctrl-c']);
const ROW_KEYS = new Set(['enter', 'F', 'd', 'D', 'x', 'X', 'H', 'l', 'right', 'h', 'left', 'j', 'down', 'k', 'up', 'tab', 'S-tab', 'pageup', 'pagedown']);

export function keyAction(model, view, key) {
  const pane = model.panes[view.pane];
  const row = pane && !pane.hidden ? pane.rows[view.row] || null : null;
  if (allPanesHidden(model) && !LANDING_KEYS.has(key)) return ROW_KEYS.has(key) ? { type: 'notice', text: 'all panes hidden · 1-6 shows a pane, 0 shows all' } : { type: 'none' };
  switch (key) {
    case 'q':
    case 'ctrl-c':
      return { type: 'quit' };
    case '?':
      return { type: 'help' };
    case '.':
      return { type: 'settings' };
    case 'r':
      return { type: 'refresh' };
    case '=':
      return { type: 'reset-columns' };
    case 'H':
      return { type: 'toggle-hidden' };
    case '0':
      return { type: 'show-panes' };
    case '1':
    case '2':
    case '3':
    case '4':
    case '5':
    case '6':
      return { type: 'toggle-pane', paneId: paneForKey(key), key };
    case 'x':
      if (!row) return { type: 'notice', text: 'nothing selected to hide', bad: true };
      return { type: row.hidden ? 'unhide' : 'hide', row };
    case 'f':
      return { type: 'search-prompt' };
    case 'F':
      if (!row) return { type: 'notice', text: 'nothing selected to focus', bad: true };
      return { type: 'focus', row, any: true };
    case 'd':
    case 'D': {
      const problem = holdActionProblem(row, key === 'd' ? 'discard' : 'defer');
      if (problem) return { type: 'notice', text: problem, bad: true };
      return { type: key === 'd' ? 'discard-prompt' : 'defer-prompt', row };
    }
    case 'X':
      return pane ? { type: 'unhide-pane', paneId: pane.id, title: pane.title } : { type: 'none' };
    case 'l':
    case 'right':
      if (row && row.group && !row.expanded) return { type: 'expand', key: row.group };
      return { type: 'none' };
    case 'h':
    case 'left': {
      const key2 = row ? row.parent || (row.expanded ? row.group : null) : null;
      return key2 ? { type: 'collapse', key: key2 } : { type: 'none' };
    }
    case 'enter':
      if (!row) return { type: 'none' };
      if (row.group) return row.expanded ? { type: 'collapse', key: row.group } : { type: 'expand', key: row.group };
      // A hold card wins over the pane's own enter; review rows carry none.
      if (row.card) return { type: 'card', row };
      if (pane.id === LANDED_PANE) {
        const target = landedTarget(row, Boolean(model.herdrOn));
        if (target) return { type: target, row };
        // Nothing this board can reach: an ordinary notice, not an error.
        return { type: 'notice', text: `${row.name}: nothing to open (no PR, report or pane)`, bad: false };
      }
      if (OPEN_PANES.has(pane.id) && row.url) return { type: 'open', row };
      if (FOCUS_PANES.has(pane.id)) return { type: 'focus', row };
      if (VIEW_PANES.has(pane.id)) return { type: 'view', row };
      // A PR pane without a PR URL (every other pane is covered above).
      return { type: 'notice', text: `${row.name}: no PR URL on this row`, bad: true };
    default:
      return { type: 'move', key };
  }
}

// The search prompt's matches over the current model, best first
// (lib/search.mjs rankRows over model.search), and the prompt's cursor
// clamped to them. Both the renderer and the actions below read them, so the
// row the frame highlights is the row enter jumps to.
export function searchResults(model, prompt) {
  if (!prompt || prompt.kind !== 'search') return [];
  return rankRows(prompt.value, model && Array.isArray(model.search) ? model.search : []);
}

export function searchIndex(prompt, count) {
  if (!count) return 0;
  return Math.max(0, Math.min(Number.isInteger(prompt.index) ? prompt.index : 0, count - 1));
}

// Two marks { time } are within the double-click window of each other.
function within(mark, ev) {
  const since = mark && Number.isFinite(mark.time) && Number.isFinite(ev.time) ? ev.time - mark.time : NaN;
  return since >= 0 && since <= DBLCLICK_MS;
}

// A mouse event, from the terminal adapter or the --mouse list:
//   { type: 'down' | 'up' | 'drag' | 'wheel', button: 'left' | 'right' |
//     'middle', x, y, dir: 'up' | 'down', time }
// x and y count cells from 0 at the top-left; time is milliseconds on any
// one clock; `drag` is motion with the button held. view.frame is the last
// drawn frame's { cols, rows, zones } (renderFrame) and view.lastClick the
// previous left click, on a row { pane, row, time } or on a column boundary
// { boundary: { pane, index }, time }, which is how a double-click is
// recognized here rather than by the terminal library. view.lastActivate,
// { pane, row, time } set by applyAction when a double-click acts (absent
// until the first one), is the guard: a press on that row within DBLCLICK_MS
// of it only selects and starts no new pair, so one gesture opens a PR
// exactly once however many presses the terminal reports for it; a press
// after the window, or enter at any time, acts as usual. view.drag is the
// column drag in progress or null.
// Actions: select (pane focus and cursor, also for a title or empty space),
// activate (a double-click: the enter action for that row), wheel,
// drag-start / drag-move / drag-end (a column boundary), reset-column (a
// double-click on a boundary), none. Only the left button acts.
export function mouseAction(model, view, ev) {
  if (!ev || allPanesHidden(model)) return { type: 'none' };
  const drag = view.drag || null;
  if (drag) {
    if (ev.type === 'drag') return { type: 'drag-move', x: ev.x };
    if (ev.type === 'up') return { type: 'drag-end' };
    if (ev.type === 'down' && ev.button === 'left') {
      // A press while the drag is still open: the harness's dblclick (two
      // presses, no release), or a terminal that skipped the release. On the
      // same boundary inside the window it is the double-click that resets
      // the column; anywhere else it ends the drag.
      const b = boundaryAt(view.frame, ev.x, ev.y);
      if (b && b.pane === drag.pane && b.index === drag.index && within(drag, ev)) return { type: 'reset-column', paneId: drag.paneId, columnId: drag.columnId, label: drag.label };
      return { type: 'drag-end' };
    }
    return { type: 'none' };
  }
  if (ev.type === 'up' || ev.type === 'drag') return { type: 'none' };
  if (ev.type === 'wheel') return { type: 'wheel', dir: ev.dir === 'up' ? -1 : 1 };
  if (ev.type !== 'down' || ev.button !== 'left') return { type: 'none' };
  const boundary = boundaryAt(view.frame, ev.x, ev.y);
  if (boundary) {
    const pane = model.panes[boundary.pane];
    if (!pane || pane.hidden) return { type: 'none' };
    const last = view.lastClick;
    if (last && last.boundary && last.boundary.pane === boundary.pane && last.boundary.index === boundary.index && within(last, ev)) {
      return { type: 'reset-column', paneId: pane.id, columnId: boundary.columnId, label: boundary.label };
    }
    return {
      type: 'drag-start',
      pane: boundary.pane,
      paneId: pane.id,
      index: boundary.index,
      columnId: boundary.columnId,
      label: boundary.label,
      startX: ev.x,
      startWidth: boundary.width,
      sign: boundary.sign,
      min: boundary.min,
      max: boundary.max,
      time: ev.time,
      click: { boundary: { pane: boundary.pane, index: boundary.index }, time: ev.time },
    };
  }
  const hit = hitTest(view.frame, ev.x, ev.y);
  if (!hit) return { type: 'none' };
  const pane = model.panes[hit.pane];
  if (!pane || pane.hidden) return { type: 'none' };
  if (hit.kind !== 'row') return { type: 'select', pane: hit.pane, row: hit.pane === view.pane ? view.row : 0 };
  const sameRowWithin = (mark) => Boolean(mark) && mark.pane === hit.pane && mark.row === hit.row && within(mark, ev);
  if (sameRowWithin(view.lastActivate)) return { type: 'select', pane: hit.pane, row: hit.row };
  if (sameRowWithin(view.lastClick)) {
    return { type: 'activate', pane: hit.pane, row: hit.row, time: ev.time, action: keyAction(model, { ...view, pane: hit.pane, row: hit.row }, 'enter') };
  }
  return { type: 'select', pane: hit.pane, row: hit.row, click: { pane: hit.pane, row: hit.row, time: ev.time } };
}

// A mouse event while the search prompt is up: a left click on a result
// selects it, two within DBLCLICK_MS jump to it (view.lastClick keeps the
// first as { result, time }), the wheel moves the cursor; everything else
// does nothing. The results view's zones are { kind: 'result', index }
// (lib/render.mjs renderSearch, lib/layout.mjs hitTest).
export function searchMouseAction(model, view, ev) {
  if (!ev) return { type: 'none' };
  if (ev.type === 'wheel') return { type: 'search-move', by: (ev.dir === 'up' ? -1 : 1) * WHEEL_ROWS };
  if (ev.type !== 'down' || ev.button !== 'left') return { type: 'none' };
  const hit = hitTest(view.frame, ev.x, ev.y);
  if (!hit || hit.kind !== 'result') return { type: 'none' };
  const last = view.lastClick;
  if (last && last.result === hit.index && within(last, ev)) return { type: 'search-activate', index: hit.index };
  return { type: 'search-select', index: hit.index, click: { result: hit.index, time: ev.time } };
}

function clampSelection(ctx) {
  const v = moveSelection(ctx.model, ctx.view, null);
  ctx.view.pane = v.pane;
  ctx.view.row = v.row;
}

// The jump enter (or a double-click) makes from a search result: the row's
// pane shown if it was hidden (as its number key would, saved with the view
// state), its group expanded if collapsed, H switched on for the session if
// the row is hidden, then the model rebuilt and the row found again by its
// hide key and selected. The footer names the row, its pane and whatever had
// to change for it to be seen.
function jumpToResult(ctx, target) {
  const { view } = ctx;
  const { row, paneId, paneTitle } = target;
  const notes = [];
  if (view.hiddenPanes.has(paneId)) {
    view.hiddenPanes.delete(paneId);
    ctx.persist();
    notes.push(`pane shown: ${paneTitle}`);
  }
  if (row.parent && !view.expanded.has(row.parent)) {
    view.expanded.add(row.parent);
    notes.push('group expanded');
  }
  if (row.hidden && !view.showHidden) {
    view.showHidden = true;
    notes.push('hidden row: H is on for this session');
  }
  ctx.rebuild();
  const paneIdx = ctx.model.panes.findIndex((p) => p.id === paneId);
  const pane = paneIdx >= 0 ? ctx.model.panes[paneIdx] : null;
  const idx = pane ? pane.rows.findIndex((r) => r.hideKey === row.hideKey) : -1;
  if (paneIdx >= 0) view.pane = paneIdx;
  view.row = idx >= 0 ? idx : 0;
  view.lastClick = null;
  clampSelection(ctx);
  ctx.notice(`${row.name} in ${paneTitle}${notes.length ? ` · ${notes.join(' · ')}` : ''}${idx < 0 ? ' · row not found after the rebuild' : ''}`, idx < 0);
}

// The captain's column widths in the view: view.columns[paneId][columnId].
function overrideOf(view, paneId, columnId) {
  const pane = view.columns && view.columns[paneId];
  return pane && Number.isInteger(pane[columnId]) ? pane[columnId] : undefined;
}

function setOverride(view, paneId, columnId, w) {
  if (!view.columns || typeof view.columns !== 'object') view.columns = {};
  if (!view.columns[paneId]) view.columns[paneId] = {};
  view.columns[paneId][columnId] = w;
}

function clearOverride(view, paneId, columnId) {
  const pane = view.columns && view.columns[paneId];
  if (!pane) return;
  delete pane[columnId];
  if (!Object.keys(pane).length) delete view.columns[paneId];
}

function overrideCount(view) {
  return Object.values(view.columns || {}).reduce((n, pane) => n + Object.keys(pane || {}).length, 0);
}

// The Settings page, open: one action from settingsKeyAction or
// settingsMouseAction (lib/settings.mjs decides what a key or a click means)
// applied to view.settings, with the effects handed to the host:
// settingsFetch() fetches the release data, settingsUpgrade(running) starts
// the launcher's upgrade and later calls finishUpgrade, relaunch() exits the
// board with RELAUNCH_EXIT. Closing the page never touches the board's
// selection, expanded groups or hidden rows. `reset-columns` is the one entry
// that acts on the board's view, through the same applyAction as the = key.
function applySettingsAction(ctx, action) {
  const { view } = ctx;
  const s = view.settings;
  switch (action.type) {
    case 'quit':
      ctx.quit();
      return;
    case 'close':
      s.pending = null;
      view.page = 'board';
      view.lastClick = null;
      return;
    case 'help':
      view.help = true;
      return;
    case 'menu':
      s.menu = action.menu;
      s.cursor = 0;
      view.lastClick = null;
      return;
    case 'move':
      s.cursor = action.cursor;
      view.lastClick = action.click || null;
      return;
    case 'activate':
      s.cursor = action.cursor;
      view.lastClick = null;
      applySettingsAction(ctx, action.action);
      return;
    case 'fetch':
      ctx.settingsFetch();
      return;
    case 'confirm':
      s.pending = { channel: action.channel, version: action.version };
      ctx.notice(confirmText(s.pending));
      return;
    case 'cancel':
      s.pending = null;
      ctx.notice('cancelled; nothing was installed');
      return;
    case 'upgrade': {
      s.pending = null;
      s.running = { channel: action.channel, version: action.version, args: upgradeArgs(action) };
      s.output = [];
      s.result = null;
      ctx.notice(`running firstmate-tui upgrade ${s.running.args.join(' ')} …`);
      ctx.settingsUpgrade(s.running);
      return;
    }
    case 'relaunch':
      ctx.relaunch();
      return;
    case 'reset-columns':
      applyAction(ctx, action);
      return;
    case 'notice':
      ctx.notice(action.text, action.bad);
      return;
    default:
      break;
  }
}

// ctx: { view, model, rebuild(), notice(text, bad), open(row), focus(row,
//        { any }), viewReport(row), viewCard(row), holdDiscard(row),
//        holdDefer(row, { reason, until }), holdReason(row), refresh(),
//        persist(), settingsFetch(), settingsUpgrade(running), relaunch(),
//        quit() }.
// rebuild() must replace ctx.model from the current view (the expanded set,
// the hidden set, the dismissed set and the hidden panes change which rows
// and panes exist); persist() saves view.hidden, view.hiddenPanes and
// view.columns, never view.dismissed. The three
// hold effects run firstmate's command or read a delegate home (lib/hold.mjs)
// and set view.busy to a short text meanwhile, which the actions here
// refuse to start over; holdReason(row) reads a delegate hold's full reason
// and then calls openDeferPrompt itself, or notices why it cannot.
export function handleKey(ctx, key) {
  const { view } = ctx;
  if (view.help) {
    if (key === '?' || key === 'escape' || key === 'q' || key === 'enter') view.help = false;
    if (key === 'ctrl-c') ctx.quit();
    return;
  }
  if (view.page === 'settings') {
    applySettingsAction(ctx, settingsKeyAction(view.settings, key));
    return;
  }
  if (view.prompt) {
    applyAction(ctx, promptKeyAction(view.prompt, key));
    return;
  }
  if (view.drag) applyAction(ctx, { type: 'drag-end' });
  applyAction(ctx, keyAction(ctx.model, view, key));
}

// The defer prompt on `row` with the hold's full `reason`, prefilled with
// today plus 14 days (lib/card.mjs deferPrompt). Called by applyAction when
// the row carries the full reason and by the host once it has read it.
export function openDeferPrompt(view, row, reason) {
  view.prompt = deferPrompt(row, reason, localDate());
  view.lastClick = null;
}

export function handleMouse(ctx, ev) {
  const { view } = ctx;
  if (!ev) return;
  if (view.help) {
    if (ev.type === 'down') view.help = false;
    return;
  }
  if (view.page === 'settings') {
    applySettingsAction(ctx, settingsMouseAction(view.settings, view, ev, { dblclickMs: DBLCLICK_MS }));
    return;
  }
  // The search prompt's results take the mouse; the hold prompts take the
  // keyboard alone: a click neither confirms nor cancels them.
  if (view.prompt && view.prompt.kind === 'search') {
    applyAction(ctx, searchMouseAction(ctx.model, view, ev));
    return;
  }
  if (view.prompt) return;
  // A release or a motion report means nothing unless a drag is open.
  if ((ev.type === 'up' || ev.type === 'drag') && !view.drag) return;
  applyAction(ctx, mouseAction(ctx.model, view, ev));
}

function applyAction(ctx, action) {
  const { view } = ctx;
  const clamp = () => clampSelection(ctx);
  switch (action.type) {
    case 'select':
      view.pane = action.pane;
      view.row = action.row;
      view.lastClick = action.click || null;
      clamp();
      return;
    case 'activate':
      view.pane = action.pane;
      view.row = action.row;
      view.lastClick = null;
      view.lastActivate = { pane: action.pane, row: action.row, time: action.time };
      clamp();
      applyAction(ctx, action.action);
      return;
    case 'wheel': {
      const count = paneCount(ctx.model, view.pane);
      if (count > 0) view.row = Math.max(0, Math.min(count - 1, view.row + action.dir * WHEEL_ROWS));
      view.lastClick = null;
      return;
    }
    case 'drag-start':
      // `before` is the override the drag may replace (undefined for an
      // automatic width), so a drag that ends where it began leaves nothing
      // behind; `moved` says whether any motion arrived.
      view.drag = {
        pane: action.pane,
        paneId: action.paneId,
        index: action.index,
        columnId: action.columnId,
        label: action.label,
        startX: action.startX,
        startWidth: action.startWidth,
        sign: action.sign,
        min: action.min,
        max: action.max,
        time: action.time,
        before: overrideOf(view, action.paneId, action.columnId),
        moved: false,
      };
      view.lastClick = action.click;
      return;
    case 'drag-move': {
      const d = view.drag;
      if (!d) return;
      const w = Math.max(d.min, Math.min(d.max, d.startWidth + d.sign * (action.x - d.startX)));
      setOverride(view, d.paneId, d.columnId, w);
      d.moved = true;
      return;
    }
    case 'drag-end': {
      const d = view.drag;
      if (!d) return;
      view.drag = null;
      if (!d.moved) return;
      // Dragged back to the automatic width: no override to keep.
      if (d.before === undefined && overrideOf(view, d.paneId, d.columnId) === d.startWidth) clearOverride(view, d.paneId, d.columnId);
      const w = overrideOf(view, d.paneId, d.columnId);
      if (w === d.before) return;
      ctx.persist();
      ctx.notice(w === undefined ? `${d.label} back to its automatic width` : `${d.label} ${w} wide · double-click the boundary resets it, = resets every column`);
      return;
    }
    case 'reset-column': {
      view.drag = null;
      view.lastClick = null;
      const had = overrideOf(view, action.paneId, action.columnId) !== undefined;
      clearOverride(view, action.paneId, action.columnId);
      if (had) ctx.persist();
      ctx.notice(had ? `${action.label} back to its automatic width` : `${action.label} already has its automatic width`);
      return;
    }
    case 'reset-columns': {
      view.drag = null;
      const n = overrideCount(view);
      view.columns = {};
      if (n) {
        ctx.persist();
        ctx.notice(`column widths reset: ${n} custom width${n === 1 ? '' : 's'} dropped, every column automatic again`);
      } else ctx.notice('no custom column widths to reset; every column is automatic');
      return;
    }
    case 'quit':
      ctx.quit();
      return;
    case 'help':
      view.help = true;
      return;
    case 'settings':
      // Open on the main menu with the cursor at the top; the release data is
      // fetched on every open (never on the refresh tick), and a result from
      // an earlier visit stays on the page.
      view.page = 'settings';
      view.settings.menu = 'main';
      view.settings.cursor = 0;
      view.settings.pending = null;
      view.lastClick = null;
      ctx.settingsFetch();
      return;
    case 'refresh':
      ctx.refresh();
      return;
    case 'open':
      ctx.open(action.row);
      return;
    case 'focus':
      ctx.focus(action.row, { any: Boolean(action.any) });
      return;
    case 'view':
      ctx.viewReport(action.row);
      return;
    case 'card':
      if (view.busy) {
        ctx.notice(`busy: ${view.busy}`, true);
        return;
      }
      ctx.viewCard(action.row);
      return;
    case 'discard-prompt':
      if (view.busy) {
        ctx.notice(`busy: ${view.busy}`, true);
        return;
      }
      view.prompt = discardPrompt(action.row);
      view.lastClick = null;
      return;
    case 'defer-prompt': {
      if (view.busy) {
        ctx.notice(`busy: ${view.busy}`, true);
        return;
      }
      const { hold } = action.row;
      if (hold.reason && !hold.truncated) {
        openDeferPrompt(view, action.row, hold.reason);
        return;
      }
      // A delegate home's hold: the ledger keeps the reason cut at 160
      // characters, so the host reads the home's own record first and opens
      // the prompt with the full reason, or refuses rather than shorten it.
      ctx.holdReason(action.row);
      return;
    }
    case 'prompt-cancel': {
      const p = view.prompt;
      view.prompt = null;
      ctx.notice(`cancelled; ${p ? p.id : 'the hold'} is unchanged`);
      return;
    }
    case 'discard': {
      const p = view.prompt;
      view.prompt = null;
      if (p) ctx.holdDiscard(p.row);
      return;
    }
    case 'defer-edit':
      if (view.prompt) view.prompt = { ...view.prompt, value: action.value };
      return;
    case 'defer-submit': {
      const p = view.prompt;
      if (!p) return;
      const problem = checkDeferDate(p.value, localDate());
      if (problem) {
        // The prompt stays open with its value for the captain to fix.
        ctx.notice(problem, true);
        return;
      }
      view.prompt = null;
      ctx.holdDefer(p.row, { reason: p.reason, until: p.value });
      return;
    }
    case 'search-prompt':
      view.drag = null;
      view.lastClick = null;
      view.prompt = searchPrompt();
      return;
    case 'search-edit':
      // A changed query starts again from its best match.
      if (view.prompt && view.prompt.kind === 'search') view.prompt = { ...view.prompt, value: action.value, index: 0 };
      return;
    case 'search-move': {
      const p = view.prompt;
      if (!p || p.kind !== 'search') return;
      const n = searchResults(ctx.model, p).length;
      view.prompt = { ...p, index: n ? Math.max(0, Math.min(n - 1, searchIndex(p, n) + action.by)) : 0 };
      view.lastClick = null;
      return;
    }
    case 'search-select':
      if (view.prompt && view.prompt.kind === 'search') view.prompt = { ...view.prompt, index: action.index };
      view.lastClick = action.click || null;
      return;
    case 'search-activate':
      if (view.prompt && view.prompt.kind === 'search') view.prompt = { ...view.prompt, index: action.index };
      view.lastClick = null;
      applyAction(ctx, { type: 'search-jump' });
      return;
    case 'search-cancel':
      // The selection was never touched while the prompt was up.
      view.prompt = null;
      view.lastClick = null;
      return;
    case 'search-jump': {
      const p = view.prompt;
      if (!p || p.kind !== 'search') return;
      const results = searchResults(ctx.model, p);
      // No match: the prompt stays up and enter does nothing.
      if (!results.length) return;
      const target = results[searchIndex(p, results.length)];
      view.prompt = null;
      jumpToResult(ctx, target);
      return;
    }
    case 'notice':
      ctx.notice(action.text, action.bad);
      return;
    case 'expand':
      view.expanded.add(action.key);
      ctx.rebuild();
      return;
    case 'collapse': {
      view.expanded.delete(action.key);
      ctx.rebuild();
      const pane = ctx.model.panes[view.pane];
      const idx = pane ? pane.rows.findIndex((r) => r.group === action.key) : -1;
      if (idx >= 0) view.row = idx;
      return;
    }
    case 'hide':
      view.hidden.add(action.row.hideKey);
      ctx.rebuild();
      clamp();
      ctx.persist();
      ctx.notice(`hidden ${action.row.name} · H shows hidden rows, X unhides this pane`);
      return;
    case 'unhide':
      view.hidden.delete(action.row.hideKey);
      ctx.rebuild();
      clamp();
      ctx.persist();
      ctx.notice(`unhidden ${action.row.name}`);
      return;
    case 'unhide-pane': {
      const prefix = `${action.paneId}:`;
      const keys = [...view.hidden].filter((k) => k.startsWith(prefix));
      for (const k of keys) view.hidden.delete(k);
      ctx.rebuild();
      clamp();
      if (keys.length) {
        ctx.persist();
        ctx.notice(`unhidden ${keys.length} row${keys.length === 1 ? '' : 's'} in ${action.title}`);
      } else ctx.notice(`nothing hidden in ${action.title}`);
      return;
    }
    case 'toggle-hidden':
      view.showHidden = !view.showHidden;
      ctx.rebuild();
      clamp();
      ctx.notice(view.showHidden ? 'showing hidden rows (greyed); H hides them again' : 'hidden rows out of view');
      return;
    case 'toggle-pane': {
      const pane = ctx.model.panes.find((p) => p.id === action.paneId);
      if (!pane) return;
      if (view.hiddenPanes.has(action.paneId)) {
        view.hiddenPanes.delete(action.paneId);
        ctx.rebuild();
        clamp();
        ctx.persist();
        ctx.notice(`pane shown: ${pane.title}`);
        return;
      }
      view.hiddenPanes.add(action.paneId);
      ctx.rebuild();
      clamp();
      ctx.persist();
      if (allPanesHidden(ctx.model)) ctx.notice(`pane hidden: ${pane.title} · every pane hidden; 1-6 or 0 shows them`);
      else ctx.notice(`pane hidden: ${pane.title} · ${action.key} or 0 shows it again`);
      return;
    }
    case 'show-panes':
      if (view.hiddenPanes.size === 0) {
        ctx.notice('every pane is already shown');
        return;
      }
      view.hiddenPanes.clear();
      ctx.rebuild();
      clamp();
      ctx.persist();
      ctx.notice('all panes shown');
      return;
    case 'move': {
      const v = moveSelection(ctx.model, view, action.key);
      view.pane = v.pane;
      view.row = v.row;
      return;
    }
    default:
      break;
  }
}
