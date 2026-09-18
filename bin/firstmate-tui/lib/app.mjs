// lib/app.mjs - the interactive controller: owns the refresh schedule, the
// herdr subscription, the view state (selected pane/row, expanded groups,
// hidden rows and panes, help, notices) and the effects behind each key. Key
// semantics live in lib/controller.mjs so the --render-once --keys test driver
// shares them; this module supplies the I/O: herdr focus, the browser opener,
// the report viewer, snapshots and the view-state file. The terminal is reached only through the adapter's screen contract.
//
// Cadence: one refresh runs the fleet snapshot and then, unless --no-prs, the
// live GitHub PR fetch (at most four searches through gh api graphql for the
// two PR panes, all at once, then one lookup of the recorded PRs the author
// search missed; the firstmate script when gh is not on PATH), applied in one
// frame update. The next refresh is due --refresh seconds (default 30)
// after the last one started: a single timer, armed when a refresh completes
// (armRefreshTimer), and the title line counts down to it once a second. A
// herdr event touching a known task pane brings a refresh forward, debounced
// to one start per 10 s, and r starts one at once; both reset the countdown.
// Never two refreshes at once: a tick or an event that lands while one is
// still running is skipped, not queued, and the panes keep the data they
// have; r during a refresh queues exactly one follow-up so the key press is
// honored. A failed snapshot or PR fetch keeps the previous data, marks that
// pane's title (stale) (each PR pane on its own: My PRs keeps its rows when
// only the To review searches failed), turns the title line's label into
// `refresh failed Ns ago, retrying in Ns` until a later refresh is clean, and
// is named in the footer once, as is a fetch note (the script fallback, a
// search that was capped). Herdr pushes redraw the frame immediately because
// the agents map is already updated. With --no-prs, r says why the PR panes
// did not change.
//
// Identity and config: the config file (lib/config.mjs) is read once at
// startup, written from the example when absent, and the GitHub login the two
// PR panes are built around is resolved on the first refresh (the file, then
// `gh api user`, then git; lib/identity.mjs) and cached for the session; a
// manual r resolves it again only while it is unknown. Until the rungs have
// answered the identity is null (pending): the two PR panes spin on it the
// way the other four spin on the snapshot, and r sets it back to null while
// it asks again, so the identity row shows only for a resolved unknown login.
// The Settings page shows both.
//
// Cold start: until the first snapshot and the first PR fetch land, the panes
// have nothing to show, so each draws a spinner line naming what it waits on
// (lib/model.mjs paneLoading). The spinner runs on its own 10 Hz timer
// (syncSpinner) that starts when a rebuilt model has a loading pane and stops
// when none is left, so the board redraws ten times a second only during
// those few seconds; the frame index is a counter, never the clock.
//
// State cache (lib/cache.mjs): after every refresh that landed cleanly, and on
// quit, the facts just rendered that came from outside (the snapshot, the
// ledgers, the PR data with its identity, the herdr agents) are written to
// state-cache.json beside the view-state file. At launch a cache younger than
// --cache-max-age (default an hour) is drawn at once, each pane's title marked
// `(cached 12m ago)`, the title line reading its refreshing label while the
// launch refresh runs exactly as it would without a cache, never skipped or delayed;
// the snapshot landing clears the four fleet panes' markers and each PR pane's
// fetch landing clears its own, so a pane whose live fetch failed keeps its
// cached rows, its marker and the (stale) word. The cached herdr agents stand
// in for the HERDR column until the herdr bootstrap answers. A failed refresh
// never overwrites the file; --no-cache skips the read only; a damaged or
// foreign cache is named in the footer once and cold-starts the board.
//
// View restore (lib/viewstate.mjs): the focused pane, the selected row (by
// its hide key, else its index), the expanded In flight groups and the scroll
// offsets are saved with the hidden rows, at every persist point, 1.5 s after
// the last key or click (schedulePersist) and on quit, and put back at launch
// as soon as the saved pane has its rows (applyPendingView), cache or not.
//
// --headless runs this schedule with no terminal (tests/fm-board.test.sh does,
// against a stand-in home, and stops it with a signal): nothing is drawn, no
// key is read and neo-blessed is never loaded, so the suite needs only Node.
//
// The report viewer takes the terminal over: the screen is suspended (normal
// buffer, raw mode off, input paused), the viewer runs with inherited stdio,
// and the screen is resumed and repainted when it exits. SIGINT is ignored by
// the board meanwhile so a ctrl-c meant for the viewer never quits the board.
//
// The Settings page (`.`, lib/settings.mjs) fetches the GitHub releases API
// through --curl-cmd when it opens and on r inside it, never on the tick; a
// confirmed upgrade runs `bash <root>/bin/firstmate-tui.sh upgrade ...` with piped
// output and each line is drawn as it arrives; the relaunch key exits the
// process with RELAUNCH_EXIT, which bin/firstmate-tui.sh run answers by starting
// the copy at the same path again (Node cannot exec in place).

