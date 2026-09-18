// lib/render.mjs - pure frame renderer. Turns a board model plus a view state
// into `rows` lines of exactly `cols` display columns. Each line is a list of
// styled segments so the neo-blessed adapter can color them and the
// --render-once mode can print them plain. Nothing here touches a terminal.

import { columns, GUTTER, layoutMode, MIN_COLS, MIN_ROWS, paneDemand, paneHeights } from './layout.mjs';
import { clampCursor, confirmText, DEFAULT_REPO, describeVersion, settingsEntries, upgradeOffer } from './settings.mjs';
import { fit, fitRaw, padRight, truncate, width } from './text.mjs';

const H = '─';
const V = '│';

export const HELP_LINES = [
  'firstmate-tui keys',
  '',
  '  j / down     next row            k / up       previous row',
  '  tab          next pane           shift-tab    previous pane',
  '  enter        Ready for review, Landed or a Needs-you PR row: open the PR in the browser',
  '               In flight group row: expand or collapse it',
  '               In flight worker or Needs-you worker: focus its herdr pane',
  '               Findings row: open the report in the viewer (glow, $EDITOR, vim, less)',
  '  l / right    expand the selected In flight group',
  '  h / left     collapse the group (from the group row or one of its children)',
  '  x            hide the selected row from view (x on a shown hidden row unhides it)',
  '  X            unhide every row in the current pane',
  '  H            toggle showing hidden rows, greyed and marked (hidden)',
  '  1 - 5        show or hide a pane; each pane title carries its key: [1] Needs you',
  '               [2] Ready for review  [3] In flight  [4] Findings  [5] Landed',
  '  0            show every pane (with all five hidden the board lists these keys)',
  '  r            refresh now: the fleet snapshot and the PR checks (unless --no-prs)',
  '  .            settings page: installed version, latest release, upgrade or a beta',
  '               (each install asks y first; . or esc brings the board back)',
  '  =            reset every column width to its automatic size',
  '  ?            toggle this help    q / ctrl-c   quit',
  '',
  'mouse (off with --no-mouse; hold your terminal\'s text-selection modifier to select text)',
  '  click        select that row and focus its pane; a pane title focuses the pane',
  '  double-click the same as enter on that row',
  '  wheel        move the selection three rows in the focused pane',
  '  drag         a column boundary in a pane\'s header row resizes that column; the',
  '               width is kept across restarts. double-click the boundary to reset it',
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

// The GUTTER cells after column `index`: blank in the row's style, or, while
// the captain drags the boundary at that index in this pane (view.drag), a
// bar in the first cell so the boundary is seen moving on the header and on
// every row of the pane.
function gutterSegments(index, base, drag) {
  if (drag && drag.index === index) return [seg(V, 'drag'), seg(' '.repeat(GUTTER - 1), base)];
  return [seg(' '.repeat(GUTTER), base)];
}

// One segment per cell so a single cell can carry its own color. Styles are
// space-separated tag names (lib/tui-blessed.mjs composes them):
//   whole row   selected > grey (a hidden row shown by H) > bad (blocked,
//               failed, failing, or a lost pane in a pane without a HERDR
//               column) > flag > row
//   HERDR cell  "pane lost" adds `lost` (red); "unknown" adds `grey`
function rowSegments(row, spec, selected, paneId = null, drag = null) {
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
    if (i < spec.length - 1) out.push(...gutterSegments(i, base, drag));
  });
  return out;
}

// The column header: one segment when nothing is dragged, so the plain and
// --tags frames stay the same as before; segments around the bar otherwise.
function headSegments(spec, drag = null) {
  const out = [];
  spec.forEach((c, i) => {
    out.push(seg(fit(c.label, c.width, c.align), 'colhead'));
    if (i < spec.length - 1) out.push(...gutterSegments(i, 'colhead', drag));
  });
  if (drag) return out;
  return [seg(out.map((s) => s.text).join(''), 'colhead')];
}

// The toggle key of a pane, shown btop-style before its title: `[1]`.
export function paneBadge(pane) {
  return `[${pane.key}]`;
}

