#!/usr/bin/env node
// bin/fm-board/index.mjs - entry point for the fm-board TUI.
//
// Modes:
//   run (default)  interactive board (neo-blessed through lib/tui-blessed.mjs)
//   --render-once  print one frame to stdout and exit; with --fixture <json> the
//                  frame comes from that facts file and no firstmate home or
//                  herdr is touched, which is how tests/fm-board.test.sh works.
//                  --keys <list> presses keys, and --mouse <list> clicks,
//                  double-clicks and wheels (see lib/args.mjs),
//                  through lib/controller.mjs before
//                  the frame is rendered (a PR open runs --opener-cmd when
//                  given, and is only reported in the footer otherwise; a herdr
//                  focus is reported, never run; r against a live home re-runs
//                  the snapshot and then the PR fetch (unless --no-prs) and
//                  against a fixture only reports that it cannot; enter on a
//                  Findings row runs --viewer-cmd when given and otherwise only
//                  reports the viewer the chain resolved to, naming the binary
//                  found on PATH, so a test can shadow glow with a fake without
//                  ever launching a real viewer); --expand <all|ids>
//                  expands In flight groups; --tags prints the color tags;
//                  --view-state <file> loads hidden rows and panes from that
//                  file and saves x/X/1-5/0 changes back to it (without the
//                  flag a fixture render loads nothing and saves nothing).
//
// Fixture file shape (see tests/fixtures/*.json):
//   { "now": ISO time, "cols": N, "rows": N, "fm_home": path,
//     "snapshot": fm-fleet-snapshot.v1 document,
//     "ledgers": [ { id, home, remote, cached, summary, error } ]   (optional;
//                 derived from snapshot.secondmate_current when absent),
//     "herdr": { "state": "connected" | "disconnected" | ... (optional),
//                "agents": [ { pane_id, agent_status, terminal_title_stripped } ] } | null,
//     "prs": { "candidate_prs": [ { num, repo, task, url, review, mergeable,
//                                   checks, created_at? } ] } | null,
//     "mtimes": { "<absolute path>": epoch seconds } }
// With --no-herdr the fixture's herdr block is still applied as an offline
// overlay (header says "herdr fixture") so the join is testable without a
// live server; a "state" in the block overrides that label (a "disconnected"
// fixture shows the grey "unknown" HERDR cells); without a herdr block the
// header says "herdr off".

import { readFileSync } from 'node:fs';
import { parseArgs, USAGE } from './lib/args.mjs';
import { buildModel } from './lib/model.mjs';
import { renderFrame, toPlain } from './lib/render.mjs';
import { toTags } from './lib/tui-blessed.mjs';
import { agentsFromSnapshot, HerdrClient } from './lib/herdr.mjs';
import { collectLedgers, discoverHomes, fetchPrs, mtime, runSnapshot } from './lib/sources.mjs';
import { focusProblem, handleKey, handleMouse, viewProblem } from './lib/controller.mjs';
import { isOpenableUrl, openUrl } from './lib/opener.mjs';
import { resolveViewer, runViewer } from './lib/viewer.mjs';
import { loadViewState, resolveViewStatePath, saveViewState } from './lib/viewstate.mjs';

function fail(msg, code = 1) {
  process.stderr.write(`fm-board: ${msg}\n`);
  process.exit(code);
}

