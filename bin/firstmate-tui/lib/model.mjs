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
//                 mergeable, checks} plus, from gh only (absent from
//                 fm-bearings-snapshot.sh's rows): merge_state (GitHub's
//                 mergeStateStatus, CLEAN, DIRTY, BLOCKED, ... or null),
//                 created_at, merged_at,
//                 closed_at (ISO 8601), title, base (the base branch), draft
//                 (boolean), state (OPEN, MERGED or CLOSED), author (a login or
//                 null), labels (strings), requested (the identity was asked
//                 to review it), my_review (APPROVED, CHANGES_REQUESTED or
//                 null: the identity's own latest review) and pane ('mine' or
//                 'toreview'; absent means 'mine'). identity is { login,
//                 source, reason } (lib/identity.mjs; unknown when login is
//                 null) once resolved, and null while the app is still
//                 resolving it (its first refresh, after the snapshot, and r
//                 asking again for an unknown one): the two PR panes spin on
//                 a null identity and show their identity row only for a
//                 resolved unknown one. mine and toreview each carry that pane's own
//                 { fetchedAt, error } (falling back to the top-level pair
//                 when absent), toreview also `scope` (the repositories
//                 searched) and `unavailable` (why it cannot fetch at all)
//   refresh       the schedule for the title line, or null when nothing is
//                 scheduled (a one-shot render): { nextAt, refreshing,
//                 fetching, failedAt, failed, loadingFrame }, the times in
//                 epoch seconds; refreshing while the app's local cycle (the
//                 fleet snapshot and the ledgers) runs, fetching while its
//                 GitHub cycle (the identity and the PR fetch) is in flight,
//                 the two independent; `failed` the last failure's text,
//                 kept until a later landing of both is clean, and
//                 loadingFrame the spinner's frame counter (the app's 10 Hz
//                 tick count, a fixture's refresh.loading_frame; never
//                 wall-clock, so a one-shot frame is deterministic)
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
//   allHomesNeeds accepted and ignored since 0.7.0: Captain's Call lists every
//                 home's live captain holds by default (the --all-homes-needs
//                 flag is kept so an old launcher line still works)
//   hidden        Set of row hide keys the captain hid with `x` (view state)
//   showHidden    list hidden rows anyway, marked "(hidden)" (the `H` toggle)
//   hiddenPanes   Set of pane ids switched off with `1`-`6`
//   dismissed     Set of dismiss keys (`<home id>:<task id>`, dismissKey) of
//                 the holds discarded or deferred in this session: every row
//                 carrying that task's card (Captain's Call's hold, decide and
//                 blocked rows, a Charted Next hold row, an Underway or
//                 Recently Landed row whose task is the hold, a delegate's
//                 decision row) is dropped before the
//                 hidden rows are marked (applyDismissed), so the row leaves
//                 the frame the moment the command succeeds, before the
//                 refresh it starts has landed. Session state only: never
//                 written to the view-state file, never counted or listed by
//                 H. The host clears an entry (pruneDismissed) on a clean
//                 refresh only when the new facts no longer list the task as
//                 a live hold (liveHoldKeys: what Needs you would list with
//                 row.hold, every home's); an entry whose task is still
//                 listed stays dismissed until a later refresh agrees, so a
//                 stale or cached snapshot cannot bring the row back for a
//                 tick
//
// Output: { panes: [ { id, title, empty, header, rows[], hidden, hiddenCount, loading, cached } x6 ], search[], meta },
// where header is `Title (count[, n warnings][, n hidden])` (the count leaves
// Charted Next's warning rows out) plus ` (stale)` when that pane's
// own data failed to refresh, ` (cached 12m ago)` while its rows come from
// the state cache (paneCached below; cached is null or { ageSeconds, label }
// so the host can name the age when a cached row is opened) and, on a PR
// pane that has something to show, ` (updating)` while the GitHub cycle is
// in flight (paneUpdating below), in that order; loading is null or
// { source, text } while the
// pane still waits for its first data (paneLoading below; text is the spinner
// line the renderer draws), and meta carries the title line's refresh label
// ({ text, failed }) and herdr warning ('' while the link is up).
// Every row carries tag, extra, id, text, repo, home, base, author, age
// (display fields; base is the PR's base branch, drawn by the two PR panes
// only, and author the PR author's login, drawn by Teammates' PRs only) plus
// name (the undecorated id for notices), homeId (main or the secondmate id),
// hideKey (pane:home:name, plus the completion date for Recently Landed),
// ageSeconds (numeric; `age` is its short form, with a trailing `~` when
// ageFallback says the row wanted a better source and got the file-time age
// instead; Charted Next draws the item's filed date there instead),
// paneId (herdr pane id when the row has one), lost (that pane is absent from
// a connected herdr), unknown (herdr is disconnected, so absence is unproved),
// focusable, url (a PR URL the row can open, or null), reportPath (Recently
// Landed: the absolute report path on this host, or null; reportRemote when a
// remote home holds it), card and hold (below), warning (a Charted Next
// integrity notice, left out of the pane's count) and, for Underway grouping,
// group / expanded / flag on a group row and parent on its children (flag on
// a worker row: its task is also the captain's, in Captain's Call). A row
// listed under showHidden carries hidden: true. The panes follow the four
// sections of firstmate's bearings digest (its chat-response contract); the
// README's Using the board section is the current pane-to-data table.
//
// search: the f key's index (lib/search.mjs), one entry per row of every
// pane, { pane (the index in panes), paneId, paneTitle, row }, in pane order
// then row order: the builders' full lists with the dismissed rows dropped,
// every hidden row kept and marked as H shows it, every group expanded (a
// collapsed group's children are searchable, and the jump expands the group)
// and the hidden panes' rows included (the jump shows the pane). Each row
// carries searchText and searchHead (lib/search.mjs searchTextOf), filled
// here so the matcher never reads a pane's own fields. The list is built
// from the same builder calls as the panes, plus one more build of any pane
// whose rows hold a collapsed group, with every group open, so a refresh
// that changes the rows changes the results with it. Nothing here names a
// pane: the index follows PANES (lib/layout.mjs) and the builders map.
//
// card: null, or what `enter` opens as the row's hold card (lib/card.mjs,
// lib/hold.mjs): { id, home (path), homeId, homeLabel, remote, source,
// record }. A main-home row's record is the snapshot's backlog record
// (source 'snapshot'); a delegate home's row carries a ledger-shaped stand-in
// (source 'ledger') and the host reads the full record from that home on
// demand. Which rows carry one: Captain's Call's hold rows and the decide
// and blocked rows built from a task's status decisions (mainCard), a
// delegate's decision rows (ledgerCard), every Charted Next item row (its
// backlog record or ledger entry, a hold in a non-live bucket or a plain
// queued item), and any Underway or Recently Landed row whose task has a
// backlog record with hold_kind captain, whatever its bucket. Review rows and
// warning rows never do: a review row's enter opens the PR, a warning has
// nothing to open.
// hold: null, or the captain hold d and D act on: { id, home, homeId, remote,
// reason, truncated }, set only while the record is a captain hold that is
// not done; a delegate's reason comes from its ledger cut at 160 characters
// (truncated: true), so a defer reads the full record first (lib/app.mjs).

