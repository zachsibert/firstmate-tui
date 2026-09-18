// lib/settings.mjs - the Settings page behind the `.` key, pure. It holds the
// page's state shape, the entries it lists, the meaning of each key while it
// is open and the parsing of the GitHub releases API. Nothing here reads a
// file, spawns a process or touches a terminal: lib/upgrade.mjs reads the
// install record and runs the upgrade, lib/sources.mjs fetches the releases,
// lib/render.mjs draws the page and lib/controller.mjs applies the actions.
//
// The page shows the running version (bin/firstmate-tui/package.json), where the
// copy is installed (<prefix>/install-record, written by bin/install.sh) and
// the latest stable release; from an install it offers one `Upgrade to <v>`
// action, a Betas submenu of prereleases with `Back to stable`, and after a
// successful install a relaunch. Every install goes through one confirmation
// (`y`) and then runs `bash <prefix>/bin/firstmate-tui.sh upgrade ...`, so the
// launcher's own record checks stay the single owner of that path. A git
// checkout (no install record) gets the `git pull` hint and no actions.
//
// State (view.settings):
//   install   from lib/upgrade.mjs readInstall(): { root, version, kind,
//             record | null, checkout, git, launcher, repo, error }
//   flags     read-only { label, value } lines (settingsFlags)
//   identity  { login, source, reason } (lib/identity.mjs), the login the two
//             PR panes are built around, or null while the app is still
//             resolving it (the Identity line then reads so, not as a
//             warning); the app updates it when it resolves
//   config    { path, problem, status, error, review } (lib/config.mjs
//             loadOrCreateConfig plus the config's review block): where the
//             config file is and whether it was created, loaded or replaced
//             by the defaults; settingsInfo() turns both into read-only lines
//   releases  { state: idle | fetching | ready | error, fetchedAt, latest |
//             null, latestError, betas[], error, idleReason }
//   menu      'main' | 'betas'      cursor  index into the selectable entries
//   pending   { channel, version } awaiting `y`, or null
//   running   { channel, version, args } while the upgrade child runs, or null
//   output    the child's stdout and stderr lines, in arrival order
//   result    null | { ok: true, version } | { ok: false, code, signal, error }
//
// The mouse works on the page through settingsMouseAction: the renderer marks
// each selectable entry's line with a { kind: 'settings', entry } zone, a
// click on one moves the cursor there, a second click within the double-click
// window is enter on it, the wheel moves the cursor, and a click while a
// confirmation is pending cancels it. Only `y` on the keyboard confirms.

import { hitTest } from './layout.mjs';
import { describeIdentity, identityUnknown } from './identity.mjs';

export const DEFAULT_REPO = 'zachsibert/firstmate-tui';

// The board exits with this status on the relaunch key; bin/firstmate-tui.sh run
// then starts the copy at the same path again, which after an upgrade is the
// new one.
export const RELAUNCH_EXIT = 75;

export const RELEASES_PER_PAGE = 30;

const SEMVER = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/;
const SHA7 = /^[0-9a-f]{7}$/;

export function parseVersion(v) {
  const m = SEMVER.exec(String(v || '').replace(/^v/, ''));
  if (!m) return null;
  return { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]), suffix: m[4] || '', base: `${m[1]}.${m[2]}.${m[3]}` };
}

// stable (X.Y.Z), beta (X.Y.Z-<7 hex>, the per-commit prerelease the release
// workflow publishes), prerelease (any other suffix) or unknown. Mirrors
// version_kind in bin/firstmate-tui.sh.
export function versionKind(v) {
  const p = parseVersion(v);
  if (!p) return 'unknown';
  if (!p.suffix) return 'stable';
  return SHA7.test(p.suffix) ? 'beta' : 'prerelease';
}

// -1, 0 or 1 comparing X.Y.Z only (a beta compares as its base release), or
// null when either side is not a version.
export function compareBase(a, b) {
  const pa = parseVersion(a);
  const pb = parseVersion(b);
  if (!pa || !pb) return null;
  for (const k of ['major', 'minor', 'patch']) if (pa[k] !== pb[k]) return pa[k] < pb[k] ? -1 : 1;
  return 0;
}

