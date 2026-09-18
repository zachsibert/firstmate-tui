// lib/model.mjs - pure projection from firstmate facts to the six board panes.
//
// Input (one `facts` object, built by lib/sources.mjs from live reads or by
// index.mjs from a --fixture file):
//   now           epoch seconds the frame is rendered at
//   fmHome        the main firstmate home path
//   snapshot      fm-fleet-snapshot.v1 document from fm-fleet-snapshot.sh --json
//   snapshotAt    epoch seconds of that snapshot (null when never taken)
//   snapshotError last snapshot failure text (null when the last run succeeded)
//   ledgers[]     one per secondmate home: { id, home, remote, cached, summary,
//                 error, generatedAt } where summary is fm-secondmate-home-summary.v1
//   herdr         { state, detail, agents: { <pane-id>: { agent_status, title } } }
//   prs           { enabled, fetchedAt, error, candidate_prs[], identity, mine,
//                 toreview } from the live PR fetch in lib/sources.mjs (enabled
//                 unless --no-prs; fetchedAt is null until the first fetch of a
//                 session lands). A candidate is {num, repo, task, url, review,
//                 mergeable, checks} plus, from gh only (absent from the
//                 fm-bearings-snapshot.sh fallback): merge_state (GitHub's
//                 mergeStateStatus, CLEAN, DIRTY, BLOCKED, ... or null),
//                 created_at, merged_at,
//                 closed_at (ISO 8601), title, base (the base branch), draft
//                 (boolean), state (OPEN, MERGED or CLOSED), author (a login or
//                 null), labels (strings), requested (the identity was asked
//                 to review it), my_review (APPROVED, CHANGES_REQUESTED or
//                 null: the identity's own latest review) and pane ('mine' or
//                 'toreview'; absent means 'mine'). identity is { login,
//                 source, reason } (lib/identity.mjs; unknown when login is
//                 null). mine and toreview each carry that pane's own
//                 { fetchedAt, error } (falling back to the top-level pair
//                 when absent), toreview also `scope` (the repositories
//                 searched) and `unavailable` (why it cannot fetch at all)
//   refresh       the schedule for the title line, or null when nothing is
//                 scheduled (a one-shot render): { nextAt, refreshing,
//                 failedAt, failed, loadingFrame }, the times in epoch seconds,
//                 `failed` the last failure's text, kept until a later refresh
//                 succeeds, and loadingFrame the spinner's frame counter (the
//                 app's 10 Hz tick count, a fixture's refresh.loading_frame;
//                 never wall-clock, so a one-shot frame is deterministic)
//   cached        null, or { at, snapshot, prs: { mine, toreview } } while
//                 some of the facts above come from the state cache
//                 (lib/cache.mjs) and their live source has not landed in this
//                 session: at is when the cached data landed (epoch seconds),
//                 snapshot marks the four fleet panes and prs.mine /
//                 prs.toreview each PR pane; the app clears each flag as its
//                 source lands live (lib/app.mjs)
//   mtime(path)   epoch seconds of a file's last write, or null
//   statusVerbs(path)  the verbs of a task's status log in file order
//                 (['working', 'done', 'working']), or null when it cannot be
//                 read; only isRepairing reads it
//
// Options (second argument of buildModel):
//   expanded      Set of In flight group keys currently expanded
//   allHomesNeeds also list every secondmate ledger's open decisions in Needs
//                 you (the --all-homes-needs flag); default off, main home only
//   hidden        Set of row hide keys the captain hid with `x` (view state)
//   showHidden    list hidden rows anyway, marked "(hidden)" (the `H` toggle)
//   hiddenPanes   Set of pane ids switched off with `1`-`6`
//
// Output: { panes: [ { id, title, empty, header, rows[], hidden, hiddenCount, loading, cached } x6 ], meta },
// where header is `Title (count[, n hidden])` plus ` (stale)` when that pane's
// own data failed to refresh and ` (cached 12m ago)` while its rows come from
// the state cache (paneCached below; cached is null or { ageSeconds, label }
// so the host can name the age when a cached row is opened), loading is null
// or { source, text } while the
// pane still waits for its first data (paneLoading below; text is the spinner
// line the renderer draws), and meta carries the title line's refresh label
// ({ text, failed }) and herdr warning ('' while the link is up).
// Every row carries tag, extra, id, text, repo, home, base, author, age
// (display fields; base is the PR's base branch, drawn by the two PR panes
// only, and author the PR author's login, drawn by Teammates' PRs only) plus
// name (the undecorated id for notices), homeId (main or the secondmate id),
// hideKey (pane:home:name, plus the completion date for Landed), ageSeconds
// (numeric; `age` is its short form, with a trailing `~` when ageFallback says
// the row wanted a better source and got the file-time age instead),
// paneId (herdr pane id when the row has one), lost (that pane is absent from
// a connected herdr), unknown (herdr is disconnected, so absence is unproved),
// focusable, url (a PR URL the row can open, or null), reportPath (Findings and
// Landed: the absolute report path on this host, or null; reportRemote when a
// remote home holds it) and, for In flight grouping,
// group / expanded / flag on a group row and parent on its children. A row
// listed under showHidden carries hidden: true. The mapping follows the scout
// report's section 1 table.

import { PANES } from './layout.mjs';
import { basename, clean, fmtAge, parseTime, relativeTo, repoFromUrl } from './text.mjs';
import { identityKnown } from './identity.mjs';

const MAIN_HOME_LABEL = 'main';

// endpoint.target is "<herdr-session>:<pane-id>", e.g. "default:w2Y:p2"; tmux
// targets look like "0:fm-task-window". Returns { session, paneId } for herdr
// shapes, { session, tmux } for tmux shapes, null otherwise.
export function parseTarget(target) {
  if (!target || typeof target !== 'string') return null;
  const i = target.indexOf(':');
  if (i <= 0) return null;
  const session = target.slice(0, i);
  const rest = target.slice(i + 1);
  if (/^w[0-9A-Za-z]+:p[0-9A-Za-z]+$/.test(rest)) return { session, paneId: rest };
  return { session, tmux: rest };
}

function ageSince(now, epoch) {
  if (epoch === null || epoch === undefined) return null;
  return Math.max(0, now - epoch);
}

function daysToSeconds(days) {
  if (days === null || days === undefined || Number.isNaN(Number(days))) return null;
  return Number(days) * 86400;
}

function homeLabel(ledger) {
  if (!ledger) return MAIN_HOME_LABEL;
  const suffix = ledger.remote ? ' (remote)' : ledger.cached ? ' (cached)' : '';
  return `${homeIdOf(ledger)}${suffix}`;
}

// The undecorated home id used in hide keys and group rows.
function homeIdOf(ledger) {
  if (!ledger) return MAIN_HOME_LABEL;
  return ledger.id || basename(ledger.home) || 'home';
}

// The HERDR cell for one endpoint target and the join flags behind it.
//   lost     the pane is absent from a herdr we are connected to (or from the
//            fixture overlay): the worker pane is gone, red in the frame
//   unknown  herdr is connecting or disconnected: the pane may be gone, but
//            absence cannot be proved, grey in the frame
// A remote home's panes live in another host's herdr, so they are neither.
function herdrColumn(facts, target, { remote = false } = {}) {
  const none = { extra: '-', paneId: null, lost: false, unknown: false };
  const parsed = parseTarget(target);
  if (!parsed) return none;
  if (parsed.tmux) return { ...none, extra: 'tmux' };
  if (remote) return { ...none, extra: 'remote', paneId: parsed.paneId };
  const state = facts.herdr ? facts.herdr.state : 'off';
  if (state === 'off' || state === 'unavailable') return { ...none, paneId: parsed.paneId };
  const agent = facts.herdr.agents ? facts.herdr.agents[parsed.paneId] : null;
  if (!agent) {
    if (state === 'connected' || state === 'fixture') return { ...none, extra: 'pane lost', paneId: parsed.paneId, lost: true };
    return { ...none, extra: 'unknown', paneId: parsed.paneId, unknown: true };
  }
  return { ...none, extra: agent.agent_status || 'unknown', paneId: parsed.paneId };
}

function decisionTag(verb) {
  switch (verb) {
    case 'blocked':
      return 'blocked';
    case 'needs-decision':
      return 'decide';
    case 'captain-hold':
      return 'hold';
    default:
      return clean(verb || 'decide').slice(0, 8);
  }
}

function makeRow(fields) {
  const row = {
    tag: '',
    extra: '',
    id: '',
    text: '',
    repo: '-',
    home: MAIN_HOME_LABEL,
    homeId: MAIN_HOME_LABEL,
    base: '-',
    author: '-',
    hideKey: null,
    ageSeconds: null,
    paneId: null,
    lost: false,
    unknown: false,
    focusable: false,
    url: null,
    reportPath: null,
    reportRemote: false,
    group: null,
    parent: null,
    expanded: false,
    flag: false,
    hidden: false,
    ageFallback: false,
    ...fields,
  };
  row.name = fields.name ?? row.id;
  // The marker is display only: ageSeconds stays numeric for ordering, and a
  // row with no age at all reads "-" with no marker.
  row.age = fmtAge(row.ageSeconds) + (row.ageFallback && row.ageSeconds !== null && row.ageSeconds !== undefined ? '~' : '');
  row.repo = row.repo || '-';
  row.base = row.base || '-';
  row.url = row.url && /^https?:\/\//.test(row.url) ? row.url : null;
  return row;
}

