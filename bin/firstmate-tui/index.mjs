#!/usr/bin/env node
// bin/firstmate-tui/index.mjs - entry point for the firstmate-tui board.
//
// Modes:
//   run (default)  interactive board (neo-blessed through lib/tui-blessed.mjs)
//   --render-once  print one frame to stdout and exit; with --fixture <json> the
//                  frame comes from that facts file and no firstmate home or
//                  herdr is touched, which is how tests/fm-board.test.sh works.
//                  --keys <list> presses keys, and --mouse <list> clicks,
//                  double-clicks, wheels and drags column boundaries (see
//                  lib/args.mjs), through lib/controller.mjs before
//                  the frame is rendered (a PR open runs --opener-cmd when
//                  given, and is only reported in the footer otherwise; a herdr
//                  focus is reported, never run; r against a live home re-runs
//                  the snapshot and then the PR fetch (unless --no-prs) and
//                  against a fixture only reports that it cannot; enter on a
//                  Findings row, or a Landed row whose report is its first
//                  reachable target, runs --viewer-cmd when given and otherwise only
//                  reports the viewer the chain resolved to, naming the binary
//                  found on PATH, so a test can shadow glow with a fake without
//                  ever launching a real viewer; enter on a row with a hold
//                  card builds the card (a delegate home's record is read
//                  through that home's fm-fleet-snapshot.sh) and shows it the
//                  same way, from a temp file removed afterwards; d,y and
//                  D,enter really run bash <home>/bin/fm-captain-hold.sh in
//                  the hold's home, awaited before the frame, so a test points
//                  the fixture's homes at scratch directories holding a fake);
//                  --expand <all|ids>
//                  expands In flight groups; --tags prints the color tags;
//                  --view-state <file> loads hidden rows, hidden panes,
//                  dragged column widths and the saved selection (the focused
//                  pane, the selected row by its hide key else its index, the
//                  expanded groups, the scroll offsets) from that file and
//                  saves x/X/1-6/0 changes and drags back to it; the selection
//                  it restores is written back as it was read, never as the
//                  keys left it, since a one-shot render is scripted from a
//                  known start and successive renders over one file must stay
//                  independent (the app records the selection; lib/app.mjs).
//                  Without the flag a fixture render loads nothing and saves
//                  nothing;
//                  --cache <file> reads the state cache before the frame is
//                  built, the way the app does at launch: a fresh cache fills
//                  in whatever the fixture (or the live home) has not landed,
//                  no snapshot, no PR data, and those panes are marked
//                  `(cached Nm ago)` against the fixture's clock; a stale,
//                  damaged or foreign cache is ignored (the footer says so) and
//                  the frame is the fixture's alone. When nothing was taken
//                  from it the rendered facts are written to it at the end,
//                  as a clean tick of the app would, so a test can build a
//                  cache with the real serializer; without the flag a
//                  one-shot render reads and writes no cache; --config <file>
//                  reads the board's config (the GitHub login, the To review
//                  label rules) and writes the example there when absent
//                  (without the flag a fixture render reads none, and a live
//                  render walks the default chain as the app does).
//                  `.` opens the Settings page: its install identity comes
//                  from --install-root (default: the directory above bin/),
//                  its release data from --curl-cmd (without the flag a
//                  one-shot render fetches nothing and says so), an upgrade it
//                  confirms runs `bash <root>/bin/firstmate-tui.sh upgrade ...` and
//                  is awaited before the next key, and the relaunch key only
//                  reports the exit status the launcher would act on.
//
// Fixture file shape (see tests/fixtures/*.json):
//   { "now": ISO time, "cols": N, "rows": N, "fm_home": path,
//     "snapshot": fm-fleet-snapshot.v1 document,
//     "ledgers": [ { id, home, remote, cached, summary, error } ]   (optional;
//                 derived from snapshot.secondmate_current when absent),
//     "herdr": { "state": "connected" | "disconnected" | ... (optional),
//                "agents": [ { pane_id, agent_status, terminal_title_stripped } ] } | null,
//     "prs": { "candidate_prs": [ { num, repo, task, url, review, mergeable,
//                                   checks, created_at?, title?, base?, draft?,
//                                   state?, merged_at?, closed_at?, author?,
//                                   labels?, requested?, my_review?, pane? } ],
//              "error"?, "identity"?, "mine"?, "toreview"? } | null,
//     "snapshot_error": text (optional; marks the four snapshot panes stale),
//     "refresh": { "next_in": seconds, "refreshing": bool, "failed_ago": seconds,
//                  "failed": text, "loading_frame": N } (optional; every field optional),
//     "mtimes": { "<absolute path>": epoch seconds },
//     "status_logs": { "<absolute status log path>": [ "working", "done", ... ] } }
// status_logs stands in for the lines of a task's status log (the verbs, in
// order), which the model reads to tell a task repairing its PR (working
// again after a done line) from one on its first pass; a path absent from
// the map reads as an unreadable log, never repairing.
// The refresh block stands in for the app's schedule, which a one-shot render
// has none of: {"next_in": 18} draws `next refresh in 18s` on the title line,
// {"refreshing": true} draws `refreshing…`, and {"failed_ago": 40, "next_in":
// 20, "failed": "PR fetch: exit 1"} draws `refresh failed 40s ago, retrying in
// 20s` in red; without the block the title line carries no refresh label.
// With {"refreshing": true} a fixture that omits "snapshot" (or sets it null)
// puts Needs you, In flight, Findings and Landed into the loading state, and
// one that omits "prs" (or sets it null) puts My PRs and To review there: each
// such pane draws the spinner line, `⠋ loading fleet snapshot…`, `⠋ loading
// GitHub checks…` or `⠋ loading GitHub review requests…`, in place of its
// rows. "loading_frame" (a whole number, default 0) picks the spinner glyph,
// the app's frame counter standing still, so the frame is the same on every
// render.
// A candidate row's "pane" is 'mine' (the default) or 'toreview'. prs.identity
// is the { login, source } the panes are built around: absent, a fixture
// stands for a known login (`captain`, source `fixture`); null is the
// identity the app has not resolved yet, which with {"refreshing": true}
// puts `⠋ resolving GitHub identity…` in both PR panes and lists nothing
// there; an object with no login ({ "login": null, "source": "unknown",
// "reason": text }) is the identity every rung failed to resolve, which puts
// `identity unknown: see Settings (.)` in both. The identity reaches the
// Settings page under --no-prs as well. prs.mine
// and prs.toreview carry a pane's own { error, fetched, scope, unavailable }
// (fetched: false keeps that pane before its first fetch; scope: [] is an
// empty To review scope), the top-level "error" standing for both when a pane
// has no block.
// With --no-herdr the fixture's herdr block is still applied as an offline
// overlay (state "fixture", which the title line treats as connected: no
// herdr text) so the join is testable without a live server; a "state" in
// the block overrides it, and a "detail" is the reason the title line's red
// `herdr disconnected (<reason>)` warning names (a "disconnected" fixture also
// shows the grey "unknown" HERDR cells). Without a herdr block the state is
// "off", which under --no-herdr warns `herdr disconnected (--no-herdr)`.