// The same words `firstmate-tui version` prints (NAME in bin/firstmate-tui.sh).
export function describeVersion(v) {
  switch (versionKind(v)) {
    case 'stable':
      return `firstmate-tui ${v} (stable release)`;
    case 'beta': {
      const p = parseVersion(v);
      return `firstmate-tui ${v} (beta: ${p.base} at commit ${p.suffix})`;
    }
    case 'prerelease':
      return `firstmate-tui ${v} (prerelease)`;
    default:
      return v ? `firstmate-tui ${v}` : 'firstmate-tui (version unknown)';
  }
}

// The read-only lines on the page: one per launch flag worth seeing at a
// glance. A new flag is one more entry here.
export function settingsFlags(opts) {
  return [
    { label: 'refresh cadence', value: `${opts.refresh} s (--refresh)` },
    { label: 'PR data', value: opts.prs ? 'on: live GitHub checks on every tick' : 'off (--no-prs)' },
    { label: 'herdr overlay', value: opts.herdr ? 'on' : 'off (--no-herdr)' },
    { label: 'mouse', value: opts.mouse === false ? 'off (--no-mouse)' : 'on: click selects, double-click acts, wheel scrolls, a header boundary drags' },
  ];
}

// The read-only block after the flags: who the PR panes are built around,
// where the config file is and what it says about To review. Pure entries,
// no actions. `bad` marks the two warnings (an identity resolved unknown, a
// config file replaced by the defaults; a null identity is still being
// resolved and reads so, not as a warning); a line with an empty label
// continues the one above it (the per-repository label rules).
export function settingsInfo(s) {
  const identity = s.identity ?? null;
  const config = s.config || { path: null, status: 'none', error: null, review: null };
  const lines = [];
  lines.push({ label: 'Identity', value: describeIdentity(identity, config.path), bad: identityUnknown(identity) });
  if (identityUnknown(identity) && identity.reason) lines.push({ label: '', value: `  tried: ${identity.reason}`, bad: false });
  // The path, then what became of it: nothing when the file was read, the
  // example note when it was just written, the reason when the defaults are
  // in effect instead. With no path at all the reason stands alone.
  let where;
  if (!config.path) where = `none: using defaults (${config.error || config.problem || 'no config directory: set XDG_CONFIG_HOME or HOME'})`;
  else if (config.status === 'created') where = `${config.path}  (created from the example)`;
  else if (config.status === 'defaults') where = `${config.path}  (using defaults: ${config.error || config.problem || 'unreadable'})`;
  else where = config.path;
  lines.push({ label: 'Config', value: where, bad: config.status === 'defaults' });
  const review = config.review || { default_labels: [], repos: {} };
  const defaults = Array.isArray(review.default_labels) && review.default_labels.length ? review.default_labels.join(', ') : 'none';
  lines.push({ label: 'Review labels', value: `default: ${defaults}`, bad: false });
  for (const [repo, entry] of Object.entries(review.repos || {})) {
    const labels = entry && Array.isArray(entry.labels) && entry.labels.length ? entry.labels.join(', ') : 'unfiltered';
    lines.push({ label: '', value: `  ${repo}: ${labels}`, bad: false });
  }
  return lines;
}

// The Settings page's config block from what loadOrCreateConfig returned.
export function settingsConfig(cfg) {
  return { path: cfg.path, problem: cfg.problem, status: cfg.status, error: cfg.error, review: cfg.config.review };
}

export function initialSettings({ install, flags, idleReason = null, identity = null, config = null }) {
  return {
    install,
    flags,
    identity,
    config,
    releases: { state: 'idle', fetchedAt: null, latest: null, latestError: null, betas: [], error: null, idleReason },
    menu: 'main',
    cursor: 0,
    pending: null,
    running: null,
    output: [],
    result: null,
  };
}