function factsFromFixture(path, opts) {
  let fx;
  try {
    fx = JSON.parse(readFileSync(path, 'utf8'));
  } catch (e) {
    fail(`cannot read fixture ${path}: ${e.message}`, 2);
  }
  const now = fx.now ? Math.floor(Date.parse(fx.now) / 1000) : Math.floor(Date.now() / 1000);
  if (Number.isNaN(now)) fail(`fixture "now" is not a parseable time: ${fx.now}`, 2);
  const snapshot = fx.snapshot || null;
  const fmHome = fx.fm_home || (snapshot && snapshot.fm_home) || '/fixture/firstmate';
  const mtimes = fx.mtimes || {};
  const fixtureMtime = (p) => (Object.prototype.hasOwnProperty.call(mtimes, p) ? Number(mtimes[p]) : null);
  let ledgers;
  if (Array.isArray(fx.ledgers)) {
    ledgers = fx.ledgers.map((l) => ({ id: l.id || null, home: l.home, remote: Boolean(l.remote), cached: Boolean(l.cached), summary: l.summary || null, error: l.error || null, generatedAt: l.summary && l.summary.generated_epoch ? Number(l.summary.generated_epoch) : null }));
  } else {
    const records = snapshot && snapshot.secondmate_current && Array.isArray(snapshot.secondmate_current.records) ? snapshot.secondmate_current.records : [];
    ledgers = records.map((r) => ({
      id: r.id,
      home: r.home,
      remote: Boolean(r.remote),
      cached: Boolean(r.provenance && r.provenance.summary_source === 'remote-ledger-cache'),
      summary: { active_children: r.active_children || [], endpoints: r.endpoints || [], decisions_open: r.decisions_open || [], landed: Array.isArray(r.landed) ? r.landed : [], queued: Array.isArray(r.queued) ? r.queued : [] },
      error: null,
      generatedAt: null,
    }));
  }
  let herdr;
  if (fx.herdr && (Array.isArray(fx.herdr.agents) || fx.herdr.snapshot)) {
    const agents = fx.herdr.snapshot ? agentsFromSnapshot({ snapshot: fx.herdr.snapshot }) : agentsFromSnapshot({ agents: fx.herdr.agents });
    const state = typeof fx.herdr.state === 'string' && fx.herdr.state ? fx.herdr.state : opts.herdr ? 'connected' : 'fixture';
    herdr = { state, detail: fx.herdr.detail || '', agents };
  } else {
    herdr = { state: 'off', detail: '', agents: {} };
  }
  const prs = opts.prs
    ? { enabled: true, fetchedAt: fx.prs && Array.isArray(fx.prs.candidate_prs) ? now - 30 : null, error: fx.prs && fx.prs.error ? fx.prs.error : null, candidate_prs: fx.prs && Array.isArray(fx.prs.candidate_prs) ? fx.prs.candidate_prs : [] }
    : { enabled: false };
  return {
    facts: { now, fmHome, snapshot, snapshotAt: snapshot ? now - Number(fx.snapshot_age_seconds ?? 12) : null, snapshotError: fx.snapshot_error || null, ledgers, herdr, prs, mtime: fixtureMtime },
    size: { cols: opts.cols || fx.cols || 120, rows: opts.rows || fx.rows || 40 },
  };
}

async function factsLive(opts) {
  if (!opts.fmHome) fail('FM_HOME is not set and --fm-home was not given', 2);
  const fmHome = opts.fmHome.replace(/\/+$/, '');
  const now = () => Math.floor(Date.now() / 1000);
  const timeoutMs = opts.snapshotTimeout * 1000;
  // The snapshot, then the PR fetch against the repositories it names, as one
  // tick of the app does.
  const snap = await runSnapshot(fmHome, { timeoutMs });
  const snapshot = snap.error ? null : snap.value;
  const r = opts.prs ? await fetchPrs(fmHome, snapshot, { timeoutMs }) : null;
  const ledgers = collectLedgers(snapshot, discoverHomes(fmHome, opts.homes));
  const prs = r ? { enabled: true, fetchedAt: r.error ? null : now(), error: r.error, candidate_prs: r.candidate_prs } : { enabled: false };
  let herdr = { state: 'off', detail: '', agents: {} };
  if (opts.herdr) {
    const client = new HerdrClient({ cmd: opts.herdrCmd, socketPath: opts.herdrSocket });
    const ok = await client.bootstrap();
    herdr = ok ? { state: 'connected', detail: 'one-shot', agents: client.agents } : { state: 'unavailable', detail: client.detail, agents: {} };
  }
  return {
    facts: { now: now(), fmHome, snapshot, snapshotAt: snapshot ? now() : null, snapshotError: snap.error, ledgers, herdr, prs, mtime },
    size: { cols: opts.cols || process.stdout.columns || 120, rows: opts.rows || process.stdout.rows || 40 },
  };
}