import { readFileSync } from 'node:fs';
import { userInfo } from 'node:os';
import { parseArgs, USAGE } from './lib/args.mjs';
import { buildModel, initialPrs, mergePrs, prsFailureText } from './lib/model.mjs';
import { renderFrame, toPlain } from './lib/render.mjs';
import { toTags } from './lib/tui-blessed.mjs';
import { agentsFromSnapshot, HerdrClient } from './lib/herdr.mjs';
import { collectLedgers, discoverHomes, fetchPrs, fetchReleases, mtime, readHoldRecord, resolveIdentityLive, runSnapshot, statusVerbs } from './lib/sources.mjs';
import { focusFromSaved, focusProblem, handleKey, handleMouse, openDeferPrompt, scrollFromSaved, viewProblem } from './lib/controller.mjs';
import { deferHold, discardHold, firstLine, HOLD_TIMEOUT_MS, holdFailureText, prepareHoldCard, removeTempDir } from './lib/hold.mjs';
import { isOpenableUrl, openUrl } from './lib/opener.mjs';
import { resolveViewer, runViewer, whichOnPath } from './lib/viewer.mjs';
import { loadViewState, resolveViewStatePath, saveViewState } from './lib/viewstate.mjs';
import { cachedFlags, loadStateCache, resolveCachePath, saveStateCache } from './lib/cache.mjs';
import { finishUpgrade, initialSettings, RELAUNCH_EXIT, resultNotice, settingsConfig, settingsFlags } from './lib/settings.mjs';
import { defaultInstallRoot, readInstall, runUpgrade } from './lib/upgrade.mjs';
import { defaultConfig, loadOrCreateConfig } from './lib/config.mjs';
import { identityKnown } from './lib/identity.mjs';

