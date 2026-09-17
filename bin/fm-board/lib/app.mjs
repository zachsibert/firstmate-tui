// lib/app.mjs - the interactive controller: owns the refresh schedule, the
// herdr subscription, the view state (selected pane/row, expanded groups,
// hidden rows and panes, help, notices) and the effects behind each key. Key
// semantics live in lib/controller.mjs so the --render-once --keys test driver
// shares them; this module supplies the I/O: herdr focus, the browser opener,
// the report viewer, the firstmate pane move, snapshots and the view-state
// file. The terminal is reached only through the adapter's screen contract.
//
// Cadence (scout report section 6.4): a full snapshot every --refresh seconds,
// or sooner on any herdr event that touches a known task pane, debounced so no
// more than one snapshot starts per 10 s and never two at once. Herdr pushes
// redraw the frame immediately because the agents map is already updated.
//
// The report viewer takes the terminal over: the screen is suspended (normal
// buffer, raw mode off, input paused), the viewer runs with inherited stdio,
// and the screen is resumed and repainted when it exits. SIGINT is ignored by
// the board meanwhile so a ctrl-c meant for the viewer never quits the board.

import { buildModel, parseTarget } from './model.mjs';
import { renderFrame } from './render.mjs';
import { collectLedgers, discoverHomes, mtime, runBearingsPrs, runSnapshot } from './sources.mjs';
import { HerdrClient } from './herdr.mjs';
import { createScreen } from './tui-blessed.mjs';
import { defaultOpenerCmd, isOpenableUrl, openUrl } from './opener.mjs';
import { focusProblem, handleKey, moveSelection, viewProblem } from './controller.mjs';
import { resolveViewer, runViewer } from './viewer.mjs';
import { loadViewState, resolveViewStatePath, saveViewState } from './viewstate.mjs';
import { moveFirstmatePane } from './split.mjs';

export { moveSelection } from './controller.mjs';

