// lib/settings.mjs - the Settings page behind the `.` key, pure. It holds the
// page's state shape, the entries it lists, the meaning of each key while it
// is open and the parsing of the GitHub releases API. Nothing here reads a
// file, spawns a process or touches a terminal: lib/upgrade.mjs reads the
// install record and runs the upgrade, lib/sources.mjs fetches the releases,
// lib/render.mjs draws the page and lib/controller.mjs applies the actions.
//
// The page shows the running version (bin/fm-board/package.json), where the
// copy is installed (<prefix>/install-record, written by bin/install.sh) and
// the latest stable release; from an install it offers one `Upgrade to <v>`
// action, a Betas submenu of prereleases with `Back to stable`, and after a
// successful install a relaunch. Every install goes through one confirmation
// (`y`) and then runs `bash <prefix>/bin/fm-board.sh upgrade ...`, so the
// launcher's own record checks stay the single owner of that path. A git
// checkout (no install record) gets the `git pull` hint and no actions.
//
// State (view.settings):
//   install   from lib/upgrade.mjs readInstall(): { root, version, kind,
//             record | null, checkout, git, launcher, repo, error }
//   flags     read-only { label, value } lines (settingsFlags)
//   releases  { state: idle | fetching | ready | error, fetchedAt, latest |
//             null, latestError, betas[], error, idleReason }
//   menu      'main' | 'betas'      cursor  index into the selectable entries
//   pending   { channel, version } awaiting `y`, or null
//   running   { channel, version, args } while the upgrade child runs, or null
//   output    the child's stdout and stderr lines, in arrival order
//   result    null | { ok: true, version } | { ok: false, code, signal, error }

export const DEFAULT_REPO = 'zachsibert/firstmate-tui';

// The board exits with this status on the relaunch key; bin/fm-board.sh run
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
// version_kind in bin/fm-board.sh.
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

// The same words `fm-board version` prints.
export function describeVersion(v) {
  switch (versionKind(v)) {
    case 'stable':
      return `fm-board ${v} (stable release)`;
    case 'beta': {
      const p = parseVersion(v);
      return `fm-board ${v} (beta: ${p.base} at commit ${p.suffix})`;
    }
    case 'prerelease':
      return `fm-board ${v} (prerelease)`;
    default:
      return v ? `fm-board ${v}` : 'fm-board (version unknown)';
  }
}

// The read-only lines on the page: one per launch flag worth seeing at a
// glance. A new flag is one more entry here.
export function settingsFlags(opts) {
  return [
    { label: 'refresh cadence', value: `${opts.refresh} s (--refresh)` },
    { label: 'PR data', value: opts.prs ? 'on: live GitHub checks on every tick' : 'off (--no-prs)' },
    { label: 'herdr overlay', value: opts.herdr ? 'on' : 'off (--no-herdr)' },
  ];
}

export function initialSettings({ install, flags, idleReason = null }) {
  return {
    install,
    flags,
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
    if (offer.version) entries.push({ id: 'upgrade', label: `Upgrade to ${offer.version}`, detail: `fm-board upgrade --version ${offer.version}`, selectable: true, action: { type: 'confirm', channel: 'version', version: offer.version } });
  }
  entries.push({ id: 'betas', label: 'Betas', detail: betasDetail(r, checkout), selectable: true, action: { type: 'menu', menu: 'betas' } });
  entries.push({ id: 'refetch', label: 'Refresh release data', detail: `GitHub releases of ${s.install.repo}`, selectable: true, action: { type: 'fetch' } });
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
  const cmd = `fm-board upgrade ${upgradeArgs(pending).join(' ')}`;
  const what = pending.channel === 'stable' ? `back to stable${pending.version ? ` ${pending.version}` : ' (the latest stable release)'}` : `install ${pending.version}`;
  return `${what} (${cmd})? y to confirm, esc to cancel`;
}

// bin/install.sh ends with "install: fm-board <version> installed" (plus
// "(replaced <old>)" on an upgrade); that is the version the swap put in place.
export function installedVersionFromOutput(lines) {
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const m = /fm-board (\S+) installed\b/.exec(lines[i]);
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
      return entry.action;
    }
    default:
      return { type: 'none' };
  }
}