function taskRepo(task) {
  if (task.backlog && task.backlog.repo) return task.backlog.repo;
  const pr = task.pr && task.pr.url ? repoFromUrl(task.pr.url) : null;
  if (pr) return pr.repo;
  return basename(task.project) || '-';
}

function statusLogAge(facts, task) {
  const path = task.paths && task.paths.status_log ? task.paths.status_log.path : null;
  return ageSince(facts.now, path ? facts.mtime(path) : null);
}

function childStatusAge(facts, ledger, id) {
  if (!ledger || !ledger.home || !id) return null;
  return ageSince(facts.now, facts.mtime(`${ledger.home}/state/${id}.status`));
}

function backlogIndex(snap) {
  const backlog = snap.backlog && Array.isArray(snap.backlog.records) ? snap.backlog.records : [];
  return new Map(backlog.map((r) => [r.id, r]));
}

// The backlog state of a task's row: the snapshot's backlog record first, then
// the state the task record itself carries, else null (secondmate records
// never have a backlog row).
function taskBacklogState(task, backlogById) {
  const row = backlogById.get(task.id);
  if (row) return row.state || null;
  return task.backlog && task.backlog.state ? task.backlog.state : null;
}

// Green-unmerged: the worker said done with a PR and its backlog row is still
// open, so the PR awaits the captain's merge. Secondmate agents answer many
// requests with "done" lines and mention PRs they did not raise, so that kind
// never qualifies (their work surfaces through their own ledger). The In
// flight "awaiting merge" state; the Needs you review row widens the same
// test to a paused task (parkedForCaptain) and then asks GitHub whether the
// PR is really ready.
function awaitingMerge(task, backlogById) {
  const cs = task.current_state || {};
  if (task.kind === 'secondmate' || cs.state !== 'done' || !(task.pr && task.pr.url)) return false;
  return taskBacklogState(task, backlogById) !== 'done';
}

// Parked for the captain: the worker is finished (`done`) or firstmate parked
// the task on the captain (`paused`, e.g. "paused: awaiting captain
// approve-and-label"). A working, blocked, failed or unknown task is not.
const PARKED_STATES = new Set(['done', 'paused']);

function parkedForCaptain(state) {
  return PARKED_STATES.has(String(state || ''));
}

// A main-home task whose PR is the captain's to look at: parked, a recorded PR
// and an open backlog row (the same open-row test awaitingMerge uses).
function parkedWithPr(task, backlogById) {
  const cs = task.current_state || {};
  if (task.kind === 'secondmate' || !parkedForCaptain(cs.state) || !(task.pr && task.pr.url)) return false;
  return taskBacklogState(task, backlogById) !== 'done';
}

// Repairing: a task with a recorded PR that is working again after it once
// said done (a merge-conflict repair, a re-resolve after review). The status
// log is the one record of that history (the snapshot carries only the
// current state and the last event), so this is the one place the board
// reads a log's lines. Defined once for the main home (the task record's
// status_log path) and for a secondmate child (`<home>/state/<id>.status`,
// the file childStatusAge dates); an unreadable log (a remote home, no file)
// is never repairing.
function repairingFromLog(facts, state, url, path) {
  if (!url || String(state || '') !== 'working' || !path) return false;
  const verbs = facts.statusVerbs(path);
  return Array.isArray(verbs) && verbs.includes('done');
}

function isRepairing(facts, task) {
  const cs = task.current_state || {};
  const path = task.paths && task.paths.status_log ? task.paths.status_log.path : null;
  return repairingFromLog(facts, cs.state, task.pr && task.pr.url, path);
}

function childRepairing(facts, ledger, id, state, url) {
  if (!ledger || !ledger.home || !id || ledger.remote) return false;
  return repairingFromLog(facts, state, url, `${ledger.home}/state/${id}.status`);
}

// The PR of a secondmate child, from the one ledger field that names a
// child's PR: contributions.captain[] (fm-contributions.sh, folded into the
// home summary), each { task, url, kind: 'pr' | 'issue', reason, hold }, the
// forge contributions whose next actor is the captain. active_children and
// endpoints carry no PR field. null when the ledger has no such entry.
function childPrUrl(ledger, id) {
  const summary = ledger && ledger.summary ? ledger.summary : {};
  const list = summary.contributions && Array.isArray(summary.contributions.captain) ? summary.contributions.captain : [];
  const hit = list.find((c) => c && c.task === id && (c.kind === undefined || c.kind === 'pr') && typeof c.url === 'string' && /\/pull\/\d+/.test(c.url));
  return hit ? hit.url : null;
}

// The state of every task record of one ledger, by id: endpoints carry every
// record (done and paused ones included), active_children the working ones;
// a child in both reads the endpoint's state.
function ledgerChildStates(ledger) {
  const summary = ledger && ledger.summary ? ledger.summary : {};
  const out = new Map();
  for (const c of Array.isArray(summary.active_children) ? summary.active_children : []) if (c && c.id) out.set(c.id, c.state || 'working');
  for (const e of Array.isArray(summary.endpoints) ? summary.endpoints : []) if (e && e.id) out.set(e.id, e.state || out.get(e.id) || 'unknown');
  return out;
}

// What GitHub says about a fetched PR, for the review row and the READY /
// REPAIRING words:
//   finished     merged or closed
//   conflicting  mergeable CONFLICTING, or a DIRTY merge state
//   ready        mergeable MERGEABLE and not DIRTY. BLOCKED (a required
//                review missing) and UNSTABLE (checks failing) count as
//                ready: the review is the captain's own step and CHECKS
//                shows the checks. A draft is not excluded: a worker that
//                parked on a draft still asks for the captain's eyes
//   unknown      GitHub has not computed mergeability yet
// null when no fetched record is at hand (fetch off, failed, or the PR not
// in the fetched set): the caller falls back to the task state.
function prReadiness(c) {
  if (!c) return null;
  const status = prStatus(c);
  if (status === 'MERGED' || status === 'CLOSED') return 'finished';
  const mergeable = String(c.mergeable || 'UNKNOWN').toUpperCase();
  const mergeState = String(c.merge_state || c.mergeStateStatus || '').toUpperCase();
  if (mergeable === 'CONFLICTING' || mergeState === 'DIRTY') return 'conflicting';
  if (mergeable === 'MERGEABLE') return 'ready';
  return 'unknown';
}

// The fetched candidates by URL, when the fetch is on and landed; a My PRs
// record wins over a To review copy of the same PR.
function fetchedByUrl(prs) {
  const out = new Map();
  if (!prs || !prs.enabled || !Array.isArray(prs.candidate_prs)) return out;
  for (const c of prs.candidate_prs) {
    if (!c || !c.url) continue;
    const pane = c.pane || 'mine';
    if (!out.has(c.url) || pane === 'mine') out.set(c.url, c);
  }
  return out;
}

// Every fleet task that recorded a PR, by URL, with what the READY /
// REPAIRING words need: main-home task records (not the secondmate agents'
// mentions) and secondmate children named by their ledger's contributions.
// { id, parked, repairing }. (Whether the task's backlog row is still open is
// mineRows' own test, through recordedPrs.)
function fleetPrTasks(facts) {
  const snap = facts.snapshot || {};
  const out = new Map();
  for (const task of Array.isArray(snap.tasks) ? snap.tasks : []) {
    if (task.kind === 'secondmate' || !(task.pr && task.pr.url)) continue;
    const cs = task.current_state || {};
    out.set(task.pr.url, { id: task.id, parked: parkedForCaptain(cs.state), repairing: isRepairing(facts, task) });
  }
  for (const ledger of facts.ledgers || []) {
    for (const [id, state] of ledgerChildStates(ledger)) {
      const url = childPrUrl(ledger, id);
      if (!url || out.has(url)) continue;
      out.set(url, { id, parked: parkedForCaptain(state), repairing: childRepairing(facts, ledger, id, state, url) });
    }
  }
  return out;
}

// The keyed decisions and the blocked event of one task record, as rows
// (without the review row). Needs you lists them for main-home workers; a
// secondmate record's rows go under its In flight group instead.
function taskDecisionRows(facts, task, decisions = null) {
  const rows = [];
  const hints = task.hints || {};
  const herdr = herdrColumn(facts, task.endpoint && task.endpoint.target);
  const list = decisions || (Array.isArray(hints.open_decisions) ? hints.open_decisions : []);
  for (const d of list) {
    rows.push(
      makeRow({
        tag: decisionTag(d.verb),
        extra: d.key || '-',
        id: task.id,
        text: d.summary,
        repo: taskRepo(task),
        ageSeconds: statusLogAge(facts, task),
        paneId: herdr.paneId,
        lost: herdr.lost,
        unknown: herdr.unknown,
        focusable: Boolean(herdr.paneId),
      }),
    );
  }
  if (hints.blocked_event && !list.some((d) => d.verb === 'blocked')) {
    rows.push(
      makeRow({
        tag: 'blocked',
        extra: '-',
        id: task.id,
        text: hints.last_event_text || 'blocked',
        repo: taskRepo(task),
        ageSeconds: statusLogAge(facts, task),
        paneId: herdr.paneId,
        lost: herdr.lost,
        unknown: herdr.unknown,
        focusable: Boolean(herdr.paneId),
      }),
    );
  }
  return rows;
}

