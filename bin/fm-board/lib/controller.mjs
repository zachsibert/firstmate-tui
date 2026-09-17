// lib/controller.mjs - key handling shared by the interactive app and the
// --render-once --keys test driver. keyAction() is pure: it maps a key on the
// current selection to one action. handleKey() applies that action to the view
// and calls back into the host for anything that touches the outside world
// (herdr focus, the browser opener, a refresh, quitting), so a test can drive
// the same code with fakes and read the resulting frame.
//
// Actions on a row:
//   enter   group row: expand or collapse; Ready for review / Needs you row
//           with a PR URL: open it; In flight worker or Needs you worker:
//           herdr focus
//   o       open the row's PR URL (any pane)
//   l/right expand the selected group      h/left collapse it (from the group
//           row or from one of its children; the selection lands on the group)

import { PANES } from './layout.mjs';

const OPEN_PANES = new Set(['review', 'needs']);
const FOCUS_PANES = new Set(['inflight', 'needs']);

// Move the selection: pure on (model, view). Returns { pane, row }.
export function moveSelection(model, view, key) {
  const v = { pane: view.pane, row: view.row };
  const count = (i) => model.panes[i].rows.length;
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
  if (count(v.pane) === 0) v.row = 0;
  else v.row = Math.min(v.row, count(v.pane) - 1);
  return v;
}

export function selectedRow(model, view) {
  const pane = model.panes[view.pane];
  return pane ? pane.rows[view.row] || null : null;
}

// Why a row cannot be focused right now, or null when `herdr agent focus` may
// run. Shared so the app and the --render-once driver report the same reasons.
export function focusProblem(pane, row, herdrOn) {
  if (!row) return 'nothing selected';
  if (!FOCUS_PANES.has(pane.id)) return 'enter focuses a worker: pick a row in In flight';
  if (!herdrOn) return 'herdr is off (--no-herdr); cannot focus';
  if (!row.paneId) return `${row.name}: no herdr pane to focus${row.extra === 'tmux' ? ' (tmux-backed task)' : ''}`;
  if (!row.focusable) return `${row.name}: pane lives in another host (${row.home})`;
  return null;
}

export function keyAction(model, view, key) {
  const pane = model.panes[view.pane];
  const row = pane ? pane.rows[view.row] || null : null;
  switch (key) {
    case 'q':
    case 'ctrl-c':
      return { type: 'quit' };
    case '?':
      return { type: 'help' };
    case 'r':
      return { type: 'refresh' };
    case 'o':
      if (!row) return { type: 'none' };
      if (row.url) return { type: 'open', row };
      return { type: 'notice', text: `${row.name}: no PR URL on this row`, bad: true };
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
      if (OPEN_PANES.has(pane.id) && row.url) return { type: 'open', row };
      if (pane.id === 'review') return { type: 'notice', text: `${row.name}: no PR URL on this row`, bad: true };
      if (FOCUS_PANES.has(pane.id)) return { type: 'focus', row };
      return {
        type: 'notice',
        text: row.url ? 'enter opens a PR from Ready for review or Needs you; press o to open this one' : 'enter opens a PR or focuses a worker: pick a row in Ready for review, Needs you or In flight',
        bad: true,
      };
    default:
      return { type: 'move', key };
  }
}

// ctx: { view, model, rebuild(), notice(text, bad), open(row), focus(row),
//        refresh(), quit() }. rebuild() must replace ctx.model from the current
// view (the expanded set changes which rows exist).
export function handleKey(ctx, key) {
  const { view } = ctx;
  if (view.help) {
    if (key === '?' || key === 'escape' || key === 'q' || key === 'enter') view.help = false;
    if (key === 'ctrl-c') ctx.quit();
    return;
  }
  const action = keyAction(ctx.model, view, key);
  switch (action.type) {
    case 'quit':
      ctx.quit();
      return;
    case 'help':
      view.help = true;
      return;
    case 'refresh':
      ctx.refresh();
      return;
    case 'open':
      ctx.open(action.row);
      return;
    case 'focus':
      ctx.focus(action.row);
      return;
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
    case 'move': {
      const v = moveSelection(ctx.model, view, key);
      view.pane = v.pane;
      view.row = v.row;
      return;
    }
    default:
      break;
  }
}