// The view-state file for a one-shot render: the explicit --view-state, or the
// default location when rendering a live home. A fixture render without the
// flag loads nothing, so the frame depends on the fixture alone.
function viewStateFor(opts, fmHome) {
  if (opts.fixture && !opts.viewState) return { path: null, problem: null };
  return resolveViewStatePath({ explicit: opts.viewState, fmHome, env: process.env });
}

// One-shot view: apply --expand, then --keys and --mouse in command-line order
// through the shared handlers, then hand back the model and view to render.
// Effects: an opened PR runs --opener-cmd (awaited, so a fake opener has
// written its record before the process exits) or, without one, only leaves a
// footer notice; a focus is checked the same way the app checks it, then
// reported rather than run; a viewed report runs the resolved viewer
// (awaited); r re-reads a live home. Before each mouse event the frame is
// rendered at the final size, as the app redraws after every key, so the
// pointer is measured against what would be on screen; the events of one
// token share a time stamp and tokens are a second apart, so dblclick is a
// double-click and two click tokens on one row are two single clicks. With
// --no-mouse the mouse tokens are skipped, as the app would ignore the events.
async function driveOnce(facts, opts, size) {
  const vs = viewStateFor(opts, facts.fmHome);
  const loaded = loadViewState(vs.path);
  const view = { pane: 0, row: 0, scroll: [], expanded: new Set(), hidden: loaded.state.hidden, hiddenPanes: loaded.state.hiddenPanes, showHidden: false, help: false, frame: null, lastClick: null, notice: '', noticeBad: false };
  const build = () => buildModel(facts, { expanded: view.expanded, allHomesNeeds: opts.allHomesNeeds, hidden: view.hidden, showHidden: view.showHidden, hiddenPanes: view.hiddenPanes });
  let model = build();
  if (opts.expand.length) {
    const inflight = model.panes.find((p) => p.id === 'inflight');
    for (const row of inflight.rows) {
      if (row.group && (opts.expand.includes('all') || opts.expand.includes(row.homeId))) view.expanded.add(row.group);
    }
    model = build();
  }
  const pending = [];
  const ctx = {
    view,
    get model() {
      return model;
    },
    rebuild: () => {
      model = build();
    },
    notice: (text, bad = false) => {
      view.notice = text;
      view.noticeBad = bad;
    },
    open: (row) => {
      if (!isOpenableUrl(row.url)) {
        ctx.notice(`${row.name}: not an http(s) URL`, true);
        return;
      }
      if (!opts.openerCmd) {
        ctx.notice(`would open ${row.url} (${row.name}); no --opener-cmd in --render-once`);
        return;
      }
      pending.push(
        openUrl(row.url, { cmd: opts.openerCmd, wait: true })
          .then(() => ctx.notice(`opened ${row.url} (${row.name})`))
          .catch((e) => ctx.notice(`open failed: ${e.message} · ${row.url}`, true)),
      );
    },
    focus: (row) => {
      const pane = model.panes[view.pane];
      const problem = focusProblem(pane, row, opts.herdr && facts.herdr && facts.herdr.state === 'connected');
      ctx.notice(problem || `would focus ${row.paneId} (${row.name}); --render-once never runs herdr agent focus`, Boolean(problem));
    },
    viewReport: (row) => {
      const pane = model.panes[view.pane];
      const problem = viewProblem(pane, row);
      if (problem) {
        ctx.notice(problem, true);
        return;
      }
      const { argv, source } = resolveViewer({ cmd: opts.viewerCmd, env: process.env });
      if (!opts.viewerCmd) {
        ctx.notice(`would view ${row.reportPath} with ${argv.join(' ')} (${source}); no --viewer-cmd in --render-once`);
        return;
      }
      pending.push(
        runViewer(row.reportPath, { argv })
          .then((r) => ctx.notice(r.code === 0 || r.code === null ? `viewed ${row.reportPath} (${source})` : `${argv[0]} exited ${r.code} · ${row.reportPath}`, r.code !== 0 && r.code !== null))
          .catch((e) => ctx.notice(`viewer failed (${argv[0]}): ${e.message} · ${row.reportPath}`, true)),
      );
    },
    refresh: () => {
      if (opts.fixture) {
        ctx.notice('refresh is not available with --fixture', true);
        return;
      }
      pending.push(refreshLive(facts, opts).then((text) => ctx.notice(text)).then(() => ctx.rebuild()));
    },
    persist: () => {
      if (!vs.path) return;
      const err = saveViewState(vs.path, { hidden: view.hidden, hiddenPanes: view.hiddenPanes });
      if (err) ctx.notice(`view state not saved: ${err}`, true);
    },
    quit: () => {},
  };
  if (loaded.error) ctx.notice(`view state: ${loaded.error}`, true);
  if (vs.problem) ctx.notice(vs.problem, true);
  opts.inputs.forEach((input, n) => {
    if (input.kind === 'key') {
      handleKey(ctx, input.key);
      return;
    }
    if (!opts.mouse) return;
    for (const ev of input.events) {
      const frame = renderFrame(model, size, { ...view, stale: Boolean(facts.snapshotError) });
      view.scroll = frame.scroll;
      view.frame = { cols: frame.cols, rows: frame.rows, zones: frame.zones };
      handleMouse(ctx, { ...ev, time: n * 1000 });
    }
  });
  await Promise.all(pending);
  return { model, view };
}