function fail(msg, code = 1) {
  process.stderr.write(`firstmate-tui: ${msg}\n`);
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
  const statusLogs = fx.status_logs || {};
  const fixtureVerbs = (p) => (Object.prototype.hasOwnProperty.call(statusLogs, p) && Array.isArray(statusLogs[p]) ? statusLogs[p].map((v) => String(v).toLowerCase()) : null);
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
      summary: { active_children: r.active_children || [], endpoints: r.endpoints || [], decisions_open: r.decisions_open || [], holds: Array.isArray(r.holds) ? r.holds : [], landed: Array.isArray(r.landed) ? r.landed : [], queued: Array.isArray(r.queued) ? r.queued : [], contributions: r.contributions && typeof r.contributions === 'object' ? r.contributions : null },
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
    herdr = { state: 'off', detail: opts.herdr ? '' : '--no-herdr', agents: {} };
  }
  const refresh = refreshFromFixture(fx.refresh, now);
  return {
    // `identity` beside `prs` is what the Settings page reads when the fetch is off.
    facts: { now, fmHome, snapshot, snapshotAt: snapshot ? now - Number(fx.snapshot_age_seconds ?? 12) : null, snapshotError: fx.snapshot_error || null, ledgers, herdr, prs: prsFromFixture(fx.prs, opts, now), identity: identityFromFixture(fx.prs), refresh, mtime: fixtureMtime, statusVerbs: fixtureVerbs },
    size: { cols: opts.cols || fx.cols || 120, rows: opts.rows || fx.rows || 40 },
  };
}

// The fixture's prs.identity -> the identity the panes and the Settings page
// read: absent, a known login; null, the app's not-yet-resolved state; an
// object, its login when it has one, else the resolved unknown identity with
// the object's reason.
export function identityFromFixture(block) {
  if (!block || !Object.prototype.hasOwnProperty.call(block, 'identity')) return { login: 'captain', source: 'fixture', reason: null };
  const given = block.identity;
  if (given === null || given === undefined) return null;
  if (typeof given === 'object' && given.login) return { login: String(given.login), source: given.source || 'fixture', reason: null };
  return { login: null, source: 'unknown', reason: (given && typeof given === 'object' && given.reason) || 'fixture: no login' };
}

// The fixture's prs block -> the facts the two PR panes read (lib/model.mjs).
export function prsFromFixture(block, opts, now) {
  if (!opts.prs) return { enabled: false };
  const fetched = block && Array.isArray(block.candidate_prs) ? now - 30 : null;
  const topError = block && block.error ? block.error : null;
  const pane = (id) => {
    const own = block && block[id] && typeof block[id] === 'object' ? block[id] : {};
    return {
      fetchedAt: own.fetched === false ? null : fetched,
      error: own.error !== undefined ? own.error : topError,
      scope: Array.isArray(own.scope) ? own.scope : null,
      unavailable: typeof own.unavailable === 'string' ? own.unavailable : null,
    };
  };
  return { enabled: true, fetchedAt: fetched, error: topError, candidate_prs: block && Array.isArray(block.candidate_prs) ? block.candidate_prs : [], identity: identityFromFixture(block), mine: pane('mine'), toreview: pane('toreview') };
}