import { buildModel, initialPrs, mergePrs, parseTarget, prsFailureText } from './model.mjs';
import { renderFrame } from './render.mjs';
import { collectLedgers, discoverHomes, fetchPrs, fetchReleases, mtime, resolveIdentityLive, runSnapshot, statusVerbs } from './sources.mjs';
import { HerdrClient } from './herdr.mjs';
import { defaultOpenerCmd, isOpenableUrl, openUrl } from './opener.mjs';
import { focusFromSaved, focusProblem, handleKey, handleMouse, moveSelection, savedFocus, savedScroll, viewProblem } from './controller.mjs';
import { resolveViewer, runViewer, whichOnPath } from './viewer.mjs';
import { loadViewState, resolveViewStatePath, saveViewState } from './viewstate.mjs';
import { cachedFlags, loadStateCache, resolveCachePath, saveStateCache } from './cache.mjs';
import { finishUpgrade, initialSettings, RELAUNCH_EXIT, resultNotice, settingsConfig, settingsFlags } from './settings.mjs';
import { defaultInstallRoot, readInstall, runUpgrade } from './upgrade.mjs';
import { loadOrCreateConfig } from './config.mjs';
import { identityKnown } from './identity.mjs';

export { moveSelection } from './controller.mjs';

const SNAPSHOT_DEBOUNCE_MS = 10000;
const CLOCK_TICK_MS = 1000; // the title line's countdown moves once a second
const SPINNER_TICK_MS = 100; // the loading spinner advances ten frames a second
const PERSIST_DEBOUNCE_MS = 1500; // the selection is saved this long after the last key or click

// The screen contract of lib/tui-blessed.mjs with no terminal behind it.
function headlessScreen(opts) {
  const size = { cols: opts.cols || 120, rows: opts.rows || 40 };
  return { size: () => size, draw() {}, suspended: () => false, suspend() {}, resume() {}, destroy() {} };
}

export function knownPaneIds(snapshot, ledgers) {
  const ids = new Set();
  for (const t of snapshot && Array.isArray(snapshot.tasks) ? snapshot.tasks : []) {
    const p = parseTarget(t.endpoint && t.endpoint.target);
    if (p && p.paneId) ids.add(p.paneId);
  }
  for (const l of ledgers || []) {
    for (const e of Array.isArray(l.summary && l.summary.endpoints) ? l.summary.endpoints : []) {
      const p = parseTarget(e.endpoint && e.endpoint.target);
      if (p && p.paneId) ids.add(p.paneId);
    }
  }
  return [...ids];
}

