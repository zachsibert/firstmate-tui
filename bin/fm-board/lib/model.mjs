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
// Output: { panes: [ { id, title, empty, header, rows[] } x5 ], meta }.
// Every row carries tag, extra, id, text, repo, home, age (display fields) plus
// ageSeconds, paneId (herdr pane id when the row has one) and focusable.
// The mapping follows the scout report's section 1 table row for row.

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
  return `${ledger.id || basename(ledger.home) || 'home'}${suffix}`;
}

function herdrColumn(facts, target) {
  const parsed = parseTarget(target);
  if (!parsed) return { extra: '-', paneId: null };
  if (parsed.tmux) return { extra: 'tmux', paneId: null };
  const state = facts.herdr ? facts.herdr.state : 'off';
  if (state === 'off' || state === 'unavailable') return { extra: '-', paneId: parsed.paneId };
  const agent = facts.herdr.agents ? facts.herdr.agents[parsed.paneId] : null;
  if (!agent) return { extra: state === 'connected' || state === 'fixture' ? 'absent' : '?', paneId: parsed.paneId };
  return { extra: agent.agent_status || 'unknown', paneId: parsed.paneId };
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
    ageSeconds: null,
    paneId: null,
    focusable: false,
    ...fields,
  };
  row.age = fmtAge(row.ageSeconds);
  row.repo = row.repo || '-';
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