// The r key against a live home: the same refresh a tick of the app runs, the
// snapshot and then, unless --no-prs, the PR fetch. Mutates facts in place and
// resolves to the footer text (a fetch note, such as the script fallback, is
// appended so a one-shot render shows it).
async function refreshLive(facts, opts) {
  facts.now = Math.floor(Date.now() / 1000);
  const timeoutMs = opts.snapshotTimeout * 1000;
  const snap = await runSnapshot(facts.fmHome, { timeoutMs });
  if (snap.value && !snap.error) {
    facts.snapshot = snap.value;
    facts.snapshotAt = Math.floor(Date.now() / 1000);
    facts.snapshotError = null;
  } else facts.snapshotError = snap.error || 'snapshot failed';
  facts.ledgers = collectLedgers(facts.snapshot, discoverHomes(facts.fmHome, opts.homes));
  if (!opts.prs) return 'PR checks off: start without --no-prs';
  const r = await fetchPrs(facts.fmHome, facts.snapshot, { timeoutMs });
  facts.prs = { enabled: true, fetchedAt: r.error ? facts.prs.fetchedAt : Math.floor(Date.now() / 1000), error: r.error, candidate_prs: r.error ? facts.prs.candidate_prs : r.candidate_prs };
  if (r.error) return `PR fetch: ${r.error}`;
  return r.note ? `refreshed: snapshot and PR checks · ${r.note}` : 'refreshed: snapshot and PR checks';
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2), process.env);
  } catch (e) {
    process.stderr.write(`fm-board: ${e.message}\n${USAGE}\n`);
    process.exit(2);
  }
  if (opts.help) {
    process.stdout.write(`${USAGE}\n`);
    return;
  }
  if (opts.renderOnce) {
    const { facts, size } = opts.fixture ? factsFromFixture(opts.fixture, opts) : await factsLive(opts);
    const { model, view } = await driveOnce(facts, opts, size);
    const frame = renderFrame(model, size, { ...view, stale: Boolean(facts.snapshotError) });
    process.stdout.write(opts.tags ? `${toTags(frame.lines)}\n` : `${toPlain(frame.lines).join('\n')}\n`);
    if (facts.snapshotError && !opts.fixture) {
      process.stderr.write(`fm-board: snapshot failed: ${facts.snapshotError}\n`);
      process.exit(1);
    }
    return;
  }
  if (!opts.fmHome) fail('FM_HOME is not set and --fm-home was not given', 2);
  if (!process.stdout.isTTY && !opts.headless) fail('interactive mode needs a terminal; use --render-once for a one-shot frame', 2);
  const { runApp } = await import('./lib/app.mjs');
  await runApp({ ...opts, fmHome: opts.fmHome.replace(/\/+$/, '') });
}

// A closed pipe (`fm-board.sh --render-once | head`) is not an error worth a
// stack trace.
process.stdout.on('error', (e) => {
  if (e && e.code === 'EPIPE') process.exit(0);
  throw e;
});

main().catch((e) => fail(e && e.stack ? e.stack : String(e)));