// ------------------------------------------------------------ releases API
function releaseEntry(rel) {
  const tag = typeof rel.tag_name === 'string' ? rel.tag_name : '';
  const version = tag.replace(/^v/, '');
  const p = parseVersion(version);
  const published = typeof rel.published_at === 'string' ? Date.parse(rel.published_at) : NaN;
  return {
    tag,
    version,
    date: typeof rel.published_at === 'string' && rel.published_at.length >= 10 ? rel.published_at.slice(0, 10) : '-',
    publishedAt: Number.isNaN(published) ? 0 : Math.floor(published / 1000),
    prerelease: Boolean(rel.prerelease),
    commit: p && SHA7.test(p.suffix) ? p.suffix : '-',
  };
}

// latest: { value, error } from GET /releases/latest (GitHub's "latest" is
// never a prerelease); list: { value, error } from GET /releases, of which the
// prereleases are the betas, newest first by publish time. A missing latest
// release (a repository with betas only) is reported beside the latest line
// and does not fail the list.
export function parseReleases({ latest, list }, now = Math.floor(Date.now() / 1000)) {
  const out = { state: 'ready', fetchedAt: now, latest: null, latestError: null, betas: [], error: null, idleReason: null };
  if (latest.error) out.latestError = latest.error;
  else if (latest.value && typeof latest.value === 'object' && typeof latest.value.tag_name === 'string') out.latest = releaseEntry(latest.value);
  else out.latestError = 'no tag_name in the latest release';
  if (list.error) out.error = list.error;
  else if (Array.isArray(list.value)) {
    out.betas = list.value
      .filter((r) => r && typeof r === 'object' && r.prerelease && typeof r.tag_name === 'string')
      .map(releaseEntry)
      .sort((a, b) => b.publishedAt - a.publishedAt);
  } else out.error = 'the releases list is not a JSON array';
  if (out.latestError && out.error) out.state = 'error';
  return out;
}

// What the page says beside the latest stable release, and the version the
// main menu offers to install (null when there is nothing to offer).
export function upgradeOffer(settings) {
  const { install, releases } = settings;
  const latest = releases.latest;
  if (!latest) return { version: null, status: releases.latestError ? `no stable release found: ${releases.latestError}` : '' };
  const cmp = compareBase(install.version, latest.version);
  if (cmp === null) return { version: install.checkout ? null : latest.version, status: 'running version unreadable' };
  if (cmp < 0 && install.checkout) return { version: null, status: 'newer than this checkout; git pull updates it' };
  if (cmp < 0) return { version: latest.version, status: 'upgrade available' };
  if (cmp > 0) return { version: null, status: 'ahead of the latest release' };
  if (versionKind(install.version) !== 'stable') return { version: null, status: `a beta of ${latest.version}; Betas > Back to stable returns to the release` };
  return { version: null, status: 'up to date' };
}

// ----------------------------------------------------------------- entries
function betasDetail(releases, checkout) {
  if (releases.state === 'fetching') return 'fetching…';
  if (releases.state === 'idle') return releases.idleReason || 'release data not fetched';
  if (releases.error) return `list unavailable: ${releases.error}`;
  const n = releases.betas.length;
  const count = n === 0 ? 'no prereleases published' : `${n} prerelease${n === 1 ? '' : 's'}`;
  return checkout ? `${count} (read-only from a checkout)` : count;
}

