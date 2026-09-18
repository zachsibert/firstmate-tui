// lib/layout.mjs - pure layout arithmetic: pane heights, column sets and the
// width breakpoints. The renderer and the interactive app both call this so a
// frame printed by --render-once and a frame drawn in herdr share one geometry.

export const PANES = [
  { id: 'needs', title: 'Needs you', empty: 'no captain decisions, holds or blocked workers' },
  { id: 'review', title: 'Ready for review', empty: 'no recorded pull requests' },
  { id: 'inflight', title: 'In flight', empty: 'no workers in flight' },
  { id: 'findings', title: 'Findings', empty: 'no scout reports' },
  { id: 'landed', title: 'Landed', empty: 'nothing landed yet' },
];

export const MIN_ROWS = 20;
export const MIN_COLS = 40;
export const LIST_BREAKPOINT = 80; // below: one scrolling list with section headers
export const WIDE_BREAKPOINT = 100; // below: drop REPO and AGE

// Column labels per pane for the two narrow leading columns.
const TAG_LABEL = { needs: 'STATE', review: 'CHECKS', inflight: 'STATE', findings: 'KIND', landed: 'VERB' };
const EXTRA_LABEL = { needs: 'KEY', review: 'REVIEW', inflight: 'HERDR', findings: 'VERB', landed: 'DATE' };

export function layoutMode(cols) {
  return cols < LIST_BREAKPOINT ? 'list' : 'panes';
}

export const TAG_WIDTH_MIN = 8;
export const TAG_WIDTH_MAX = 14; // "awaiting merge"

// Column spec for one pane. `cols` is the terminal width, which decides the
// breakpoints; `innerWidth` is the room the row text may use. Fixed columns
// keep the same width in every pane so the grid lines up across the board;
// the renderer passes one `tagWidth` for the whole board (the widest STATE
// word on it, between TAG_WIDTH_MIN and TAG_WIDTH_MAX).
export function columns(cols, innerWidth, paneId, tagWidth = TAG_WIDTH_MIN) {
  const mode = layoutMode(cols);
  const wide = cols >= WIDE_BREAKPOINT;
  const spec = [{ key: 'tag', label: mode === 'panes' ? TAG_LABEL[paneId] || 'STATE' : 'STATE', width: Math.min(TAG_WIDTH_MAX, Math.max(TAG_WIDTH_MIN, tagWidth | 0)) }];
  if (mode === 'panes') spec.push({ key: 'extra', label: EXTRA_LABEL[paneId] || 'INFO', width: 9 });
  spec.push({ key: 'id', label: 'ID', width: 22 });
  spec.push({ key: 'text', label: paneId === 'findings' ? 'REPORT' : 'WHAT', width: 0, flex: true });
  if (wide) spec.push({ key: 'repo', label: 'REPO', width: 18 });
  spec.push({ key: 'home', label: 'HOME', width: wide ? 20 : 14 });
  if (wide) spec.push({ key: 'age', label: 'AGE', width: 5, align: 'right' });
  // Shrink fixed columns until the flex column has room to say something.
  const fixed = () => spec.filter((c) => !c.flex).reduce((n, c) => n + c.width, 0) + (spec.length - 1);
  const idCol = spec.find((c) => c.key === 'id');
  while (innerWidth - fixed() < 16 && idCol.width > 12) idCol.width -= 1;
  const homeCol = spec.find((c) => c.key === 'home');
  while (innerWidth - fixed() < 12 && homeCol.width > 8) homeCol.width -= 1;
  const flexWidth = Math.max(4, innerWidth - fixed());
  return spec.map((c) => (c.flex ? { ...c, width: flexWidth } : c));
}

// Content heights (rows inside the borders) for the five panes. Every shown
// pane gets at least one content row; spare rows go where the demand is, then
// to In flight and Needs you, which are the panes the captain watches most.
// `visible[i] === false` switches pane i off (the 1-5 keys): it draws nothing
// and its rows go to the panes still shown. The result always has one entry
// per pane, 0 for a hidden one.
export function paneHeights(totalRows, demands, visible = []) {
  const rows = Math.max(totalRows, MIN_ROWS);
  const shown = PANES.map((_, i) => visible[i] !== false);
  const shownCount = shown.filter(Boolean).length;
  const chrome = 2; // title line + footer line
  const borders = shownCount * 2;
  let spare = rows - chrome - borders - shownCount;
  const heights = PANES.map((_, i) => (shown[i] ? 1 : 0));
  const want = PANES.map((_, i) => Math.max(1, demands[i] || 0));
  const priority = [0, 2, 1, 3, 4].filter((i) => shown[i]);
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
  for (const i of [2, 0, 1, 3, 4]) {
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
//                                message, blank filler, bottom border
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
  return null;
}

// The context menu box: one bordered column of `key  label` lines, its top-left
// corner at the pointer, moved left or up as far as needed to stay inside the
// frame. The renderer draws it and the controller hit-tests clicks against it,
// so both take the box from here. Item i sits on line top + 1 + i.
export const MENU_MARKER = '▸';

export function menuBox(menu, cols, rows) {
  const keyWidth = Math.max(...menu.items.map((it) => it.key.length), 1);
  const widest = Math.max(...menu.items.map((it) => keyWidth + 2 + it.label.length), 1);
  const width = Math.min(cols, widest + 5); // border, marker, space, text, space, border
  const height = Math.min(rows, menu.items.length + 2);
  const left = Math.max(0, Math.min(menu.x | 0, cols - width));
  const top = Math.max(0, Math.min(menu.y | 0, rows - height));
  return { left, top, width, height, keyWidth };
}

// Which menu item a frame cell falls on: its index, or -1 when the cell is a
// border cell or outside the box.
export function menuItemAt(menu, cols, rows, x, y) {
  const box = menuBox(menu, cols, rows);
  if (x <= box.left || x >= box.left + box.width - 1) return -1;
  const i = y - box.top - 1;
  return i >= 0 && i < menu.items.length && y < box.top + box.height - 1 ? i : -1;
}

// Is the cell anywhere on the box, border included?
export function insideMenu(menu, cols, rows, x, y) {
  const box = menuBox(menu, cols, rows);
  return x >= box.left && x < box.left + box.width && y >= box.top && y < box.top + box.height;
}