import { PANES } from './layout.mjs';
import { basename, clean, fmtAge, parseTime, relativeTo, repoFromUrl } from './text.mjs';
import { identityPending, identityUnknown } from './identity.mjs';
import { searchTextOf } from './search.mjs';

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
    card: null,
    hold: null,
    warning: false,
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

// The card and the hold of a main-home task from its backlog record (see the
// header): every such row carries the card; the hold only while the record
// is a captain hold that is not done, since the two actions act on an open
// hold and a finished task has none to discard or defer.
function mainCard(facts, id, record) {
  const rec = record || null;
  const at = { id, home: facts.fmHome, homeId: MAIN_HOME_LABEL, homeLabel: MAIN_HOME_LABEL, remote: false };
  const held = Boolean(rec && rec.hold_kind === 'captain');
  return {
    card: { ...at, source: 'snapshot', record: rec },
    hold: held && rec.state !== 'done' ? { ...at, reason: rec.hold_reason ?? null, truncated: false } : null,
  };
}

// Whether a main-home task's backlog record carries a captain hold, any bucket.
function heldForCaptain(record) {
  return Boolean(record && record.hold_kind === 'captain');
}

// The card and the hold of a delegate home's task from its ledger: the
// captain-hold entry of decisions_open (the one place the ledger says a live
// hold is the captain's) or the captain-held queued entry (a hold in any
// bucket, Charted Next's rows), with the title and repo of its queued entry
// and the reason of its holds entry when the decision carries none. The
// stand-in record is shaped like a backlog record so the card builder reads
// it as one; the host replaces it with the home's own record when it can. A
// row without a captain hold still gets a card (d is the decision it lists),
// never a hold.
function ledgerCard(ledger, id, summaryText = null) {
  const summary = ledger.summary || {};
  const list = (key) => (Array.isArray(summary[key]) ? summary[key] : []);
  const d = list('decisions_open').find((x) => x && x.id === id && x.verb === 'captain-hold') || null;
  const q = list('queued').find((x) => x && x.id === id) || {};
  const h = list('holds').find((x) => x && x.id === id) || {};
  const at = { id, home: ledger.home, homeId: homeIdOf(ledger), homeLabel: homeLabel(ledger), remote: Boolean(ledger.remote) };
  const held = Boolean(d) || q.hold_kind === 'captain';
  const reason = (d && d.reason) || q.hold_reason || h.reason || null;
  const record = {
    id,
    title: q.title || h.title || (d && d.summary) || summaryText || null,
    repo: q.repo || null,
    state: q.id ? 'queued' : null,
    kind: q.kind || null,
    hold_kind: held ? 'captain' : null,
    hold_reason: reason,
    hold_until: (d && d.hold_until) || q.hold_until || null,
    hold_set: null,
    hold_bucket: (d && d.hold_bucket) || q.hold_bucket || null,
    hold_age_days: (d && d.hold_age_days) ?? q.hold_age_days ?? null,
    body_lines: [],
    pr_url: null,
    report_path: null,
  };
  return {
    card: { ...at, source: 'ledger', record },
    hold: held ? { ...at, reason, truncated: true } : null,
  };
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
// (without the review row). Captain's Call lists them for main-home workers
// and, through relayedDecisionRows, for a delegate's task record when its
// ledger does not carry the call (`extra` then names the delegate's home).
// Each row carries the task's card (its backlog record, when the snapshot has
// one).
function taskDecisionRows(facts, task, decisions = null, backlogById = new Map(), extra = {}) {
  const rows = [];
  const hints = task.hints || {};
  const herdr = herdrColumn(facts, task.endpoint && task.endpoint.target);
  const list = decisions || (Array.isArray(hints.open_decisions) ? hints.open_decisions : []);
  const held = mainCard(facts, task.id, backlogById.get(task.id));
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
        ...held,
        ...extra,
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
        ...held,
        ...extra,
      }),
    );
  }
  return rows;
}

// The task id a relayed captain hold names. fm-captain-hold.sh publishes a
// delegate's hold into its task record in the main home through the parent
// channel as `needs-decision [key=captain-hold-<task>-<n>]`, n counting that
// task's resolution records; the board reads it back through
// tasks[].hints.open_decisions. null for a key of any other shape.
export function relayedTaskId(key) {
  const m = /^captain-hold-(.+)-\d+$/.exec(String(key || ''));
  return m ? m[1] : null;
}

// Whether a delegate's ledger carries a task as the captain's: an entry of
// decisions_open (any bucket) or a captain-held queued item, by id or key.
function ledgerHoldsTask(ledger, id) {
  if (!id) return false;
  const summary = ledger && ledger.summary ? ledger.summary : {};
  const list = (key) => (Array.isArray(summary[key]) ? summary[key] : []);
  return list('decisions_open').some((d) => d && (d.id === id || d.key === id)) || list('queued').some((q) => q && q.id === id && q.hold_kind === 'captain');
}

// The calls a delegate relayed through its own task record in the main home
// (mateTask: hints.open_decisions and blocked_event) that its ledger does not
// carry, as Captain's Call rows with the delegate's home label. A relay
// whose key names a task the ledger holds (relayedTaskId, or the key itself)
// is dropped: the ledger is the authority over the home's calls and the relay
// is fallback evidence, drawn only when the ledger is unreadable or silent.
// This is the one-row-per-captain-held-task rule for delegate holds.
function relayedDecisionRows(facts, ledger, mateTask, backlogById) {
  if (!mateTask) return [];
  const hints = mateTask.hints || {};
  const list = Array.isArray(hints.open_decisions) ? hints.open_decisions : [];
  const unmatched = list.filter((d) => d && !ledgerHoldsTask(ledger, relayedTaskId(d.key)) && !ledgerHoldsTask(ledger, d.key));
  if (!unmatched.length && !hints.blocked_event) return [];
  return taskDecisionRows(facts, mateTask, unmatched, backlogById, { home: homeLabel(ledger), homeId: homeIdOf(ledger) });
}

