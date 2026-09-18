// lib/app.mjs - the interactive controller: owns the refresh schedule, the
// herdr subscription, the view state (selected pane/row, expanded groups,
// hidden rows and panes, help, notices) and the effects behind each key. Key
// semantics live in lib/controller.mjs so the --render-once --keys test driver
// shares them; this module supplies the I/O: herdr focus, the browser opener,
// the report viewer, snapshots and the view-state file. The terminal is reached only through the adapter's screen contract.
//
// Cadence: one refresh runs the fleet snapshot and then, unless --no-prs, the
// live GitHub PR fetch (one gh pr list per candidate repository named by that
// snapshot, all at once; the firstmate script when gh is not on PATH), applied
// in one frame update. The next refresh is due --refresh seconds (default 30)
// after the last one started: a single timer, armed when a refresh completes
// (armRefreshTimer), and the title line counts down to it once a second. A
// herdr event touching a known task pane brings a refresh forward, debounced
// to one start per 10 s, and r starts one at once; both reset the countdown.
// Never two refreshes at once: a tick or an event that lands while one is
// still running is skipped, not queued, and the panes keep the data they
// have; r during a refresh queues exactly one follow-up so the key press is
// honored. A failed snapshot or PR fetch keeps the previous data, marks that
// pane's title (stale), turns the title line's label into `refresh failed Ns
// ago, retrying in Ns` until a later refresh is clean, and is named in the
// footer once, as is a fetch note (the script fallback, a repository that did
// not answer). Herdr pushes redraw the frame immediately because the agents
// map is already updated. With --no-prs, r says why the PR pane did not
// change.
//
// Cold start: until the first snapshot and the first PR fetch land, the panes
// have nothing to show, so each draws a spinner line naming what it waits on
// (lib/model.mjs paneLoading). The spinner runs on its own 10 Hz timer
// (syncSpinner) that starts when a rebuilt model has a loading pane and stops
// when none is left, so the board redraws ten times a second only during
// those few seconds; the frame index is a counter, never the clock.
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

import { buildModel, parseTarget } from './model.mjs';
import { renderFrame } from './render.mjs';
import { collectLedgers, discoverHomes, fetchPrs, fetchReleases, mtime, runSnapshot } from './sources.mjs';
import { HerdrClient } from './herdr.mjs';
import { defaultOpenerCmd, isOpenableUrl, openUrl } from './opener.mjs';
import { focusProblem, handleKey, handleMouse, moveSelection, viewProblem } from './controller.mjs';
import { resolveViewer, runViewer } from './viewer.mjs';
import { loadViewState, resolveViewStatePath, saveViewState } from './viewstate.mjs';
import { finishUpgrade, initialSettings, RELAUNCH_EXIT, resultNotice, settingsFlags } from './settings.mjs';
import { defaultInstallRoot, readInstall, runUpgrade } from './upgrade.mjs';

export { moveSelection } from './controller.mjs';

const SNAPSHOT_DEBOUNCE_MS = 10000;
const CLOCK_TICK_MS = 1000; // the title line's countdown moves once a second
const SPINNER_TICK_MS = 100; // the loading spinner advances ten frames a second

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
  const state = {
    fmHome: opts.fmHome,
    homes: discoverHomes(opts.fmHome, opts.homes),
    snapshot: null,
    snapshotAt: null,
    snapshotError: null,
    ledgers: [],
    prs: { enabled: opts.prs, fetchedAt: null, error: null, candidate_prs: [] },
    prsErrorShown: null,
    prsNoteShown: null,
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
      frame: null, // the last drawn frame's { cols, rows, zones }: what the mouse points at
      lastClick: null,
      notice: '',
      noticeBad: false,
      page: 'board',
      settings: initialSettings({ install: readInstall(opts.installRoot || defaultInstallRoot()), flags: settingsFlags(opts) }),
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
    herdr: herdr ? { state: herdr.state, detail: herdr.detail, agents: herdr.agents } : { state: 'off', detail: '--no-herdr', agents: {} },
    prs: state.prs,
    refresh: {
      nextAt: state.nextRefreshAt === null ? null : Math.floor(state.nextRefreshAt / 1000),
      refreshing: state.refreshing,
      failedAt: state.lastFailure ? state.lastFailure.at : null,
      failed: state.lastFailure ? state.lastFailure.text : null,
      loadingFrame: state.loadingFrame,
    },
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

  const draw = () => {
    if (!screen || quitting || state.viewing) return;
    rebuild();
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

  // View state: hidden rows and panes, written to the board's own file only.
  const persist = () => {
    if (!viewStatePath.path) {
      notice(viewStatePath.problem || 'view state not saved: no config directory (set XDG_CONFIG_HOME or HOME)', true, 10000);
      return;
    }
    const err = saveViewState(viewStatePath.path, { hidden: state.view.hidden, hiddenPanes: state.view.hiddenPanes });
    if (err) notice(`view state not saved: ${err}`, true, 15000);
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
    } else {
      state.snapshotError = snap.error || 'snapshot failed';
    }
    state.ledgers = collectLedgers(state.snapshot, state.homes);
    const prs = state.prs.enabled ? await fetchPrs(state.fmHome, state.snapshot, { timeoutMs }) : null;
    let prsFailure = null;
    let prsNote = null;
    if (prs && prs.error) {
      // Keep the previous PR data and its age; the pane title marks them stale.
      state.prs = { ...state.prs, error: prs.error };
      if (prs.error !== state.prsErrorShown) prsFailure = prs.error;
    } else if (prs) {
      state.prs = { enabled: true, fetchedAt: Math.floor(Date.now() / 1000), error: null, candidate_prs: prs.candidate_prs };
      state.prsErrorShown = null;
      if (prs.note && prs.note !== state.prsNoteShown) prsNote = prs.note;
    }
    if (herdr) herdr.setPanes(knownPaneIds(state.snapshot, state.ledgers));
    state.refreshing = false;
    const failure = state.snapshotError ? `snapshot: ${state.snapshotError}` : state.prs.error ? `PR fetch: ${state.prs.error}` : null;
    state.lastFailure = failure ? { at: Math.floor(Date.now() / 1000), text: failure } : null;
    armRefreshTimer();
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

  const shutdown = (code) => {
    if (quitting) return;
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
  };
  const onMouse = (ev) => {
    if (state.viewing) return;
    handleMouse(ctx, ev);
    draw();
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
