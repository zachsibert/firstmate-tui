// lib/model.mjs - pure projection from firstmate facts to the five board panes.
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
//   prs           { enabled, fetchedAt, error, candidate_prs[] } from
//                 fm-bearings-snapshot.sh --json --include-prs (only with --prs)
//   mtime(path)   epoch seconds of a file's last write, or null
//
// Options (second argument of buildModel):
//   expanded      Set of In flight group keys currently expanded
//   allHomesNeeds also list every secondmate ledger's open decisions in Needs
//                 you (the --all-homes-needs flag); default off, main home only
//   hidden        Set of row hide keys the captain hid with `x` (view state)
//   showHidden    list hidden rows anyway, marked "(hidden)" (the `H` toggle)
//   hiddenPanes   Set of pane ids switched off with `1`-`5`
//
// Output: { panes: [ { id, title, empty, header, rows[], hidden, hiddenCount } x5 ], meta }.
// Every row carries tag, extra, id, text, repo, home, age (display fields) plus
// name (the undecorated id for notices), homeId (main or the secondmate id),
// hideKey (pane:home:name, plus the completion date for Landed), ageSeconds,
// paneId (herdr pane id when the row has one), lost (that pane is absent from
// a connected herdr), unknown (herdr is disconnected, so absence is unproved),
// focusable, url (a PR URL the row can open, or null), reportPath (Findings:
// the absolute report path on this host, or null) and, for In flight grouping,
// group / expanded / flag on a group row and parent on its children. A row
// listed under showHidden carries hidden: true. The mapping follows the scout
// report's section 1 table.

import { PANES } from './layout.mjs';
import { basename, clean, fmtAge, parseTime, relativeTo, repoFromUrl } from './text.mjs';

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
    ...fields,
  };
  row.name = fields.name ?? row.id;
  row.age = fmtAge(row.ageSeconds);
  row.repo = row.repo || '-';
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
// never qualifies (their work surfaces through their own ledger). Shared by
// the Needs you merge? row and the In flight "awaiting merge" state.
function awaitingMerge(task, backlogById) {
  const cs = task.current_state || {};
  if (task.kind === 'secondmate' || cs.state !== 'done' || !(task.pr && task.pr.url)) return false;
  return taskBacklogState(task, backlogById) !== 'done';
}

