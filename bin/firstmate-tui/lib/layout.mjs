// lib/layout.mjs - pure layout arithmetic: pane heights, column sets and the
// width breakpoints. The renderer and the interactive app both call this so a
// frame printed by --render-once and a frame drawn in herdr share one geometry.

import { width } from './text.mjs';

// The six panes in screen order, which is also the order of the 1-6 keys
// (lib/controller.mjs paneForKey reads PANES by position). The two PR panes
// sit together so the captain's own PRs and the teammates' PRs read side by
// side. A saved view-state file keeps its meaning across a reorder because
// hidden_panes, hidden row keys and column widths are stored by pane id,
// never by key number (lib/viewstate.mjs).
export const PANES = [
  { id: 'needs', title: 'Needs you', empty: 'no captain decisions, holds or blocked workers' },
  { id: 'mine', title: 'My PRs', empty: 'no pull requests of yours' },
  { id: 'toreview', title: "Teammates' PRs", empty: 'no pull requests waiting for your review' },
  { id: 'inflight', title: 'In flight', empty: 'no workers in flight' },
  { id: 'findings', title: 'Findings', empty: 'no scout reports' },
  { id: 'landed', title: 'Landed', empty: 'nothing landed yet' },
];

// The two PR panes that draw pull requests (CHECKS, STATUS, ID, TITLE, BASE,
// AGE; Teammates' PRs adds AUTHOR between ID and TITLE).
export const PR_PANES = new Set(['mine', 'toreview']);

// The index of a pane id in PANES, so a rule that names panes (the height
// priorities below) survives a reorder.
function paneIndex(id) {
  return PANES.findIndex((p) => p.id === id);
}

export const MIN_ROWS = 20;
export const MIN_COLS = 40;
export const LIST_BREAKPOINT = 80; // below: one scrolling list with section headers
export const WIDE_BREAKPOINT = 100; // below: drop REPO and AGE (the PR panes: drop BASE, keep AGE)

// Column labels per pane for the two narrow leading columns.
const TAG_LABEL = { needs: 'STATE', mine: 'CHECKS', toreview: 'CHECKS', inflight: 'STATE', findings: 'KIND', landed: 'VERB' };
const EXTRA_LABEL = { needs: 'KEY', mine: 'STATUS', toreview: 'STATUS', inflight: 'HERDR', findings: 'VERB', landed: 'DATE' };

export function layoutMode(cols) {
  return cols < LIST_BREAKPOINT ? 'list' : 'panes';
}

// ------------------------------------------------------------------ columns
// Every pane draws one flexible column (WHAT, TITLE or REPORT) and a set of
// fixed ones. A fixed column is as wide as the widest value it shows in that
// pane: at least its header label, at most its cap, so BASE reading `main` on
// every row is 4 cells wide and a long repository name gets up to its cap
// before the ellipsis. Columns are separated by GUTTER blank cells and the
// flexible column takes whatever is left of the row. The widest value is
// measured over every row of the pane, not only the rows on screen, so
// scrolling never moves the grid.
//
// The captain can drag a boundary in a pane's header (lib/controller.mjs) to
// set one fixed column's width by hand; such an override, keyed by pane id and
// column key ({ needs: { id: 30 } }), replaces the automatic width until it is
// reset and is clamped to [label width + 1, whatever leaves the flexible
// column its minimum]. The narrow list (below LIST_BREAKPOINT) draws one
// shared header for every pane and ignores overrides.
export const GUTTER = 2;
export const COLUMN_CAP = 24; // widest a fixed column grows on its own
export const COLUMN_KEYS = ['tag', 'extra', 'id', 'author', 'text', 'repo', 'home', 'base', 'age'];

// The columns of one pane, before any width: `cols` is the terminal width,
// which decides the breakpoints. In list mode every pane shares the shared set
// under one header, so the renderer only ever asks for the shared set there.
//
//   shared            STATE INFO ID WHAT (flex) REPO HOME AGE; below
//                     WIDE_BREAKPOINT REPO and AGE go
//   My PRs            CHECKS STATUS ID TITLE (flex) BASE AGE: the PR's title,
//                     base branch and age, no REPO or HOME (repo, home and url
//                     stay on the row for enter and the notices); below
//                     WIDE_BREAKPOINT BASE goes and AGE stays, since the age is
//                     the column the captain reads the pane by
//   Teammates' PRs    the same with AUTHOR (the PR author's GitHub login, `-`
//                     when GitHub names none) between ID and TITLE: who is
//                     waiting on the review is what the pane is read for, so
//                     AUTHOR stays below WIDE_BREAKPOINT too, and only the
//                     narrow list, whose one shared header has no room for a
//                     column five panes never fill, leaves it out. My PRs has
//                     no AUTHOR: the author there is the captain
function columnSpec(cols, paneId) {
  const mode = layoutMode(cols);
  const wide = cols >= WIDE_BREAKPOINT;
  const spec = [{ key: 'tag', label: mode === 'panes' ? TAG_LABEL[paneId] || 'STATE' : 'STATE', cap: 14 /* "awaiting merge" */ }];
  if (mode === 'panes') spec.push({ key: 'extra', label: EXTRA_LABEL[paneId] || 'INFO', cap: 17 /* "CHANGES REQUESTED" */ });
  spec.push({ key: 'id', label: 'ID', cap: COLUMN_CAP });
  if (mode === 'panes' && PR_PANES.has(paneId)) {
    if (paneId === 'toreview') spec.push({ key: 'author', label: 'AUTHOR', cap: COLUMN_CAP });
    spec.push({ key: 'text', label: 'TITLE', flex: true });
    if (wide) spec.push({ key: 'base', label: 'BASE', cap: COLUMN_CAP });
    spec.push({ key: 'age', label: 'AGE', cap: 6, align: 'right' });
  } else {
    spec.push({ key: 'text', label: paneId === 'findings' ? 'REPORT' : 'WHAT', flex: true });
    if (wide) spec.push({ key: 'repo', label: 'REPO', cap: COLUMN_CAP });
    spec.push({ key: 'home', label: 'HOME', cap: COLUMN_CAP });
    if (wide) spec.push({ key: 'age', label: 'AGE', cap: 6, align: 'right' });
  }
  return spec;
}