const SNAPSHOT_DEBOUNCE_MS = 10000;
const PRS_INTERVAL_MS = 120000;
const CLOCK_TICK_MS = 5000;

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
  const state = {
    fmHome: opts.fmHome,
    homes: discoverHomes(opts.fmHome, opts.homes),
    snapshot: null,
    snapshotAt: null,
    snapshotError: null,
    ledgers: [],
    prs: { enabled: opts.prs, fetchedAt: null, error: null, candidate_prs: [] },
    lastPrsAt: 0,
    herdr: null,
    model: null,
    view: {
      pane: 0,
      row: 0,
      scroll: [],
      expanded: new Set(),
      hidden: loaded.state.hidden,
      hiddenPanes: loaded.state.hiddenPanes,
      showHidden: false,
      help: false,
      notice: '',
      noticeBad: false,
      stale: false,
    },
    refreshing: false,
    refreshPending: false,
    lastSnapshotStart: 0,
    debounceTimer: null,
    noticeTimer: null,
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
    herdr: herdr ? { state: herdr.state, detail: herdr.detail, agents: herdr.agents } : { state: 'off', agents: {} },
    prs: state.prs,
    mtime,
  });

  const rebuild = () => {
    state.model = buildModel(facts(), {
      expanded: state.view.expanded,
      allHomesNeeds: opts.allHomesNeeds,
      hidden: state.view.hidden,
      showHidden: state.view.showHidden,
      hiddenPanes: state.view.hiddenPanes,
    });
    return state.model;
  };

  const draw = () => {
    if (!screen || quitting || state.viewing) return;
    rebuild();
    const v = moveSelection(state.model, state.view, null); // clamp only
    state.view.pane = v.pane;
    state.view.row = v.row;
    state.view.stale = Boolean(state.snapshotError);
    const frame = renderFrame(state.model, screen.size(), state.view);
    state.view.scroll = frame.scroll;
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

  // View state: hidden rows and panes, written to the board's own file only.
  const persist = () => {
    if (!viewStatePath.path) {
      notice(viewStatePath.problem || 'view state not saved: no config directory (set XDG_CONFIG_HOME or HOME)', true, 10000);
      return;
    }
    const err = saveViewState(viewStatePath.path, { hidden: state.view.hidden, hiddenPanes: state.view.hiddenPanes });
    if (err) notice(`view state not saved: ${err}`, true, 15000);
  };

  const refresh = async (why) => {
    if (state.refreshing) {
      state.refreshPending = true;
      return;
    }
    state.refreshing = true;
    state.lastSnapshotStart = Date.now();
    notice(`refreshing (${why})…`, false, 60000);
    const snap = await runSnapshot(state.fmHome, { timeoutMs: opts.snapshotTimeout * 1000 });
    if (snap.value && !snap.error) {
      state.snapshot = snap.value;
      state.snapshotAt = Math.floor(Date.now() / 1000);
      state.snapshotError = null;
    } else {
      state.snapshotError = snap.error || 'snapshot failed';
    }
    state.ledgers = collectLedgers(state.snapshot, state.homes);
    if (state.prs.enabled && Date.now() - state.lastPrsAt >= PRS_INTERVAL_MS) {
      state.lastPrsAt = Date.now();
      const prs = await runBearingsPrs(state.fmHome, { timeoutMs: opts.snapshotTimeout * 1000 });
      state.prs = { enabled: true, fetchedAt: prs.error ? state.prs.fetchedAt : Math.floor(Date.now() / 1000), error: prs.error, candidate_prs: prs.error ? state.prs.candidate_prs : prs.candidate_prs };
    }
    if (herdr) herdr.setPanes(knownPaneIds(state.snapshot, state.ledgers));
    state.refreshing = false;
    if (state.snapshotError) notice(`snapshot: ${state.snapshotError}`, true, 30000);
    else {
      const errs = state.ledgers.filter((l) => l.error && !l.cached).map((l) => `${l.id}: ${l.error}`);
      if (errs.length) notice(`ledger ${errs.join('; ')}`, true, 15000);
      else notice('', false, 1);
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
    try {
      await openUrl(row.url, { cmd });
      notice(`opened ${row.url} (${row.name})`, false, 8000);
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

  // The `f` key: put the firstmate pane beside the board or move it back out.
  // The board's own pane id comes from herdr's HERDR_PANE_ID (injected into
  // every process herdr spawns) or --board-pane.
  const firstmate = async () => {
    const boardPane = opts.boardPane || process.env.HERDR_PANE_ID || null;
    notice('finding the firstmate pane…', false, 20000);
    try {
      const r = await moveFirstmatePane({ client: herdr, fmHome: state.fmHome, boardPane, mode: 'toggle' });
      notice(r.message, false, 10000);
      scheduleRefresh('pane move');
    } catch (e) {
      notice(e.message.slice(0, 120), true, 15000);
    }
  };

  const quit = () => {
    if (quitting) return;
    quitting = true;
    if (herdr) herdr.close();
    if (screen) screen.destroy();
    process.exit(0);
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
    firstmate: () => {
      firstmate();
    },
    refresh: () => {
      refresh('manual');
    },
    persist,
    quit,
  };

  const onKey = (key) => {
    if (state.viewing) return;
    handleKey(ctx, key);
    draw();
  };

  screen = await createScreen({ onKey, onResize: () => draw() });
  process.on('SIGINT', quit);
  process.on('SIGTERM', quit);
  process.on('SIGHUP', quit);

  draw();
  if (loaded.error) notice(`view state: ${loaded.error}`, true, 15000);
  if (viewStatePath.problem) notice(viewStatePath.problem, true, 15000);
  if (herdr) {
    herdr.on('state', () => draw());
    herdr.on('event', (ev) => {
      if (ev.paneId && herdr.panes.has(ev.paneId)) scheduleRefresh(`herdr ${ev.type}`);
      draw();
    });
    herdr.bootstrap().then(() => {
      draw();
      herdr.connect();
    });
  }
  await refresh('start');
  const interval = setInterval(() => refresh('timer'), opts.refresh * 1000);
  interval.unref?.();
  const clock = setInterval(() => draw(), CLOCK_TICK_MS);
  clock.unref?.();
  // Keep the process alive on the screen's input stream.
  await new Promise(() => {});
}