// ----------------------------------------------------------- Captain's Call
// What needs the captain's own action now, from every home: the main home's
// live captain holds (backlog records with hold_kind captain and hold_bucket
// live, which is exactly captain_actionable), every delegate home's live
// captain holds (its ledger's decisions_open with verb captain-hold and
// hold_bucket live or absent, liveDecisions), the keyed decisions and blocked
// events of main-home workers (tasks[].hints: the transitional record before
// firstmate files the hold), a delegate's relayed calls its ledger does not
// carry (relayedDecisionRows), and one `review` row per fleet PR parked for
// the captain that GitHub reports ready (reviewRow), whichever home raised
// it. A blocked, dated or aged hold is never here: it is one Charted Next row
// (chartedRows), so a captain hold sits in exactly one pane. A task yields at
// most one row per kind; the old merge? row is gone. `opts.allHomesNeeds` is
// accepted and ignored: every home's calls list here since 0.7.0.
function needsRows(facts) {
  const rows = [];
  const snap = facts.snapshot || {};
  const tasks = Array.isArray(snap.tasks) ? snap.tasks : [];
  const backlog = snap.backlog && Array.isArray(snap.backlog.records) ? snap.backlog.records : [];
  const backlogById = backlogIndex(snap);

  const fetched = fetchedByUrl(facts.prs);

  for (const task of tasks) {
    if (task.kind !== 'secondmate') rows.push(...taskDecisionRows(facts, task, null, backlogById));
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
          ...mainCard(facts, r.id, r),
        }),
      );
    }
  }

  // Every delegate home's live captain holds, then the calls its task record
  // relays that the ledger does not carry (one row per held task).
  for (const ledger of facts.ledgers || []) {
    for (const d of liveDecisions(ledger)) rows.push(decisionRow(ledger, d));
    rows.push(...relayedDecisionRows(facts, ledger, mateTaskFor(tasks, ledger), backlogById));
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
// pointing at the Settings page. While it is still being resolved (null)
// each lists nothing and spins on it instead (paneLoading), so the row never
// shows before every rung has failed.

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
// The two reasons Teammates' PRs can be `unavailable` (lib/sources.mjs
// fetchPrs puts one on facts.prs.toreview when firstmate's script is the
// source): gh is not on PATH, or the config file's prs.source asked for the
// script. prPaneEmpty names what the pane needs after each.
export const GH_MISSING = 'gh not on PATH';
export const SCRIPT_CONFIGURED = 'config prs.source = firstmate';

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
// (fm-bearings-snapshot.sh lists open PRs only) counts as open.
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
// fetch is on and the board's own fetch runs it (when firstmate's script is
// the source, gh missing or the config asking for it, My PRs lists the
// script's rows, which need no login, and To review says why it is empty).
// Then a pending identity (null: the first refresh has not
// reached the rungs yet, or r is asking them again) puts the resolving
// spinner in both panes with no rows, and a resolved unknown one (every rung
// failed) puts the identity row there.
function identityNeeded(prs) {
  return Boolean(prs && prs.enabled) && !paneFetch(prs, 'toreview').unavailable;
}

function identityResolving(prs) {
  return identityNeeded(prs) && identityPending(prs.identity);
}

function identityMissing(prs) {
  return identityNeeded(prs) && identityUnknown(prs.identity);
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
  if (identityResolving(prs)) return [];
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
  if (identityResolving(prs)) return [];
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
// fetch switched off, no way to fetch at all (To review while firstmate's
// script is the source: it needs the GitHub CLI when gh is missing, the
// board's own fetch when the config chose the script), an empty To review
// scope, else the pane's own words.
function prPaneEmpty(facts, pane) {
  const prs = facts.prs || { enabled: false };
  if (!prs.enabled) return pane.id === 'toreview' ? PRS_OFF_TEXT : pane.empty;
  if (pane.id === 'toreview') {
    const own = paneFetch(prs, 'toreview');
    if (own.unavailable) return `${own.unavailable}: Teammates' PRs needs ${own.unavailable === SCRIPT_CONFIGURED ? "the board's own fetch" : 'the GitHub CLI'}`;
    if (own.scope && own.scope.length === 0) return SCOPE_EMPTY_TEXT;
  }
  return pane.empty;
}

// ------------------------------------------------------------------ Underway
//
// One row per live worker: the main home's task records and each delegate
// home's children, from its ledger. Holds and decisions are not work: they
// are Captain's Call or Charted Next rows, so nothing here is built from a
// ledger's decisions_open or holds or from a delegate's relayed decisions; a
// worker whose task is also the captain's carries a `!` in front of its id
// (and row.flag), pointing at that row. WHAT leads with the task's title,
// then what it is doing (whatText), the way the bearings digest names a
// worker.
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
// FALLBACK IN EFFECT: group by home. A home's rows are its live workers only
// (ledgerChildRows: every active_children entry, plus the endpoints whose
// state is live: not done, which is Recently Landed's, and not unknown, which
// is a Charted Next warning). A home with two or more such rows draws a
// collapsible group row over them; a home with exactly one draws that row
// directly, HOME naming the home; a home with none draws nothing here (its
// calls are Captain's Call's, its queued items and its state, when unknown,
// are Charted Next's). The delegate's own task record contributes only its
// herdr pane, so `f` on the group focuses the delegate: its current_state is
// the last verb of its own status log, "done" after any done relay, so it
// never sets the group's STATE and never lists as a child. The group row
// shows the worst state among its workers (groupState), the live worker
// count, the child ids, the shared repo and the newest child event, and a `!`
// when the home has a call in Captain's Call; expanding it lists the worker
// rows. Finished children appear in Recently Landed and nowhere here. When
// the ledger grows a per-child parent field, make groupKeyFor() read it and
// the rest stands.

// Worst-state ranking for a group row: blocked > repairing PR > working. Only
// these words are live work; a row with any other tag (paused, failed,
// awaiting merge) never raises the group, so a group whose workers all failed
// reads idle: a failed child is the delegate's own cleanup, and it shows on
// expansion. A done or unknown row is never built (ledgerChildRows), so
// neither is here; a hold or decision is not a worker row since 0.7.0.
const STATE_RANK = { blocked: 0, 'repairing PR': 1, working: 2 };
const INFLIGHT_ORDER = { working: 0, 'repairing PR': 0, blocked: 1, paused: 2, idle: 2, 'awaiting merge': 3, done: 3, failed: 4 };

// The STATE word of a task with a recorded PR: `awaiting merge` for a done
// main-home task whose backlog row is open (awaitingMerge), `repairing PR`
// for one working again after a done line (isRepairing / childRepairing),
// else firstmate's own state word.
function prStateTag(state, { awaiting = false, repairing = false }) {
  if (awaiting) return 'awaiting merge';
  if (repairing) return 'repairing PR';
  return state || 'unknown';
}
const TERMINAL_TAGS = new Set(['done', 'failed']);

// The WHAT text of a worker row: the task's title, then what it is doing,
// `title · doing`; whichever of the two exists when one is missing.
function whatText(title, doing) {
  const t = clean(title || '');
  const d = clean(doing || '');
  return t && d ? `${t} · ${d}` : t || d;
}

// The STATE of a group row over the rows listed under it: the lowest rank in
// STATE_RANK, else idle.
function groupState(rows) {
  let worst = null;
  for (const r of rows) {
    const rank = STATE_RANK[r.tag];
    if (rank !== undefined && (worst === null || rank < worst.rank)) worst = { rank, tag: r.tag };
  }
  return worst ? worst.tag : 'idle';
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
    ...ledgerCard(ledger, d.id, d.summary),
    ...extraFields,
  });
}

