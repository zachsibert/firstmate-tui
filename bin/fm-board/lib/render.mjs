// lib/render.mjs - pure frame renderer. Turns a board model plus a view state
// into `rows` lines of exactly `cols` display columns. Each line is a list of
// styled segments so the neo-blessed adapter can color them and the
// --render-once mode can print them plain. Nothing here touches a terminal.

import { columns, layoutMode, MIN_COLS, MIN_ROWS, paneDemand, paneHeights, PANES, TAG_WIDTH_MIN } from './layout.mjs';
import { fit, fitRaw, padRight, truncate, width } from './text.mjs';

const H = '─';
const V = '│';

export const HELP_LINES = [
  'fm-board keys',
  '',
  '  j / down     next row            k / up       previous row',
  '  tab          next pane           shift-tab    previous pane',
  '  enter        Ready for review or a Needs-you PR row: open the PR in the browser',
  '               In flight group row: expand or collapse it',
  '               In flight worker or Needs-you worker: focus its herdr pane',
  '               Findings row: open the report in the viewer (glow, $EDITOR, vim, less)',
  '  o            open the PR of the selected row in the browser (any pane)',
  '  l / right    expand the selected In flight group',
  '  h / left     collapse the group (from the group row or one of its children)',
  '  x            hide the selected row from view (x on a shown hidden row unhides it)',
  '  X            unhide every row in the current pane',
  '  H            toggle showing hidden rows, greyed and marked (hidden)',
  '  1 - 5        show or hide a pane: 1 Needs you  2 Ready for review  3 In flight',
  '               4 Findings  5 Landed            0            show every pane',
  '  f            put the firstmate pane beside the board, or move it back out',
  '  r            refresh the snapshot now',
  '  ?            toggle this help    q / ctrl-c   quit',
  '',
  'The board is read-only: it never answers, merges or dispatches. Hidden rows and',
  'panes are view state in the board\'s own file, never in a firstmate home.',
  'HERDR "pane lost" (red): the worker pane is gone from herdr. "unknown" (grey):',
  'herdr is disconnected, so absence cannot be proved.',
];

function seg(text, style = 'row') {
  return { text, style };
}

// Pad or clip a list of segments to exactly `cols` columns; the padding takes
// `padStyle` (the row's base style, so a selected row stays inverse to the
// border).
function fitSegments(segments, cols, padStyle = 'row') {
  const out = [];
  let used = 0;
  for (const s of segments) {
    if (used >= cols) break;
    const room = cols - used;
    const t = width(s.text) > room ? truncate(s.text, room) : s.text;
    out.push(seg(t, s.style));
    used += width(t);
  }
  if (used < cols) out.push(seg(' '.repeat(cols - used), padStyle));
  return out;
}

function line(segments, cols) {
  return fitSegments(segments, cols, 'row');
}

// One segment per cell so a single cell can carry its own color. Styles are
// space-separated tag names (lib/tui-blessed.mjs composes them):
//   whole row   selected > grey (a hidden row shown by H) > bad (blocked,
//               failed, failing, or a lost pane in a pane without a HERDR
//               column) > flag > row
//   HERDR cell  "pane lost" adds `lost` (red); "unknown" adds `grey`
function rowSegments(row, spec, selected, paneId = null) {
  const herdrCell = paneId === 'inflight' && spec.some((c) => c.key === 'extra');
  const bad = row.tag === 'blocked' || row.tag === 'failed' || row.tag === 'failing' || (row.lost && !herdrCell);
  const base = selected ? 'selected' : row.hidden ? 'grey' : bad ? 'bad' : row.flag ? 'flag' : 'row';
  const out = [];
  spec.forEach((c, i) => {
    const value = row[c.key] ?? '';
    let style = base;
    if (c.key === 'extra' && herdrCell && !row.hidden) {
      if (row.lost) style = `${base} lost`;
      else if (row.unknown) style = `${base} grey`;
    }
    out.push(seg(fit(value, c.width, c.align), style));
    if (i < spec.length - 1) out.push(seg(' ', base));
  });
  return out;
}

function headSegments(spec) {
  const parts = [];
  spec.forEach((c, i) => {
    parts.push(fit(c.label, c.width, c.align));
    if (i < spec.length - 1) parts.push(' ');
  });
  return [seg(parts.join(''), 'colhead')];
}

function titleLine(model, cols, view) {
  const m = model.meta;
  const home = cols >= 100 ? m.fmHome : m.fmHome.split('/').filter(Boolean).slice(-1)[0] || m.fmHome;
  const hiddenPanes = m.hiddenPanes && m.hiddenPanes.length ? ` · panes hidden: ${m.hiddenPanes.join(',')}` : '';
  const left = ` fm-board · ${home} · ${m.homes} home${m.homes === 1 ? '' : 's'}${hiddenPanes}`;
  const right = `${m.snapshot} · ${m.herdr} `;
  const gap = cols - width(left) - width(right);
  const text = gap >= 1 ? `${left}${' '.repeat(gap)}${right}` : truncate(`${left} · ${right}`, cols);
  return line([seg(padRight(text, cols), view.stale ? 'bad' : 'title')], cols);
}