// ---------------------------------------------------------------- Needs you
// Main home only by default: the captain reads this pane for what the main
// firstmate needs from him. A secondmate's own decisions (its ledger's
// decisions_open, and the keyed decisions its task record relays into the
// main home's status log) flag its In flight group instead and list under it
// when expanded; --all-homes-needs restores them here. The `review` rows are
// the exception: a PR parked for the captain is his to review whichever home
// raised it, so they come from the main home's task records and from every
// secondmate ledger, flag or not (reviewRow says when one lists). A task
// yields at most one row of that kind; the old merge? row is gone.
function needsRows(facts, opts) {
  const rows = [];
  const snap = facts.snapshot || {};
  const tasks = Array.isArray(snap.tasks) ? snap.tasks : [];
  const backlog = snap.backlog && Array.isArray(snap.backlog.records) ? snap.backlog.records : [];
  const backlogById = backlogIndex(snap);

  const fetched = fetchedByUrl(facts.prs);

  for (const task of tasks) {
    if (task.kind !== 'secondmate' || opts.allHomesNeeds) rows.push(...taskDecisionRows(facts, task));
    if (parkedWithPr(task, backlogById)) {
      const row = backlogById.get(task.id);
      const herdr = herdrColumn(facts, task.endpoint && task.endpoint.target);
      const review = reviewRow(facts, fetched, {
        id: task.id,
        url: task.pr.url,
        title: (row && row.title) || (task.backlog && task.backlog.title) || null,
        ageSeconds: statusLogAge(facts, task),
        herdr,
        focusable: Boolean(herdr.paneId),
      });
      if (review) rows.push(review);
    }
  }

  // Secondmate children parked with a PR the ledger names (childPrUrl), from
  // every ledger and without a flag: the PR is the captain's whichever home
  // raised it. A remote home's pane cannot be focused from here.
  for (const ledger of facts.ledgers || []) {
    const summary = ledger.summary || {};
    const endpoints = Array.isArray(summary.endpoints) ? summary.endpoints : [];
    const holdsById = new Map((Array.isArray(summary.holds) ? summary.holds : []).map((h) => [h.id, h]));
    for (const [id, state] of ledgerChildStates(ledger)) {
      if (!parkedForCaptain(state)) continue;
      const url = childPrUrl(ledger, id);
      if (!url) continue;
      const ep = endpoints.find((e) => e && e.id === id);
      const herdr = herdrColumn(facts, ep && ep.endpoint ? ep.endpoint.target : null, { remote: Boolean(ledger.remote) });
      const hold = holdsById.get(id);
      const review = reviewRow(facts, fetched, {
        id,
        url,
        title: hold && hold.title ? hold.title : null,
        ageSeconds: childStatusAge(facts, ledger, id),
        herdr,
        focusable: Boolean(herdr.paneId) && !ledger.remote,
        home: homeLabel(ledger),
        homeId: homeIdOf(ledger),
      });
      if (review) rows.push(review);
    }
  }

  for (const r of backlog) {
    if (r.hold_kind === 'captain' && r.hold_bucket === 'live' && r.captain_actionable) {
      const since = parseTime(r.hold_set) ?? parseTime(r.since);
      rows.push(
        makeRow({
          tag: 'hold',
          extra: r.hold_until ? `by ${String(r.hold_until).slice(5)}` : '-',
          id: r.id,
          text: r.hold_reason ? `${r.title} · ${r.hold_reason}` : r.title,
          repo: r.repo,
          ageSeconds: ageSince(facts.now, since) ?? daysToSeconds(r.hold_age_days),
        }),
      );
    }
  }

  if (opts.allHomesNeeds) {
    for (const ledger of facts.ledgers || []) {
      for (const d of liveDecisions(ledger)) rows.push(decisionRow(ledger, d));
    }
  }

  const order = { blocked: 0, decide: 1, hold: 2, review: 3 };
  return rows
    .map((r, i) => ({ r, i }))
    .sort((a, b) => (order[a.r.tag] ?? 9) - (order[b.r.tag] ?? 9) || a.i - b.i)
    .map((x) => x.r);
}

// The Needs you `review` row of one parked task with a PR, or null when the
// PR is not the captain's to review: GitHub reports it finished (merged or
// closed, the 12-hour tail included) or conflicting (a worker's repair, not a
// review). With a fetched record that says ready the WHAT text ends in the
// CHECKS state and AGE is the plain time since the task parked; with no
// record at hand (fetch off, failed, the PR not in the fetched set) or one
// whose mergeability GitHub has not computed, the row lists on the task state
// alone and AGE carries the fallback `~`, as the PR panes mark a stand-in
// age. `enter` opens the PR (url); the herdr fields are the worker's pane.
function reviewRow(facts, fetched, { id, url, title, ageSeconds, herdr, focusable, home = MAIN_HOME_LABEL, homeId = MAIN_HOME_LABEL }) {
  const c = fetched.get(url) || null;
  const readiness = prReadiness(c);
  if (readiness === 'finished' || readiness === 'conflicting') return null;
  const pr = repoFromUrl(url);
  const label = pr ? `${pr.repo}#${pr.num}` : url;
  const what = (c && c.title) || title || null;
  const checks = readiness === 'ready' && c.checks ? ` · checks ${c.checks}` : '';
  return makeRow({
    tag: 'review',
    extra: pr ? `#${pr.num}` : '-',
    id,
    text: `${label}${what ? ` · ${what}` : ''}${checks}`,
    repo: pr ? pr.repo : '-',
    home,
    homeId,
    ageSeconds,
    ageFallback: readiness !== 'ready',
    paneId: herdr.paneId,
    lost: herdr.lost,
    unknown: herdr.unknown,
    focusable,
    url,
  });
}

// ------------------------------------------------------ My PRs, To review
//
// Two panes over one live fetch (lib/sources.mjs), each row stamped with the
// pane it belongs to.
//
// My PRs: every open pull request the identity authored, in any repository
// the account can see, plus the recorded PRs of unfinished fleet tasks
// whatever their author (a worker's PR is the captain's to look at before
// the team sees it), plus PRs of either kind that finished inside the window.
// A recorded PR the fetch did not return keeps a '-' STATUS row. A PR stays
// listed while it is open and, once merged or closed, for
// TERMINAL_WINDOW_SECONDS after it finished, so the captain sees what landed
// or was abandoned since the last look; then it leaves the pane. A PR a
// secondmate record merely mentions is not a recorded PR (the mate's work
// lands through its ledger). A recorded PR of a task whose backlog row is done
// appears only through its fetched record, and only while that record is
// terminal and inside the window: the task is finished, so the row is a notice
// that its PR landed, not open work.
//
// To review: the open PRs in the To review scope (the candidate repositories
// plus the config file's) where the identity is a requested reviewer,
// directly or through a team, and not the author, filtered by the per
// repository label rule at fetch time, plus those that finished inside the
// window. STATUS reads APPROVED or CHANGES REQUESTED when the identity's own
// latest review says so, else the same words as My PRs.
//
// With the identity unknown neither pane can be built: each shows one row
// pointing at the Settings page.

export const TERMINAL_WINDOW_SECONDS = 12 * 3600;

// The STATUS column's words, in the order the panes list them: open work
// first (READY, a fleet task's PR waiting on the captain, ahead of the rest;
// a PR the identity already reviewed after the ones still waiting; REPAIRING,
// a fleet task's PR its worker is fixing, last of the open ones), then what
// finished. '-' is a recorded PR the fetch did not list (or the fetch is
// off), whose status is unknown; it sits between the two.
export const REVIEW_STATUSES = ['READY', 'DRAFT', 'IN REVIEW', 'CHANGES REQUESTED', 'APPROVED', 'REPAIRING', 'CLOSED', 'MERGED'];
const STATUS_ORDER = { READY: 0, DRAFT: 1, 'IN REVIEW': 2, 'CHANGES REQUESTED': 3, APPROVED: 4, REPAIRING: 5, '-': 6, CLOSED: 7, MERGED: 8 };

// The STATUS of an open PR that belongs to a fleet task (fleetPrTasks), so My
// PRs and Needs you agree: READY when the task is parked for the captain and
// GitHub reports the PR ready (prReadiness); REPAIRING when the task is
// working again after a done line (isRepairing) or GitHub reports the PR
// conflicting, whatever the task state. Otherwise the PR's own status, as for
// a PR no task recorded. A finished PR keeps MERGED or CLOSED.
function fleetStatus(c, status, task) {
  if (!task || status === 'MERGED' || status === 'CLOSED') return status;
  const readiness = prReadiness(c);
  if (task.repairing || readiness === 'conflicting') return 'REPAIRING';
  if (task.parked && readiness === 'ready') return 'READY';
  return status;
}