// The lines the page lists under its header, in order. `selectable` entries
// take the cursor and answer enter; the others are information only.
export function settingsEntries(s) {
  const checkout = s.install.checkout;
  const r = s.releases;
  const entries = [];
  if (s.menu === 'betas') {
    if (r.state === 'fetching') entries.push({ id: 'fetching', label: 'fetching…', detail: '', selectable: false });
    else if (r.state === 'idle') entries.push({ id: 'idle', label: r.idleReason || 'release data not fetched', detail: '', selectable: false });
    else if (r.error) entries.push({ id: 'error', label: r.error, detail: '', selectable: false, bad: true });
    else if (!r.betas.length) entries.push({ id: 'none', label: 'no prereleases published', detail: '', selectable: false });
    for (const b of r.betas) {
      entries.push({ id: `beta:${b.version}`, label: b.version, detail: `commit ${b.commit}   ${b.date}`, selectable: !checkout, action: { type: 'confirm', channel: 'version', version: b.version } });
    }
    if (!checkout) {
      entries.push({
        id: 'stable',
        label: 'Back to stable',
        detail: r.latest ? `${r.latest.version}   ${r.latest.date}` : 'the latest stable release',
        selectable: true,
        action: { type: 'confirm', channel: 'stable', version: r.latest ? r.latest.version : null },
      });
    }
    return entries;
  }
  if (s.result && s.result.ok) {
    entries.push({ id: 'relaunch', label: 'Relaunch now', detail: `quit and start ${s.result.version || 'the installed copy'} (R)`, selectable: true, action: { type: 'relaunch' } });
  } else if (!checkout) {
    const offer = upgradeOffer(s);
    if (offer.version) entries.push({ id: 'upgrade', label: `Upgrade to ${offer.version}`, detail: `firstmate-tui upgrade --version ${offer.version}`, selectable: true, action: { type: 'confirm', channel: 'version', version: offer.version } });
  }
  entries.push({ id: 'betas', label: 'Betas', detail: betasDetail(r, checkout), selectable: true, action: { type: 'menu', menu: 'betas' } });
  entries.push({ id: 'refetch', label: 'Refresh release data', detail: `GitHub releases of ${s.install.repo}`, selectable: true, action: { type: 'fetch' } });
  // Applied to the board's view by lib/controller.mjs, the same as the = key.
  entries.push({ id: 'columns', label: 'Reset column widths', detail: 'every pane back to its automatic widths (= on the board)', selectable: true, action: { type: 'reset-columns' } });
  return entries;
}

export function selectableEntries(s) {
  return settingsEntries(s).filter((e) => e.selectable);
}

export function clampCursor(s) {
  const n = selectableEntries(s).length;
  return n === 0 ? 0 : Math.max(0, Math.min(n - 1, s.cursor));
}

// The launcher arguments behind a confirmed choice: `--version <v>` names the
// exact version the page showed, `--stable` is the launcher's own default.
export function upgradeArgs({ channel, version }) {
  return channel === 'stable' ? ['--stable'] : ['--version', version];
}

// The one line a pending choice shows: the exact version and the command.
export function confirmText(pending) {
  const cmd = `firstmate-tui upgrade ${upgradeArgs(pending).join(' ')}`;
  const what = pending.channel === 'stable' ? `back to stable${pending.version ? ` ${pending.version}` : ' (the latest stable release)'}` : `install ${pending.version}`;
  return `${what} (${cmd})? y to confirm, esc to cancel`;
}

// bin/install.sh ends with "install: firstmate-tui <version> installed" (plus
// "(replaced <old>)" on an upgrade; the 0.1.0 installer said fm-board); that
// is the version the swap put in place.
export function installedVersionFromOutput(lines) {
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const m = /(?:firstmate-tui|fm-board) (\S+) installed\b/.exec(lines[i]);
    if (m) return m[1];
  }
  return null;
}

// Apply the upgrade child's exit to the state. Exit 0 is a success naming the
// version the installer reported (else the one that was asked for); anything
// else leaves the output on the page with the code, and the install is
// whatever install.sh left, which on a failed download or checksum is the
// previous copy untouched.
export function finishUpgrade(s, { code, signal, error }) {
  const asked = s.running ? s.running.version : null;
  s.running = null;
  if (code === 0) {
    s.result = { ok: true, version: installedVersionFromOutput(s.output) || asked };
    // Back on the main menu, where `Relaunch now` is the first entry.
    s.menu = 'main';
    s.cursor = 0;
  } else s.result = { ok: false, code, signal, error: error || null };
  return s.result;
}

// The footer's one-line summary of a finished upgrade.
export function resultNotice(result) {
  if (!result) return '';
  if (result.ok) return `installed ${result.version || 'the new copy'}; R relaunches the board`;
  return 'upgrade failed; the page shows the installer output';
}