// The fixture's refresh block -> the facts the title line reads (lib/model.mjs
// refreshLabel), anchored on the fixture's clock; null without the block.
function refreshFromFixture(block, now) {
  if (!block || typeof block !== 'object') return null;
  const seconds = (key) => {
    if (block[key] === undefined || block[key] === null) return null;
    const n = Number(block[key]);
    if (!Number.isFinite(n)) fail(`fixture refresh.${key} is not a number: ${block[key]}`, 2);
    return n;
  };
  const nextIn = seconds('next_in');
  const failedAgo = seconds('failed_ago');
  const failed = typeof block.failed === 'string' && block.failed ? block.failed : null;
  const loadingFrame = seconds('loading_frame') ?? 0;
  if (!Number.isInteger(loadingFrame) || loadingFrame < 0) fail(`fixture refresh.loading_frame is not a whole number: ${block.loading_frame}`, 2);
  return {
    nextAt: nextIn === null ? null : now + nextIn,
    refreshing: Boolean(block.refreshing),
    failedAt: failedAgo !== null ? now - failedAgo : failed ? now : null,
    failed,
    loadingFrame,
  };
}

// The identity for a live render: the config file, then gh (when the fetch is
// on and gh is on PATH), then git, as the app resolves it on its first refresh.
async function identityLive(config, opts, timeoutMs) {
  return resolveIdentityLive({ config, askGh: opts.prs && whichOnPath('gh', process.env), timeoutMs });
}

