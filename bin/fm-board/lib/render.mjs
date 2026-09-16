// lib/render.mjs - pure frame renderer. Turns a board model plus a view state
// into `rows` lines of exactly `cols` display columns. Each line is a list of
// styled segments so the neo-blessed adapter can color them and the
// --render-once mode can print them plain. Nothing here touches a terminal.

import { columns, layoutMode, MIN_COLS, MIN_ROWS, paneDemand, paneHeights, PANES } from './layout.mjs';
import { fit, fitRaw, padRight, truncate, width } from './text.mjs';

const H = '─';
const V = '│';

export const HELP_LINES = [
  'fm-board keys',
  '',
  '  j / down     next row            k / up       previous row',
  '  tab          next pane           shift-tab    previous pane',
  '  enter        focus the herdr pane of the selected worker (In flight only)',
  '  r            refresh the snapshot now',
  '  ?            toggle this help    q / ctrl-c   quit',
  '',
  'The board is read-only: it never answers, merges or dispatches.',
  'Every pane header shows the snapshot age and the herdr connection state.',
  'Rows from another home carry the home name; remote or cached homes say so.',
];

function seg(text, style = 'row') {
  return { text, style };
}

function line(segments, cols) {
  // Pad or clip the segments to exactly cols columns.
  const out = [];
  let used = 0;
  for (const s of segments) {
    if (used >= cols) break;
    const room = cols - used;
    const t = width(s.text) > room ? truncate(s.text, room) : s.text;
    out.push(seg(t, s.style));
    used += width(t);
  }
  if (used < cols) out.push(seg(' '.repeat(cols - used), 'row'));
  return out;
}

function rowSegments(row, spec, selected) {
  const parts = [];
  spec.forEach((c, i) => {
    const value = row[c.key] ?? '';
    parts.push(fit(value, c.width, c.align));
    if (i < spec.length - 1) parts.push(' ');
  });
  const text = parts.join('');
  const style = selected ? 'selected' : row.tag === 'blocked' || row.tag === 'failed' || row.tag === 'failing' ? 'bad' : 'row';
  return [seg(text, style)];
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
  const left = ` fm-board · ${home} · ${m.homes} home${m.homes === 1 ? '' : 's'}`;
  const right = `${m.snapshot} · ${m.herdr} `;
  const gap = cols - width(left) - width(right);
  const text = gap >= 1 ? `${left}${' '.repeat(gap)}${right}` : truncate(`${left} · ${right}`, cols);
  return line([seg(padRight(text, cols), view.stale ? 'bad' : 'title')], cols);
}

function footerLine(model, cols, view) {
  const keys = ' j/k move  tab pane  enter focus  r refresh  ? help  q quit';
  const notice = view.notice ? ` ${view.notice} ` : '';
  const gap = cols - width(keys) - width(notice);
  const text = gap >= 0 ? `${keys}${' '.repeat(gap)}${notice}` : truncate(`${keys} ${notice}`, cols);
  return line([seg(keys, 'dim'), seg(text.slice(keys.length), view.noticeBad ? 'bad' : 'notice')], cols);
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

function renderPanes(model, cols, rows, view) {
  const lines = [];
  lines.push(titleLine(model, cols, view));
  const heights = paneHeights(rows, model.panes.map((p) => paneDemand(p.rows.length)));
  const inner = cols - 4; // two border cells and one space padding each side
  model.panes.forEach((pane, idx) => {
    const focused = view.pane === idx;
    const spec = columns(cols, inner, pane.id);
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
      visible.forEach((r, i) => body.push(rowSegments(r, spec, focused && start + i === view.row)));
      hiddenAbove = start;
      hiddenBelow = pane.rows.length - (start + visible.length);
    }
    while (body.length < height) body.push([seg(' '.repeat(inner), 'row')]);
    for (const b of body.slice(0, height)) {
      lines.push(line([seg(`${V} `, borderStyle), ...b.map((s) => seg(fitRaw(s.text, inner), s.style)), seg(` ${V}`, borderStyle)], cols));
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
  const spec = columns(cols, inner, 'inflight');
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
      lines.push(line([seg(' ', 'row'), ...rowSegments(entry.row, spec, entry.paneIdx === view.pane && entry.rowIdx === view.row)], cols));
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
  for (const h of HELP_LINES) box.push(`${V}${fit(` ${h}`, boxW - 2)}${V}`);
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

// view: { pane, row, scroll[], help, notice, noticeBad, stale }
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