export const IDENTITY_UNKNOWN_TEXT = 'identity unknown: see Settings (.)';
export const SCOPE_EMPTY_TEXT = 'no repositories in scope: see Settings (.)';
export const PRS_OFF_TEXT = 'PR fetch off (--no-prs)';

// Recorded PRs: task records and backlog rows with a PR URL, keyed by URL, each
// with its task id, the backlog title (the TITLE fallback for a source that
// carries no PR titles) and whether the task's backlog row is done. Exported
// for lib/sources.mjs, which looks up the ones the author search missed.
export function recordedPrs(facts) {
  const snap = facts.snapshot || {};
  const backlogById = backlogIndex(snap);
  const out = new Map();
  for (const task of Array.isArray(snap.tasks) ? snap.tasks : []) {
    if (!(task.pr && task.pr.url)) continue;
    if (task.kind === 'secondmate') continue;
    const row = backlogById.get(task.id);
    const title = (row && row.title) || (task.backlog && task.backlog.title) || null;
    out.set(task.pr.url, { url: task.pr.url, task: task.id, title, done: taskBacklogState(task, backlogById) === 'done' });
  }
  const backlog = snap.backlog && Array.isArray(snap.backlog.records) ? snap.backlog.records : [];
  for (const r of backlog) {
    if (r.pr_url && !out.has(r.pr_url)) out.set(r.pr_url, { url: r.pr_url, task: r.id, title: r.title || null, done: r.state === 'done' });
  }
  return [...out.values()];
}

// The STATUS cell of a fetched PR. MERGED and CLOSED are read first, so a
// draft closed unmerged reads CLOSED and leaves with the window instead of
// sitting as DRAFT for good; then DRAFT; an open PR is APPROVED when GitHub's
// review decision says so and IN REVIEW otherwise. A record with no state
// (the fm-bearings-snapshot.sh fallback lists open PRs only) counts as open.
export function prStatus(c) {
  const state = String(c.state || 'OPEN').toUpperCase();
  if (c.merged === true || state === 'MERGED') return 'MERGED';
  if (state === 'CLOSED') return 'CLOSED';
  if (c.draft === true || c.isDraft === true) return 'DRAFT';
  return c.review === 'APPROVED' ? 'APPROVED' : 'IN REVIEW';
}

// When a finished PR left the open state, as epoch seconds: merged_at for a
// merged PR (closed_at when that is missing), closed_at for a closed one; null
// when the record carries no usable time. A stamp in the future counts as now.
function prFinishedAt(c, status, now) {
  const stamp = status === 'MERGED' ? (c.merged_at ?? c.mergedAt ?? c.closed_at ?? c.closedAt) : (c.closed_at ?? c.closedAt);
  const t = parseTime(stamp);
  return t === null ? null : Math.min(t, now);
}

// A merged or closed PR is listed while it finished less than
// TERMINAL_WINDOW_SECONDS ago; one with no time stamp cannot be placed in the
// window and is dropped, as every finished PR was before the window existed.
export function insideWindow(c, status, now) {
  const at = prFinishedAt(c, status, now);
  return at !== null && now - at < TERMINAL_WINDOW_SECONDS;
}

// One PR pane's own fetch state: its block on facts.prs when the fetch keeps
// one per pane, else the top-level pair (a fixture with one `error` marks
// both panes).
function paneFetch(prs, paneId) {
  const own = prs && prs[paneId] && typeof prs[paneId] === 'object' ? prs[paneId] : {};
  return {
    fetchedAt: own.fetchedAt !== undefined ? own.fetchedAt : (prs && prs.fetchedAt) ?? null,
    error: own.error !== undefined ? own.error : (prs && prs.error) ?? null,
    scope: Array.isArray(own.scope) ? own.scope : null,
    unavailable: typeof own.unavailable === 'string' && own.unavailable ? own.unavailable : null,
  };
}

// The candidates of one pane: a row without a pane belongs to My PRs, which
// is what every source before To review produced.
function paneCandidates(prs, paneId) {
  if (!prs || !prs.enabled || !Array.isArray(prs.candidate_prs)) return [];
  return prs.candidate_prs.filter((c) => c && (c.pane || 'mine') === paneId);
}

// The CHECKS cell and the text suffix of a recorded PR the live list does not
// carry: off, still fetching (before the first fetch of a session lands),
// failed before any fetch landed, or fetched and simply not in the list.
function unlistedChecks(prs) {
  if (!prs.enabled) return { tag: 'PR', note: 'checks: off (--no-prs)' };
  const mine = paneFetch(prs, 'mine');
  if (mine.fetchedAt) return { tag: 'unlisted', note: 'checks: not fetched' };
  if (mine.error) return { tag: 'PR', note: 'checks: fetch failed' };
  return { tag: 'PR', note: 'checks: fetching' };
}

// The one row a PR pane shows while the identity is unknown: nothing can be
// fetched for nobody, so the row points at the Settings page.
function identityRow() {
  return makeRow({ tag: '-', extra: '-', status: '-', id: '-', name: 'identity', text: IDENTITY_UNKNOWN_TEXT });
}

// Whether a PR pane's rows come from a fetch that needs the identity: the
// fetch is on, gh is there to run it (without gh My PRs lists the recorded
// PRs through the script fallback, which needs no login, and To review says
// why it is empty) and the identity is unknown.
function identityMissing(prs) {
  return Boolean(prs && prs.enabled) && !paneFetch(prs, 'toreview').unavailable && !identityKnown(prs.identity);
}

// When the PR was opened, as epoch seconds, from a candidate's created_at
// (gh's createdAt; createdAt itself is accepted too). A value that does not
// parse, or lies in the future, counts as absent so the row falls back.
function prCreatedAt(c, now) {
  const created = parseTime(c.created_at ?? c.createdAt);
  return created === null || created > now ? null : created;
}

// AGE in the PR panes: the time since the PR was opened when the live fetch
// carries it, else the task's status-log age marked `~` (fetch off, failed,
// PR not in the fetched set, no creation time, or one that does not parse).
// The marker tells the two sources apart at a glance: a PR age is a GitHub
// fact, the file-time age is only how long since the worker last wrote.
function reviewAge(facts, taskById, taskId, created) {
  if (created !== null) return { ageSeconds: facts.now - created, ageFallback: false };
  const task = taskById.get(taskId);
  return { ageSeconds: task ? statusLogAge(facts, task) : null, ageFallback: true };
}

// Newest first by ageSeconds (the PR's creation time, else the file time); a
// row with no age at all goes after the rows that have one.
function byNewest(a, b) {
  const aa = a.ageSeconds ?? null;
  const bb = b.ageSeconds ?? null;
  if (aa === null) return bb === null ? 0 : 1;
  if (bb === null) return -1;
  return aa - bb;
}

// Status order first (open work, then unknown, then finished), newest first
// inside a status, fetch order for a tie.
function byStatus(rows) {
  return rows
    .map((r, i) => ({ r, i }))
    .sort((a, b) => (STATUS_ORDER[a.r.status] ?? STATUS_ORDER['-']) - (STATUS_ORDER[b.r.status] ?? STATUS_ORDER['-']) || byNewest(a.r, b.r) || a.i - b.i)
    .map((x) => x.r);
}

// One fetched PR as a row: the task id when a fleet task recorded the PR (or
// its head branch names one), else repo#number; the title from the fetch,
// else the recorded task's, else the URL; the author's login, `-` when the
// fetch carries none (the script fallback, or a PR whose author GitHub no
// longer names).
function fetchedPrRow(facts, taskById, c, rec, status) {
  const taskId = rec ? rec.task : c.task && c.task !== '-' ? c.task : '-';
  return makeRow({
    tag: c.checks || 'none',
    extra: status,
    status,
    id: taskId === '-' ? `${basename(c.repo)}#${c.num}` : taskId,
    text: c.title || (rec && rec.title) || c.url,
    base: c.base || '-',
    author: typeof c.author === 'string' && c.author ? c.author : '-',
    repo: c.repo,
    url: c.url,
    ...reviewAge(facts, taskById, taskId, prCreatedAt(c, facts.now)),
  });
}

function mineRows(facts) {
  const prs = facts.prs || { enabled: false };
  if (identityMissing(prs)) return [identityRow()];
  const rows = [];
  const recorded = recordedPrs(facts);
  const byUrl = new Map(recorded.map((r) => [r.url, r]));
  const snap = facts.snapshot || {};
  const taskById = new Map((Array.isArray(snap.tasks) ? snap.tasks : []).map((t) => [t.id, t]));
  const unlisted = unlistedChecks(prs);
  const fleet = fleetPrTasks(facts);
  const seen = new Set();
  for (const c of paneCandidates(prs, 'mine')) {
    seen.add(c.url);
    const status = prStatus(c);
    const terminal = status === 'MERGED' || status === 'CLOSED';
    if (terminal && !insideWindow(c, status, facts.now)) continue;
    const rec = byUrl.get(c.url);
    if (rec && rec.done && !terminal) continue;
    rows.push(fetchedPrRow(facts, taskById, c, rec, fleetStatus(c, status, fleet.get(c.url))));
  }
  for (const r of recorded) {
    if (seen.has(r.url) || r.done) continue;
    const pr = repoFromUrl(r.url);
    rows.push(
      makeRow({
        tag: unlisted.tag,
        extra: '-',
        status: '-',
        id: r.task,
        text: `${r.url} · ${unlisted.note}`,
        repo: pr ? pr.repo : '-',
        url: r.url,
        ...reviewAge(facts, taskById, r.task, null),
      }),
    );
  }
  return byStatus(rows);
}