// The title line: the board, its home and the home count on the left; on the
// right the refresh label from the model (`next refresh in 18s`, `refreshing…`,
// or `refresh failed 40s ago, retrying in 20s` in red) and, only while the
// herdr subscription is down, `herdr disconnected (<reason>)` in the red the
// lost-pane cell uses. Each right-hand label is its own segment so --tags can
// color it; when the line is too narrow for both sides, the left text gives
// way first.
function titleLine(model, cols) {
  const m = model.meta;
  const home = cols >= 100 ? m.fmHome : m.fmHome.split('/').filter(Boolean).slice(-1)[0] || m.fmHome;
  const allHidden = m.hiddenPanes && m.hiddenPanes.length === model.panes.length;
  const hiddenPanes = allHidden ? ' · all panes hidden' : m.hiddenPanes && m.hiddenPanes.length ? ` · panes hidden: ${m.hiddenPanes.join(',')}` : '';
  const left = ` firstmate-tui · ${home} · ${m.homes} home${m.homes === 1 ? '' : 's'}${hiddenPanes}`;
  const right = [];
  if (m.refresh && m.refresh.text) right.push(seg(m.refresh.text, m.refresh.failed ? 'title bad' : 'title'));
  if (m.herdrWarning) {
    if (right.length) right.push(seg(' · ', 'title'));
    right.push(seg(m.herdrWarning, 'title lost'));
  }
  if (right.length) right.push(seg(' ', 'title'));
  const rightWidth = right.reduce((n, s) => n + width(s.text), 0);
  const leftText = width(left) + rightWidth + 1 > cols ? truncate(left, Math.max(0, cols - rightWidth - 1)) : left;
  const gap = Math.max(1, cols - width(leftText) - rightWidth);
  return fitSegments([seg(leftText, 'title'), seg(' '.repeat(gap), 'title'), ...right], cols, 'title');
}

const FOOTER_KEYS = ' j/k move  tab pane  enter open/focus/view  l/h expand  x hide  H hidden  1-5 panes  r refresh  . settings  ? help  q quit';
const FOOTER_KEYS_SHORT = ' j/k  tab  enter  l/h  x hide  H  1-5 panes  r  . settings  ? help  q quit';
const FOOTER_KEYS_MIN = ' ? help';
const BOARD_FOOTER_HINTS = [FOOTER_KEYS, FOOTER_KEYS_SHORT, FOOTER_KEYS_MIN];

