#!/usr/bin/env node
// bin/fm-board/index.mjs - entry point for the fm-board TUI.
//
// Modes:
//   run (default)  interactive board (neo-blessed through lib/tui-blessed.mjs)
//   --render-once  print one frame to stdout and exit; with --fixture <json> the
//                  frame comes from that facts file and no firstmate home or
//                  herdr is touched, which is how tests/fm-board.test.sh works.
//                  --keys <list> presses keys through lib/controller.mjs before
//                  the frame is rendered (a PR open runs --opener-cmd when
//                  given, and is only reported in the footer otherwise; a herdr
//                  focus is reported, never run); --expand <all|ids> expands
//                  In flight groups.
//
// Fixture file shape (see tests/fixtures/*.json):
//   { "now": ISO time, "cols": N, "rows": N, "fm_home": path,
//     "snapshot": fm-fleet-snapshot.v1 document,
//     "ledgers": [ { id, home, remote, cached, summary, error } ]   (optional;
//                 derived from snapshot.secondmate_current when absent),
//     "herdr": { "agents": [ { pane_id, agent_status, terminal_title_stripped } ] } | null,
//     "prs": { "candidate_prs": [...] } | null,
//     "mtimes": { "<absolute path>": epoch seconds } }
// With --no-herdr the fixture's herdr block is still applied as an offline
// overlay (header says "herdr fixture") so the join is testable without a
// live server; without a herdr block the header says "herdr off".

import { readFileSync } from 'node:fs';
import { parseArgs, USAGE } from './lib/args.mjs';
import { buildModel } from './lib/model.mjs';
import { renderFrame, toPlain } from './lib/render.mjs';
import { agentsFromSnapshot } from './lib/herdr.mjs';
import { collectLedgers, discoverHomes, mtime, runBearingsPrs, runSnapshot } from './lib/sources.mjs';
import { focusProblem, handleKey } from './lib/controller.mjs';
import { isOpenableUrl, openUrl } from './lib/opener.mjs';

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
    herdr = { state: opts.herdr ? 'connected' : 'fixture', detail: '', agents };
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
  const snap = await runSnapshot(fmHome, { timeoutMs: opts.snapshotTimeout * 1000 });
  const snapshot = snap.error ? null : snap.value;
  const ledgers = collectLedgers(snapshot, discoverHomes(fmHome, opts.homes));
  let prs = { enabled: false };
  if (opts.prs) {
    const r = await runBearingsPrs(fmHome, { timeoutMs: opts.snapshotTimeout * 1000 });
    prs = { enabled: true, fetchedAt: r.error ? null : now(), error: r.error, candidate_prs: r.candidate_prs };
  }
  let herdr = { state: 'off', detail: '', agents: {} };
  if (opts.herdr) {
    const { HerdrClient } = await import('./lib/herdr.mjs');
    const client = new HerdrClient({ cmd: opts.herdrCmd, socketPath: opts.herdrSocket });
    const ok = await client.bootstrap();
    herdr = ok ? { state: 'connected', detail: 'one-shot', agents: client.agents } : { state: 'unavailable', detail: client.detail, agents: {} };
  }
  return {
    facts: { now: now(), fmHome, snapshot, snapshotAt: snapshot ? now() : null, snapshotError: snap.error, ledgers, herdr, prs, mtime },
    size: { cols: opts.cols || process.stdout.columns || 120, rows: opts.rows || process.stdout.rows || 40 },
  };
}

// One-shot view: apply --expand and --keys through the shared key handler,
// then hand back the model and view to render. Effects: an opened PR runs
// --opener-cmd (awaited, so a fake opener has written its record before the
// process exits) or, without one, only leaves a footer notice; a focus is
// checked the same way the app checks it, then reported rather than run.
async function driveOnce(facts, opts) {
  const view = { pane: 0, row: 0, scroll: [], expanded: new Set(), help: false, notice: '', noticeBad: false };
  const build = () => buildModel(facts, { expanded: view.expanded, allHomesNeeds: opts.allHomesNeeds });
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
    refresh: () => ctx.notice('refresh is not available in --render-once', true),
    quit: () => {},
  };
  for (const key of opts.keys) handleKey(ctx, key);
  await Promise.all(pending);
  return { model, view };
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
    const { model, view } = await driveOnce(facts, opts);
    const frame = renderFrame(model, size, { ...view, stale: Boolean(facts.snapshotError) });
    process.stdout.write(`${toPlain(frame.lines).join('\n')}\n`);
    if (facts.snapshotError && !opts.fixture) {
      process.stderr.write(`fm-board: snapshot failed: ${facts.snapshotError}\n`);
      process.exit(1);
    }
    return;
  }
  if (!opts.fmHome) fail('FM_HOME is not set and --fm-home was not given', 2);
  if (!process.stdout.isTTY) fail('interactive mode needs a terminal; use --render-once for a one-shot frame', 2);
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