const FOOTER_KEYS = ' j/k move  tab pane  enter open/focus/view  o open PR  l/h expand  x hide  H hidden  1-5 panes  f firstmate  r refresh  ? help  q quit';
const FOOTER_KEYS_SHORT = ' j/k  tab  enter  o open  l/h  x hide  H  1-5 panes  f  r  ? help  q quit';
const FOOTER_KEYS_MIN = ' ? help';

// The key hint and the transient notice share the footer; the notice wins.
// The full hint needs its own width plus 24 spare columns, the short hint
// whatever is left beside the notice, and a notice too long for even the
// minimal hint is truncated after it.
function footerLine(model, cols, view) {
  const notice = view.notice ? ` ${view.notice} ` : '';
  const fits = (k) => width(k) + width(notice) + (notice ? 2 : 0) <= cols;
  let keys;
  if (cols >= width(FOOTER_KEYS) + 24 && fits(FOOTER_KEYS)) keys = FOOTER_KEYS;
  else if (fits(FOOTER_KEYS_SHORT)) keys = FOOTER_KEYS_SHORT;
  else keys = FOOTER_KEYS_MIN;
  const room = Math.max(0, cols - width(keys));
  const shown = width(notice) > room ? truncate(notice, room) : notice;
  const gap = cols - width(keys) - width(shown);
  return line([seg(keys, 'dim'), seg(`${' '.repeat(Math.max(0, gap))}${shown}`, view.noticeBad ? 'bad' : 'notice')], cols);
}

// Visible window [start, start+height) of a pane's rows so the selected row
// stays on screen. Returns the start index.
export function scrollStart(rowCount, height, selected, previousStart = 0) {
  if (height <= 0 || rowCount <= height) return 0;
  let start = Math.min(previousStart, rowCount - height);
  if (selected < start) start = selected;
  if (selected >= start + height) start = selected - height + 1;
  return Math.max(0, start);
}

// One STATE column width for the whole frame: the widest state word on the
// board, at least TAG_WIDTH_MIN, so "awaiting merge" fits when present and the
// grid stays aligned across panes.
export function tagColumnWidth(model) {
  let w = TAG_WIDTH_MIN;
  for (const pane of model.panes) for (const row of pane.rows) w = Math.max(w, width(row.tag || ''));
  return w;
}

function renderPanes(model, cols, rows, view) {
  const lines = [];
  lines.push(titleLine(model, cols, view));
  const heights = paneHeights(
    rows,
    model.panes.map((p) => paneDemand(p.rows.length)),
    model.panes.map((p) => !p.hidden),
  );
  const inner = cols - 4; // two border cells and one space padding each side
  const tagWidth = tagColumnWidth(model);
  model.panes.forEach((pane, idx) => {
    if (pane.hidden) return;
    const focused = view.pane === idx;
    const spec = columns(cols, inner, pane.id, tagWidth);
    const borderStyle = focused ? 'border-focus' : 'border';
    const topText = `┌${H} ${truncate(pane.header, cols - 6)} `;
    const top = `${topText}${H.repeat(Math.max(0, cols - 1 - width(topText)))}┐`;
    lines.push(line([seg(top, borderStyle)], cols));
    const height = heights[idx];
    const body = [];
    if (height >= 2) body.push(headSegments(spec));
    const roomForRows = height - body.length;
    let hiddenBelow = 0;
    let hiddenAbove = 0;
    if (pane.rows.length === 0) {
      body.push([seg(fit(pane.empty, inner), 'empty')]);
    } else {
      const start = scrollStart(pane.rows.length, roomForRows, focused ? view.row : 0, view.scroll[idx] || 0);
      view.scrollOut[idx] = start;
      const visible = pane.rows.slice(start, start + roomForRows);
      visible.forEach((r, i) => body.push(rowSegments(r, spec, focused && start + i === view.row, pane.id)));
      hiddenAbove = start;
      hiddenBelow = pane.rows.length - (start + visible.length);
    }
    while (body.length < height) body.push([seg(' '.repeat(inner), 'row')]);
    for (const b of body.slice(0, height)) {
      const padStyle = b.length && b[0].style.startsWith('selected') ? 'selected' : 'row';
      lines.push(line([seg(`${V} `, borderStyle), ...fitSegments(b, inner, padStyle), seg(` ${V}`, borderStyle)], cols));
    }
    const markers = [];
    if (hiddenAbove > 0) markers.push(`${hiddenAbove} above`);
    if (hiddenBelow > 0) markers.push(`+${hiddenBelow} more`);
    const marker = markers.length ? ` ${markers.join(', ')} ${H}${H}` : '';
    const bottom = `└${H.repeat(Math.max(0, cols - 2 - width(marker)))}${marker}┘`;
    lines.push(line([seg(bottom, borderStyle)], cols));
  });
  while (lines.length < rows - 1) lines.push(line([], cols));
  lines.push(footerLine(model, cols, view));
  return lines.slice(0, rows);
}

