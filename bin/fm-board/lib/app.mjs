// lib/app.mjs - the interactive controller: owns the refresh schedule, the
// herdr subscription, the view state (selected pane/row, help, notices) and
// the key handling. It composes the pure modules and the two I/O modules; the
// terminal is reached only through the adapter's screen contract.
//
// Cadence (scout report section 6.4): a full snapshot every --refresh seconds,
// or sooner on any herdr event that touches a known task pane, debounced so no
// more than one snapshot starts per 10 s and never two at once. Herdr pushes
// redraw the frame immediately because the agents map is already updated.

import { buildModel, parseTarget } from './model.mjs';
import { renderFrame } from './render.mjs';
import { collectLedgers, discoverHomes, mtime, runBearingsPrs, runSnapshot } from './sources.mjs';
import { HerdrClient } from './herdr.mjs';
import { createScreen } from './tui-blessed.mjs';
import { PANES } from './layout.mjs';

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

// Move the selection: pure on (model, view) so the list and pane modes share it.
export function moveSelection(model, view, key) {
  const v = { ...view };
  const count = (i) => model.panes[i].rows.length;
  const nextPane = (from, dir) => {
    let i = from;
    for (let n = 0; n < PANES.length; n += 1) {
      i = (i + dir + PANES.length) % PANES.length;
      if (count(i) > 0) return i;
    }
    return from;
  };
  switch (key) {
    case 'j':
    case 'down':
      if (v.row + 1 < count(v.pane)) v.row += 1;
      else if (nextPane(v.pane, 1) !== v.pane && nextPane(v.pane, 1) > v.pane) {
        v.pane = nextPane(v.pane, 1);
        v.row = 0;
      }
      break;
    case 'k':
    case 'up':
      if (v.row > 0) v.row -= 1;
      else if (nextPane(v.pane, -1) !== v.pane && nextPane(v.pane, -1) < v.pane) {
        v.pane = nextPane(v.pane, -1);
        v.row = Math.max(0, count(v.pane) - 1);
      }
      break;
    case 'tab':
      v.pane = nextPane(v.pane, 1);
      v.row = 0;
      break;
    case 'S-tab':
      v.pane = nextPane(v.pane, -1);
      v.row = 0;
      break;
    case 'pagedown':
      v.row = Math.max(0, Math.min(count(v.pane) - 1, v.row + 10));
      break;
    case 'pageup':
      v.row = Math.max(0, v.row - 10);
      break;
    default:
      break;
  }
  if (count(v.pane) === 0) v.row = 0;
  else v.row = Math.min(v.row, count(v.pane) - 1);
  return v;
}

export async function runApp(opts) {
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
    view: { pane: 0, row: 0, scroll: [], help: false, notice: '', noticeBad: false, stale: false },
    refreshing: false,
    refreshPending: false,
    lastSnapshotStart: 0,
    debounceTimer: null,
    noticeTimer: null,
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

  const draw = () => {
    if (!screen || quitting) return;
    state.model = buildModel(facts());
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

  const focusSelected = async () => {
    const pane = state.model && state.model.panes[state.view.pane];
    const row = pane && pane.rows[state.view.row];
    if (!row) return;
    if (pane.id !== 'inflight' && pane.id !== 'needs') {
      notice('enter focuses a worker: pick a row in In flight', true);
      return;
    }
    if (!herdr) {
      notice('herdr is off (--no-herdr); cannot focus', true);
      return;
    }
    if (!row.paneId) {
      notice(`${row.id}: no herdr pane to focus${row.extra === 'tmux' ? ' (tmux-backed task)' : ''}`, true);
      return;
    }
    if (!row.focusable) {
      notice(`${row.id}: pane lives in another host (${row.home})`, true);
      return;
    }
    try {
      await herdr.focus(row.paneId);
      notice(`focused ${row.paneId} (${row.id})`);
    } catch (e) {
      notice(e.message.slice(0, 80), true);
    }
  };

  const quit = () => {
    if (quitting) return;
    quitting = true;
    if (herdr) herdr.close();
    if (screen) screen.destroy();
    process.exit(0);
  };

  const onKey = (key) => {
    if (state.view.help) {
      if (key === '?' || key === 'escape' || key === 'q' || key === 'enter') state.view.help = false;
      if (key === 'ctrl-c') quit();
      draw();
      return;
    }
    switch (key) {
      case 'q':
      case 'ctrl-c':
        quit();
        return;
      case '?':
        state.view.help = true;
        break;
      case 'enter':
        focusSelected();
        return;
      case 'r':
        refresh('manual');
        return;
      default:
        state.view = moveSelection(state.model || buildModel(facts()), state.view, key);
    }
    draw();
  };

  screen = await createScreen({ onKey, onResize: () => draw() });
  process.on('SIGINT', quit);
  process.on('SIGTERM', quit);
  process.on('SIGHUP', quit);

  draw();
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