// The keyed decisions and the blocked event of one task record, as rows
// (without the merge? row). Needs you lists them for main-home workers; a
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
// when expanded; --all-homes-needs restores them here.
function needsRows(facts, opts) {
  const rows = [];
  const snap = facts.snapshot || {};
  const tasks = Array.isArray(snap.tasks) ? snap.tasks : [];
  const backlog = snap.backlog && Array.isArray(snap.backlog.records) ? snap.backlog.records : [];
  const backlogById = backlogIndex(snap);

  for (const task of tasks) {
    if (task.kind !== 'secondmate' || opts.allHomesNeeds) rows.push(...taskDecisionRows(facts, task));
    if (awaitingMerge(task, backlogById)) {
      const herdr = herdrColumn(facts, task.endpoint && task.endpoint.target);
      const pr = repoFromUrl(task.pr.url);
      rows.push(
        makeRow({
          tag: 'merge?',
          extra: pr ? `#${pr.num}` : '-',
          id: task.id,
          text: `PR ready: ${task.pr.url}`,
          repo: pr ? pr.repo : taskRepo(task),
          ageSeconds: statusLogAge(facts, task),
          paneId: herdr.paneId,
          lost: herdr.lost,
          unknown: herdr.unknown,
          focusable: Boolean(herdr.paneId),
          url: task.pr.url,
        }),
      );
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

  const order = { blocked: 0, decide: 1, hold: 2, 'merge?': 3 };
  return rows
    .map((r, i) => ({ r, i }))
    .sort((a, b) => (order[a.r.tag] ?? 9) - (order[b.r.tag] ?? 9) || a.i - b.i)
    .map((x) => x.r);
}

// --------------------------------------------------------- Ready for review
// A PR is still "ready for review" while its task is unfinished. A secondmate
// record's pr.url is the mate's own mention of a PR (its work lands through its
// ledger), and a task whose backlog row is done is finished work; both stay out.
function recordedPrs(facts) {
  const snap = facts.snapshot || {};
  const backlogById = backlogIndex(snap);
  const out = new Map();
  for (const task of Array.isArray(snap.tasks) ? snap.tasks : []) {
    if (!(task.pr && task.pr.url)) continue;
    if (task.kind === 'secondmate') continue;
    if (taskBacklogState(task, backlogById) === 'done') continue;
    out.set(task.pr.url, { url: task.pr.url, task: task.id, source: task.pr.source || 'meta' });
  }
  const backlog = snap.backlog && Array.isArray(snap.backlog.records) ? snap.backlog.records : [];
  for (const r of backlog) {
    if (r.pr_url && r.state !== 'done' && !out.has(r.pr_url)) out.set(r.pr_url, { url: r.pr_url, task: r.id, source: 'backlog' });
  }
  return [...out.values()];
}

function reviewShort(review) {
  switch (review) {
    case 'APPROVED':
      return 'approved';
    case 'CHANGES_REQUESTED':
      return 'changes';
    case 'REVIEW_REQUIRED':
      return 'review';
    default:
      return review ? clean(review).toLowerCase().slice(0, 9) : '-';
  }
}

// GitHub says the PR is no longer open. fm-bearings-snapshot.sh lists open PRs
// only and carries no state field today, so this reads `state` (MERGED, CLOSED)
// or `merged` when a candidate carries one; such a PR is dropped, and a
// recorded PR it matches is dropped too rather than shown as unlisted.
function prClosed(c) {
  if (c.merged === true) return true;
  const state = String(c.state || '').toUpperCase();
  return state === 'MERGED' || state === 'CLOSED';
}

function reviewRows(facts) {
  const rows = [];
  const recorded = recordedPrs(facts);
  const prs = facts.prs || { enabled: false };
  const seen = new Set();
  if (prs.enabled && Array.isArray(prs.candidate_prs)) {
    for (const c of prs.candidate_prs) {
      seen.add(c.url);
      if (prClosed(c)) continue;
      const rec = recorded.find((r) => r.url === c.url);
      const taskId = rec ? rec.task : c.task && c.task !== '-' ? c.task : '-';
      const parts = [c.url];
      if (c.mergeable && c.mergeable !== 'MERGEABLE') parts.push(String(c.mergeable).toLowerCase());
      rows.push(
        makeRow({
          tag: c.checks || 'none',
          extra: reviewShort(c.review),
          id: taskId === '-' ? `${basename(c.repo)}#${c.num}` : taskId,
          text: parts.join(' · '),
          repo: c.repo,
          url: c.url,
        }),
      );
    }
  }
  for (const r of recorded) {
    if (seen.has(r.url)) continue;
    const pr = repoFromUrl(r.url);
    rows.push(
      makeRow({
        tag: prs.enabled ? 'unlisted' : 'PR',
        extra: pr ? `#${pr.num}` : '-',
        id: r.task,
        text: `${r.url} · checks: not fetched`,
        repo: pr ? pr.repo : '-',
        url: r.url,
      }),
    );
  }
  const order = { failing: 0, pending: 1, passing: 2, none: 3 };
  return rows
    .map((r, i) => ({ r, i }))
    .sort((a, b) => (order[a.r.tag] ?? 5) - (order[b.r.tag] ?? 5) || a.i - b.i)
    .map((x) => x.r);
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
const STATE_RANK = { blocked: 0, failed: 3, decide: 1, 'needs-decision': 1, hold: 1, working: 2 };
const INFLIGHT_ORDER = { working: 0, blocked: 1, decide: 1, 'needs-decision': 1, hold: 1, unknown: 2, 'awaiting merge': 3, done: 3, failed: 4 };
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
    tag: awaitingMerge(task, backlogById) ? 'awaiting merge' : cs.state || 'unknown',
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
    rows.push(
      makeRow({
        tag: d ? decisionTag(d.verb) : child.state || 'working',
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
    rows.push(
      makeRow({
        tag: d ? decisionTag(d.verb) : ep.state || 'unknown',
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
function landedRows(facts) {
  const rows = [];
  const snap = facts.snapshot || {};
  const backlog = snap.backlog && Array.isArray(snap.backlog.records) ? snap.backlog.records : [];
  for (const r of backlog) {
    if (r.state !== 'done') continue;
    const date = r.completion && r.completion.date ? r.completion.date : r.merged || r.done || r.reported || null;
    rows.push(
      makeRow({
        tag: (r.completion && r.completion.verb) || 'done',
        extra: date ? String(date).slice(5) : '-',
        id: r.id,
        text: r.pr_url ? `${r.title} · ${r.pr_url}` : r.title,
        repo: r.repo,
        hideKey: `landed:${MAIN_HOME_LABEL}:${r.id}:${date || '-'}`,
        ageSeconds: ageSince(facts.now, parseTime(date)),
        url: r.pr_url || null,
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
    rows.push(
      makeRow({
        tag: (rec.completion && rec.completion.verb) || 'done',
        extra: date ? String(date).slice(5) : '-',
        id: rec.id,
        text: rec.pr_url ? `${rec.title} · ${rec.pr_url}` : rec.title,
        repo: pr ? pr.repo : '-',
        home: homeLabel(ledger),
        homeId: homeIdOf(ledger),
        hideKey: `landed:${homeIdOf(ledger)}:${rec.id}:${date || '-'}`,
        ageSeconds: ageSince(facts.now, parseTime(date)),
        url: rec.pr_url || null,
      }),
    );
  }
  return rows.sort((a, b) => (a.ageSeconds ?? Infinity) - (b.ageSeconds ?? Infinity));
}

// ------------------------------------------------------------------- Header
export function herdrLabel(herdr) {
  if (!herdr) return 'herdr off';
  switch (herdr.state) {
    case 'connected':
      return 'herdr connected';
    case 'connecting':
      return 'herdr connecting';
    case 'disconnected':
      return `herdr disconnected${herdr.detail ? ` (${herdr.detail})` : ''}`;
    case 'unavailable':
      return `herdr unavailable${herdr.detail ? ` (${herdr.detail})` : ''}`;
    case 'fixture':
      return 'herdr fixture';
    case 'off':
    default:
      return 'herdr off';
  }
}

export function snapshotLabel(facts) {
  if (facts.snapshotError && facts.snapshotAt === null) return 'snapshot failed';
  if (facts.snapshotAt === null || facts.snapshotAt === undefined) return 'snapshot pending';
  const age = fmtAge(facts.now - facts.snapshotAt);
  return facts.snapshotError ? `snapshot ${age} ago (stale)` : `snapshot ${age} ago`;
}

function paneHeader(facts, pane, count, hiddenCount, showHidden) {
  const hiddenNote = hiddenCount > 0 ? `, ${hiddenCount} hidden${showHidden ? ' shown' : ''}` : '';
  const parts = [`${pane.title} (${count}${hiddenNote})`, snapshotLabel(facts), herdrLabel(facts.herdr)];
  if (pane.id === 'review') {
    const prs = facts.prs || { enabled: false };
    if (!prs.enabled) parts.push('checks not fetched');
    else if (prs.error) parts.push('checks failed');
    else if (prs.fetchedAt) parts.push(`checks ${fmtAge(facts.now - prs.fetchedAt)} ago`);
    else parts.push('checks pending');
  }
  return parts.join(' · ');
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
    mtime: typeof facts.mtime === 'function' ? facts.mtime : () => null,
  };
  const builders = { needs: needsRows, review: reviewRows, inflight: inflightRows, findings: findingsRows, landed: landedRows };
  const panes = PANES.map((p, i) => {
    const { rows, hiddenCount } = applyHidden(p.id, builders[p.id](f, opts), opts);
    return { id: p.id, title: p.title, key: String(i + 1), empty: p.empty, rows, hiddenCount, hidden: opts.hiddenPanes.has(p.id), header: paneHeader(f, p, rows.length, hiddenCount, opts.showHidden) };
  });
  const homes = 1 + f.ledgers.length;
  return {
    panes,
    meta: {
      fmHome: f.fmHome,
      homes,
      snapshot: snapshotLabel(f),
      snapshotError: f.snapshotError,
      herdr: herdrLabel(f.herdr),
      hiddenPanes: panes.filter((p) => p.hidden).map((p) => p.key),
      hiddenRows: panes.reduce((n, p) => n + p.hiddenCount, 0),
      showHidden: opts.showHidden,
      ledgerErrors: f.ledgers.filter((l) => l.error).map((l) => `${l.id || basename(l.home)}: ${l.error}`),
    },
  };
}