// A main-home worker's row, or null when the task is not a worker: a task
// whose backlog record is held (a captain hold or an external one) lists
// here only while it is working (the hold is a Captain's Call or Charted
// Next row, and a failed or parked task under it has nothing running); a
// working task under a captain hold then carries the card, the hold and the
// `!` marker, so enter shows the hold instead of focusing the pane; f still
// focuses it. A task that said done lists only while its PR awaits the
// captain's merge (`awaiting merge`): a plain done task is finished work,
// Recently Landed's row, until firstmate cleans its record up. Working,
// blocked, paused and failed tasks list.
function mainTaskRow(facts, task, backlogById = new Map()) {
  const cs = task.current_state || {};
  const record = backlogById.get(task.id);
  const held = Boolean(record && record.hold_kind);
  const captainHeld = heldForCaptain(record);
  if (held && cs.state !== 'working') return null;
  if (cs.state === 'done' && !awaitingMerge(task, backlogById)) return null;
  const herdr = herdrColumn(facts, task.endpoint && task.endpoint.target);
  const doing = cs.detail || (task.hints && task.hints.last_event_text) || (task.paths && task.paths.status_log && task.paths.status_log.last_event && task.paths.status_log.last_event.note) || '';
  const title = (record && record.title) || (task.backlog && task.backlog.title) || '';
  return makeRow({
    tag: prStateTag(cs.state, { awaiting: awaitingMerge(task, backlogById), repairing: isRepairing(facts, task) }),
    extra: herdr.extra,
    id: captainHeld ? `!${task.id}` : task.id,
    name: task.id,
    text: `${kindPrefix(task.kind)}${whatText(title, doing)}`,
    repo: taskRepo(task),
    ageSeconds: statusLogAge(facts, task),
    paneId: herdr.paneId,
    lost: herdr.lost,
    unknown: herdr.unknown,
    focusable: Boolean(herdr.paneId),
    url: task.pr && task.pr.url ? task.pr.url : null,
    flag: captainHeld,
    ...(captainHeld ? mainCard(facts, task.id, record) : {}),
  });
}

// Worker rows of one secondmate ledger, in ledger order: every
// active_children entry, then the endpoints entries the ledger lists on their
// own whose state is live. An endpoint whose state is done is finished work
// (Recently Landed lists it from the ledger's landed entries) and is skipped;
// one whose state is unknown, or missing, is skipped too: nothing is known to
// run there, and the canonical snapshot reports the home's state unavailable
// for it, which Charted Next draws as a warning (warningRows). Working,
// repairing, blocked, paused and failed endpoints list. A row is never built
// from the delegate's own task record, its status lines, its relayed notes or
// its ledger's decisions; a child the ledger holds for the captain (a live
// entry of decisions_open) keeps its worker row, marked `!` and carrying the
// card and the hold, while the call itself is a Captain's Call row. WHAT is
// the child's title (`name`), then its `doing`; a held endpoint without a
// title reads its hold's title.
function ledgerChildRows(facts, ledger) {
  const summary = ledger.summary || {};
  const endpoints = Array.isArray(summary.endpoints) ? summary.endpoints : [];
  const endpointById = new Map(endpoints.map((e) => [e.id, e]));
  const heldIds = new Set(liveDecisions(ledger).filter((d) => d.verb === 'captain-hold').map((d) => d.id));
  const holdsById = new Map((Array.isArray(summary.holds) ? summary.holds : []).map((h) => [h.id, h]));
  const rows = [];
  const covered = new Set();
  for (const child of Array.isArray(summary.active_children) ? summary.active_children : []) {
    covered.add(child.id);
    const ep = endpointById.get(child.id);
    const herdr = herdrColumn(facts, ep && ep.endpoint ? ep.endpoint.target : null, { remote: Boolean(ledger.remote) });
    const childState = child.state || 'working';
    const held = heldIds.has(child.id);
    rows.push(
      makeRow({
        tag: prStateTag(childState, { repairing: childRepairing(facts, ledger, child.id, childState, childPrUrl(ledger, child.id)) }),
        extra: herdr.extra,
        id: held ? `!${child.id}` : child.id,
        name: child.id,
        text: `${kindPrefix(child.kind)}${whatText(child.name, child.doing)}`,
        repo: child.repo,
        home: homeLabel(ledger),
        homeId: homeIdOf(ledger),
        ageSeconds: childStatusAge(facts, ledger, child.id),
        paneId: herdr.paneId,
        lost: herdr.lost,
        unknown: herdr.unknown,
        focusable: Boolean(herdr.paneId) && !ledger.remote,
        flag: held,
        // A child the ledger holds for the captain carries the card and the hold; any other child keeps enter = focus.
        ...(held ? ledgerCard(ledger, child.id) : {}),
      }),
    );
  }
  for (const ep of endpoints) {
    if (covered.has(ep.id)) continue;
    const epState = ep.state || 'unknown';
    if (epState === 'done' || epState === 'unknown') continue;
    const herdr = herdrColumn(facts, ep.endpoint ? ep.endpoint.target : null, { remote: Boolean(ledger.remote) });
    const held = heldIds.has(ep.id);
    const h = holdsById.get(ep.id);
    rows.push(
      makeRow({
        tag: prStateTag(epState, { repairing: childRepairing(facts, ledger, ep.id, epState, childPrUrl(ledger, ep.id)) }),
        extra: herdr.extra,
        id: held ? `!${ep.id}` : ep.id,
        name: ep.id,
        text: h && h.title ? whatText(h.title, h.reason && h.reason !== h.title ? h.reason : '') : `endpoint ${ep.endpoint && ep.endpoint.target ? ep.endpoint.target : '?'} (${ep.source || 'pane'})`,
        repo: '-',
        home: homeLabel(ledger),
        homeId: homeIdOf(ledger),
        ageSeconds: childStatusAge(facts, ledger, ep.id),
        paneId: herdr.paneId,
        lost: herdr.lost,
        unknown: herdr.unknown,
        focusable: Boolean(herdr.paneId) && !ledger.remote,
        flag: held,
        ...(held ? ledgerCard(ledger, ep.id) : {}),
      }),
    );
  }
  return rows;
}