// The narrowest a column may be: its label plus one cell, for a fixed column
// and for the flexible one alike.
export function minWidth(col) {
  return width(col.label) + 1;
}

// The automatic width of a fixed column: the widest value of `key` on the
// rows, between the label width and the cap.
function autoWidth(col, rows) {
  let w = width(col.label);
  for (const row of rows) w = Math.max(w, width(row[col.key] ?? ''));
  return Math.min(col.cap, w);
}

// Column spec with widths for one pane. `cols` is the terminal width,
// `innerWidth` the room the row text may use, `rows` the pane's rows (their
// values size the fixed columns) and `overrides` the captain's widths for this
// pane ({ columnKey: width }, from view state), ignored in list mode. Returns
// [{ key, label, width, align, flex, override }] in drawing order.
export function columns(cols, innerWidth, paneId, { rows = [], overrides = null } = {}) {
  const mode = layoutMode(cols);
  const spec = columnSpec(cols, paneId).map((c) => ({ ...c, width: c.flex ? 0 : autoWidth(c, rows), override: false }));
  const flex = spec.find((c) => c.flex);
  if (mode === 'panes' && overrides && typeof overrides === 'object') {
    for (const c of spec) {
      const w = overrides[c.key];
      if (c.flex || !Number.isInteger(w) || w < 1) continue;
      c.width = Math.max(minWidth(c), w);
      c.override = true;
    }
  }
  const fixed = () => spec.filter((c) => !c.flex).reduce((n, c) => n + c.width, 0) + GUTTER * (spec.length - 1);
  const room = () => innerWidth - fixed();
  // Too wide for the row: shrink the overridden columns first (the widest
  // first, down to its minimum), then the automatic ones in the order that
  // keeps the identifying columns readable longest.
  const shrink = (col, min) => {
    while (col && room() < minWidth(flex) && col.width > min) col.width -= 1;
  };
  for (const c of spec.filter((c) => c.override).sort((a, b) => b.width - a.width)) shrink(c, minWidth(c));
  for (const key of ['repo', 'home', 'base', 'author', 'id', 'extra', 'tag']) shrink(spec.find((c) => c.key === key && !c.override), key === 'id' ? 12 : 8);
  for (const key of ['repo', 'home', 'base', 'author', 'id', 'extra', 'tag']) {
    const c = spec.find((x) => x.key === key && !x.override);
    shrink(c, c ? minWidth(c) : 0);
  }
  flex.width = Math.max(minWidth(flex), room());
  return spec;
}

// Where each column of a drawn spec starts, given the x of the first cell:
// [{ ...col, x }] so the mouse geometry has one source.
export function columnPositions(spec, x0) {
  let x = x0;
  return spec.map((c) => {
    const at = { ...c, x };
    x += c.width + GUTTER;
    return at;
  });
}

// The boundaries of a drawn spec: one between each pair of neighbours, at the
// x of the first gutter cell after the left column. `left` is the column a
// drag resizes and `sign` the direction its width moves per cell of pointer
// travel to the right: the left column when it is fixed, else the right one
// (a boundary beside the flexible column moves the fixed column on its other
// side, so the boundary still follows the pointer). Without a fixed neighbour
// (never the case: every pane has one) the boundary is not draggable.
export function boundaries(spec, x0) {
  const at = columnPositions(spec, x0);
  const out = [];
  for (let i = 0; i + 1 < at.length; i += 1) {
    const l = at[i];
    const r = at[i + 1];
    const target = !l.flex ? { column: l, sign: 1 } : !r.flex ? { column: r, sign: -1 } : null;
    if (!target) continue;
    out.push({ index: i, x: l.x + l.width, left: l, right: r, columnId: target.column.key, sign: target.sign, width: target.column.width });
  }
  return out;
}

// The pointer is "on" a boundary from one cell left of its first gutter cell
// to one cell right of its last.
export const BOUNDARY_REACH = 1;

