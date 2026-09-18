// lib/controller.mjs - key handling shared by the interactive app and the
// --render-once --keys test driver. keyAction() is pure: it maps a key on the
// current selection to one action. handleKey() applies that action to the view
// and calls back into the host for anything that touches the outside world
// (herdr focus, the browser opener, the report viewer, a refresh, saving
// view state, quitting), so a test can drive the same
// code with fakes and read the resulting frame.
//
// Actions on a row:
//   enter   group row: expand or collapse; Ready for review, Landed or Needs
//           you row with a PR URL: open it; In flight worker or Needs you
//           worker: herdr focus; Findings row: open its report in the viewer
//   l/right expand the selected group      h/left collapse it (from the group
//           row or from one of its children; the selection lands on the group)
//   x       hide the row (view state); on a hidden row shown by H: unhide it
//   X       unhide every row of the current pane
// Board-wide:
//   H       toggle showing hidden rows (greyed, marked "(hidden)")
//   1-5     show or hide one pane (Needs you .. Landed); 0 shows all five.
//           Any pane may go, the last one too: with all five hidden the frame
//           is the landing page (lib/render.mjs) and only 0-5, r, ? and q act
//   r       refresh (the snapshot, and the PR checks when --prs is on)
//   ?       help       q / ctrl-c  quit

import { PANES } from './layout.mjs';
import { allPanesHidden } from './render.mjs';

const OPEN_PANES = new Set(['review', 'needs', 'landed']);
const FOCUS_PANES = new Set(['inflight', 'needs']);
const VIEW_PANES = new Set(['findings']);

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

// Why a row cannot be focused right now, or null when `herdr agent focus` may
// run. Shared so the app and the --render-once driver report the same reasons.
// A lost pane is reported before the herdr-off check: the fixture overlay can
// prove the pane gone even when the live client is off, and "pane lost" is the
// more useful answer.
export function focusProblem(pane, row, herdrOn) {
  if (!row) return 'nothing selected';
  if (!FOCUS_PANES.has(pane.id)) return 'enter focuses a worker: pick a row in In flight';
  if (row.lost) return `${row.name}: pane ${row.paneId} is gone from herdr (pane lost); nothing to focus`;
  if (!herdrOn) return 'herdr is off (--no-herdr); cannot focus';
  if (!row.paneId) return `${row.name}: no herdr pane to focus${row.extra === 'tmux' ? ' (tmux-backed task)' : ''}`;
  if (!row.focusable) return `${row.name}: pane lives in another host (${row.home})`;
  return null;
}

// Why a Findings row cannot be viewed, or null.
export function viewProblem(pane, row) {
  if (!row) return 'nothing selected';
  if (!VIEW_PANES.has(pane.id)) return 'enter views a report: pick a row in Findings';
  if (row.reportRemote) return `${row.name}: report lives on another host (${row.home}); not reachable from here`;
  if (!row.reportPath) return `${row.name}: no report path on this row`;
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
const LANDING_KEYS = new Set(['0', '1', '2', '3', '4', '5', 'r', '?', 'q', 'ctrl-c']);
const ROW_KEYS = new Set(['enter', 'x', 'X', 'H', 'l', 'right', 'h', 'left', 'j', 'down', 'k', 'up', 'tab', 'S-tab', 'pageup', 'pagedown']);

export function keyAction(model, view, key) {
  const pane = model.panes[view.pane];
  const row = pane && !pane.hidden ? pane.rows[view.row] || null : null;
  if (allPanesHidden(model) && !LANDING_KEYS.has(key)) return ROW_KEYS.has(key) ? { type: 'notice', text: 'all panes hidden · 1-5 shows a pane, 0 shows all' } : { type: 'none' };
  switch (key) {
    case 'q':
    case 'ctrl-c':
      return { type: 'quit' };
    case '?':
      return { type: 'help' };
    case 'r':
      return { type: 'refresh' };
    case 'H':
      return { type: 'toggle-hidden' };
    case '0':
      return { type: 'show-panes' };
    case '1':
    case '2':
    case '3':
    case '4':
    case '5':
      return { type: 'toggle-pane', paneId: paneForKey(key), key };
    case 'x':
      if (!row) return { type: 'notice', text: 'nothing selected to hide', bad: true };
      return { type: row.hidden ? 'unhide' : 'hide', row };
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
      if (OPEN_PANES.has(pane.id) && row.url) return { type: 'open', row };
      if (FOCUS_PANES.has(pane.id)) return { type: 'focus', row };
      if (VIEW_PANES.has(pane.id)) return { type: 'view', row };
      // Ready for review or Landed without a PR URL (every pane is covered above).
      return { type: 'notice', text: `${row.name}: no PR URL on this row`, bad: true };
    default:
      return { type: 'move', key };
  }
}

// ctx: { view, model, rebuild(), notice(text, bad), open(row), focus(row),
//        viewReport(row), refresh(), persist(), quit() }.
// rebuild() must replace ctx.model from the current view (the expanded set,
// the hidden set and the hidden panes change which rows and panes exist);
// persist() saves view.hidden and view.hiddenPanes.
export function handleKey(ctx, key) {
  const { view } = ctx;
  if (view.help) {
    if (key === '?' || key === 'escape' || key === 'q' || key === 'enter') view.help = false;
    if (key === 'ctrl-c') ctx.quit();
    return;
  }
  const clamp = () => {
    const v = moveSelection(ctx.model, view, null);
    view.pane = v.pane;
    view.row = v.row;
  };
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
    case 'view':
      ctx.viewReport(action.row);
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
      if (allPanesHidden(ctx.model)) ctx.notice(`pane hidden: ${pane.title} · every pane hidden; 1-5 or 0 shows them`);
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
      const v = moveSelection(ctx.model, view, key);
      view.pane = v.pane;
      view.row = v.row;
      return;
    }
    default:
      break;
  }
}