// The STATUS cell of a To review row: the identity's own verdict when it
// gave one and the PR is still open, else the PR's own status.
export function toReviewStatus(c) {
  const status = prStatus(c);
  if (status === 'MERGED' || status === 'CLOSED' || status === 'DRAFT') return status;
  if (c.my_review === 'APPROVED') return 'APPROVED';
  if (c.my_review === 'CHANGES_REQUESTED') return 'CHANGES REQUESTED';
  return status;
}

function toReviewRows(facts) {
  const prs = facts.prs || { enabled: false };
  if (identityMissing(prs)) return [identityRow()];
  const rows = [];
  const snap = facts.snapshot || {};
  const taskById = new Map((Array.isArray(snap.tasks) ? snap.tasks : []).map((t) => [t.id, t]));
  const login = prs.identity ? prs.identity.login : null;
  for (const c of paneCandidates(prs, 'toreview')) {
    // The fetch filters authorship, scope and labels; the author check is
    // repeated here so a fixture row of the captain's own never lists.
    if (login && c.author === login) continue;
    const status = toReviewStatus(c);
    const terminal = status === 'MERGED' || status === 'CLOSED';
    if (terminal && !insideWindow(c, status, facts.now)) continue;
    rows.push(fetchedPrRow(facts, taskById, c, null, status));
  }
  return byStatus(rows);
}

// The empty text of a PR pane, by what stands between it and its rows: the
// fetch switched off, no way to fetch at all (To review without gh), an empty
// To review scope, else the pane's own words.
function prPaneEmpty(facts, pane) {
  const prs = facts.prs || { enabled: false };
  if (!prs.enabled) return pane.id === 'toreview' ? PRS_OFF_TEXT : pane.empty;
  if (pane.id === 'toreview') {
    const own = paneFetch(prs, 'toreview');
    if (own.unavailable) return `${own.unavailable}: Teammates' PRs needs the GitHub CLI`;
    if (own.scope && own.scope.length === 0) return SCOPE_EMPTY_TEXT;
  }
  return pane.empty;
}

// ---------------------------------------------------------------- In flight
//
// One row per main-home worker, and one GROUP row per secondmate home.
//
// The captain asked for one row per initiative the main firstmate delegated,
// not one row per secondmate worker. What the ledger
// (fm-secondmate-home-summary.v1, produced by fm-fleet-snapshot.sh
// --secondmate-home-summary) carries per child is:
//   active_children[] {id, kind, state, repo, source, doing}   working only
//   endpoints[]       {id, state, source, endpoint.target}     every task record
//   holds[]           {id, title, reason, source}              held queued items
//                     and in-flight children that are parked, paused or blocked
//   decisions_open[]  {id, key, verb, summary, reason, hold_bucket, ...}
//   queued[]          {id, title, repo, kind, hold_*}
//   contributions     {captain[]: {task, url, kind, reason, hold}, ...}  the
//                     forge contributions whose next actor is the captain;
//                     the one field naming a child's PR (childPrUrl)
// The handoff that delegates an item (fm-backlog-handoff.sh -> tasks-axi mv)
// moves the backlog block byte-exact and writes no origin marker; a child's
// task id IS the mate's backlog item id, and nothing in the ledger, the fleet
// snapshot or state/<id>.meta names a parent item above it. A child can thus be
// tied to its own item (holds/decisions_open/queued by id, used below for the
// child's title, decision text or hold reason) but not to a coarser
// initiative, and item-level grouping would reproduce one row per worker.
// FALLBACK IN EFFECT: group by home. The group row shows the worst state among
// the mate's agent row, its children and the mate's own relayed decisions, the
// live worker count, the child ids, the shared repo and the newest child event;
// expanding it lists the mate's own agent row, every child, the home's live
// captain decisions and the mate's relayed decisions. When the ledger grows a
// per-child parent field, make groupKeyFor() read it and the rest stands.

// Worst-state ranking for a group row: blocked > decision > working > failed >
// everything else (idle, unknown, done, parked). A failed child is the mate's
// own cleanup, so it does not outrank live work; it shows on expansion.
const STATE_RANK = { blocked: 0, failed: 3, decide: 1, 'needs-decision': 1, hold: 1, working: 2, 'repairing PR': 2 };
const INFLIGHT_ORDER = { working: 0, 'repairing PR': 0, blocked: 1, decide: 1, 'needs-decision': 1, hold: 1, unknown: 2, 'awaiting merge': 3, done: 3, failed: 4 };

// The STATE word of a task with a recorded PR: `awaiting merge` for a done
// main-home task whose backlog row is open (awaitingMerge), `repairing PR`
// for one working again after a done line (isRepairing / childRepairing),
// else firstmate's own state word.
function prStateTag(state, { awaiting = false, repairing = false }) {
  if (awaiting) return 'awaiting merge';
  if (repairing) return 'repairing PR';
  return state || 'unknown';
}
const FLAG_TAGS = new Set(['blocked', 'decide', 'needs-decision', 'hold']);
const TERMINAL_TAGS = new Set(['done', 'failed']);

function stateRank(tag) {
  return STATE_RANK[tag] ?? 4;
}

function sortInflight(entries) {
  return entries
    .map((e, i) => ({ e, i }))
    .sort((a, b) => (INFLIGHT_ORDER[a.e.row.tag] ?? 2) - (INFLIGHT_ORDER[b.e.row.tag] ?? 2) || a.i - b.i)
    .map((x) => x.e);
}

function groupKeyFor(ledger) {
  return `home:${ledger.home}`;
}

function kindPrefix(kind) {
  return kind && kind !== 'ship' && kind !== 'task' ? `(${kind}) ` : '';
}

function liveDecisions(ledger) {
  const summary = ledger.summary || {};
  const list = Array.isArray(summary.decisions_open) ? summary.decisions_open : [];
  return list.filter((d) => d && d.id && (!d.hold_bucket || d.hold_bucket === 'live'));
}

function decisionRow(ledger, d, extraFields = {}) {
  const summary = ledger.summary || {};
  const queued = Array.isArray(summary.queued) ? summary.queued : [];
  const q = queued.find((x) => x.id === d.id);
  return makeRow({
    tag: decisionTag(d.verb),
    extra: d.key && d.key !== d.id ? d.key : '-',
    id: d.id,
    text: d.reason && d.reason !== d.summary ? `${d.summary} · ${d.reason}` : d.summary,
    repo: q ? q.repo : '-',
    home: homeLabel(ledger),
    homeId: homeIdOf(ledger),
    ageSeconds: daysToSeconds(d.hold_age_days),
    ...extraFields,
  });
}

function mainTaskRow(facts, task, backlogById = new Map()) {
  const cs = task.current_state || {};
  const herdr = herdrColumn(facts, task.endpoint && task.endpoint.target);
  const doing = cs.detail || (task.hints && task.hints.last_event_text) || (task.paths && task.paths.status_log && task.paths.status_log.last_event && task.paths.status_log.last_event.note) || '';
  return makeRow({
    tag: prStateTag(cs.state, { awaiting: awaitingMerge(task, backlogById), repairing: isRepairing(facts, task) }),
    extra: herdr.extra,
    id: task.id,
    text: `${kindPrefix(task.kind)}${doing}`,
    repo: taskRepo(task),
    ageSeconds: statusLogAge(facts, task),
    paneId: herdr.paneId,
    lost: herdr.lost,
    unknown: herdr.unknown,
    focusable: Boolean(herdr.paneId),
    url: task.pr && task.pr.url ? task.pr.url : null,
  });
}