// The widest a dragged column may become without pushing the flexible column
// under its minimum: everything the flexible column can spare goes to it.
export function maxWidth(spec, columnId) {
  const col = spec.find((c) => c.key === columnId);
  const flex = spec.find((c) => c.flex);
  if (!col || !flex) return 0;
  return col.width + Math.max(0, flex.width - minWidth(flex));
}

// Content heights (rows inside the borders) for the six panes. Every shown
// pane gets at least one content row; spare rows go where the demand is (Needs
// you, In flight and the two PR panes first), then to In flight and Needs you,
// which are the panes the captain watches most. Both orders name panes by id,
// so they follow the panes wherever PANES puts them. `visible[i] === false`
// switches pane i off (the 1-6 keys): it draws nothing and its rows go to the
// panes still shown. The result always has one entry per pane, 0 for a hidden
// one.
const DEMAND_PRIORITY = ['needs', 'inflight', 'mine', 'toreview', 'findings', 'landed'].map(paneIndex);
const SPARE_PRIORITY = ['inflight', 'needs', 'mine', 'toreview', 'findings', 'landed'].map(paneIndex);

export function paneHeights(totalRows, demands, visible = []) {
  const rows = Math.max(totalRows, MIN_ROWS);
  const shown = PANES.map((_, i) => visible[i] !== false);
  const shownCount = shown.filter(Boolean).length;
  const chrome = 2; // title line + footer line
  const borders = shownCount * 2;
  let spare = rows - chrome - borders - shownCount;
  const heights = PANES.map((_, i) => (shown[i] ? 1 : 0));
  const want = PANES.map((_, i) => Math.max(1, demands[i] || 0));
  const priority = DEMAND_PRIORITY.filter((i) => shown[i]);
  let progressed = true;
  while (spare > 0 && progressed) {
    progressed = false;
    for (const i of priority) {
      if (spare <= 0) break;
      if (heights[i] < want[i]) {
        heights[i] += 1;
        spare -= 1;
        progressed = true;
      }
    }
  }
  for (const i of SPARE_PRIORITY) {
    if (spare <= 0) break;
    if (!shown[i]) continue;
    heights[i] += spare;
    spare = 0;
  }
  return heights;
}

// Rows needed to show a pane in full: one column-header line, then rows or the
// empty message.
export function paneDemand(rowCount) {
  return 1 + Math.max(1, rowCount);
}

// Mouse hit test. The renderer records, for every line it draws, what that
// line is (frame.zones[y], one entry per line):
//   { kind: 'title', pane }      a pane's top border (panes) or section header (list)
//   { kind: 'row', pane, row }   one list row of pane `pane`, its index in pane.rows
//   { kind: 'pane', pane }       the pane's other cells: column header, empty
//                                message, blank filler, bottom border; the
//                                column header also carries `header: { x0,
//                                spec }`, the drawn columns and the x of the
//                                first one, which boundaryAt() reads
//   null                         the title line, the footer, the landing page
// A row spans the whole frame width, so only y decides; x only has to be
// inside the frame. Hidden panes draw nothing and so own no zone: a click on
// where one used to be lands on whatever pane took its place, or on nothing.
export function hitTest(frame, x, y) {
  if (!frame || !Array.isArray(frame.zones)) return null;
  if (!Number.isInteger(x) || !Number.isInteger(y) || x < 0 || y < 0 || x >= frame.cols || y >= frame.rows) return null;
  const zone = frame.zones[y];
  if (!zone) return null;
  if (zone.kind === 'row') return { kind: 'row', pane: zone.pane, row: zone.row };
  if (zone.kind === 'title') return { kind: 'title', pane: zone.pane };
  if (zone.kind === 'pane') return { kind: 'pane', pane: zone.pane };
  // The Settings page (lib/settings.mjs): one of its selectable entries.
  if (zone.kind === 'settings') return { kind: 'settings', entry: zone.entry };
  return null;
}

// The column boundary under (x, y), or null: (x, y) must be on a pane's
// column-header line (a `pane` zone carrying `header`) and within
// BOUNDARY_REACH cells of a boundary's gutter. Returns { pane, index, x,
// columnId, sign, width, min, max, label }: the pane index, the boundary, the
// column a drag resizes with its current width and the range a drag may move
// it through. The narrow list's header carries no geometry, so nothing there
// is a boundary.
export function boundaryAt(frame, x, y) {
  if (!frame || !Array.isArray(frame.zones)) return null;
  if (!Number.isInteger(x) || !Number.isInteger(y) || x < 0 || y < 0 || x >= frame.cols || y >= frame.rows) return null;
  const zone = frame.zones[y];
  if (!zone || zone.kind !== 'pane' || !zone.header) return null;
  const { x0, spec } = zone.header;
  for (const b of boundaries(spec, x0)) {
    if (x >= b.x - BOUNDARY_REACH && x <= b.x + GUTTER - 1 + BOUNDARY_REACH) {
      const col = spec.find((c) => c.key === b.columnId);
      return { pane: zone.pane, index: b.index, x: b.x, columnId: b.columnId, sign: b.sign, width: b.width, min: minWidth(col), max: maxWidth(spec, b.columnId), label: col.label };
    }
  }
  return null;
}