function childMarker(row) {
  return { ...row, id: `↳ ${row.id}`, name: row.name, parent: row.parent };
}

// The Underway entry of one secondmate home, or null when it has no live
// worker: { row, children } with a group row over two or more worker rows
// (children listed when expanded), or the one worker row itself, drawn
// directly. The delegate's own task record (mateTask) lends the group only
// its herdr pane, so `f` focuses the delegate; its state and status line stay
// out (the header above says why). The group's `!` says the home has a call
// in Captain's Call (a live hold in its ledger, or a relayed call the ledger
// does not carry).
function ledgerEntry(facts, ledger, mateTask, expanded, backlogById = new Map()) {
  const key = groupKeyFor(ledger);
  const workers = sortInflight(ledgerChildRows(facts, ledger).map((row) => ({ row }))).map((e) => e.row);
  if (!workers.length) return null;
  if (workers.length === 1) return { row: workers[0], children: [] };
  const flag = liveDecisions(ledger).length > 0 || relayedDecisionRows(facts, ledger, mateTask, backlogById).length > 0;
  const live = workers.filter((r) => !TERMINAL_TAGS.has(r.tag)).length;
  const newest = (rows) => {
    const ages = rows.map((r) => r.ageSeconds).filter((a) => a !== null && a !== undefined);
    return ages.length ? Math.min(...ages) : null;
  };
  const repos = [...new Set(workers.map((r) => r.repo).filter((r) => r && r !== '-'))];
  const matePane = mateTask ? herdrColumn(facts, mateTask.endpoint && mateTask.endpoint.target).paneId : null;
  const groupRow = makeRow({
    tag: groupState(workers),
    extra: `${live} live`,
    id: `${flag ? '!' : ''}${expanded ? '▾' : '▸'} ${homeIdOf(ledger)}`,
    name: homeIdOf(ledger),
    text: workers.map((r) => r.name).join(', '),
    repo: repos.length === 1 ? repos[0] : repos.length > 1 ? `${repos.length} repos` : '-',
    home: homeLabel(ledger),
    homeId: homeIdOf(ledger),
    hideKey: `inflight:${homeIdOf(ledger)}:home`,
    ageSeconds: newest(workers),
    paneId: matePane,
    focusable: false,
    group: key,
    expanded,
    flag,
  });
  const children = expanded ? workers.map((r) => childMarker({ ...r, parent: key })) : [];
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
    // expandAll (the search index) opens every group so its children are listed.
    const entry = ledgerEntry(facts, ledger, mate, Boolean(opts.expandAll) || expanded.has(groupKeyFor(ledger)), backlogById);
    if (entry) entries.push(entry);
  }
  const mainEntries = tasks
    .filter((t) => !folded.has(t.id))
    .map((t) => mainTaskRow(facts, t, backlogById))
    .filter(Boolean)
    .map((row) => ({ row, children: [] }));
  const ordered = sortInflight([...mainEntries, ...entries]);
  const rows = [];
  for (const e of ordered) {
    rows.push(e.row);
    for (const c of e.children) rows.push(c);
  }
  return rows;
}

// -------------------------------------------------------------- Charted Next
//
// Queued and gated work, one row per item, and the fleet's action-free
// warnings. Every hold here is one the captain need not act on now: its
// hold_bucket is blocked (a blocker unresolved), dated (hold_until still in
// the future) or aged (an undated hold past firstmate's age threshold), so it
// left Captain's Call, and it is here exactly once; a live hold is Captain's
// Call's and never here. The buckets are the canonical snapshot's
// (fm-fleet-snapshot.sh hold_bucket, decided from structured fields), never
// read from prose. Rows:
//   queued     a queued backlog record (main), or a delegate's ledger queued[]
//              entry, with no live hold; `blocked` instead when
//              unresolved_blocker_ids names a blocker
//   blocked / dated / aged   a captain hold in that bucket, WHY its structured
//              reason: `by <first blocker> +N`, `until MM-DD`, `held Nd`
//   warning    an integrity notice, nothing to act on: the main inventory
//              invalid (main_inventory), a delegate home unreadable, its
//              ledger invalid or its state unknown (the canonical snapshot's
//              current.state and reason, else the ledger's valid, state and
//              reason), a ledger endpoint whose state is unknown and that is
//              not an active child: gone (exists false), or its child's
//              current state unavailable (when no home-level warning already
//              names the home). A lost pane behind a live worker, main or
//              delegate, is not a warning: its Underway row already reads
//              `pane lost` in red
// Warnings come first, are left out of the pane's count (row.warning,
// paneHeader) and carry no card; the items follow newest filed first (the
// record's `since` date, drawn as FILED in the last column, in place of an
// age), undated items after the dated ones in record order. A hold row
// carries its card and hold (mainCard, ledgerCard), so enter shows the card
// and d / D act on it as in Captain's Call; a plain queued row carries its
// card alone. The main-home rule is the bearings digest's gate rule: a
// structured record that is not done, not captain_actionable, and a hold in a
// non-live bucket, a queued item, or an in-flight item held for the captain
// that no worker is working.
const NON_LIVE_BUCKETS = new Set(['blocked', 'dated', 'aged']);

function chartedState(rec) {
  if (NON_LIVE_BUCKETS.has(rec.hold_bucket)) return rec.hold_bucket;
  return Array.isArray(rec.unresolved_blocker_ids) && rec.unresolved_blocker_ids.length ? 'blocked' : 'queued';
}

// The WHY cell: the structured reason the item waits, by its state.
function chartedWhy(rec) {
  const state = chartedState(rec);
  const blockers = Array.isArray(rec.unresolved_blocker_ids) ? rec.unresolved_blocker_ids.map((b) => String(b)).filter(Boolean) : [];
  if (state === 'blocked') return blockers.length ? `by ${blockers[0]}${blockers.length > 1 ? ` +${blockers.length - 1}` : ''}` : 'blocked';
  if (state === 'dated') return rec.hold_until ? `until ${String(rec.hold_until).slice(5, 10)}` : 'dated';
  if (state === 'aged') return rec.hold_age_days !== null && rec.hold_age_days !== undefined ? `held ${rec.hold_age_days}d` : 'aged';
  return '-';
}

// Whether a backlog record (main) or a ledger queued entry (a delegate's,
// with `state` defaulted to queued) is a Charted Next item. `workingIds` are
// the main tasks whose worker is working, so a held in-flight item that is
// being worked stays out (its Underway row carries the `!`).
function chartedItem(rec, workingIds) {
  if (!rec || !rec.id || rec.structured === false || rec.state === 'done') return false;
  if (rec.captain_actionable === true || rec.hold_bucket === 'live') return false;
  if (NON_LIVE_BUCKETS.has(rec.hold_bucket)) return true;
  if (rec.state === 'queued') return true;
  return rec.state === 'in_flight' && rec.current_role === 'held' && !workingIds.has(rec.id);
}