// Child worker rows of one secondmate ledger, in ledger order. A child keyed by
// an open decision shows the decision text; a held child shows its hold title
// and reason; otherwise its `doing`.
function ledgerChildRows(facts, ledger, decisionByChild) {
  const summary = ledger.summary || {};
  const endpoints = Array.isArray(summary.endpoints) ? summary.endpoints : [];
  const endpointById = new Map(endpoints.map((e) => [e.id, e]));
  const holdsById = new Map((Array.isArray(summary.holds) ? summary.holds : []).map((h) => [h.id, h]));
  const heldText = (h) => (h.reason && h.reason !== h.title ? `${h.title} · ${h.reason}` : h.title);
  const decisionText = (d) => (d.reason && d.reason !== d.summary ? `${d.summary} · ${d.reason}` : d.summary);
  const rows = [];
  const covered = new Set();
  for (const child of Array.isArray(summary.active_children) ? summary.active_children : []) {
    covered.add(child.id);
    const ep = endpointById.get(child.id);
    const herdr = herdrColumn(facts, ep && ep.endpoint ? ep.endpoint.target : null, { remote: Boolean(ledger.remote) });
    const d = decisionByChild.get(child.id);
    const h = holdsById.get(child.id);
    const childState = child.state || 'working';
    rows.push(
      makeRow({
        tag: d ? decisionTag(d.verb) : prStateTag(childState, { repairing: childRepairing(facts, ledger, child.id, childState, childPrUrl(ledger, child.id)) }),
        extra: herdr.extra,
        id: child.id,
        text: d ? decisionText(d) : h && h.title ? heldText(h) : `${kindPrefix(child.kind)}${child.doing || child.name || ''}`,
        repo: child.repo,
        home: homeLabel(ledger),
        homeId: homeIdOf(ledger),
        ageSeconds: childStatusAge(facts, ledger, child.id),
        paneId: herdr.paneId,
        lost: herdr.lost,
        unknown: herdr.unknown,
        focusable: Boolean(herdr.paneId) && !ledger.remote,
      }),
    );
  }
  for (const ep of endpoints) {
    if (covered.has(ep.id)) continue;
    const herdr = herdrColumn(facts, ep.endpoint ? ep.endpoint.target : null, { remote: Boolean(ledger.remote) });
    const d = decisionByChild.get(ep.id);
    const h = holdsById.get(ep.id);
    const epState = ep.state || 'unknown';
    rows.push(
      makeRow({
        tag: d ? decisionTag(d.verb) : prStateTag(epState, { repairing: childRepairing(facts, ledger, ep.id, epState, childPrUrl(ledger, ep.id)) }),
        extra: herdr.extra,
        id: ep.id,
        text: d ? decisionText(d) : h && h.title ? heldText(h) : `endpoint ${ep.endpoint && ep.endpoint.target ? ep.endpoint.target : '?'} (${ep.source || 'pane'})`,
        repo: '-',
        home: homeLabel(ledger),
        homeId: homeIdOf(ledger),
        ageSeconds: childStatusAge(facts, ledger, ep.id),
        paneId: herdr.paneId,
        lost: herdr.lost,
        unknown: herdr.unknown,
        focusable: Boolean(herdr.paneId) && !ledger.remote,
      }),
    );
  }
  return rows;
}

function childMarker(row) {
  return { ...row, id: `↳ ${row.id}`, name: row.name, parent: row.parent };
}

// One group per secondmate home: { row, children } where children is the list
// of rows shown under it when expanded (the mate's own agent row from the main
// snapshot first, then workers by state, then the home's live decisions).
function ledgerGroup(facts, ledger, mateTask, expanded) {
  const key = groupKeyFor(ledger);
  const decisions = liveDecisions(ledger);
  const summary = ledger.summary || {};
  const childIds = new Set([
    ...(Array.isArray(summary.active_children) ? summary.active_children : []).map((c) => c.id),
    ...(Array.isArray(summary.endpoints) ? summary.endpoints : []).map((e) => e.id),
  ]);
  const decisionByChild = new Map(decisions.filter((d) => childIds.has(d.id)).map((d) => [d.id, d]));
  const homeDecisions = decisions.filter((d) => !childIds.has(d.id));
  const workers = sortInflight(ledgerChildRows(facts, ledger, decisionByChild).map((row) => ({ row }))).map((e) => e.row);
  const mateRow = mateTask ? mainTaskRow(facts, mateTask) : null;
  // The mate's own keyed decisions and blocker, relayed through its task record
  // in the main home (hints.open_decisions / blocked_event); one the ledger
  // already lists under the same id or key is not repeated.
  const relayedDecisions = (Array.isArray(mateTask && mateTask.hints && mateTask.hints.open_decisions) ? mateTask.hints.open_decisions : []).filter((d) => !decisions.some((x) => x.id === d.key || x.key === d.key));
  const relayed = mateTask ? taskDecisionRows(facts, mateTask, relayedDecisions) : [];
  const ranked = [...(mateRow ? [mateRow] : []), ...workers, ...relayed];
  const worst = ranked.reduce((w, r) => (w === null || stateRank(r.tag) < stateRank(w.tag) ? r : w), null);
  const live = workers.filter((r) => !TERMINAL_TAGS.has(r.tag)).length;
  const flag = homeDecisions.length > 0 || relayed.length > 0 || workers.some((r) => FLAG_TAGS.has(r.tag));
  const ages = workers.map((r) => r.ageSeconds).filter((a) => a !== null && a !== undefined);
  const repos = [...new Set(workers.map((r) => r.repo).filter((r) => r && r !== '-'))];
  const groupRow = makeRow({
    tag: worst ? worst.tag : 'idle',
    extra: `${live} live`,
    id: `${flag ? '!' : ''}${expanded ? '▾' : '▸'} ${homeIdOf(ledger)}`,
    name: homeIdOf(ledger),
    text: workers.length ? workers.map((r) => r.name).join(', ') : mateRow ? mateRow.text : 'no workers',
    repo: repos.length === 1 ? repos[0] : repos.length > 1 ? `${repos.length} repos` : '-',
    home: homeLabel(ledger),
    homeId: homeIdOf(ledger),
    hideKey: `inflight:${homeIdOf(ledger)}:home`,
    ageSeconds: ages.length ? Math.min(...ages) : mateRow ? mateRow.ageSeconds : null,
    paneId: mateRow ? mateRow.paneId : null,
    focusable: false,
    group: key,
    expanded,
    flag,
  });
  const children = expanded
    ? [...(mateRow ? [mateRow] : []), ...workers, ...homeDecisions.map((d) => decisionRow(ledger, d)), ...relayed].map((r) => childMarker({ ...r, parent: key }))
    : [];
  return { row: groupRow, children };
}

// The main-snapshot task that is this ledger's secondmate agent, if any: same
// id, or a project path equal to the mate's home.
function mateTaskFor(tasks, ledger) {
  return tasks.find((t) => t.kind === 'secondmate' && (t.id === ledger.id || String(t.project || '').replace(/\/+$/, '') === ledger.home)) || null;
}

function inflightRows(facts, opts) {
  const snap = facts.snapshot || {};
  const tasks = Array.isArray(snap.tasks) ? snap.tasks : [];
  const backlogById = backlogIndex(snap);
  const expanded = opts.expanded || new Set();
  const folded = new Set();
  const entries = [];
  for (const ledger of facts.ledgers || []) {
    const mate = mateTaskFor(tasks, ledger);
    if (mate) folded.add(mate.id);
    entries.push(ledgerGroup(facts, ledger, mate, expanded.has(groupKeyFor(ledger))));
  }
  const mainEntries = tasks.filter((t) => !folded.has(t.id)).map((t) => ({ row: mainTaskRow(facts, t, backlogById), children: [] }));
  const ordered = sortInflight([...mainEntries, ...entries]);
  const rows = [];
  for (const e of ordered) {
    rows.push(e.row);
    for (const c of e.children) rows.push(c);
  }
  return rows;
}

// ----------------------------------------------------------------- Findings
//
// Every row carries reportPath, the absolute path of the report on this host,
// resolved against the home that owns it (the main home for scout reports and
// backlog report_path values, the secondmate home for its landed reports), so
// `enter` can hand it to the viewer. A remote home's report lives on another
// host: reportPath stays null and reportRemote says why.
function absolutePath(path, home) {
  if (!path) return null;
  return path.startsWith('/') ? path : `${String(home || '').replace(/\/+$/, '')}/${path}`;
}