async function factsLive(opts, cfg) {
  if (!opts.fmHome) fail('FM_HOME is not set and --fm-home was not given', 2);
  const fmHome = opts.fmHome.replace(/\/+$/, '');
  const now = () => Math.floor(Date.now() / 1000);
  const timeoutMs = opts.snapshotTimeout * 1000;
  // The snapshot, then the PR fetch against the repositories it names, as one
  // tick of the app does.
  const snap = await runSnapshot(fmHome, { timeoutMs });
  const snapshot = snap.error ? null : snap.value;
  const identity = await identityLive(cfg.config, opts, timeoutMs);
  const r = opts.prs ? await fetchPrs(fmHome, snapshot, { identity, config: cfg.config, timeoutMs }) : null;
  const ledgers = collectLedgers(snapshot, discoverHomes(fmHome, opts.homes));
  const prs = r ? mergePrs(initialPrs(true, identity), r, now(), identity) : { enabled: false };
  let herdr = { state: 'off', detail: '--no-herdr', agents: {} };
  if (opts.herdr) {
    const client = new HerdrClient({ cmd: opts.herdrCmd, socketPath: opts.herdrSocket });
    const ok = await client.bootstrap();
    herdr = ok ? { state: 'connected', detail: 'one-shot', agents: client.agents } : { state: 'unavailable', detail: client.detail, agents: {} };
  }
  return {
    // A one-shot render has no schedule, so the title line carries no refresh label.
    facts: { now: now(), fmHome, snapshot, snapshotAt: snapshot ? now() : null, snapshotError: snap.error, ledgers, herdr, prs, refresh: null, mtime, statusVerbs, identity, config: cfg.config },
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

// The state cache for a one-shot render: only with --cache, so a render never
// reads or writes one by accident (the app resolves the default beside the
// view-state file; here that default applies only to a refused --cache path).
function cacheFor(opts, fmHome, viewStatePath) {
  if (!opts.cachePath) return { path: null, problem: null };
  return resolveCachePath({ explicit: opts.cachePath, viewStatePath, fmHome });
}

// A fresh cache into the facts, where they have not landed: the snapshot (and
// its ledgers) when the fixture or the home gave none, the PR block when the
// fetch is on and has not landed. A failure the fixture carries (snapshot_error,
// a prs error) stays beside the cached rows, as the app keeps the cached rows
// under a failed launch refresh: the pane is stale and cached at once.
// Mutates facts, sets facts.cached for the markers, and says whether anything
// was taken.
function restoreFromCache(facts, cache) {
  const c = cache.facts;
  if (!c) return false;
  const flags = { at: cache.fetchedAt, snapshot: false, prs: { mine: false, toreview: false } };
  let took = false;
  if (!facts.snapshot) {
    facts.snapshot = c.snapshot;
    facts.snapshotAt = c.snapshotAt;
    facts.ledgers = c.ledgers;
    flags.snapshot = true;
    took = true;
  }
  const prs = facts.prs || { enabled: false };
  if (prs.enabled && !prs.fetchedAt && c.prs && c.prs.enabled) {
    const paneError = (id) => (prs[id] && prs[id].error !== undefined ? prs[id].error : prs.error) ?? null;
    facts.prs = { ...c.prs, enabled: true, error: prs.error ?? null, mine: { ...c.prs.mine, error: paneError('mine') }, toreview: { ...c.prs.toreview, error: paneError('toreview') } };
    flags.prs = cachedFlags(cache, { prsEnabled: true }).prs;
    took = true;
  }
  if (took) facts.cached = flags;
  return took;
}

// The config file for a one-shot render, the same way: a fixture render reads
// (and creates) one only with --config, so a fixture frame depends on the
// fixture alone; a live render walks the default chain as the app does.
function configFor(opts, fmHome) {
  if (opts.fixture && !opts.config) return { path: null, problem: null, config: defaultConfig(), status: 'none', error: 'not read (fixture render without --config)' };
  return loadOrCreateConfig({ explicit: opts.config, fmHome, env: process.env });
}

// One-shot view: apply --expand, then --keys and --mouse in command-line order
// through the shared handlers, then hand back the model and view to render.
// Effects: an opened PR runs --opener-cmd (awaited, so a fake opener has
// written its record before the process exits) or, without one, only leaves a
// footer notice; a focus is checked the same way the app checks it, then
// reported rather than run; a viewed report runs the resolved viewer
// (awaited); r re-reads a live home. Before each mouse event the frame is
// rendered at the final size, as the app redraws after every key, so the
// pointer is measured against what would be on screen (a drag's motion
// reports each see the frame the previous one produced, as in the app); the
// events of one token share a time stamp and tokens are a second apart, so
// dblclick is a double-click and two click tokens on one row are two single
// clicks. With --no-mouse the mouse tokens are skipped, as the app would
// ignore the events.
// On the Settings page the release fetch and the upgrade child are awaited
// before the next input, so a list reads in order: `.` fetches, `enter`
// asks, `y` runs the launcher to its end, `R` reports the relaunch.
async function driveOnce(facts, opts, size, cfg) {
  const vs = viewStateFor(opts, facts.fmHome);
  const loaded = loadViewState(vs.path);
  const cachePath = cacheFor(opts, facts.fmHome, vs.path);
  const cache = opts.cache === false ? { facts: null, fetchedAt: null, error: null, stale: false } : loadStateCache(cachePath.path, { now: facts.now, maxAge: opts.cacheMaxAge, fmHome: facts.fmHome });
  const restored = restoreFromCache(facts, cache);
  const settings = initialSettings({
    install: readInstall(opts.installRoot || defaultInstallRoot()),
    flags: settingsFlags(opts),
    idleReason: opts.curlCmd ? null : 'not fetched (no --curl-cmd in --render-once)',
    identity: facts.prs && facts.prs.identity ? facts.prs.identity : facts.identity || null,
    config: settingsConfig(cfg),
  });
  const view = { pane: 0, row: 0, scroll: scrollFromSaved(loaded.state.scroll), expanded: new Set(loaded.state.expanded), hidden: loaded.state.hidden, hiddenPanes: loaded.state.hiddenPanes, columns: loaded.state.columns, drag: null, showHidden: false, help: false, frame: null, lastClick: null, notice: '', noticeBad: false, prompt: null, busy: null, page: 'board', settings };
  // The login a discard names: the fixture's or the live identity, else the OS user.
  const identity = facts.identity || (facts.prs && facts.prs.identity) || null;
  const holdLogin = () => (identityKnown(identity) ? { login: identity.login, os: false } : { login: userInfo().username, os: true });
  const build = () => buildModel(facts, { expanded: view.expanded, allHomesNeeds: opts.allHomesNeeds, hidden: view.hidden, showHidden: view.showHidden, hiddenPanes: view.hiddenPanes });
  let model = build();
  if (opts.expand.length) {
    const inflight = model.panes.find((p) => p.id === 'inflight');
    for (const row of inflight.rows) {
      if (row.group && (opts.expand.includes('all') || opts.expand.includes(row.homeId))) view.expanded.add(row.group);
    }
    model = build();
  }
  // The saved selection, as the app restores it once the pane has its rows: a
  // pane still loading in this frame keeps the default selection.
  const focus = focusFromSaved(model, loaded.state.focus);
  if (focus) {
    view.pane = focus.pane;
    view.row = focus.row;
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
      // A row whose pane still draws the state cache names the data's age.
      const pane = model.panes[view.pane];
      const cached = pane && pane.cached ? ` · ${pane.cached.label.replace(/^cached /, 'data cached ')}` : '';
      if (!opts.openerCmd) {
        ctx.notice(`would open ${row.url} (${row.name}); no --opener-cmd in --render-once${cached}`);
        return;
      }
      pending.push(
        openUrl(row.url, { cmd: opts.openerCmd, wait: true })
          .then(() => ctx.notice(`opened ${row.url} (${row.name})${cached}`))
          .catch((e) => ctx.notice(`open failed: ${e.message} · ${row.url}`, true)),
      );
    },
    focus: (row, { any = false } = {}) => {
      const pane = model.panes[view.pane];
      const problem = focusProblem(pane, row, opts.herdr && facts.herdr && facts.herdr.state === 'connected', { any });
      ctx.notice(problem || `would focus ${row.paneId} (${row.name}); --render-once never runs herdr agent focus`, Boolean(problem));
    },
    // The hold card: built for real (a delegate home's record read through
    // its own snapshot script), shown through --viewer-cmd when given and
    // only described otherwise; the temp file goes either way.
    viewCard: (row) => {
      const what = `the hold card of ${row.name}`;
      view.busy = `preparing ${what}`;
      pending.push(
        (async () => {
          let prepared;
          try {
            prepared = await prepareHoldCard(row.card, { timeoutMs: opts.snapshotTimeout * 1000, onBusy: (text) => ctx.notice(text) });
          } catch (e) {
            ctx.notice(`${what}: ${e.message}`, true);
            return;
          }
          const partial = prepared.partial ? ' (partial record)' : '';
          const { argv, source } = resolveViewer({ cmd: opts.viewerCmd, env: process.env });
          try {
            if (!opts.viewerCmd) {
              ctx.notice(`would view ${what}${partial}, ${prepared.text.split('\n').length} lines, with ${argv.join(' ')} (${source}); no --viewer-cmd in --render-once`);
              return;
            }
            const r = await runViewer(prepared.path, { argv });
            ctx.notice(r.code === 0 || r.code === null ? `viewed ${what}${partial} (${source})` : `${argv[0]} exited ${r.code} · ${what}`, r.code !== 0 && r.code !== null);
          } catch (e) {
            ctx.notice(`viewer failed (${argv[0]}): ${e.message} · ${what}`, true);
          } finally {
            removeTempDir(prepared.dir);
          }
        })().finally(() => {
          view.busy = null;
        }),
      );
    },
    // The two writes, for real, against the home the row names: a fixture
    // points its homes at scratch directories holding a fake fm-captain-hold.sh.
    // A one-shot render refreshes nothing afterwards; the footer says what ran.
    holdDiscard: (row) => {
      const { hold } = row;
      const who = holdLogin();
      view.busy = `discarding ${hold.id}`;
      pending.push(
        discardHold({ home: hold.home, id: hold.id, login: who.login, timeoutMs: HOLD_TIMEOUT_MS })
          .then((r) => {
            if (!r.ok) {
              ctx.notice(holdFailureText(r), true);
              return;
            }
            const said = firstLine(r.stdout);
            ctx.notice(`discarded ${hold.id}${who.os ? ` as OS user ${who.login} (GitHub login unknown)` : ''}${said ? ` · ${said}` : ''}`);
          })
          .finally(() => {
            view.busy = null;
          }),
      );
    },
    holdDefer: (row, { reason, until }) => {
      const { hold } = row;
      view.busy = `deferring ${hold.id}`;
      pending.push(
        deferHold({ home: hold.home, id: hold.id, reason, until, timeoutMs: HOLD_TIMEOUT_MS })
          .then((r) => {
            if (!r.ok) {
              ctx.notice(holdFailureText(r), true);
              return;
            }
            const said = firstLine(r.stdout);
            ctx.notice(`deferred ${hold.id} until ${until}${said ? ` · ${said}` : ''}`);
          })
          .finally(() => {
            view.busy = null;
          }),
      );
    },
    // A delegate hold's full reason, read from its home before the defer
    // prompt opens (the ledger's copy is cut at 160 characters).
    holdReason: (row) => {
      const { hold } = row;
      view.busy = `reading the record of ${hold.id}`;
      pending.push(
        readHoldRecord(hold.home, hold.id, { timeoutMs: opts.snapshotTimeout * 1000 })
          .then((r) => {
            const reason = r.record && r.record.hold_reason ? String(r.record.hold_reason) : null;
            if (!reason) {
              ctx.notice(`${hold.id}: the full hold reason is not readable (${r.error || 'no hold reason on the record'}); defer it from ${hold.homeId} itself`, true);
              return;
            }
            openDeferPrompt(view, row, reason);
          })
          .finally(() => {
            view.busy = null;
          }),
      );
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
      pending.push(
        refreshLive(facts, opts, cfg)
          .then((text) => ctx.notice(text))
          .then(() => {
            settings.identity = facts.identity || settings.identity;
            ctx.rebuild();
          }),
      );
    },
    persist: () => {
      if (!vs.path) return;
      // The selection goes back as it was read (see the header): a hide never
      // wipes a saved selection, and never records the scripted one.
      const err = saveViewState(vs.path, { hidden: view.hidden, hiddenPanes: view.hiddenPanes, columns: view.columns, focus: loaded.state.focus, expanded: loaded.state.expanded, scroll: loaded.state.scroll });
      if (err) ctx.notice(`view state not saved: ${err}`, true);
    },
    // Settings page effects. Without --curl-cmd nothing is fetched, so a test
    // never reaches GitHub by accident; the page says so on its latest line.
    settingsFetch: () => {
      const s = view.settings;
      if (!opts.curlCmd) {
        ctx.notice('release data not fetched: no --curl-cmd in --render-once');
        return;
      }
      if (s.releases.state === 'fetching') return;
      s.releases = { ...s.releases, state: 'fetching' };
      pending.push(
        fetchReleases({ repo: s.install.repo, curlCmd: opts.curlCmd, timeoutMs: opts.snapshotTimeout * 1000 }).then((r) => {
          s.releases = r;
        }),
      );
    },
    settingsUpgrade: (running) => {
      const s = view.settings;
      pending.push(
        runUpgrade({ launcher: s.install.launcher, args: running.args, onLine: (text) => s.output.push(text) }).then((r) => {
          const result = finishUpgrade(s, r);
          ctx.notice(resultNotice(result), !result.ok);
        }),
      );
    },
    relaunch: () => {
      ctx.notice(`would relaunch: exit ${RELAUNCH_EXIT} makes bin/firstmate-tui.sh run start the installed copy again; --render-once never exits ${RELAUNCH_EXIT}`);
    },
    quit: () => {},
  };
  if (loaded.error) ctx.notice(`view state: ${loaded.error}`, true);
  if (vs.problem) ctx.notice(vs.problem, true);
  if (cache.error) ctx.notice(`state cache ignored: ${cache.error}`, true);
  if (cachePath.problem) ctx.notice(cachePath.problem, true);
  if (cfg.problem) ctx.notice(cfg.problem, true);
  if (cfg.status === 'defaults' && cfg.error) ctx.notice(`config: ${cfg.error}; running with the defaults`, true);
  for (const [n, input] of opts.inputs.entries()) {
    // On the Settings page, and while a hold effect runs (view.busy: a card,
    // a delegate record read that opens the defer prompt, the command), the
    // effects finish before the next input, so a list reads in order.
    if ((view.page === 'settings' || view.busy) && pending.length) await Promise.all(pending.splice(0));
    if (input.kind === 'key') {
      handleKey(ctx, input.key);
      continue;
    }
    if (!opts.mouse) continue;
    for (const ev of input.events) {
      const frame = renderFrame(model, size, view);
      view.scroll = frame.scroll;
      view.frame = { cols: frame.cols, rows: frame.rows, zones: frame.zones };
      handleMouse(ctx, { ...ev, time: n * 1000 });
    }
  }
  await Promise.all(pending);
  // After the frame: the rendered facts go to the cache when none of them
  // came from it and nothing failed, as a clean tick of the app writes them.
  const finish = () => {
    if (cachePath.path && !restored && facts.snapshot && !facts.snapshotError && !(facts.prs && facts.prs.error)) {
      const err = saveStateCache(cachePath.path, { fmHome: facts.fmHome, snapshot: facts.snapshot, snapshotAt: facts.snapshotAt, ledgers: facts.ledgers, prs: facts.prs, identity: facts.identity || (facts.prs && facts.prs.identity) || null, herdr: { agents: facts.herdr && facts.herdr.agents ? facts.herdr.agents : {} } }, { fetchedAt: facts.now });
      if (err) process.stderr.write(`firstmate-tui: state cache not saved: ${err}\n`);
    }
  };
  return { model, view, finish };
}

// The r key against a live home: the same refresh a tick of the app runs, the
// snapshot and then, unless --no-prs, the PR fetch (the identity resolved
// again first while it is unknown). Mutates facts in place and resolves to the
// footer text (a fetch note, such as the script fallback, is appended so a
// one-shot render shows it).
async function refreshLive(facts, opts, cfg) {
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
  if (!identityKnown(facts.identity)) {
    facts.identity = await identityLive(cfg.config, opts, timeoutMs);
    facts.prs = { ...facts.prs, identity: facts.identity };
  }
  const r = await fetchPrs(facts.fmHome, facts.snapshot, { identity: facts.identity, config: cfg.config, timeoutMs });
  facts.prs = mergePrs(facts.prs, r, Math.floor(Date.now() / 1000), facts.identity);
  const failure = prsFailureText(r);
  if (failure) return `PR fetch: ${failure}`;
  return r.note ? `refreshed: snapshot and PR checks · ${r.note}` : 'refreshed: snapshot and PR checks';
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2), process.env);
  } catch (e) {
    process.stderr.write(`firstmate-tui: ${e.message}\n${USAGE}\n`);
    process.exit(2);
  }
  if (opts.help) {
    process.stdout.write(`${USAGE}\n`);
    return;
  }
  if (opts.renderOnce) {
    // A live render reads the config first, since the fetch needs it; a
    // fixture render reads it (with --config only) against the fixture's home,
    // so a path inside that home is refused the way the view state is.
    const live = opts.fixture ? null : configFor(opts, opts.fmHome ? opts.fmHome.replace(/\/+$/, '') : null);
    const { facts, size } = opts.fixture ? factsFromFixture(opts.fixture, opts) : await factsLive(opts, live);
    const cfg = live || configFor(opts, facts.fmHome);
    const { model, view, finish } = await driveOnce(facts, opts, size, cfg);
    const frame = renderFrame(model, size, view);
    finish();
    process.stdout.write(opts.tags ? `${toTags(frame.lines)}\n` : `${toPlain(frame.lines).join('\n')}\n`);
    if (facts.snapshotError && !opts.fixture) {
      process.stderr.write(`firstmate-tui: snapshot failed: ${facts.snapshotError}\n`);
      process.exit(1);
    }
    return;
  }
  if (!opts.fmHome) fail('FM_HOME is not set and --fm-home was not given', 2);
  if (!process.stdout.isTTY && !opts.headless) fail('interactive mode needs a terminal; use --render-once for a one-shot frame', 2);
  const { runApp } = await import('./lib/app.mjs');
  await runApp({ ...opts, fmHome: opts.fmHome.replace(/\/+$/, '') });
}

// A closed pipe (`firstmate-tui --render-once | head`) is not an error worth a
// stack trace.
process.stdout.on('error', (e) => {
  if (e && e.code === 'EPIPE') process.exit(0);
  throw e;
});

main().catch((e) => fail(e && e.stack ? e.stack : String(e)));