// The record's filed date (`since`) as epoch seconds and as the MM-DD the
// FILED column draws; both null without one.
function filedDate(rec) {
  const epoch = parseTime(rec.since);
  return { epoch, filed: epoch === null ? null : String(rec.since).slice(5, 10) };
}

function chartedRow(facts, rec, fields = {}) {
  const { epoch, filed } = filedDate(rec);
  const title = clean(rec.title || rec.id);
  const reason = clean(rec.hold_reason || rec.blocked_reason || '');
  const row = makeRow({
    tag: chartedState(rec),
    extra: chartedWhy(rec),
    id: rec.id,
    text: reason && reason !== title ? `${title} · ${reason}` : title,
    repo: rec.repo,
    ageSeconds: ageSince(facts.now, epoch),
    ...fields,
  });
  row.age = filed || '-';
  return row;
}

function warningRow({ id, text, home = MAIN_HOME_LABEL, homeId = MAIN_HOME_LABEL }) {
  const row = makeRow({ tag: 'warning', extra: '-', id, text: clean(text), repo: '-', home, homeId, hideKey: `charted:${homeId}:warning:${id}`, warning: true });
  row.age = '-';
  return row;
}

// The fleet's integrity warnings (the header above lists them), main home
// first, then each delegate home in ledger order.
function warningRows(facts) {
  const rows = [];
  const snap = facts.snapshot || {};
  const inv = snap.main_inventory;
  if (inv && inv.valid === false) rows.push(warningRow({ id: 'main inventory', text: inv.reason || 'main inventory invalid' }));
  const records = snap.secondmate_current && Array.isArray(snap.secondmate_current.records) ? snap.secondmate_current.records : [];
  for (const ledger of facts.ledgers || []) {
    const home = homeLabel(ledger);
    const homeId = homeIdOf(ledger);
    const summary = ledger.summary;
    if (!summary) {
      rows.push(warningRow({ id: homeId, text: `structured state unreadable: ${ledger.error || 'no ledger'}`, home, homeId }));
      continue;
    }
    const rec = records.find((r) => r && String(r.home || '').replace(/\/+$/, '') === ledger.home) || null;
    const current = rec && rec.current ? rec.current : {};
    const reason = (current.state === 'unknown' && (current.reason || 'current home state unavailable')) || (summary.valid === false && (summary.reason || 'home ledger invalid')) || (summary.state === 'unknown' && (summary.reason || 'current home state unavailable')) || null;
    if (reason) rows.push(warningRow({ id: homeId, text: reason, home, homeId }));
    const active = new Set((Array.isArray(summary.active_children) ? summary.active_children : []).map((c) => c && c.id));
    for (const ep of Array.isArray(summary.endpoints) ? summary.endpoints : []) {
      if (!ep || !ep.id) continue;
      const target = ep.endpoint && ep.endpoint.target ? ep.endpoint.target : '?';
      // Only an endpoint nothing is known to run behind warns: a done one is
      // finished work, a live one is an Underway row (its HERDR cell reads
      // pane lost when the pane is gone), an active child is a worker.
      if ((ep.state || 'unknown') !== 'unknown' || active.has(ep.id)) continue;
      if (ep.endpoint && ep.endpoint.exists === false) rows.push(warningRow({ id: ep.id, text: `endpoint ${target} is gone (exists: false)`, home, homeId }));
      else if (!reason) rows.push(warningRow({ id: ep.id, text: `child current state unavailable (endpoint ${target}, ${ep.source || 'pane'})`, home, homeId }));
    }
  }
  return rows;
}

function chartedRows(facts) {
  const snap = facts.snapshot || {};
  const tasks = Array.isArray(snap.tasks) ? snap.tasks : [];
  const backlog = snap.backlog && Array.isArray(snap.backlog.records) ? snap.backlog.records : [];
  const workingIds = new Set(tasks.filter((t) => t.kind !== 'secondmate' && t.current_state && t.current_state.state === 'working').map((t) => t.id));
  const items = [];
  for (const r of backlog) if (chartedItem(r, workingIds)) items.push(chartedRow(facts, r, mainCard(facts, r.id, r)));
  for (const ledger of facts.ledgers || []) {
    const summary = ledger.summary || {};
    const queued = Array.isArray(summary.queued) ? summary.queued : [];
    const decisions = Array.isArray(summary.decisions_open) ? summary.decisions_open : [];
    for (const q of queued) {
      if (!q) continue;
      // The queued entry carries the item; its decisions_open entry, when the
      // hold is a captain's, carries the until date, the age and the reason
      // the queued entry may lack.
      const d = decisions.find((x) => x && x.id === q.id && x.verb === 'captain-hold') || {};
      const rec = { ...q, state: q.state || 'queued', hold_until: q.hold_until ?? d.hold_until ?? null, hold_age_days: q.hold_age_days ?? d.hold_age_days ?? null, hold_reason: q.hold_reason ?? d.reason ?? null };
      if (!chartedItem(rec, workingIds)) continue;
      items.push(chartedRow(facts, rec, { home: homeLabel(ledger), homeId: homeIdOf(ledger), ...ledgerCard(ledger, q.id) }));
    }
  }
  // Newest filed first; an item with no date after every dated one, in record order.
  const ordered = items
    .map((r, i) => ({ r, i }))
    .sort((a, b) => {
      const aa = a.r.ageSeconds ?? null;
      const bb = b.r.ageSeconds ?? null;
      if (aa === null && bb === null) return a.i - b.i;
      if (aa === null) return 1;
      if (bb === null) return -1;
      return aa - bb || a.i - b.i;
    })
    .map((x) => x.r);
  return [...warningRows(facts), ...ordered];
}

// ---------------------------------------------------------- Recently Landed
//
// Completions and reports, one row each, newest first: the main home's Done
// rows that firstmate's landed rule admits (landedRecord, the port of
// bin/fm-landed-lib.sh: a scout with its report, a merged PR, a local-only
// done, or a plain closed row that names none of the three artifacts), the
// answered and discarded captain calls (Done rows that keep hold_kind or kind
// captain, VERB `answered`: the bearings digest leaves them out as not
// deliveries, the board keeps them because d and D happen here and the row's
// card holds the captain's words), every delegate home's landed rows
// (secondmate_landed and the ledger's landed[], already selected by the same
// rule inside firstmate), and every report on disk (scout_reports[]) whose
// task has no listed Done row, VERB `report` with the file's date. A Done row
// that fails the rule (a scout that recorded no report, a merge that names no
// PR) is not a delivery and draws nothing. Newest first by date, a tie kept in
// backlog order, the delegates' rows after the main home's.
//
// Every row with a report carries reportPath, the absolute path of the report
// on this host, resolved against the home that owns it (the main home for
// scout reports and backlog report_path values, the secondmate home for its
// landed reports), so `enter` can hand it to the viewer. A remote home's
// report lives on another host: reportPath stays null and reportRemote says
// why.
function absolutePath(path, home) {
  if (!path) return null;
  return path.startsWith('/') ? path : `${String(home || '').replace(/\/+$/, '')}/${path}`;
}