// -------------------------------------------------------------------- keys
// The meaning of a key while the page is open. Pure on (settings, key).
//   running   every key is ignored except ctrl-c (quit)
//   pending   y confirms; any other key cancels and does nothing else
//   .  q      close the page          esc h left   back a menu, else close
//   j k       move the cursor         enter        choose the highlighted entry
//   r         fetch the release data  R            relaunch after a success
//   ?         help overlay            ctrl-c       quit
// enter answers { type: 'activate', cursor, action }, the object a double-click
// on the same entry yields, so the keyboard and the mouse open a confirmation
// through the one activate case in lib/controller.mjs. The terminal adapter
// delivers one enter per press (lib/tui-blessed.mjs normalizeKey); the pending
// prompt only ever sees the keys pressed after it opened.
export function settingsKeyAction(s, key) {
  if (s.running) return key === 'ctrl-c' ? { type: 'quit' } : { type: 'none' };
  if (s.pending) return key === 'y' ? { type: 'upgrade', channel: s.pending.channel, version: s.pending.version } : { type: 'cancel' };
  const sel = selectableEntries(s);
  const cursor = clampCursor(s);
  switch (key) {
    case 'ctrl-c':
      return { type: 'quit' };
    case '.':
    case 'q':
      return { type: 'close' };
    case 'escape':
    case 'h':
    case 'left':
      return s.menu === 'betas' ? { type: 'menu', menu: 'main' } : { type: 'close' };
    case '?':
      return { type: 'help' };
    case 'r':
      return { type: 'fetch' };
    case 'R':
      return s.result && s.result.ok ? { type: 'relaunch' } : { type: 'none' };
    case 'j':
    case 'down':
      return { type: 'move', cursor: Math.min(Math.max(0, sel.length - 1), cursor + 1) };
    case 'k':
    case 'up':
      return { type: 'move', cursor: Math.max(0, cursor - 1) };
    case 'pagedown':
      return { type: 'move', cursor: Math.min(Math.max(0, sel.length - 1), cursor + 10) };
    case 'pageup':
      return { type: 'move', cursor: Math.max(0, cursor - 10) };
    case 'enter':
    case 'l':
    case 'right': {
      const entry = sel[cursor];
      if (!entry) {
        if (s.menu === 'betas' && s.install.checkout) return { type: 'notice', text: `no upgrade from a checkout; update it with git -C ${s.install.root} pull`, bad: true };
        return { type: 'none' };
      }
      if (key !== 'enter' && entry.action.type !== 'menu') return { type: 'none' };
      // The same object a double-click on this entry yields (settingsMouseAction),
      // so both reach the entry's action through the one activate case.
      return { type: 'activate', cursor, action: entry.action };
    }
    default:
      return { type: 'none' };
  }
}

// The meaning of a mouse event while the page is open (the event shape is the
// one lib/controller.mjs mouseAction documents; view.frame.zones come from
// the last drawn frame and view.lastClick is the previous click on the page,
// { settings: <entry>, time }). Pure on (settings, view, ev).
//   running          nothing               pending   a left press cancels
//   left press on an entry line   move the cursor there; a second press on
//                                 the same entry within dblclickMs is enter
//   wheel            move the cursor one entry        anything else  nothing
export function settingsMouseAction(s, view, ev, { dblclickMs = 400 } = {}) {
  if (!ev || ev.type === 'up' || s.running) return { type: 'none' };
  if (s.pending) return ev.type === 'down' ? { type: 'cancel' } : { type: 'none' };
  const sel = selectableEntries(s);
  const last = Math.max(0, sel.length - 1);
  const cursor = clampCursor(s);
  if (ev.type === 'wheel') return { type: 'move', cursor: Math.max(0, Math.min(last, cursor + (ev.dir === 'up' ? -1 : 1))) };
  if (ev.type !== 'down' || ev.button !== 'left') return { type: 'none' };
  const hit = hitTest(view.frame, ev.x, ev.y);
  if (!hit || hit.kind !== 'settings') return { type: 'none' };
  const entry = sel[hit.entry];
  if (!entry) return { type: 'none' };
  const prev = view.lastClick;
  const since = prev && Number.isFinite(prev.time) && Number.isFinite(ev.time) ? ev.time - prev.time : NaN;
  if (prev && prev.settings === hit.entry && since >= 0 && since <= dblclickMs) return { type: 'activate', cursor: hit.entry, action: entry.action };
  return { type: 'move', cursor: hit.entry, click: { settings: hit.entry, time: ev.time } };
}