export async function runApp(opts) {
  const viewStatePath = resolveViewStatePath({ explicit: opts.viewState, fmHome: opts.fmHome, env: process.env });
  const loaded = loadViewState(viewStatePath.path);
  // The config file, read once (and written from the example when absent).
  const cfg = loadOrCreateConfig({ explicit: opts.config, fmHome: opts.fmHome, env: process.env });
  // The state cache: read before the first refresh when --no-cache is absent,
  // and only when it is fresh, for this home and intact (lib/cache.mjs).
  const cachePath = resolveCachePath({ explicit: opts.cachePath, viewStatePath: viewStatePath.path, fmHome: opts.fmHome });
  const cache = opts.cache === false ? { facts: null, fetchedAt: null, error: null, stale: false } : loadStateCache(cachePath.path, { now: Math.floor(Date.now() / 1000), maxAge: opts.cacheMaxAge, fmHome: opts.fmHome });
  const restored = cache.facts;
  // The PR block is restored only when both the cache and this run have the
  // fetch on: rows that will never refresh are worse than the off text.
  const restorePrs = Boolean(restored && restored.prs && restored.prs.enabled && opts.prs);
  const state = {
    fmHome: opts.fmHome,
    homes: discoverHomes(opts.fmHome, opts.homes),
    snapshot: restored ? restored.snapshot : null,
    snapshotAt: restored ? restored.snapshotAt : null,
    snapshotError: null,
    ledgers: restored ? restored.ledgers : [],
    config: cfg.config,
    identity: null, // resolved on the first refresh, then cached for the session
    prs: restorePrs ? { ...restored.prs, enabled: true } : initialPrs(opts.prs),
    // The cached markers (lib/model.mjs paneCached): which panes still draw
    // the cache, cleared source by source as the live data lands.
    cached: restored ? cachedFlags(cache, { prsEnabled: restorePrs }) : null,
    // The cached herdr agents stand in for the HERDR column until the live
    // bootstrap answers (herdrLive).
    cachedAgents: restored && opts.herdr ? restored.herdr.agents : null,
    herdrLive: false,
    fetchedAt: null, // epoch seconds of the last refresh of this session that landed cleanly; what the cache is stamped with
    cacheErrorShown: null,
    pendingView: { focus: loaded.state.focus, scroll: { ...loaded.state.scroll } }, // the saved selection and scroll, applied pane by pane as the rows land (applyPendingView)
    prsErrorShown: null,
    prsNoteShown: null,
    identityShown: false, // the unknown-identity notice is shown once per session
    herdr: null,
    model: null,
    view: {
      pane: 0,
      row: 0,
      scroll: [],
      expanded: loaded.state.expanded,
      hidden: loaded.state.hidden,
      hiddenPanes: loaded.state.hiddenPanes,
      columns: loaded.state.columns, // dragged column widths by pane id and column key (view state)
      drag: null, // the column boundary being dragged, or null (lib/controller.mjs)
      showHidden: false,
      help: false,
      frame: null, // the last drawn frame's { cols, rows, zones }: what the mouse points at
      lastClick: null,
      notice: '',
      noticeBad: false,
      page: 'board',
      settings: initialSettings({ install: readInstall(opts.installRoot || defaultInstallRoot()), flags: settingsFlags(opts), config: settingsConfig(cfg) }),
    },
    refreshing: false,
    refreshPending: false,
    lastSnapshotStart: 0,
    refreshTimer: null, // the one timer to the next refresh (armRefreshTimer)
    nextRefreshAt: null, // epoch ms that timer is due, for the title line's countdown
    lastFailure: null, // { at: epoch seconds, text } of the last failed refresh, until one succeeds
    loadingFrame: 0, // the spinner's frame counter, advanced by spinnerTimer while a pane is loading
    spinnerTimer: null,
    debounceTimer: null,
    noticeTimer: null,
    persistTimer: null, // the debounced selection save (schedulePersist)
    viewing: false,
  };

  const herdr = opts.herdr ? new HerdrClient({ cmd: opts.herdrCmd, socketPath: opts.herdrSocket }) : null;
  let screen = null;
  let quitting = false;

  const facts = () => ({
    now: Math.floor(Date.now() / 1000),
    fmHome: state.fmHome,
    snapshot: state.snapshot,
    snapshotAt: state.snapshotAt,
    snapshotError: state.snapshotError,
    ledgers: state.ledgers,
    herdr: herdr ? { state: herdr.state, detail: herdr.detail, agents: state.cachedAgents && !state.herdrLive ? state.cachedAgents : herdr.agents } : { state: 'off', detail: '--no-herdr', agents: {} },
    prs: state.prs,
    cached: state.cached,
    refresh: {
      nextAt: state.nextRefreshAt === null ? null : Math.floor(state.nextRefreshAt / 1000),
      refreshing: state.refreshing,
      failedAt: state.lastFailure ? state.lastFailure.at : null,
      failed: state.lastFailure ? state.lastFailure.text : null,
      loadingFrame: state.loadingFrame,
    },
    mtime,
    statusVerbs,
  });

  const rebuild = () => {
    state.model = buildModel(facts(), {
      expanded: state.view.expanded,
      allHomesNeeds: opts.allHomesNeeds,
      hidden: state.view.hidden,
      showHidden: state.view.showHidden,
      hiddenPanes: state.view.hiddenPanes,
    });
    syncSpinner();
    return state.model;
  };

  // The spinner timer follows the model: it starts on the first rebuild that
  // has a loading pane (the start refresh, before the snapshot lands) and
  // stops on the first that has none (every source landed or failed once), so
  // outside a cold start the board never redraws faster than the clock. Each
  // tick advances the frame counter and draws; the draw rebuilds, which is
  // how the timer sees the loading end. Unref'd like the clock: the refresh
  // timer is what keeps a headless run alive.
  const syncSpinner = () => {
    const loading = Boolean(state.model && state.model.panes.some((p) => p.loading));
    if (loading && !state.spinnerTimer) {
      state.spinnerTimer = setInterval(() => {
        state.loadingFrame += 1;
        draw();
      }, SPINNER_TICK_MS);
      state.spinnerTimer.unref?.();
    } else if (!loading && state.spinnerTimer) {
      clearInterval(state.spinnerTimer);
      state.spinnerTimer = null;
    }
  };

  // The saved selection and scroll offsets, put back once the pane they name
  // has its first data: at the first draw when a cache was restored, when the
  // snapshot (or the PR fetch) lands on a cold start otherwise. Applied once;
  // a row that is gone falls back to its index (lib/controller.mjs
  // focusFromSaved), and the scroll is re-clamped by the renderer.
  const applyPendingView = () => {
    const pending = state.pendingView;
    if (!pending) return;
    const { panes } = state.model;
    const landed = (id) => {
      const idx = panes.findIndex((p) => p.id === id);
      return idx < 0 || !panes[idx].loading ? idx : null; // null: its rows have not landed yet
    };
    if (pending.focus && landed(pending.focus.pane) !== null) {
      const focus = focusFromSaved(state.model, pending.focus);
      if (focus) {
        state.view.pane = focus.pane;
        state.view.row = focus.row;
      }
      pending.focus = null;
    }
    for (const [id, n] of Object.entries(pending.scroll)) {
      const idx = landed(id);
      if (idx === null) continue;
      if (idx >= 0) state.view.scroll[idx] = n;
      delete pending.scroll[id];
    }
    if (!pending.focus && !Object.keys(pending.scroll).length) state.pendingView = null;
  };

  const draw = () => {
    if (!screen || quitting || state.viewing) return;
    rebuild();
    applyPendingView();
    const v = moveSelection(state.model, state.view, null); // clamp only
    state.view.pane = v.pane;
    state.view.row = v.row;
    const frame = renderFrame(state.model, screen.size(), state.view);
    state.view.scroll = frame.scroll;
    state.view.frame = { cols: frame.cols, rows: frame.rows, zones: frame.zones };
    screen.draw(frame.lines);
  };

  const notice = (text, bad = false, ttlMs = 6000) => {
    state.view.notice = text;
    state.view.noticeBad = bad;
    if (state.noticeTimer) clearTimeout(state.noticeTimer);
    state.noticeTimer = setTimeout(() => {
      state.view.notice = '';
      state.view.noticeBad = false;
      draw();
    }, ttlMs);
    state.noticeTimer.unref?.();
    draw();
  };

  // View state: hidden rows and panes, the dragged column widths and the
  // selection (the focused pane, the selected row, the expanded groups, the
  // scroll offsets), written to the board's own file only.
  const viewStateToSave = () => ({
    hidden: state.view.hidden,
    hiddenPanes: state.view.hiddenPanes,
    columns: state.view.columns,
    // A saved selection not yet put back (its pane still loading) is kept as
    // it was, so a quick quit loses nothing; and a board that never had data
    // to select from (no cache, no snapshot landed) keeps the file's selection
    // rather than recording an empty one.
    focus: !state.snapshot ? loaded.state.focus : state.pendingView && state.pendingView.focus ? state.pendingView.focus : state.model ? savedFocus(state.model, state.view) : null,
    expanded: state.view.expanded,
    scroll: !state.snapshot ? loaded.state.scroll : { ...savedScroll(state.view.scroll), ...(state.pendingView ? state.pendingView.scroll : {}) },
  });
  const persist = () => {
    if (state.persistTimer) {
      clearTimeout(state.persistTimer);
      state.persistTimer = null;
    }
    if (!viewStatePath.path) {
      notice(viewStatePath.problem || 'view state not saved: no config directory (set XDG_CONFIG_HOME or HOME)', true, 10000);
      return;
    }
    const err = saveViewState(viewStatePath.path, viewStateToSave());
    if (err) notice(`view state not saved: ${err}`, true, 15000);
  };
  // The selection save that follows a key or click: quiet without a path, and
  // never over a file that failed to parse (the hidden-row actions still write
  // it, as before), so a hand edit can be repaired.
  const autoPersist = () => {
    if (!viewStatePath.path || loaded.error) return;
    persist();
  };
  const schedulePersist = () => {
    if (!viewStatePath.path || loaded.error) return;
    if (state.persistTimer) clearTimeout(state.persistTimer);
    state.persistTimer = setTimeout(() => {
      state.persistTimer = null;
      autoPersist();
    }, PERSIST_DEBOUNCE_MS);
    state.persistTimer.unref?.();
  };

  // The state cache, written after a clean refresh and on quit: the facts
  // the board just rendered that came from outside, stamped with the time
  // they landed (fetchedAt), never with the write time. A write that fails is
  // named once per distinct error.
  const writeCache = () => {
    if (!cachePath.path || !state.fetchedAt || !state.snapshot) return;
    const agents = herdr ? (state.cachedAgents && !state.herdrLive ? state.cachedAgents : herdr.agents) : {};
    const err = saveStateCache(cachePath.path, { fmHome: state.fmHome, snapshot: state.snapshot, snapshotAt: state.snapshotAt, ledgers: state.ledgers, prs: state.prs, identity: state.identity, herdr: { agents } }, { fetchedAt: state.fetchedAt });
    if (err && err !== state.cacheErrorShown) {
      state.cacheErrorShown = err;
      notice(`state cache not saved: ${err}`, true, 15000);
    }
  };

  // The one timer to the next refresh, armed when a refresh completes for that
  // refresh's start plus --refresh: the title line counts down to exactly this
  // moment. A refresh that took longer than the cadence leaves it already due,
  // so the next one starts at once; nothing is queued and nothing doubles.
  // A manual r or a herdr event starts a refresh of its own, which clears the
  // pending timer and re-arms it on completion: that is what resets the
  // countdown. Headless, this timer is what keeps the process alive.
  const armRefreshTimer = () => {
    if (state.refreshTimer) clearTimeout(state.refreshTimer);
    state.nextRefreshAt = state.lastSnapshotStart + opts.refresh * 1000;
    state.refreshTimer = setTimeout(() => {
      state.refreshTimer = null;
      refresh('timer');
    }, Math.max(0, state.nextRefreshAt - Date.now()));
    if (!opts.headless) state.refreshTimer.unref?.();
  };

  // One refresh: the snapshot, then the PR fetch against the repositories that
  // snapshot names, landing in one frame update. While one is running, a timer
  // tick or a herdr event is skipped (the next one catches up) and only a key
  // press queues a follow-up. The title line reads `refreshing…` meanwhile,
  // then either the countdown or, when the snapshot or the fetch failed,
  // `refresh failed Ns ago, retrying in Ns` until a later refresh is clean.
  const refresh = async (why) => {
    const manual = why === 'manual';
    if (state.refreshing) {
      if (manual) state.refreshPending = true;
      return;
    }
    state.refreshing = true;
    state.lastSnapshotStart = Date.now();
    if (state.refreshTimer) {
      clearTimeout(state.refreshTimer);
      state.refreshTimer = null;
    }
    state.nextRefreshAt = state.lastSnapshotStart + opts.refresh * 1000;
    notice(`refreshing (${why})…`, false, 60000);
    const timeoutMs = opts.snapshotTimeout * 1000;
    const snap = await runSnapshot(state.fmHome, { timeoutMs });
    if (snap.value && !snap.error) {
      state.snapshot = snap.value;
      state.snapshotAt = Math.floor(Date.now() / 1000);
      state.snapshotError = null;
      if (state.cached) state.cached.snapshot = false; // the four fleet panes are live now
    } else {
      state.snapshotError = snap.error || 'snapshot failed';
    }
    state.ledgers = collectLedgers(state.snapshot, state.homes);
    // The identity: once per session, again on r only while it is unknown.
    // Pending (null) while the rungs are asked, so the PR panes spin on it
    // instead of keeping the identity row; the draw starts the spinner.
    if (!state.identity || (manual && !identityKnown(state.identity))) {
      state.identity = null;
      state.view.settings.identity = null;
      state.prs = { ...state.prs, identity: null };
      draw();
      state.identity = await resolveIdentityLive({ config: state.config, askGh: state.prs.enabled && whichOnPath('gh', process.env), timeoutMs });
      state.view.settings.identity = state.identity;
      state.prs = { ...state.prs, identity: state.identity };
      draw(); // the panes switch from the resolving line to the fetch line or the identity row at once
    }
    const prs = state.prs.enabled ? await fetchPrs(state.fmHome, state.snapshot, { identity: state.identity, config: state.config, timeoutMs }) : null;
    let prsFailure = null;
    let prsNote = null;
    if (prs) {
      // A failing pane keeps its previous rows and its title marks them stale.
      state.prs = mergePrs(state.prs, prs, Math.floor(Date.now() / 1000), state.identity);
      // A pane whose searches answered draws live data now; a failing one
      // keeps its cached rows and marker, as it keeps them stale.
      if (state.cached) {
        if (!(prs.mine && prs.mine.error)) state.cached.prs.mine = false;
        if (!(prs.toreview && prs.toreview.error)) state.cached.prs.toreview = false;
      }
      const failure = prsFailureText(prs);
      if (failure) {
        if (failure !== state.prsErrorShown) prsFailure = failure;
      } else state.prsErrorShown = null;
      if (prs.note && prs.note !== state.prsNoteShown) prsNote = prs.note;
    }
    if (herdr) herdr.setPanes(knownPaneIds(state.snapshot, state.ledgers));
    state.refreshing = false;
    const failure = state.snapshotError ? `snapshot: ${state.snapshotError}` : state.prs.error ? `PR fetch: ${state.prs.error}` : null;
    state.lastFailure = failure ? { at: Math.floor(Date.now() / 1000), text: failure } : null;
    armRefreshTimer();
    if (!failure) {
      // A clean refresh: what is on screen is worth drawing first next time.
      state.fetchedAt = Math.floor(Date.now() / 1000);
      writeCache();
    }
    if (state.snapshotError) notice(`snapshot: ${state.snapshotError}`, true, 30000);
    else {
      const errs = state.ledgers.filter((l) => l.error && !l.cached).map((l) => `${l.id}: ${l.error}`);
      if (errs.length) notice(`ledger ${errs.join('; ')}`, true, 15000);
      else if (prsFailure) {
        state.prsErrorShown = prsFailure;
        notice(`PR fetch: ${prsFailure}`, true, 15000);
      } else if (prsNote) {
        state.prsNoteShown = prsNote;
        notice(prsNote, false, 15000);
      } else if (manual && !state.prs.enabled) notice('PR checks off: start without --no-prs', false, 8000);
      else if (state.prs.enabled && !identityKnown(state.identity) && !state.identityShown) {
        state.identityShown = true;
        notice(`GitHub identity unknown (${state.identity.reason}); set identity.github_login in ${cfg.path || 'the config file'} or run gh auth login`, true, 30000);
      } else notice('', false, 1);
    }
    if (state.refreshPending) {
      state.refreshPending = false;
      scheduleRefresh('queued');
    }
  };

  // Event-triggered refresh, debounced to one snapshot start per 10 s.
  const scheduleRefresh = (why) => {
    if (state.debounceTimer) return;
    const wait = Math.max(0, SNAPSHOT_DEBOUNCE_MS - (Date.now() - state.lastSnapshotStart));
    state.debounceTimer = setTimeout(() => {
      state.debounceTimer = null;
      refresh(why);
    }, wait);
    state.debounceTimer.unref?.();
  };

  const focusRow = async (row) => {
    const pane = state.model.panes[state.view.pane];
    const problem = focusProblem(pane, row, Boolean(herdr));
    if (problem) {
      notice(problem, true);
      return;
    }
    try {
      await herdr.focus(row.paneId);
      notice(`focused ${row.paneId} (${row.name})`);
    } catch (e) {
      notice(e.message.slice(0, 80), true);
    }
  };

  // Open the row's PR in the browser. The URL travels as one argv element to
  // `open` / `xdg-open` (or --opener-cmd); nothing is written anywhere.
  const openRow = async (row) => {
    if (!isOpenableUrl(row.url)) {
      notice(`${row.name}: not an http(s) URL`, true);
      return;
    }
    const cmd = opts.openerCmd || defaultOpenerCmd();
    if (!cmd) {
      notice(`no browser opener known for ${process.platform}; ${row.url}`, true, 15000);
      return;
    }
    // A row whose pane still draws the state cache: the footer names the age
    // of what the row was read from, before and after the open; no prompt.
    const pane = state.model ? state.model.panes[state.view.pane] : null;
    const cached = pane && pane.cached ? pane.cached.label.replace(/^cached /, 'data cached ') : null;
    if (cached) notice(`opening PR from ${cached} · ${row.url}`, false, 8000);
    try {
      await openUrl(row.url, { cmd });
      notice(`opened ${row.url} (${row.name})${cached ? ` · ${cached}` : ''}`, false, 8000);
    } catch (e) {
      notice(`open failed: ${e.message.slice(0, 60)} · ${row.url}`, true, 15000);
    }
  };

  // Show a Findings report: suspend the screen, run the viewer with the
  // terminal, resume and repaint. Refreshes keep running underneath; their
  // draws are skipped until the viewer has exited.
  const viewRow = async (row) => {
    const pane = state.model.panes[state.view.pane];
    const problem = viewProblem(pane, row);
    if (problem) {
      notice(problem, true);
      return;
    }
    if (state.viewing) return;
    const { argv, source } = resolveViewer({ cmd: opts.viewerCmd, env: process.env });
    state.viewing = true;
    const sigint = process.listeners('SIGINT');
    process.removeAllListeners('SIGINT');
    const ignore = () => {};
    process.on('SIGINT', ignore);
    screen.suspend();
    let result = null;
    let failure = null;
    try {
      result = await runViewer(row.reportPath, { argv });
    } catch (e) {
      failure = e;
    } finally {
      screen.resume();
      process.removeListener('SIGINT', ignore);
      for (const fn of sigint) process.on('SIGINT', fn);
      state.viewing = false;
    }
    if (failure) notice(`viewer failed (${argv[0]}): ${failure.message.slice(0, 60)} · ${row.reportPath}`, true, 15000);
    else if (result && result.code !== 0 && result.code !== null) notice(`${argv[0]} exited ${result.code} · ${row.reportPath}`, true, 10000);
    else notice(`viewed ${row.reportPath} (${source})`, false, 8000);
    draw();
  };

  const shutdown = (code) => {
    if (quitting) return;
    // The selection and the cache, saved where the board stands (writeCache
    // writes nothing when no refresh of this session landed cleanly, so a
    // launch that was quit before its first tick leaves the file as it was).
    autoPersist();
    writeCache();
    quitting = true;
    if (herdr) herdr.close();
    if (screen) screen.destroy();
    process.exit(code);
  };
  const quit = () => shutdown(0);

  // Settings page: the release data, fetched on open and on r (never on the
  // tick), and the upgrade child, whose lines are drawn as they arrive.
  const settingsFetch = () => {
    const s = state.view.settings;
    if (s.releases.state === 'fetching') return;
    s.releases = { ...s.releases, state: 'fetching' };
    draw();
    fetchReleases({ repo: s.install.repo, curlCmd: opts.curlCmd, timeoutMs: 20000 }).then((r) => {
      s.releases = r;
      draw();
    });
  };
  const settingsUpgrade = (running) => {
    const s = state.view.settings;
    runUpgrade({
      launcher: s.install.launcher,
      args: running.args,
      onLine: (text) => {
        s.output.push(text);
        draw();
      },
    }).then((r) => {
      const result = finishUpgrade(s, r);
      notice(resultNotice(result), !result.ok, result.ok ? 30000 : 15000);
      draw();
    });
  };

  const ctx = {
    view: state.view,
    get model() {
      return state.model || rebuild();
    },
    rebuild,
    notice: (text, bad) => notice(text, bad),
    open: (row) => {
      openRow(row);
    },
    focus: (row) => {
      focusRow(row);
    },
    viewReport: (row) => {
      viewRow(row);
    },
    refresh: () => {
      refresh('manual');
    },
    persist,
    settingsFetch,
    settingsUpgrade,
    relaunch: () => shutdown(RELAUNCH_EXIT),
    quit,
  };

  const onKey = (key) => {
    if (state.viewing) return;
    handleKey(ctx, key);
    draw();
    schedulePersist();
  };
  const onMouse = (ev) => {
    if (state.viewing) return;
    handleMouse(ctx, ev);
    draw();
    schedulePersist();
  };

  if (opts.headless) screen = headlessScreen(opts);
  else {
    const { createScreen } = await import('./tui-blessed.mjs');
    screen = await createScreen({ onKey, onMouse, onResize: () => draw(), mouse: opts.mouse !== false });
  }
  process.on('SIGINT', quit);
  process.on('SIGTERM', quit);
  process.on('SIGHUP', quit);

  draw();
  if (loaded.error) notice(`view state: ${loaded.error}`, true, 15000);
  if (viewStatePath.problem) notice(viewStatePath.problem, true, 15000);
  if (cache.error) notice(`state cache ignored: ${cache.error}`, true, 15000);
  if (cachePath.problem) notice(cachePath.problem, true, 15000);
  if (cfg.problem) notice(cfg.problem, true, 15000);
  if (cfg.status === 'defaults' && cfg.error) notice(`config: ${cfg.error}; running with the defaults`, true, 15000);
  if (herdr) {
    herdr.on('state', () => draw());
    herdr.on('event', (ev) => {
      if (ev.paneId && herdr.panes.has(ev.paneId)) scheduleRefresh(`herdr ${ev.type}`);
      draw();
    });
    // The client starts out "off", which the title line would read as
    // --no-herdr; until the subscription is up it warns "herdr disconnected
    // (connecting)" instead, and the warning goes as soon as it is acked.
    herdr.setState('connecting');
    herdr.bootstrap().then(() => {
      state.herdrLive = true; // the live agents replace the cached overlay
      draw();
      herdr.connect();
    });
  }
  // The first refresh starts now and each completed refresh arms the timer
  // for the next (armRefreshTimer), so the cadence counts from each start.
  // The clock redraws once a second so the countdown moves; the render is
  // pure and cheap, and headless it draws nothing. The screen's input stream
  // keeps the process alive; headless, the refresh timer does.
  const clock = setInterval(() => draw(), CLOCK_TICK_MS);
  clock.unref?.();
  refresh('start');
  await new Promise(() => {});
}