// The delivery test of bin/fm-landed-lib.sh (landed_delivery, landed_record),
// row for row: a closed captain call is never a delivery, a scout's delivery
// is its report, a merge's its PR, a local-only completion's its note, and a
// plain closed row with none of the three is kept for compatibility.
function landedDelivery(r) {
  const verb = r.completion && r.completion.verb;
  if (r.kind === 'scout') return Boolean(r.report_path);
  if (r.kind === 'captain' || r.hold_kind === 'captain') return false;
  if (verb === 'merged') return Boolean(r.pr_url);
  if (verb === 'done') return Boolean(r.local_note);
  return false;
}

function landedRecord(r) {
  if (!r || r.state !== 'done' || r.structured === false) return false;
  if (landedDelivery(r)) return true;
  return r.kind !== 'scout' && r.kind !== 'captain' && r.hold_kind !== 'captain' && !r.pr_url && !r.report_path && !r.local_note;
}

// A closed captain call: the row keeps the captain-hold provenance a
// non-release answer leaves behind (hold_kind captain), or was created as a
// captain question (kind captain).
function answeredCall(r) {
  return Boolean(r && r.state === 'done' && (r.hold_kind === 'captain' || r.kind === 'captain'));
}

// The YYYY-MM-DD of an epoch, in UTC, for a report dated by its file time.
function isoDate(epoch) {
  return epoch === null || epoch === undefined ? null : new Date(epoch * 1000).toISOString().slice(0, 10);
}