// Flattened list for narrow terminals: one section header per pane, one
// scrolling body, shared column header under the title.
export function flattenRows(model) {
  const out = [];
  model.panes.forEach((pane, paneIdx) => {
    if (pane.hidden) return;
    out.push({ kind: 'section', paneIdx, text: pane.header });
    if (pane.rows.length === 0) out.push({ kind: 'empty', paneIdx, text: pane.empty });
    pane.rows.forEach((row, rowIdx) => out.push({ kind: 'row', paneIdx, rowIdx, row }));
  });
  return out;
}

function renderList(model, cols, rows, view) {
  const lines = [];
  lines.push(titleLine(model, cols, view));
  const inner = cols - 1;
  const spec = columns(cols, inner, 'inflight', tagColumnWidth(model));
  lines.push(line([seg(' ', 'row'), ...headSegments(spec)], cols));
  const flat = flattenRows(model);
  const height = Math.max(rows, MIN_ROWS) - 3;
  const selectedIdx = flat.findIndex((e) => e.kind === 'row' && e.paneIdx === view.pane && e.rowIdx === view.row);
  const anchor = selectedIdx >= 0 ? selectedIdx : flat.findIndex((e) => e.paneIdx === view.pane);
  const start = scrollStart(flat.length, height, Math.max(0, anchor), view.scroll[0] || 0);
  view.scrollOut[0] = start;
  for (const entry of flat.slice(start, start + height)) {
    if (entry.kind === 'section') {
      const focused = entry.paneIdx === view.pane;
      const text = `${H}${H} ${truncate(entry.text, cols - 4)} `;
      lines.push(line([seg(`${text}${H.repeat(Math.max(0, cols - width(text)))}`, focused ? 'border-focus' : 'border')], cols));
    } else if (entry.kind === 'empty') {
      lines.push(line([seg(' ', 'row'), seg(fit(entry.text, inner), 'empty')], cols));
    } else {
      lines.push(line([seg(' ', 'row'), ...rowSegments(entry.row, spec, entry.paneIdx === view.pane && entry.rowIdx === view.row, null)], cols));
    }
  }
  while (lines.length < height + 2) lines.push(line([], cols));
  lines.push(footerLine(model, cols, view));
  return lines;
}

function overlayHelp(lines, cols) {
  const boxW = Math.min(cols - 4, Math.max(...HELP_LINES.map(width)) + 4);
  const boxH = HELP_LINES.length + 2;
  const top = Math.max(1, Math.floor((lines.length - boxH) / 2));
  const left = Math.max(0, Math.floor((cols - boxW) / 2));
  const box = [];
  box.push(`┌${H.repeat(boxW - 2)}┐`);
  for (const h of HELP_LINES) box.push(`${V}${fitRaw(` ${h}`, boxW - 2)}${V}`); // fitRaw keeps the key/description columns aligned
  box.push(`└${H.repeat(boxW - 2)}┘`);
  box.forEach((text, i) => {
    const target = top + i;
    if (target >= lines.length) return;
    const plain = toPlain([lines[target]])[0];
    const before = truncate(plain, left).padEnd(left, ' ');
    const after = plain.slice(before.length + text.length);
    lines[target] = line([seg(before, 'row'), seg(text, 'help'), seg(after, 'row')], cols);
  });
  return lines;
}

// view: { pane, row, scroll[], help, notice, noticeBad, stale } (the app's view
// also carries `expanded`, `hidden`, `hiddenPanes` and `showHidden`, which only
// buildModel reads)
// Returns { lines, cols, rows, mode, scroll } where scroll holds the start
// offsets actually used so the app can keep them for the next frame.
export function renderFrame(model, size, view = {}) {
  const cols = Math.max(MIN_COLS, size.cols | 0);
  const rows = Math.max(MIN_ROWS, size.rows | 0);
  const v = {
    pane: view.pane ?? 0,
    row: view.row ?? 0,
    scroll: view.scroll || [],
    scrollOut: [],
    help: Boolean(view.help),
    notice: view.notice || '',
    noticeBad: Boolean(view.noticeBad),
    stale: Boolean(view.stale),
  };
  const mode = layoutMode(cols);
  let lines = mode === 'list' ? renderList(model, cols, rows, v) : renderPanes(model, cols, rows, v);
  if (v.help) lines = overlayHelp(lines, cols);
  return { lines, cols, rows, mode, scroll: v.scrollOut };
}

export function toPlain(lines) {
  return lines.map((segments) => segments.map((s) => s.text).join(''));
}