function findingsRows(facts) {
  const rows = [];
  const snap = facts.snapshot || {};
  const backlog = snap.backlog && Array.isArray(snap.backlog.records) ? snap.backlog.records : [];
  const backlogById = new Map(backlog.map((r) => [r.id, r]));
  const seen = new Set();
  const seenPaths = new Set();
  for (const rep of Array.isArray(snap.scout_reports) ? snap.scout_reports : []) {
    seen.add(`main:${rep.id}`);
    seenPaths.add(relativeTo(rep.path, facts.fmHome));
    const b = backlogById.get(rep.id);
    rows.push(
      makeRow({
        tag: rep.kind || 'scout',
        extra: b && b.completion && b.completion.verb ? b.completion.verb : '-',
        id: rep.id,
        text: relativeTo(rep.path, facts.fmHome),
        repo: b ? b.repo : '-',
        ageSeconds: ageSince(facts.now, facts.mtime(rep.path)),
        reportPath: absolutePath(rep.path, facts.fmHome),
      }),
    );
  }
  for (const r of backlog) {
    if (r.state !== 'done' || !r.report_path || seen.has(`main:${r.id}`)) continue;
    // Two backlog rows can point at one report (a scout and the decision it
    // fed); the report is one finding.
    if (seenPaths.has(relativeTo(r.report_path, facts.fmHome))) continue;
    seen.add(`main:${r.id}`);
    seenPaths.add(relativeTo(r.report_path, facts.fmHome));
    const abs = absolutePath(r.report_path, facts.fmHome);
    rows.push(
      makeRow({
        tag: r.kind || 'report',
        extra: r.completion && r.completion.verb ? r.completion.verb : '-',
        id: r.id,
        text: relativeTo(r.report_path, facts.fmHome),
        repo: r.repo,
        ageSeconds: ageSince(facts.now, facts.mtime(abs)) ?? ageSince(facts.now, parseTime(r.completion && r.completion.date)),
        reportPath: abs,
      }),
    );
  }
  const ledgerById = new Map((facts.ledgers || []).map((l) => [l.home, l]));
  const smLanded = snap.secondmate_landed && Array.isArray(snap.secondmate_landed.records) ? snap.secondmate_landed.records : [];
  const landedSources = [];
  for (const r of smLanded) landedSources.push({ rec: r, home: r.home, id: r.home_id });
  for (const ledger of facts.ledgers || []) {
    for (const r of Array.isArray(ledger.summary && ledger.summary.landed) ? ledger.summary.landed : []) {
      landedSources.push({ rec: r, home: ledger.home, id: ledger.id });
    }
  }
  for (const { rec, home, id } of landedSources) {
    if (!rec.report_path) continue;
    const key = `${home}:${rec.id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const ledger = ledgerById.get(home) || { id, home };
    const abs = absolutePath(rec.report_path, home);
    rows.push(
      makeRow({
        tag: 'report',
        extra: rec.completion && rec.completion.verb ? rec.completion.verb : '-',
        id: rec.id,
        text: rec.report_path,
        repo: '-',
        home: homeLabel(ledger),
        homeId: homeIdOf(ledger),
        ageSeconds: ageSince(facts.now, facts.mtime(abs)) ?? ageSince(facts.now, parseTime(rec.completion && rec.completion.date)),
        reportPath: ledger.remote ? null : abs,
        reportRemote: Boolean(ledger.remote),
      }),
    );
  }
  return rows.sort((a, b) => (a.ageSeconds ?? Infinity) - (b.ageSeconds ?? Infinity));
}

// ------------------------------------------------------------------- Landed
//
// A Landed row carries every target its record has, so `enter` can fall back
// from one to the next (lib/controller.mjs landedTarget): url (the PR), then
// reportPath / reportRemote (the record's report_path resolved against the
// home that owns it, as findingsRows does; a remote home's report stays
// unreachable), then paneId / lost / unknown / focusable for a done task whose
// worker pane herdr still lists (the main home's task record, or the ledger's
// endpoint for that child, read as inflightRows reads them; a done task with
// no record or no pane has none). The WHAT text names the first target that
// exists, `<title> · <pr url>`, `<title> · <report path relative to its
// home>` or `<title> · pane <id>`, else the bare title; a lost pane is no
// target, so its row reads the bare title.
function landedWhat(title, { url, reportText, paneId, lost }) {
  if (url) return `${title} · ${url}`;
  if (reportText) return `${title} · ${reportText}`;
  if (paneId && !lost) return `${title} · pane ${paneId}`;
  return title;
}

function landedRows(facts) {
  const rows = [];
  const snap = facts.snapshot || {};
  const backlog = snap.backlog && Array.isArray(snap.backlog.records) ? snap.backlog.records : [];
  const taskById = new Map((Array.isArray(snap.tasks) ? snap.tasks : []).map((t) => [t.id, t]));
  for (const r of backlog) {
    if (r.state !== 'done') continue;
    const date = r.completion && r.completion.date ? r.completion.date : r.merged || r.done || r.reported || null;
    const task = taskById.get(r.id);
    const herdr = herdrColumn(facts, task && task.endpoint ? task.endpoint.target : null);
    const url = r.pr_url || null;
    const reportPath = absolutePath(r.report_path, facts.fmHome);
    rows.push(
      makeRow({
        tag: (r.completion && r.completion.verb) || 'done',
        extra: date ? String(date).slice(5) : '-',
        id: r.id,
        text: landedWhat(r.title, { url, reportText: r.report_path ? relativeTo(reportPath, facts.fmHome) : null, paneId: herdr.paneId, lost: herdr.lost }),
        repo: r.repo,
        hideKey: `landed:${MAIN_HOME_LABEL}:${r.id}:${date || '-'}`,
        ageSeconds: ageSince(facts.now, parseTime(date)),
        url,
        reportPath,
        paneId: herdr.paneId,
        lost: herdr.lost,
        unknown: herdr.unknown,
        focusable: Boolean(herdr.paneId),
      }),
    );
  }
  const seen = new Set();
  const ledgerById = new Map((facts.ledgers || []).map((l) => [l.home, l]));
  const smLanded = snap.secondmate_landed && Array.isArray(snap.secondmate_landed.records) ? snap.secondmate_landed.records : [];
  const sources = smLanded.map((r) => ({ rec: r, home: r.home, id: r.home_id }));
  for (const ledger of facts.ledgers || []) {
    for (const r of Array.isArray(ledger.summary && ledger.summary.landed) ? ledger.summary.landed : []) {
      sources.push({ rec: r, home: ledger.home, id: ledger.id });
    }
  }
  for (const { rec, home, id } of sources) {
    const key = `${home}:${rec.id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const ledger = ledgerById.get(home) || { id, home };
    const date = rec.completion && rec.completion.date ? rec.completion.date : null;
    const pr = rec.pr_url ? repoFromUrl(rec.pr_url) : null;
    const endpoints = Array.isArray(ledger.summary && ledger.summary.endpoints) ? ledger.summary.endpoints : [];
    const ep = endpoints.find((e) => e.id === rec.id);
    const herdr = herdrColumn(facts, ep && ep.endpoint ? ep.endpoint.target : null, { remote: Boolean(ledger.remote) });
    const url = rec.pr_url || null;
    const abs = absolutePath(rec.report_path, home);
    rows.push(
      makeRow({
        tag: (rec.completion && rec.completion.verb) || 'done',
        extra: date ? String(date).slice(5) : '-',
        id: rec.id,
        text: landedWhat(rec.title, { url, reportText: rec.report_path ? relativeTo(abs, home) : null, paneId: herdr.paneId, lost: herdr.lost }),
        repo: pr ? pr.repo : '-',
        home: homeLabel(ledger),
        homeId: homeIdOf(ledger),
        hideKey: `landed:${homeIdOf(ledger)}:${rec.id}:${date || '-'}`,
        ageSeconds: ageSince(facts.now, parseTime(date)),
        url,
        reportPath: ledger.remote ? null : abs,
        reportRemote: Boolean(rec.report_path && ledger.remote),
        paneId: herdr.paneId,
        lost: herdr.lost,
        unknown: herdr.unknown,
        focusable: Boolean(herdr.paneId) && !ledger.remote,
      }),
    );
  }
  return rows.sort((a, b) => (a.ageSeconds ?? Infinity) - (b.ageSeconds ?? Infinity));
}

// ---------------------------------------------------------------- PR facts
// The facts.prs shape across a session, shared by lib/app.mjs and the live
// one-shot render in index.mjs.

// The PR facts of a session start: nothing fetched, nothing failed, both
// panes waiting.
export function initialPrs(enabled, identity = null) {
  return { enabled, fetchedAt: null, error: null, candidate_prs: [], identity, mine: { fetchedAt: null, error: null }, toreview: { fetchedAt: null, error: null, scope: null, unavailable: null } };
}

// Fold one fetch (lib/sources.mjs fetchPrs: { mine, toreview, note }) into the
// previous PR facts at `at`: a pane whose searches failed keeps its previous
// rows and records the failure, a pane that answered replaces them. The
// top-level error names the first failing pane for the title line; the
// per-pane errors mark the pane titles stale.
export function mergePrs(prev, fetched, at, identity) {
  const keep = (paneId) => (Array.isArray(prev.candidate_prs) ? prev.candidate_prs : []).filter((c) => c && (c.pane || 'mine') === paneId);
  const pane = (paneId) => {
    const r = fetched[paneId] || { rows: [], error: null };
    const before = prev[paneId] || {};
    if (r.error) return { rows: keep(paneId), state: { ...before, error: r.error, scope: r.scope ?? before.scope ?? null, unavailable: r.unavailable ?? null } };
    return { rows: r.rows || [], state: { fetchedAt: at, error: null, scope: r.scope ?? null, unavailable: r.unavailable ?? null } };
  };
  const mine = pane('mine');
  const toreview = pane('toreview');
  return {
    enabled: true,
    fetchedAt: mine.state.fetchedAt ?? null,
    error: mine.state.error || toreview.state.error || null,
    candidate_prs: [...mine.rows, ...toreview.rows],
    identity,
    mine: mine.state,
    toreview: toreview.state,
  };
}

// The footer's words for the failures of one fetch, or null: each failing
// pane named once.
export function prsFailureText(fetched) {
  const parts = [];
  if (fetched.mine && fetched.mine.error) parts.push(fetched.mine.error);
  if (fetched.toreview && fetched.toreview.error && fetched.toreview.error !== (fetched.mine && fetched.mine.error)) parts.push(fetched.toreview.error);
  return parts.length ? parts.join('; ') : null;
}

// ------------------------------------------------------------------- Header
// The title line's herdr text: nothing while the subscription is up (or a
// fixture block stands in for it, which the HERDR column also reads as
// connected), otherwise `herdr disconnected (<reason>)` whatever brought the
// link down: never connected (connecting), dropped (the socket error), the
// board started with --no-herdr, herdr not on PATH or its socket unknown
// (the client's detail). The reason is left out when nothing recorded one.
export function herdrWarning(herdr) {
  const state = herdr ? herdr.state : 'off';
  if (state === 'connected' || state === 'fixture') return '';
  const detail = (herdr && herdr.detail) || (state === 'connecting' ? 'connecting' : '');
  return detail ? `herdr disconnected (${detail})` : 'herdr disconnected';
}

// The title line's refresh label, from facts.refresh: { nextAt, refreshing,
// failedAt, failed } in epoch seconds, or null when nothing is scheduled (a
// one-shot render). `refreshing…` while one runs; after a failure, `refresh
// failed 40s ago, retrying in 20s` until a later refresh succeeds, so stale
// data stays visibly stale; otherwise `next refresh in 18s`, whole seconds
// and never negative. Returns { text, failed } so the renderer can color a
// failure; text is '' with no schedule.
export function refreshLabel(facts) {
  const r = facts.refresh;
  if (!r) return { text: '', failed: false };
  if (r.refreshing) return { text: 'refreshing…', failed: false };
  const countdown = r.nextAt === null || r.nextAt === undefined ? null : `${Math.max(0, Math.floor(r.nextAt - facts.now))}s`;
  if (r.failedAt !== null && r.failedAt !== undefined) {
    const ago = fmtAge(facts.now - r.failedAt);
    return { text: countdown === null ? `refresh failed ${ago} ago` : `refresh failed ${ago} ago, retrying in ${countdown}`, failed: true };
  }
  return { text: countdown === null ? '' : `next refresh in ${countdown}`, failed: false };
}

const PR_PANE_IDS = new Set(['mine', 'toreview']);

// A pane is stale when its own data failed to refresh and the rows on screen
// are the previous ones: a PR pane when its own searches failed, the other
// four when the snapshot failed. The title line's refresh label says when.
function paneStale(facts, pane) {
  if (PR_PANE_IDS.has(pane.id)) return Boolean(facts.prs && facts.prs.enabled && paneFetch(facts.prs, pane.id).error);
  return Boolean(facts.snapshotError);
}

// The cached marker of a pane, or null: its rows come from the state cache
// (lib/cache.mjs, facts.cached) and the live source has not landed in this
// session. The four fleet panes read the snapshot flag, each PR pane its own,
// so a landed snapshot clears four markers while the PR panes keep theirs
// until the fetch lands. The age counts from when the cached data landed, in
// the AGE column's shape (fmtAge), and moves with the clock. A pane can be
// cached and stale at once: the launch refresh failed and the rows on screen
// are still the cached ones.
function paneCached(facts, pane, cached) {
  if (!cached) return null;
  const flag = PR_PANE_IDS.has(pane.id) ? Boolean(cached.prs && cached.prs[pane.id]) : Boolean(cached.snapshot);
  if (!flag) return null;
  const ageSeconds = Math.max(0, facts.now - (Number(cached.at) || facts.now));
  return { ageSeconds, label: `cached ${fmtAge(ageSeconds)} ago` };
}

function paneHeader(facts, pane, count, hiddenCount, showHidden, cached) {
  const hiddenNote = hiddenCount > 0 ? `, ${hiddenCount} hidden${showHidden ? ' shown' : ''}` : '';
  return `${pane.title} (${count}${hiddenNote})${paneStale(facts, pane) ? ' (stale)' : ''}${cached ? ` (${cached.label})` : ''}`;
}

// ------------------------------------------------------------------ Loading
// The spinner's ten braille frames, in cycle order. The frame index is a
// counter (facts.refresh.loadingFrame), never the clock, so a one-shot render
// with a fixture's refresh.loading_frame always draws the same glyph.
export const SPINNER_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

export function spinnerGlyph(frame) {
  const n = Number.isInteger(frame) && frame >= 0 ? frame : 0;
  return SPINNER_FRAMES[n % SPINNER_FRAMES.length];
}

// What a pane is still waiting for, or null: a pane is loading only while a
// refresh is in flight and the source it draws from has never landed in this
// session. Needs you, In flight, Findings and Landed wait on the fleet
// snapshot; My PRs waits on the GitHub checks and To review on the GitHub
// review requests (with --no-prs neither is ever loading: the panes show the
// off state, and with the identity unknown they show its row); In flight's
// HERDR column comes from herdr, which its spinner names only once the
// snapshot has landed while the herdr link is still connecting. A source that
// landed once never loads again (an empty pane reads its empty text, a
// refreshing pane keeps its rows), and a source whose first fetch failed
// shows the failure text, not the spinner, until a later refresh lands it.
function paneLoadingSource(facts, pane) {
  if (!facts.refresh || !facts.refresh.refreshing) return null;
  if (PR_PANE_IDS.has(pane.id)) {
    const prs = facts.prs;
    if (!prs || !prs.enabled || identityMissing(prs)) return null;
    const own = paneFetch(prs, pane.id);
    if (own.fetchedAt || own.error || own.unavailable) return null;
    return pane.id === 'mine' ? 'GitHub checks' : 'GitHub review requests';
  }
  if (!facts.snapshot && !facts.snapshotError) return 'fleet snapshot';
  if (pane.id === 'inflight' && facts.herdr && facts.herdr.state === 'connecting') return 'herdr';
  return null;
}

function paneLoading(facts, pane) {
  const source = paneLoadingSource(facts, pane);
  if (!source) return null;
  return { source, text: `${spinnerGlyph(facts.refresh.loadingFrame)} loading ${source}…` };
}

function asSet(value) {
  if (value instanceof Set) return value;
  return new Set(Array.isArray(value) ? value : []);
}

// Hide keys: pane:home:name, except group rows (inflight:<home>:home) and
// Landed rows, which carry the completion date so a re-landed item reappears.
// A child of a hidden group is hidden with it.
function applyHidden(paneId, rows, opts) {
  for (const r of rows) if (!r.hideKey) r.hideKey = `${paneId}:${r.homeId}:${r.name}`;
  const groupHideKey = new Map(rows.filter((r) => r.group).map((r) => [r.group, r.hideKey]));
  const isHidden = (r) => opts.hidden.has(r.hideKey) || (r.parent ? opts.hidden.has(groupHideKey.get(r.parent)) : false);
  const marked = rows.map((r) => (isHidden(r) ? { ...r, hidden: true, text: `(hidden) ${r.text}` } : r));
  const hiddenCount = marked.filter((r) => r.hidden).length;
  const listed = opts.showHidden ? marked : marked.filter((r) => !r.hidden);
  return { rows: listed, hiddenCount };
}

export function buildModel(facts, options = {}) {
  const opts = {
    expanded: asSet(options.expanded),
    allHomesNeeds: Boolean(options.allHomesNeeds),
    hidden: asSet(options.hidden),
    showHidden: Boolean(options.showHidden),
    hiddenPanes: asSet(options.hiddenPanes),
  };
  const f = {
    now: facts.now,
    fmHome: facts.fmHome || '',
    snapshot: facts.snapshot || null,
    snapshotAt: facts.snapshotAt ?? null,
    snapshotError: facts.snapshotError ?? null,
    ledgers: Array.isArray(facts.ledgers) ? facts.ledgers : [],
    herdr: facts.herdr || { state: 'off', agents: {} },
    prs: facts.prs || { enabled: false },
    refresh: facts.refresh || null,
    cached: facts.cached && typeof facts.cached === 'object' ? facts.cached : null,
    mtime: typeof facts.mtime === 'function' ? facts.mtime : () => null,
    statusVerbs: typeof facts.statusVerbs === 'function' ? facts.statusVerbs : () => null,
  };
  const builders = { needs: needsRows, mine: mineRows, inflight: inflightRows, findings: findingsRows, landed: landedRows, toreview: toReviewRows };
  const panes = PANES.map((p, i) => {
    const { rows, hiddenCount } = applyHidden(p.id, builders[p.id](f, opts), opts);
    const empty = PR_PANE_IDS.has(p.id) ? prPaneEmpty(f, p) : p.empty;
    const cached = paneCached(f, p, f.cached);
    return { id: p.id, title: p.title, key: String(i + 1), empty, rows, hiddenCount, hidden: opts.hiddenPanes.has(p.id), header: paneHeader(f, p, rows.length, hiddenCount, opts.showHidden, cached), loading: paneLoading(f, p), cached };
  });
  const homes = 1 + f.ledgers.length;
  return {
    panes,
    // Whether a herdr pane can be reached from this board: false under
    // --no-herdr (state off, or the fixture overlay that stands in for a
    // server); a connecting or dropped link still counts, as In flight's focus
    // does, and the focus itself reports the failure.
    herdrOn: f.herdr.state !== 'off' && f.herdr.state !== 'fixture',
    meta: {
      fmHome: f.fmHome,
      homes,
      refresh: refreshLabel(f),
      snapshotError: f.snapshotError,
      herdrWarning: herdrWarning(f.herdr),
      hiddenPanes: panes.filter((p) => p.hidden).map((p) => p.key),
      hiddenRows: panes.reduce((n, p) => n + p.hiddenCount, 0),
      showHidden: opts.showHidden,
      ledgerErrors: f.ledgers.filter((l) => l.error).map((l) => `${l.id || basename(l.home)}: ${l.error}`),
    },
  };
}