// A Recently Landed row carries every target its record has, so `enter` can fall back
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
  const backlogById = backlogIndex(snap);
  const taskById = new Map((Array.isArray(snap.tasks) ? snap.tasks : []).map((t) => [t.id, t]));
  // The main-home reports already listed through a Done row, by path relative
  // to the home, so a report on disk lists once.
  const reported = new Set();
  for (const r of backlog) {
    if (r.state !== 'done') continue;
    const answered = answeredCall(r);
    if (!answered && !landedRecord(r)) continue;
    const date = r.completion && r.completion.date ? r.completion.date : r.merged || r.done || r.reported || null;
    const task = taskById.get(r.id);
    const herdr = herdrColumn(facts, task && task.endpoint ? task.endpoint.target : null);
    const url = r.pr_url || null;
    const reportPath = absolutePath(r.report_path, facts.fmHome);
    if (reportPath) reported.add(relativeTo(reportPath, facts.fmHome));
    rows.push(
      makeRow({
        tag: answered ? 'answered' : (r.completion && r.completion.verb) || 'done',
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
        // A finished captain hold keeps its card (the answer is on the record); it is done, so there is no hold to act on.
        ...(heldForCaptain(r) ? mainCard(facts, r.id, r) : {}),
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
  // Every report on disk whose task has no Done row above (the task is live,
  // queued, gone, or its Done row failed the landed rule): a completion the
  // backlog does not record, dated by the file, `enter` opens it.
  for (const rep of Array.isArray(snap.scout_reports) ? snap.scout_reports : []) {
    if (!rep || !rep.path) continue;
    const rel = relativeTo(rep.path, facts.fmHome);
    if (reported.has(rel)) continue;
    reported.add(rel);
    const b = backlogById.get(rep.id);
    const at = facts.mtime(rep.path);
    const date = isoDate(at);
    rows.push(
      makeRow({
        tag: 'report',
        extra: date ? date.slice(5) : '-',
        id: rep.id,
        text: landedWhat((b && b.title) || rep.id, { reportText: rel }),
        repo: b ? b.repo : '-',
        hideKey: `landed:${MAIN_HOME_LABEL}:${rep.id}:${date || '-'}`,
        ageSeconds: ageSince(facts.now, at),
        reportPath: absolutePath(rep.path, facts.fmHome),
      }),
    );
  }
  return rows
    .map((r, i) => ({ r, i }))
    .sort((a, b) => (a.r.ageSeconds ?? Infinity) - (b.r.ageSeconds ?? Infinity) || a.i - b.i)
    .map((x) => x.r);
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
// rows and records the failure, a pane that answered replaces them, and a
// pane the fetch skipped (`skipped`: the identity was unknown, so nothing
// was asked) lists nothing and keeps its fetch state, above all a null
// fetchedAt, so the first-fetch spinner still follows once r resolves the
// login. The top-level error names the first failing pane for the title
// line; the per-pane errors mark the pane titles stale.
export function mergePrs(prev, fetched, at, identity) {
  const keep = (paneId) => (Array.isArray(prev.candidate_prs) ? prev.candidate_prs : []).filter((c) => c && (c.pane || 'mine') === paneId);
  const pane = (paneId) => {
    const r = fetched[paneId] || { rows: [], error: null };
    const before = prev[paneId] || {};
    if (r.error) return { rows: keep(paneId), state: { ...before, error: r.error, scope: r.scope ?? before.scope ?? null, unavailable: r.unavailable ?? null } };
    if (r.skipped) return { rows: [], state: { ...before, fetchedAt: before.fetchedAt ?? null, error: null, scope: r.scope ?? before.scope ?? null, unavailable: null } };
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

// A PR pane is updating while the GitHub cycle is in flight
// (facts.refresh.fetching) and it has something to keep on screen meanwhile:
// rows, or the empty text of an earlier fetch or the cache. A pane still
// waiting for its first fetch spins instead (paneLoading), and a pane nothing
// is fetched for, the identity unknown or the pane unavailable on the script
// source, carries no marker.
function paneUpdating(facts, pane, loading) {
  if (!PR_PANE_IDS.has(pane.id) || loading || !facts.refresh || !facts.refresh.fetching) return false;
  const prs = facts.prs;
  return Boolean(prs && prs.enabled) && !identityMissing(prs) && !paneFetch(prs, pane.id).unavailable;
}

// The pane title's count leaves Charted Next's warning rows out and names
// them apart (`Charted Next (43, 2 warnings)`), so the number is queued work.
function paneHeader(facts, pane, count, warnings, hiddenCount, showHidden, cached, loading) {
  const warningNote = warnings > 0 ? `, ${warnings} warning${warnings === 1 ? '' : 's'}` : '';
  const hiddenNote = hiddenCount > 0 ? `, ${hiddenCount} hidden${showHidden ? ' shown' : ''}` : '';
  return `${pane.title} (${count}${warningNote}${hiddenNote})${paneStale(facts, pane) ? ' (stale)' : ''}${cached ? ` (${cached.label})` : ''}${paneUpdating(facts, pane, loading) ? ' (updating)' : ''}`;
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
// cycle is in flight and the source it draws from has never landed in this
// session. Needs you, In flight, Findings and Landed wait on the fleet
// snapshot while the local cycle runs (refreshing); My PRs and To review
// wait, while either cycle runs (the GitHub cycle follows the local one, so
// a cold start spins from its first frame to its first fetch), first on the
// GitHub identity, while it is still being resolved (`resolving GitHub
// identity`, the one line whose verb is not `loading`; the resolution follows
// the snapshot, so on a cold start it is what both panes show until the login
// is known, and r shows it again while asking for an unknown one), then My
// PRs on the GitHub checks and To review on the GitHub review requests (with
// --no-prs neither is ever loading: the panes show the off state, and with
// the identity resolved unknown they show its row); In flight's HERDR column
// comes from herdr, which its spinner names only once the snapshot has landed
// while the herdr link is still connecting. A source that landed once never
// loads again (an empty pane reads its empty text, a refreshing pane keeps
// its rows and a PR pane under a fetch in flight is marked updating instead),
// and a source whose first fetch failed shows the failure text, not the
// spinner, until a later cycle lands it.
function paneLoadingSource(facts, pane) {
  const r = facts.refresh;
  if (!r) return null;
  if (PR_PANE_IDS.has(pane.id)) {
    if (!r.refreshing && !r.fetching) return null;
    const prs = facts.prs;
    if (!prs || !prs.enabled || identityMissing(prs)) return null;
    if (identityResolving(prs)) return { verb: 'resolving', source: 'GitHub identity' };
    const own = paneFetch(prs, pane.id);
    if (own.fetchedAt || own.error || own.unavailable) return null;
    return { verb: 'loading', source: pane.id === 'mine' ? 'GitHub checks' : 'GitHub review requests' };
  }
  if (!r.refreshing) return null;
  if (!facts.snapshot && !facts.snapshotError) return { verb: 'loading', source: 'fleet snapshot' };
  if (pane.id === 'inflight' && facts.herdr && facts.herdr.state === 'connecting') return { verb: 'loading', source: 'herdr' };
  return null;
}

function paneLoading(facts, pane) {
  const waiting = paneLoadingSource(facts, pane);
  if (!waiting) return null;
  return { source: waiting.source, text: `${spinnerGlyph(facts.refresh.loadingFrame)} ${waiting.verb} ${waiting.source}…` };
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

// Dismissed holds (the `dismissed` option in the header): the key of one
// task in one home, and the key a row answers to, its card's task (null for
// a row without a card, which no dismissal can match: review, PR, Findings
// and group rows). The home id is part of the key so two homes' tasks with
// one id never collide.
export function dismissKey(homeId, id) {
  return `${homeId}:${id}`;
}

export function rowDismissKey(row) {
  return row && row.card ? dismissKey(row.card.homeId, row.card.id) : null;
}

// The rows of one pane less every row whose task was dismissed: the filter
// step beside applyHidden, run first so a dismissed row is never marked or
// counted hidden. The pane count and header follow the rows that are left.
function applyDismissed(rows, opts) {
  if (!opts.dismissed.size) return rows;
  return rows.filter((r) => !opts.dismissed.has(rowDismissKey(r)));
}

// The dismiss keys of every live captain hold the facts carry: what Needs
// you lists with row.hold, every home's included (a delegate's hold can be
// discarded from its In flight group, --all-homes-needs or not). The
// clearing rule reads this set: an entry stays dismissed while its key is
// here, a stale snapshot still listing the hold included, and goes the first
// time it is not.
export function liveHoldKeys(facts) {
  const rows = needsRows(normalizeFacts(facts), { allHomesNeeds: true });
  return new Set(rows.filter((r) => r.hold).map((r) => rowDismissKey(r)));
}

// Drop from `dismissed` every entry whose task the (new) facts no longer
// list as a live hold. Mutates the set and returns it; the host calls it
// once per refresh that landed cleanly.
export function pruneDismissed(dismissed, facts) {
  const live = liveHoldKeys(facts);
  for (const key of [...dismissed]) if (!live.has(key)) dismissed.delete(key);
  return dismissed;
}

// The facts with every optional field given its default, so the builders
// never test for absence.
function normalizeFacts(facts) {
  return {
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
}

export function buildModel(facts, options = {}) {
  const opts = {
    expanded: asSet(options.expanded),
    allHomesNeeds: Boolean(options.allHomesNeeds),
    hidden: asSet(options.hidden),
    showHidden: Boolean(options.showHidden),
    hiddenPanes: asSet(options.hiddenPanes),
    dismissed: asSet(options.dismissed),
  };
  const f = normalizeFacts(facts);
  const builders = { needs: needsRows, mine: mineRows, inflight: inflightRows, charted: chartedRows, landed: landedRows, toreview: toReviewRows };
  const search = [];
  const panes = PANES.map((p, i) => {
    const full = applyDismissed(builders[p.id](f, opts), opts);
    const { rows, hiddenCount } = applyHidden(p.id, full, opts);
    // The search index (header): every row of the pane, hidden ones marked; a
    // pane with a collapsed group is built again with every group open so
    // the group's children are found too (pane-agnostic: whichever pane
    // draws groups).
    const collapsed = full.some((r) => r.group && !r.expanded);
    const indexed = collapsed ? applyDismissed(builders[p.id](f, { ...opts, expandAll: true }), opts) : full;
    // The search text is read before the hidden mark, so `(hidden)` never matches.
    const withText = indexed.map((row) => ({ ...row, ...searchTextOf(row) }));
    for (const row of applyHidden(p.id, withText, { ...opts, showHidden: true }).rows) search.push({ pane: i, paneId: p.id, paneTitle: p.title, row });
    const empty = PR_PANE_IDS.has(p.id) ? prPaneEmpty(f, p) : p.empty;
    const cached = paneCached(f, p, f.cached);
    const loading = paneLoading(f, p);
    const warnings = rows.filter((r) => r.warning).length;
    return { id: p.id, title: p.title, key: String(i + 1), empty, rows, hiddenCount, hidden: opts.hiddenPanes.has(p.id), header: paneHeader(f, p, rows.length - warnings, warnings, hiddenCount, opts.showHidden, cached, loading), loading, cached };
  });
  const homes = 1 + f.ledgers.length;
  return {
    panes,
    search,
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