// The key hint and the transient notice share the footer; the notice wins.
// `hints` runs from the full hint to the minimal one: the full hint needs its
// own width plus 24 spare columns, the next ones whatever is left beside the
// notice, and a notice too long for even the minimal hint is truncated after
// it. The Settings page passes its own hints.
function footerLine(model, cols, view, hints = BOARD_FOOTER_HINTS) {
  const notice = view.notice ? ` ${view.notice} ` : '';
  const fits = (k) => width(k) + width(notice) + (notice ? 2 : 0) <= cols;
  let keys = hints[hints.length - 1];
  for (let i = 0; i < hints.length; i += 1) {
    const spare = i === 0 ? 24 : 0;
    if (cols >= width(hints[i]) + spare && fits(hints[i])) {
      keys = hints[i];
      break;
    }
  }
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

// Each renderer returns { lines, zones }: zones[y] says what line y is, in the
// shape lib/layout.mjs hitTest() reads (a pane title, a row, the pane's other
// cells, or null for the frame's own chrome), so a mouse click can be mapped
// back to the row it landed on without a second copy of the geometry. The
// column-header line's zone also carries the drawn columns and where they
// start (`header`), which is what boundaryAt() measures a drag against.
function renderPanes(model, cols, rows, view) {
  const lines = [];
  const zones = [];
  lines.push(titleLine(model, cols));
  zones.push(null);
  const heights = paneHeights(
    rows,
    model.panes.map((p) => paneDemand(p.rows.length + (p.loading ? 1 : 0))),
    model.panes.map((p) => !p.hidden),
  );
  const inner = cols - 4; // two border cells and one space padding each side
  const textX = 2; // the row text starts after the border cell and its padding
  model.panes.forEach((pane, idx) => {
    if (pane.hidden) return;
    const focused = view.pane === idx;
    // Fixed columns size to this pane's own rows; the captain's dragged widths
    // for the pane replace them (lib/layout.mjs columns).
    const spec = columns(cols, inner, pane.id, { rows: pane.rows, overrides: view.columns[pane.id] });
    const drag = view.drag && view.drag.paneId === pane.id ? view.drag : null;
    const borderStyle = focused ? 'border-focus' : 'border';
    // `[1] Needs you (4) · ...`: the toggle key leads the title as its own dim
    // segment, so the plain frame reads the badge and --tags can grey it.
    const badge = paneBadge(pane);
    const lead = `┌${H} `;
    const topText = ` ${truncate(pane.header, cols - width(lead) - width(badge) - 4)} `;
    const top = `${topText}${H.repeat(Math.max(0, cols - 1 - width(lead) - width(badge) - width(topText)))}┐`;
    lines.push(line([seg(lead, borderStyle), seg(badge, 'badge'), seg(top, borderStyle)], cols));
    zones.push({ kind: 'title', pane: idx });
    const height = heights[idx];
    const body = [];
    const bodyZones = [];
    const paneZone = { kind: 'pane', pane: idx };
    if (height >= 2) {
      body.push(headSegments(spec, drag));
      bodyZones.push({ ...paneZone, header: { x0: textX, spec } });
    }
    // While the pane waits for its first data the spinner line leads the body
    // (in place of the empty text, or above the rows In flight already has
    // while herdr is still connecting), dimmed like the placeholder text.
    if (pane.loading) {
      body.push([seg(fit(pane.loading.text, inner), 'empty')]);
      bodyZones.push(paneZone);
    }
    const roomForRows = height - body.length;
    let hiddenBelow = 0;
    let hiddenAbove = 0;
    if (pane.rows.length === 0) {
      if (!pane.loading) {
        body.push([seg(fit(pane.empty, inner), 'empty')]);
        bodyZones.push(paneZone);
      }
    } else {
      const start = scrollStart(pane.rows.length, roomForRows, focused ? view.row : 0, view.scroll[idx] || 0);
      view.scrollOut[idx] = start;
      const visible = pane.rows.slice(start, start + roomForRows);
      visible.forEach((r, i) => {
        body.push(rowSegments(r, spec, focused && start + i === view.row, pane.id, drag));
        bodyZones.push({ kind: 'row', pane: idx, row: start + i });
      });
      hiddenAbove = start;
      hiddenBelow = pane.rows.length - (start + visible.length);
    }
    while (body.length < height) {
      body.push([seg(' '.repeat(inner), 'row')]);
      bodyZones.push(paneZone);
    }
    body.slice(0, height).forEach((b, i) => {
      const padStyle = b.length && b[0].style.startsWith('selected') ? 'selected' : 'row';
      lines.push(line([seg(`${V} `, borderStyle), ...fitSegments(b, inner, padStyle), seg(` ${V}`, borderStyle)], cols));
      zones.push(bodyZones[i]);
    });
    const markers = [];
    if (hiddenAbove > 0) markers.push(`${hiddenAbove} above`);
    if (hiddenBelow > 0) markers.push(`+${hiddenBelow} more`);
    const marker = markers.length ? ` ${markers.join(', ')} ${H}${H}` : '';
    const bottom = `└${H.repeat(Math.max(0, cols - 2 - width(marker)))}${marker}┘`;
    lines.push(line([seg(bottom, borderStyle)], cols));
    zones.push(paneZone);
  });
  while (lines.length < rows - 1) {
    lines.push(line([], cols));
    zones.push(null);
  }
  lines.push(footerLine(model, cols, view));
  zones.push(null);
  return { lines: lines.slice(0, rows), zones: zones.slice(0, rows) };
}

// Flattened list for narrow terminals: one section header per pane, one
// scrolling body, shared column header under the title. A loading pane gets
// its spinner line right under its header, the same line the panes draw.
export function flattenRows(model) {
  const out = [];
  model.panes.forEach((pane, paneIdx) => {
    if (pane.hidden) return;
    out.push({ kind: 'section', paneIdx, badge: paneBadge(pane), text: pane.header });
    if (pane.loading) out.push({ kind: 'empty', paneIdx, text: pane.loading.text });
    else if (pane.rows.length === 0) out.push({ kind: 'empty', paneIdx, text: pane.empty });
    pane.rows.forEach((row, rowIdx) => out.push({ kind: 'row', paneIdx, rowIdx, row }));
  });
  return out;
}

function renderList(model, cols, rows, view) {
  const lines = [];
  const zones = [];
  lines.push(titleLine(model, cols));
  zones.push(null);
  const inner = cols - 1;
  // One header over every section: the fixed columns size to the widest value
  // in any shown pane, and the captain's dragged widths do not apply here (the
  // header line carries no column geometry, so nothing on it is a boundary).
  const spec = columns(cols, inner, 'inflight', { rows: model.panes.flatMap((p) => (p.hidden ? [] : p.rows)) });
  lines.push(line([seg(' ', 'row'), ...headSegments(spec)], cols));
  zones.push(null);
  const flat = flattenRows(model);
  const height = Math.max(rows, MIN_ROWS) - 3;
  const selectedIdx = flat.findIndex((e) => e.kind === 'row' && e.paneIdx === view.pane && e.rowIdx === view.row);
  const anchor = selectedIdx >= 0 ? selectedIdx : flat.findIndex((e) => e.paneIdx === view.pane);
  const start = scrollStart(flat.length, height, Math.max(0, anchor), view.scroll[0] || 0);
  view.scrollOut[0] = start;
  for (const entry of flat.slice(start, start + height)) {
    if (entry.kind === 'section') {
      const focused = entry.paneIdx === view.pane;
      const style = focused ? 'border-focus' : 'border';
      const lead = `${H}${H} `;
      const text = ` ${truncate(entry.text, cols - width(lead) - width(entry.badge) - 2)} `;
      lines.push(line([seg(lead, style), seg(entry.badge, 'badge'), seg(`${text}${H.repeat(Math.max(0, cols - width(lead) - width(entry.badge) - width(text)))}`, style)], cols));
      zones.push({ kind: 'title', pane: entry.paneIdx });
    } else if (entry.kind === 'empty') {
      lines.push(line([seg(' ', 'row'), seg(fit(entry.text, inner), 'empty')], cols));
      zones.push({ kind: 'pane', pane: entry.paneIdx });
    } else {
      lines.push(line([seg(' ', 'row'), ...rowSegments(entry.row, spec, entry.paneIdx === view.pane && entry.rowIdx === view.row, null)], cols));
      zones.push({ kind: 'row', pane: entry.paneIdx, row: entry.rowIdx });
    }
  }
  while (lines.length < height + 2) {
    lines.push(line([], cols));
    zones.push(null);
  }
  lines.push(footerLine(model, cols, view));
  zones.push(null);
  return { lines, zones };
}

// Every pane hidden: instead of an empty grid, a centered key page between the
// title line and the footer that names the key bringing each pane back, the
// way btop does when all its boxes are off. Pure like the rest: model plus
// view state in, lines out.
export function allPanesHidden(model) {
  return model.panes.length > 0 && model.panes.every((p) => p.hidden);
}

export function landingEntries(model) {
  const entries = [{ key: '', text: 'all panes hidden', style: 'heading' }, null];
  for (const pane of model.panes) entries.push({ key: pane.key, text: pane.title });
  entries.push({ key: '0', text: 'show all' }, null, { key: 'r', text: 'refresh' }, { key: '?', text: 'help' }, { key: 'q', text: 'quit' });
  return entries;
}

function renderLanding(model, cols, rows, view) {
  const lines = [titleLine(model, cols)];
  const entries = landingEntries(model);
  const blockW = Math.min(cols, Math.max(...entries.map((e) => (e ? width(e.key ? `${e.key}  ${e.text}` : e.text) : 0))));
  const left = Math.max(0, Math.floor((cols - blockW) / 2));
  const body = rows - 2;
  const top = Math.max(0, Math.floor((body - entries.length) / 2));
  for (let i = 0; i < body; i += 1) {
    const entry = i >= top ? entries[i - top] : undefined;
    if (!entry) {
      lines.push(line([], cols));
      continue;
    }
    const pad = seg(' '.repeat(left), 'row');
    if (entry.key) lines.push(line([pad, seg(entry.key, 'help'), seg(`  ${truncate(entry.text, cols - left - width(entry.key) - 2)}`, 'row')], cols));
    else lines.push(line([pad, seg(truncate(entry.text, cols - left), entry.style || 'row')], cols));
  }
  lines.push(footerLine(model, cols, view));
  // Nothing on the landing page is a row or a pane: the mouse has no target.
  return { lines, zones: lines.map(() => null) };
}

// ------------------------------------------------------------ settings page
// The `.` page replaces the grid between the title line and the footer. Pure
// like the rest: view.settings (lib/settings.mjs) in, lines and zones out
// (each selectable entry's line is a { kind: 'settings', entry } zone, so a
// click can land on it). The identity
// block, the latest-release line and the menu are laid out from the top and
// the read-only flags follow; the confirmation line, the upgrade output and
// the result take what is left, newest lines kept, so the installer's last
// line and the result are always on screen.
const SETTINGS_FOOTER = ' j/k move  enter choose  r refetch  esc/. back  ? help';
const SETTINGS_FOOTER_BETAS = ' j/k move  enter choose  esc back  . close  r refetch  ? help';
const SETTINGS_FOOTER_SHORT = ' j/k  enter  r  esc/. back  ? help';

function settingsFooterHints(s) {
  if (s.running) return [' upgrading… keys are ignored until it exits (ctrl-c quits)', ' upgrading…'];
  if (s.pending) return [' y confirm  esc cancel (any other key cancels too)', ' y confirm  esc cancel'];
  const base = s.menu === 'betas' ? SETTINGS_FOOTER_BETAS : SETTINGS_FOOTER;
  return [s.result && s.result.ok ? ` R relaunch ${base}` : base, SETTINGS_FOOTER_SHORT, FOOTER_KEYS_MIN];
}

function settingsTail(s) {
  const tail = [];
  if (s.pending) tail.push({ text: confirmText(s.pending), style: 'notice' });
  if (s.running) tail.push({ text: `running firstmate-tui upgrade ${s.running.args.join(' ')} … keys are ignored until it exits`, style: 'notice' });
  for (const o of s.output) tail.push({ text: o, style: 'row' });
  if (s.result && s.result.ok) tail.push({ text: `restart to use ${s.result.version || 'the installed copy'} · R quits and relaunches the board`, style: 'help' });
  else if (s.result) {
    const why = s.result.error ? s.result.error : s.result.signal ? `signal ${s.result.signal}` : `exit ${s.result.code}`;
    tail.push({ text: `upgrade failed (${why}); the output above says why. A failed download or checksum leaves the current install untouched`, style: 'bad' });
  }
  return tail;
}

function renderSettings(model, cols, rows, view) {
  const s = view.settings;
  const L = (segments) => line(segments, cols);
  const text = (t, style = 'row') => L([seg(` ${t}`, style)]);
  const install = s.install;
  const r = s.releases;
  const height = rows - 2;
  const tail = settingsTail(s).map((t) => text(t.text, t.style));
  const head = [];
  head.push(text(s.menu === 'betas' ? 'Settings · Betas' : 'Settings', 'heading'));
  head.push(L([]));
  // Identity: the words `firstmate-tui version` prints, then where this copy lives.
  if (install.version) head.push(text(describeVersion(install.version)));
  else head.push(text(`firstmate-tui: version unreadable (${install.error})`, 'bad'));
  if (install.record) {
    head.push(text(`installed at ${install.root} (from ${install.record.installed_from || 'unknown'}) · repository ${install.repo}`));
  } else if (install.git) {
    head.push(text(`running from a checkout at ${install.root} (no install record); update it with git:`));
    head.push(text(`  git -C ${install.root} pull   (then (cd bin/firstmate-tui && npm ci) when the lockfile changed)`, 'help'));
  } else {
    head.push(text(`running from ${install.root} (no install record, not a git checkout); install a copy with:`));
    head.push(text(`  curl -fsSL https://raw.githubusercontent.com/${DEFAULT_REPO}/main/bin/install.sh | bash`, 'help'));
  }
  if (s.menu === 'main') {
    let latest;
    let style = 'row';
    if (r.state === 'fetching') latest = 'fetching…';
    else if (r.state === 'idle') latest = r.idleReason || 'not fetched';
    else if (r.latest) {
      const offer = upgradeOffer(s);
      latest = `${r.latest.version} · published ${r.latest.date}${offer.status ? ` · ${offer.status}` : ''}`;
    } else {
      latest = upgradeOffer(s).status || r.latestError || 'unknown';
      style = 'bad';
    }
    head.push(L([seg(' latest stable  ', 'dim'), seg(latest, style)]));
  } else {
    let about;
    let style = 'row';
    if (r.state === 'fetching') about = 'fetching…';
    else if (r.state === 'idle') about = r.idleReason || 'release data not fetched';
    else if (r.error) {
      about = `list unavailable: ${r.error}`;
      style = 'bad';
    } else about = `prereleases of ${install.repo}, newest first${install.checkout ? ' (read-only from a checkout)' : ''}`;
    head.push(text(about, style));
  }
  head.push(L([]));
  // The menu, windowed around the cursor when the betas list is long.
  const entries = settingsEntries(s);
  const selectable = entries.filter((e) => e.selectable);
  const current = selectable[clampCursor(s)] || null;
  const currentIdx = current ? entries.indexOf(current) : 0;
  const after = s.menu === 'main' ? s.flags.length + 1 : 0;
  const room = Math.max(3, height - head.length - after - Math.min(tail.length, 4));
  let start = 0;
  let shown = entries;
  let above = 0;
  let below = 0;
  if (entries.length > room) {
    const window = Math.max(1, room - 2);
    start = scrollStart(entries.length, window, currentIdx, 0);
    shown = entries.slice(start, start + window);
    above = start;
    below = entries.length - (start + shown.length);
  }
  const labelW = Math.min(40, Math.max(1, ...entries.map((e) => width(e.label))));
  const entryAt = new Map(); // head line index -> selectable entry index, the page's mouse zones
  if (above > 0) head.push(text(`  ↑ ${above} more`, 'grey'));
  for (const e of shown) {
    const label = fitRaw(e.label, labelW);
    const detail = e.detail ? `  ${e.detail}` : '';
    if (e.selectable) entryAt.set(head.length, selectable.indexOf(e));
    if (e === current) head.push(L([seg(' ▸ ', 'help'), seg(label, 'selected'), seg(detail, 'grey')]));
    else if (e.selectable) head.push(L([seg('   ', 'row'), seg(label, 'row'), seg(detail, 'grey')]));
    else head.push(L([seg('   ', 'row'), seg(e.label, e.bad ? 'bad' : 'grey'), seg(detail, 'grey')]));
  }
  if (below > 0) head.push(text(`  ↓ ${below} more`, 'grey'));
  if (s.menu === 'main') {
    head.push(L([]));
    const flagW = Math.max(1, ...s.flags.map((f) => width(f.label)));
    for (const f of s.flags) head.push(L([seg(` ${padRight(f.label, flagW)}  `, 'dim'), seg(f.value, 'row')]));
  }
  head.push(L([]));
  const body = head.slice(0, height);
  const left = height - body.length;
  if (left > 0 && tail.length) body.push(...tail.slice(Math.max(0, tail.length - left)));
  while (body.length < height) body.push(L([]));
  const zones = [null, ...body.slice(0, height).map((_, i) => (entryAt.has(i) ? { kind: 'settings', entry: entryAt.get(i) } : null)), null];
  return { lines: [titleLine(model, cols), ...body.slice(0, height), footerLine(model, cols, view, settingsFooterHints(s))], zones };
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

// view: { pane, row, scroll[], help, notice, noticeBad, page, settings,
// columns, drag } (the app's view also carries `expanded`, `hidden`,
// `hiddenPanes` and `showHidden`, which only buildModel reads). page is
// 'board' or 'settings'; with 'settings' the frame is the Settings page over
// view.settings. columns is the captain's column widths by pane id and column
// key (view state) and drag the boundary being dragged, { paneId, index, ... }
// (lib/controller.mjs), whose bar the pane draws.
// Returns { lines, cols, rows, mode, scroll, zones } where scroll holds the
// start offsets actually used so the app can keep them for the next frame and
// zones maps each line to what it shows (lib/layout.mjs hitTest). mode is
// 'panes', 'list' (narrow), 'landing' (every pane hidden: the key page) or
// 'settings'.
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
    page: view.page === 'settings' && view.settings ? 'settings' : 'board',
    settings: view.settings || null,
    columns: view.columns && typeof view.columns === 'object' ? view.columns : {},
    drag: view.drag || null,
  };
  const mode = v.page === 'settings' ? 'settings' : allPanesHidden(model) ? 'landing' : layoutMode(cols);
  let drawn;
  if (mode === 'settings') drawn = renderSettings(model, cols, rows, v);
  else if (mode === 'landing') drawn = renderLanding(model, cols, rows, v);
  else if (mode === 'list') drawn = renderList(model, cols, rows, v);
  else drawn = renderPanes(model, cols, rows, v);
  let { lines } = drawn;
  if (v.help) lines = overlayHelp(lines, cols);
  return { lines, cols, rows, mode, scroll: v.scrollOut, zones: drawn.zones };
}

export function toPlain(lines) {
  return lines.map((segments) => segments.map((s) => s.text).join(''));
}