// ---------------------------------------------------------------- Needs you
function needsRows(facts) {
  const rows = [];
  const snap = facts.snapshot || {};
  const tasks = Array.isArray(snap.tasks) ? snap.tasks : [];
  const backlog = snap.backlog && Array.isArray(snap.backlog.records) ? snap.backlog.records : [];
  const backlogById = new Map(backlog.map((r) => [r.id, r]));

  for (const task of tasks) {
    const hints = task.hints || {};
    const herdr = herdrColumn(facts, task.endpoint && task.endpoint.target);
    const decisions = Array.isArray(hints.open_decisions) ? hints.open_decisions : [];
    for (const d of decisions) {
      rows.push(
        makeRow({
          tag: decisionTag(d.verb),
          extra: d.key || '-',
          id: task.id,
          text: d.summary,
          repo: taskRepo(task),
          ageSeconds: statusLogAge(facts, task),
          paneId: herdr.paneId,
          focusable: Boolean(herdr.paneId),
        }),
      );
    }
    if (hints.blocked_event && !decisions.some((d) => d.verb === 'blocked')) {
      rows.push(
        makeRow({
          tag: 'blocked',
          extra: '-',
          id: task.id,
          text: hints.last_event_text || 'blocked',
          repo: taskRepo(task),
          ageSeconds: statusLogAge(facts, task),
          paneId: herdr.paneId,
          focusable: Boolean(herdr.paneId),
        }),
      );
    }
    // Green-unmerged: the worker said done with a PR and the backlog row is
    // still open. Secondmate agents answer many requests with "done" lines, so
    // that kind is excluded here (their PRs surface through their own ledger).
    const cs = task.current_state || {};
    const backlogRow = backlogById.get(task.id);
    if (task.kind !== 'secondmate' && cs.state === 'done' && task.pr && task.pr.url && (!backlogRow || backlogRow.state !== 'done')) {
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
          focusable: Boolean(herdr.paneId),
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

  for (const ledger of facts.ledgers || []) {
    const summary = ledger.summary || {};
    const queued = Array.isArray(summary.queued) ? summary.queued : [];
    const queuedById = new Map(queued.map((q) => [q.id, q]));
    for (const d of Array.isArray(summary.decisions_open) ? summary.decisions_open : []) {
      if (d.hold_bucket && d.hold_bucket !== 'live') continue;
      const q = queuedById.get(d.id);
      rows.push(
        makeRow({
          tag: decisionTag(d.verb),
          extra: d.key && d.key !== d.id ? d.key : '-',
          id: d.id,
          text: d.reason && d.reason !== d.summary ? `${d.summary} · ${d.reason}` : d.summary,
          repo: q ? q.repo : '-',
          home: homeLabel(ledger),
          ageSeconds: daysToSeconds(d.hold_age_days),
        }),
      );
    }
  }

  const order = { blocked: 0, decide: 1, hold: 2, 'merge?': 3 };
  return rows
    .map((r, i) => ({ r, i }))
    .sort((a, b) => (order[a.r.tag] ?? 9) - (order[b.r.tag] ?? 9) || a.i - b.i)
    .map((x) => x.r);
}

// --------------------------------------------------------- Ready for review
function recordedPrs(facts) {
  const snap = facts.snapshot || {};
  const out = new Map();
  for (const task of Array.isArray(snap.tasks) ? snap.tasks : []) {
    if (task.pr && task.pr.url) out.set(task.pr.url, { url: task.pr.url, task: task.id, source: task.pr.source || 'meta' });
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

function reviewRows(facts) {
  const rows = [];
  const recorded = recordedPrs(facts);
  const prs = facts.prs || { enabled: false };
  const seen = new Set();
  if (prs.enabled && Array.isArray(prs.candidate_prs)) {
    for (const c of prs.candidate_prs) {
      seen.add(c.url);
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
function inflightRows(facts) {
  const rows = [];
  const snap = facts.snapshot || {};
  for (const task of Array.isArray(snap.tasks) ? snap.tasks : []) {
    const cs = task.current_state || {};
    const herdr = herdrColumn(facts, task.endpoint && task.endpoint.target);
    const doing = cs.detail || (task.hints && task.hints.last_event_text) || (task.paths && task.paths.status_log && task.paths.status_log.last_event && task.paths.status_log.last_event.note) || '';
    const kind = task.kind && task.kind !== 'ship' && task.kind !== 'task' ? `(${task.kind}) ` : '';
    rows.push(
      makeRow({
        tag: cs.state || 'unknown',
        extra: herdr.extra,
        id: task.id,
        text: `${kind}${doing}`,
        repo: taskRepo(task),
        ageSeconds: statusLogAge(facts, task),
        paneId: herdr.paneId,
        focusable: Boolean(herdr.paneId),
      }),
    );
  }
  for (const ledger of facts.ledgers || []) {
    const summary = ledger.summary || {};
    const endpoints = Array.isArray(summary.endpoints) ? summary.endpoints : [];
    const endpointById = new Map(endpoints.map((e) => [e.id, e]));
    const covered = new Set();
    for (const child of Array.isArray(summary.active_children) ? summary.active_children : []) {
      covered.add(child.id);
      const ep = endpointById.get(child.id);
      const herdr = herdrColumn(facts, ep && ep.endpoint ? ep.endpoint.target : null);
      const kind = child.kind && child.kind !== 'ship' && child.kind !== 'task' ? `(${child.kind}) ` : '';
      rows.push(
        makeRow({
          tag: child.state || 'working',
          extra: herdr.extra,
          id: child.id,
          text: `${kind}${child.doing || child.name || ''}`,
          repo: child.repo,
          home: homeLabel(ledger),
          ageSeconds: childStatusAge(facts, ledger, child.id),
          paneId: herdr.paneId,
          focusable: Boolean(herdr.paneId) && !ledger.remote,
        }),
      );
    }
    for (const ep of endpoints) {
      if (covered.has(ep.id)) continue;
      const herdr = herdrColumn(facts, ep.endpoint ? ep.endpoint.target : null);
      rows.push(
        makeRow({
          tag: ep.state || 'unknown',
          extra: herdr.extra,
          id: ep.id,
          text: `endpoint ${ep.endpoint && ep.endpoint.target ? ep.endpoint.target : '?'} (${ep.source || 'pane'})`,
          repo: '-',
          home: homeLabel(ledger),
          ageSeconds: childStatusAge(facts, ledger, ep.id),
          paneId: herdr.paneId,
          focusable: Boolean(herdr.paneId) && !ledger.remote,
        }),
      );
    }
  }
  const order = { working: 0, blocked: 1, 'needs-decision': 1, unknown: 2, done: 3, failed: 4 };
  return rows
    .map((r, i) => ({ r, i }))
    .sort((a, b) => (order[a.r.tag] ?? 2) - (order[b.r.tag] ?? 2) || a.i - b.i)
    .map((x) => x.r);
}

// ----------------------------------------------------------------- Findings
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
    const abs = r.report_path.startsWith('/') ? r.report_path : `${facts.fmHome}/${r.report_path}`;
    rows.push(
      makeRow({
        tag: r.kind || 'report',
        extra: r.completion && r.completion.verb ? r.completion.verb : '-',
        id: r.id,
        text: relativeTo(r.report_path, facts.fmHome),
        repo: r.repo,
        ageSeconds: ageSince(facts.now, facts.mtime(abs)) ?? ageSince(facts.now, parseTime(r.completion && r.completion.date)),
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
    const abs = rec.report_path.startsWith('/') ? rec.report_path : `${home}/${rec.report_path}`;
    rows.push(
      makeRow({
        tag: 'report',
        extra: rec.completion && rec.completion.verb ? rec.completion.verb : '-',
        id: rec.id,
        text: rec.report_path,
        repo: '-',
        home: homeLabel(ledger),
        ageSeconds: ageSince(facts.now, facts.mtime(abs)) ?? ageSince(facts.now, parseTime(rec.completion && rec.completion.date)),
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
        ageSeconds: ageSince(facts.now, parseTime(date)),
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
        ageSeconds: ageSince(facts.now, parseTime(date)),
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

function paneHeader(facts, pane, count) {
  const parts = [`${pane.title} (${count})`, snapshotLabel(facts), herdrLabel(facts.herdr)];
  if (pane.id === 'review') {
    const prs = facts.prs || { enabled: false };
    if (!prs.enabled) parts.push('checks not fetched');
    else if (prs.error) parts.push('checks failed');
    else if (prs.fetchedAt) parts.push(`checks ${fmtAge(facts.now - prs.fetchedAt)} ago`);
    else parts.push('checks pending');
  }
  return parts.join(' · ');
}

export function buildModel(facts) {
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
  const panes = PANES.map((p) => {
    const rows = builders[p.id](f);
    return { id: p.id, title: p.title, empty: p.empty, rows, header: paneHeader(f, p, rows.length) };
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
      ledgerErrors: f.ledgers.filter((l) => l.error).map((l) => `${l.id || basename(l.home)}: ${l.error}`),
    },
  };
}
