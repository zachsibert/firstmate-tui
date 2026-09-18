// lib/sources.mjs - every read the board performs against firstmate homes and
// GitHub. Read-only by contract: it runs the fleet snapshot script, reads
// ledgers, stats files, reads the verbs of a task's status log and asks
// GitHub through `gh api graphql` (and, once at startup, `gh api user` for
// the captain's login). It never writes into
// FM_HOME, a project or a state directory, and every command is an argv
// spawn, never a shell string.

import { spawn } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { basename, parseTime, repoFromUrl } from './text.mjs';
import { whichOnPath } from './viewer.mjs';
import { parseReleases, RELEASES_PER_PAGE } from './settings.mjs';
import { recordedPrs, TERMINAL_WINDOW_SECONDS } from './model.mjs';
import { configuredRepos, passesLabelRule } from './config.mjs';
import { identityKnown, resolveIdentity } from './identity.mjs';

// Run a command to completion, bounded by timeoutMs. Resolves to { out, error,
// stdout }: stdout on exit 0, else the last stderr line (or the timeout /
// spawn failure); `stdout` is whatever the command printed either way, for
// the one caller that can read a partial answer (the PR lookup).
function run(cmd, args, { env, timeoutMs, cwd }) {
  return new Promise((resolve) => {
    let out = '';
    let err = '';
    let done = false;
    const child = spawn(cmd, args, { env, cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      child.kill('SIGKILL');
      resolve({ out: null, stdout: out, error: `timed out after ${Math.round(timeoutMs / 1000)} s` });
    }, timeoutMs);
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('error', (e) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ out: null, stdout: out, error: e.message });
    });
    child.on('close', (code) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (code !== 0) {
        resolve({ out: null, stdout: out, error: `exit ${code}: ${err.trim().split('\n').slice(-1)[0] || 'no stderr'}` });
        return;
      }
      resolve({ out, stdout: out, error: null });
    });
  });
}

async function runJson(cmd, args, opts) {
  const r = await run(cmd, args, opts);
  if (r.error) return { value: null, error: r.error };
  try {
    return { value: JSON.parse(r.out), error: null };
  } catch (e) {
    return { value: null, error: `bad JSON: ${e.message}` };
  }
}

export function mtime(path) {
  try {
    return Math.floor(statSync(path).mtimeMs / 1000);
  } catch {
    return null;
  }
}

// The verbs of a task's status log (`state/<id>.status`, one `verb: text`
// line per event), in file order, lower-cased: ['working', 'done', 'working'].
// null when the file cannot be read, so the model can tell "no done line"
// from "no log". lib/model.mjs reads it to tell a task repairing its PR (a
// `done:` line, then `working:` again) from one on its first pass.
export function statusVerbs(path) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch {
    return null;
  }
  const verbs = [];
  for (const line of text.split('\n')) {
    const m = /^([A-Za-z][A-Za-z-]*):/.exec(line);
    if (m) verbs.push(m[1].toLowerCase());
  }
  return verbs;
}

function isDir(path) {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

// Homes named in FM_HOME/data/secondmates.md. Each registry line looks like
// "- <name> - <charter> (home: <path>; scope: ...)". Only the name and the
// home path are used here.
export function registeredHomes(fmHome) {
  let text;
  try {
    text = readFileSync(`${fmHome}/data/secondmates.md`, 'utf8');
  } catch {
    return [];
  }
  const out = [];
  for (const line of text.split('\n')) {
    const m = /^-\s+([^\s]+)\s+-.*\(home:\s*([^;)]+)/.exec(line);
    if (m) out.push({ id: m[1], home: m[2].trim().replace(/\/+$/, '') });
  }
  return out;
}

// The final list of secondmate homes: registry plus --home extras, deduped by
// path, never including FM_HOME itself.
export function discoverHomes(fmHome, extraHomes) {
  const seen = new Set([fmHome.replace(/\/+$/, '')]);
  const out = [];
  for (const h of registeredHomes(fmHome)) {
    if (seen.has(h.home)) continue;
    seen.add(h.home);
    out.push(h);
  }
  for (const raw of extraHomes || []) {
    const home = raw.replace(/\/+$/, '');
    if (seen.has(home)) continue;
    seen.add(home);
    out.push({ id: null, home });
  }
  return out;
}

export async function runSnapshot(fmHome, { timeoutMs }) {
  const script = `${fmHome}/bin/fm-fleet-snapshot.sh`;
  const r = await runJson('bash', [script, '--json'], {
    env: { ...process.env, FM_HOME: fmHome },
    cwd: fmHome,
    timeoutMs,
  });
  if (r.value && r.value.schema && r.value.schema !== 'fm-fleet-snapshot.v1') {
    return { value: r.value, error: `unexpected snapshot schema ${r.value.schema}` };
  }
  return r;
}

// ---------------------------------------------------------------- identity
//
// The two rungs of lib/identity.mjs that run a command: gh's logged-in login
// and git's github.user. Each answers { value, error } for resolveIdentity.
// `gh api user --jq .login` is one REST call, made once at startup and
// cached by the caller for the session.

const GH_ENV = { GH_PROMPT_DISABLED: '1', GH_NO_UPDATE_NOTIFIER: '1' };

export async function ghLogin({ timeoutMs = GH_TIMEOUT_MS, env = process.env } = {}) {
  const r = await run('gh', ['api', 'user', '--jq', '.login'], { env: { ...env, ...GH_ENV }, timeoutMs: Math.min(timeoutMs, GH_TIMEOUT_MS) });
  return r.error ? { value: null, error: r.error } : { value: r.out.trim(), error: null };
}

export async function gitLogin({ timeoutMs = GH_TIMEOUT_MS, env = process.env } = {}) {
  const r = await run('git', ['config', '--get', 'github.user'], { env, timeoutMs: Math.min(timeoutMs, GH_TIMEOUT_MS) });
  // `git config --get` exits 1 for an unset key: that is "not set", not a failure.
  if (r.error) return { value: null, error: /^exit 1: no stderr$/.test(r.error) ? 'github.user not set' : r.error };
  return { value: r.out.trim(), error: null };
}

// The live resolution: the config file first, then gh (unless `askGh` is
// false: --no-prs, or gh not on PATH, so no GitHub call is made), then git.
export async function resolveIdentityLive({ config, askGh = true, timeoutMs = GH_TIMEOUT_MS, env = process.env } = {}) {
  const fromConfig = config && config.identity ? config.identity.github_login : null;
  const quick = resolveIdentity({ config: fromConfig });
  if (identityKnown(quick)) return quick;
  const gh = askGh ? await ghLogin({ timeoutMs, env }) : null;
  const ghRung = gh || { value: null, error: whichOnPath('gh', env) ? 'not asked (--no-prs)' : 'gh not on PATH' };
  const early = resolveIdentity({ config: fromConfig, gh: ghRung, git: { value: null, error: 'not asked' } });
  if (identityKnown(early)) return early;
  const git = await gitLogin({ timeoutMs, env });
  return resolveIdentity({ config: fromConfig, gh: ghRung, git });
}

// ------------------------------------------------------------- live PR data
//
// The two PR panes' live data: what the captain authored (My PRs) and what
// the captain was asked to review (To review), each PR with its check state,
// status, title, base branch, creation time, author, labels and the
// captain's own latest review. The board asks GitHub itself, through bounded
// searches in `gh api graphql` (`gh search prs --json` carries no review
// decision, checks, base or head branch, so the search API is called
// directly). Per tick, at most four searches, all started together, each
// asking for the PR_LIMIT most recently updated matches:
//   My PRs open       is:pr is:open author:<login>
//   My PRs tail       is:pr author:<login> closed:>=<12 hours ago>
//   To review open    is:pr is:open review-requested:<login> -author:<login> repo:a repo:b ...
//   To review tail    the same with closed:>=<12 hours ago> in place of is:open
// A merged PR counts as closed, so the two tails carry what finished inside
// TERMINAL_WINDOW_SECONDS, and keepFetchedPr drops the rest before the model
// sees it. review-requested:<login> matches a request to the login and a
// request to a team it belongs to (user-review-requested: would match the
// direct requests only). The To review scope is the candidate repositories
// of the fleet snapshot plus every repository the config file names; the
// scope goes into the query as repo: qualifiers while the query fits
// GitHub's 256-character limit and is applied again in code either way, so a
// long scope costs nothing but a wider search. The two To review searches
// are skipped when the scope is empty. Recorded task PRs that neither My PRs
// search returned (a bot author, or a PR older than the cap) are looked up
// in one more GraphQL call with aliased repository { pullRequest } fields,
// bounded by PR_LIMIT; a lookup that fails leaves the model's `-` row.
// The candidate rule and the checks mapping copy firstmate's
// bin/fm-bearings-snapshot.sh, which stays as the fallback for My PRs when
// gh is not on PATH (recorded PRs only, open ones only, none of the new
// fields); To review has no fallback and says so.

export const PR_REPOS = 10; // FM_BEARINGS_PR_REPOS: candidate repositories per fetch
export const PR_LIMIT = 50; // PRs asked for per search (newest-updated first) and recorded PRs looked up per tick
export const GH_TIMEOUT_MS = 20000; // FM_BEARINGS_PR_TIMEOUT: bound on one gh call
export const SEARCH_QUERY_MAX = 256; // GitHub refuses a longer search string
export const GH_PR_SORT = 'sort:updated-desc';

// The PullRequest fields every GraphQL answer carries. `commits(last: 1)` is
// the head commit, whose statusCheckRollup contexts are the CHECKS column
// (each a CheckRun { status, conclusion } or a StatusContext { state }, the
// two shapes checksState reads); latestReviews is one review per reviewer,
// from which the identity's own APPROVED or CHANGES_REQUESTED is taken.
// mergeStateStatus is GitHub's merge-box word (CLEAN, DIRTY, BLOCKED,
// UNSTABLE, BEHIND, HAS_HOOKS, DRAFT, UNKNOWN); with `mergeable` it tells a
// PR that is ready for the captain from one that conflicts with its base.
export const GH_PR_FIELDS = 'number title url headRefName baseRefName reviewDecision mergeable mergeStateStatus isDraft state createdAt mergedAt closedAt author { login } repository { nameWithOwner } labels(first: 30) { nodes { name } } latestReviews(first: 30) { nodes { state author { login } } } commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { __typename ... on CheckRun { status conclusion } ... on StatusContext { state } } } } } } }';
export const SEARCH_GRAPHQL = `query($q: String!, $n: Int!) { search(query: $q, type: ISSUE, first: $n) { issueCount nodes { ... on PullRequest { ${GH_PR_FIELDS} } } } }`;

// owner/name from a GitHub URL or remote (https://github.com/o/r/pull/1,
// git@github.com:o/r.git), or null, the way the script's repo_slug reads them.
export function repoSlug(url) {
  const m = /github\.com[:/]([^/\s]+\/[^/\s]+)/.exec(String(url || ''));
  if (!m) return null;
  return m[1].replace(/\.git$/, '') || null;
}

// The CHECKS cell of one PR from its check contexts (gh's statusCheckRollup
// list, or the GraphQL contexts nodes: the same two shapes), mapped exactly
// as the script maps it: no checks is none; any failure-like conclusion is
// failing; any check neither completed nor successful is pending; else
// passing.
const FAILING = new Set(['FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED']);
export function checksState(rollup) {
  const checks = (Array.isArray(rollup) ? rollup : []).map((c) => c || {});
  if (checks.length === 0) return 'none';
  if (checks.some((c) => FAILING.has(String(c.conclusion ?? c.state ?? '')))) return 'failing';
  if (checks.some((c) => String(c.status ?? '') !== 'COMPLETED' && String(c.state ?? '') !== 'SUCCESS')) return 'pending';
  return 'passing';
}

// One gh PR record -> the candidate_prs[] shape lib/model.mjs reads. `task` is
// the worker id when the head branch follows firstmate's fm/<task> naming.
// `state` is gh's OPEN, MERGED or CLOSED (null when the record carries none,
// which the model reads as open); `merged_at` and `closed_at` are ISO 8601 or
// null, and `title` and `base` are null rather than '' when absent so the
// model can fall back to the recorded task's title and a '-' cell. The
// record may be gh's --json shape (statusCheckRollup a list) or a GraphQL
// node (author, labels, latestReviews, commits): the extra fields read null
// or empty when absent.
export function projectPr(pr, repo) {
  const head = typeof pr.headRefName === 'string' ? pr.headRefName : '';
  const text = (v) => (typeof v === 'string' && v.trim() ? v : null);
  const contexts = pr.commits && Array.isArray(pr.commits.nodes) && pr.commits.nodes[0] && pr.commits.nodes[0].commit && pr.commits.nodes[0].commit.statusCheckRollup ? pr.commits.nodes[0].commit.statusCheckRollup.contexts : null;
  const rollup = contexts && Array.isArray(contexts.nodes) ? contexts.nodes : pr.statusCheckRollup;
  return {
    num: pr.number === null || pr.number === undefined ? '-' : String(pr.number),
    repo: repo || (pr.repository && pr.repository.nameWithOwner) || repoSlug(pr.url) || '-',
    task: head.startsWith('fm/') ? head.slice(3) : '-',
    url: pr.url ?? '-',
    title: text(pr.title),
    base: text(pr.baseRefName),
    review: pr.reviewDecision ?? 'none',
    mergeable: pr.mergeable ?? 'UNKNOWN',
    merge_state: text(pr.mergeStateStatus) ? String(pr.mergeStateStatus).toUpperCase() : null,
    checks: checksState(rollup),
    created_at: text(pr.createdAt),
    draft: pr.isDraft === true,
    state: text(pr.state) ? String(pr.state).toUpperCase() : null,
    merged_at: text(pr.mergedAt),
    closed_at: text(pr.closedAt),
    author: pr.author && typeof pr.author.login === 'string' && pr.author.login ? pr.author.login : null,
    labels: pr.labels && Array.isArray(pr.labels.nodes) ? pr.labels.nodes.map((n) => (n && typeof n.name === 'string' ? n.name : null)).filter(Boolean) : [],
    requested: false,
    my_review: null,
    pane: 'mine',
  };
}

// The identity's own latest review on a PR, APPROVED or CHANGES_REQUESTED,
// else null (a comment-only or dismissed review says nothing about the
// captain's verdict).
export function myReview(node, login) {
  const reviews = node && node.latestReviews && Array.isArray(node.latestReviews.nodes) ? node.latestReviews.nodes : [];
  for (const r of reviews) {
    if (!r || !r.author || r.author.login !== login) continue;
    return r.state === 'APPROVED' || r.state === 'CHANGES_REQUESTED' ? r.state : null;
  }
  return null;
}

// Whether a fetched PR is worth handing to the model at `now` (epoch seconds):
// every open PR, and a merged or closed one that finished less than
// TERMINAL_WINDOW_SECONDS ago (mergedAt for a merged PR, closedAt otherwise).
// A finished PR with no usable time stamp is dropped, since nothing could
// place it inside the window; lib/model.mjs applies the same window again
// against the frame's own `now`, so a row leaves the pane on time between
// fetches too.
export function keepFetchedPr(pr, now) {
  const state = String(pr.state || 'OPEN').toUpperCase();
  if (state !== 'MERGED' && state !== 'CLOSED') return true;
  const finished = parseTime(state === 'MERGED' ? pr.merged_at || pr.closed_at : pr.closed_at);
  if (finished === null) return false;
  return Math.max(0, now - finished) < TERMINAL_WINDOW_SECONDS;
}

// Candidate repositories in the script's order: the repository of every PR URL
// on the snapshot's tasks, then the origin remote of each live non-secondmate
// task worktree (git remote get-url, an argv spawn), deduped, at most PR_REPOS.
export async function candidateRepos(snapshot, { timeoutMs, env = process.env } = {}) {
  const tasks = snapshot && Array.isArray(snapshot.tasks) ? snapshot.tasks : [];
  const repos = [];
  const add = (slug) => {
    if (slug && !repos.includes(slug)) repos.push(slug);
  };
  for (const t of tasks) add(repoSlug(t.pr && t.pr.url));
  const worktrees = [
    ...new Set(
      tasks
        .filter((t) => t.kind !== 'secondmate')
        .map((t) => (t.paths && t.paths.worktree ? t.paths.worktree.path : null))
        .filter((p) => typeof p === 'string' && p && isDir(p)),
    ),
  ];
  const origins = await Promise.all(worktrees.map((wt) => run('git', ['-C', wt, 'remote', 'get-url', 'origin'], { env, timeoutMs })));
  for (const r of origins) if (!r.error) add(repoSlug(r.out.trim()));
  return repos.slice(0, PR_REPOS);
}

// The To review scope: the candidate repositories, then the repositories the
// config file names, deduped without case (GitHub's own rule for repository
// names; the first spelling is kept), in that order.
export function reviewScope(candidates, config) {
  const out = [];
  const seen = new Set();
  for (const r of [...(candidates || []), ...configuredRepos(config)]) {
    if (!r || seen.has(r.toLowerCase())) continue;
    seen.add(r.toLowerCase());
    out.push(r);
  }
  return out;
}

// Whether a fetched repository name is in the scope, compared without case.
export function inScope(scope, repo) {
  const want = String(repo || '').toLowerCase();
  return scope.some((r) => r.toLowerCase() === want);
}

// The ISO time TERMINAL_WINDOW_SECONDS before `now`, in the +00:00 form
// GitHub's search qualifiers take.
export function closedSince(now) {
  return new Date((now - TERMINAL_WINDOW_SECONDS) * 1000).toISOString().replace(/\.\d{3}Z$/, '+00:00');
}

// The four search strings (lib/sources.mjs header). The To review pair names
// its scope with repo: qualifiers when the whole scope fits under
// SEARCH_QUERY_MAX; otherwise the qualifiers are left out as a set and the
// scope filter in code does the work alone (a partial list would exclude the
// rest on GitHub's side).
export function searchQueries(login, { now, scope = [] }) {
  const since = closedSince(now);
  const mine = { open: `is:pr is:open author:${login} ${GH_PR_SORT}`, tail: `is:pr author:${login} closed:>=${since} ${GH_PR_SORT}` };
  const repoTerms = scope.map((r) => `repo:${r}`).join(' ');
  const withRepos = (base) => {
    const full = `${base} ${repoTerms} ${GH_PR_SORT}`;
    return full.length <= SEARCH_QUERY_MAX ? full : `${base} ${GH_PR_SORT}`;
  };
  const toreview = {
    open: withRepos(`is:pr is:open review-requested:${login} -author:${login}`),
    tail: withRepos(`is:pr review-requested:${login} -author:${login} closed:>=${since}`),
  };
  return { mine, toreview };
}

// The aliased lookup of recorded PRs: r0: repository(owner:, name:) {
// pullRequest(number:) { ...fields } } per target.
export function lookupGraphql(targets) {
  const fields = targets.map((t, i) => `r${i}: repository(owner: ${JSON.stringify(t.owner)}, name: ${JSON.stringify(t.name)}) { pullRequest(number: ${t.number}) { ${GH_PR_FIELDS} } }`);
  return `query { ${fields.join(' ')} }`;
}

// One GraphQL search: { rows, capped, error }. `pane` and `requested` are
// stamped on every row; `login` picks the identity's own review out.
async function ghSearch(q, { login, pane, requested, timeoutMs, env, now }) {
  const args = ['api', 'graphql', '-f', `query=${SEARCH_GRAPHQL}`, '-f', `q=${q}`, '-F', `n=${PR_LIMIT}`];
  const r = await runJson('gh', args, { env: { ...env, ...GH_ENV }, timeoutMs: Math.min(timeoutMs, GH_TIMEOUT_MS) });
  if (r.error) return { rows: [], capped: false, error: r.error };
  const search = r.value && r.value.data && r.value.data.search ? r.value.data.search : null;
  if (!search) return { rows: [], capped: false, error: r.value && Array.isArray(r.value.errors) && r.value.errors[0] ? `GraphQL: ${r.value.errors[0].message}` : 'no search data in the answer' };
  const nodes = Array.isArray(search.nodes) ? search.nodes.filter((n) => n && typeof n === 'object' && n.url) : [];
  const rows = nodes.map((n) => ({ ...projectPr(n, null), requested, my_review: myReview(n, login), pane })).filter((p) => keepFetchedPr(p, now));
  return { rows, capped: Number(search.issueCount) > PR_LIMIT, error: null };
}

// The recorded PRs the My PRs searches did not return, looked up in one
// call. A missing PR (deleted, or a repository the account cannot see) comes
// back null beside the others: gh exits 1 when the answer carries errors but
// still prints the body, so the body is read when it parses and the rest of
// the lookups stand.
async function ghLookup(urls, { login, timeoutMs, env, now }) {
  const targets = [];
  for (const url of urls) {
    const pr = repoFromUrl(url);
    if (!pr) continue;
    const [owner, name] = pr.repo.split('/');
    targets.push({ owner, name, number: Number(pr.num), url });
  }
  if (!targets.length) return { rows: [], error: null };
  const r = await run('gh', ['api', 'graphql', '-f', `query=${lookupGraphql(targets)}`], { env: { ...env, ...GH_ENV }, timeoutMs: Math.min(timeoutMs, GH_TIMEOUT_MS) });
  let body = null;
  try {
    body = JSON.parse(r.stdout || r.out || '');
  } catch {
    body = null;
  }
  const data = body && body.data && typeof body.data === 'object' ? body.data : null;
  if (!data) return { rows: [], error: r.error || 'no lookup data in the answer' };
  const rows = [];
  targets.forEach((t, i) => {
    const node = data[`r${i}`] && data[`r${i}`].pullRequest;
    if (!node || typeof node !== 'object' || !node.url) return;
    const row = { ...projectPr(node, null), my_review: myReview(node, login), pane: 'mine' };
    if (keepFetchedPr(row, now)) rows.push(row);
  });
  return { rows, error: null };
}

// The board's own fetch: at most four searches at once, then the lookup of
// the recorded PRs the author searches missed. Returns { mine, toreview } with
// each pane's { rows, error, note } (To review also carries `scope`): a pane
// whose searches all failed is a failed pane (its previous rows stay on
// screen, and the failure is named once); a pane with one search failed lists
// what the other returned and notes the failure; a capped search is noted.
export async function runGhPrs(snapshot, { identity, config, timeoutMs, env = process.env, now = () => Math.floor(Date.now() / 1000) }) {
  const at = now();
  const login = identity.login;
  const candidates = await candidateRepos(snapshot, { timeoutMs, env });
  const scope = reviewScope(candidates, config);
  const q = searchQueries(login, { now: at, scope });
  const opts = { login, timeoutMs, env, now: at };
  const searches = [ghSearch(q.mine.open, { ...opts, pane: 'mine', requested: false }), ghSearch(q.mine.tail, { ...opts, pane: 'mine', requested: false })];
  if (scope.length) searches.push(ghSearch(q.toreview.open, { ...opts, pane: 'toreview', requested: true }), ghSearch(q.toreview.tail, { ...opts, pane: 'toreview', requested: true }));
  const [mineOpen, mineTail, reviewOpen, reviewTail] = await Promise.all(searches);

  const collect = (name, results, filter) => {
    const failed = results.filter((r) => r.error);
    if (results.length && failed.length === results.length) return { rows: [], error: `${name}: ${failed[0].error}`, note: null };
    const seen = new Set();
    const rows = [];
    for (const r of results) {
      for (const row of r.rows) {
        if (seen.has(row.url) || !filter(row)) continue;
        seen.add(row.url);
        rows.push(row);
      }
    }
    const notes = [];
    if (failed.length) notes.push(`${name}: ${failed.length} of ${results.length} searches failed (${failed[0].error})`);
    if (results.some((r) => r.capped)) notes.push(`${name}: search capped at the ${PR_LIMIT} newest-updated PRs`);
    return { rows, error: null, note: notes.length ? notes.join('; ') : null, seen };
  };
  const mine = collect('My PRs', [mineOpen, mineTail], () => true);
  const toreview = scope.length ? collect("Teammates' PRs", [reviewOpen, reviewTail], (row) => row.author !== login && inScope(scope, row.repo) && passesLabelRule(config, row.repo, row.labels)) : { rows: [], error: null, note: null };
  toreview.scope = scope;
  delete toreview.seen;

  // The recorded PRs the author searches did not return, unfinished tasks
  // first, at most PR_LIMIT of them.
  if (!mine.error) {
    const recorded = recordedPrs({ snapshot }).sort((a, b) => Number(a.done) - Number(b.done));
    const missing = recorded.filter((r) => !mine.seen.has(r.url)).map((r) => r.url).slice(0, PR_LIMIT);
    if (missing.length) {
      const looked = await ghLookup(missing, opts);
      if (looked.error) mine.note = [mine.note, `recorded PR lookup failed (${looked.error})`].filter(Boolean).join('; ');
      for (const row of looked.rows) {
        if (mine.seen.has(row.url)) continue;
        mine.seen.add(row.url);
        mine.rows.push(row);
      }
    }
  }
  delete mine.seen;
  return { mine, toreview };
}

// The fallback: fm-bearings-snapshot.sh --include-prs, which runs its own fleet
// snapshot and then gh, lists open PRs only and carries no creation time,
// title, base branch or draft flag (its rows read IN REVIEW or APPROVED from
// the review decision alone, BASE '-', and the recorded task's title).
export async function runBearingsPrs(fmHome, { timeoutMs }) {
  const script = `${fmHome}/bin/fm-bearings-snapshot.sh`;
  const r = await runJson('bash', [script, '--json', '--include-prs'], {
    env: { ...process.env, FM_HOME: fmHome },
    cwd: fmHome,
    timeoutMs,
  });
  if (r.error) return { candidate_prs: [], error: r.error, note: null };
  // Without gh the script still exits 0, lists nothing and says so in its prs
  // status line ("unavailable (gh not found)"). Since PR data is on by default,
  // the board treats that as a failed fetch and names it, not as an empty list.
  const status = typeof r.value.prs === 'string' ? r.value.prs : '';
  if (/^unavailable\b/.test(status)) return { candidate_prs: [], error: status, note: null };
  const rows = (Array.isArray(r.value.candidate_prs) ? r.value.candidate_prs : []).map((c) => ({ ...c, pane: 'mine' }));
  return { candidate_prs: rows, error: null, note: null };
}

export const GH_MISSING = 'gh not on PATH';

// The live PR data of one refresh: { mine, toreview, note } with each pane's
// { rows, error, note } (To review also `scope` and, without gh,
// `unavailable`). With gh on PATH it is the board's own fetch against the
// snapshot just taken (or the last good one when this tick's failed) for the
// resolved identity; without gh the firstmate script runs for My PRs instead
// and `note` says so, for the footer to show once, while To review lists
// nothing and says why. An unknown identity fetches nothing: both panes come
// back empty with no error, and the model draws the identity row.
export async function fetchPrs(fmHome, snapshot, { identity, config, timeoutMs, env = process.env }) {
  const empty = () => ({ rows: [], error: null, note: null });
  if (!whichOnPath('gh', env)) {
    const r = await runBearingsPrs(fmHome, { timeoutMs });
    return {
      mine: { rows: r.candidate_prs, error: r.error, note: null },
      toreview: { ...empty(), scope: [], unavailable: GH_MISSING },
      note: r.error ? null : 'gh not on PATH: PR data from fm-bearings-snapshot.sh, open PRs only, without titles, base branches or PR creation times; Teammates\' PRs needs gh',
    };
  }
  if (!identityKnown(identity)) return { mine: empty(), toreview: { ...empty(), scope: [] }, note: null };
  if (!snapshot) return { mine: { ...empty(), error: 'no fleet snapshot to name the candidate repositories' }, toreview: { ...empty(), scope: [], error: 'no fleet snapshot to name the candidate repositories' }, note: null };
  const r = await runGhPrs(snapshot, { identity, config, timeoutMs, env });
  const notes = [r.mine.note, r.toreview.note].filter(Boolean);
  return { mine: r.mine, toreview: r.toreview, note: notes.length ? `PR fetch: ${notes.join('; ')}` : null };
}

// The GitHub releases of the board's own repository, for the Settings page:
// the latest stable release (GET /releases/latest, never a prerelease) and
// the prereleases (GET /releases, newest first). Fetched only when the page
// opens and on r inside it, never on the refresh tick. curl runs as an argv
// spawn (`--curl-cmd`, default curl; tests point it at tests/fake-curl.sh),
// and each reply is JSON.parse'd; a failed call keeps curl's last stderr line
// as its error so the page can show it verbatim.
export async function fetchReleases({ repo, curlCmd = null, timeoutMs = 20000 }) {
  const argv = Array.isArray(curlCmd) && curlCmd.length ? curlCmd : ['curl'];
  const api = `https://api.github.com/repos/${repo}/releases`;
  const get = (url) => runJson(argv[0], [...argv.slice(1), '-fsSL', '--retry', '2', '--retry-delay', '1', '-H', 'Accept: application/vnd.github+json', url], { env: process.env, timeoutMs });
  const [latest, list] = await Promise.all([get(`${api}/latest`), get(`${api}?per_page=${RELEASES_PER_PAGE}`)]);
  return parseReleases({ latest, list });
}

// One secondmate ledger read. Returns { summary, error, generatedAt }.
export function readLedger(home) {
  const path = `${home}/state/home-summary.json`;
  try {
    const summary = JSON.parse(readFileSync(path, 'utf8'));
    if (summary.schema !== 'fm-secondmate-home-summary.v1') {
      return { summary: null, error: `unexpected ledger schema ${summary.schema}`, generatedAt: null };
    }
    return { summary, error: null, generatedAt: Number(summary.generated_epoch) || mtime(path) };
  } catch (e) {
    return { summary: null, error: e.code === 'ENOENT' ? 'no ledger' : e.message, generatedAt: null };
  }
}

// Merge the discovered homes with what the snapshot says about each one, then
// read every local ledger. A home the snapshot marks remote keeps the
// snapshot's (cached) record as its summary and is labelled accordingly.
export function collectLedgers(snapshot, homes) {
  const records = snapshot && snapshot.secondmate_current && Array.isArray(snapshot.secondmate_current.records) ? snapshot.secondmate_current.records : [];
  const byHome = new Map(records.map((r) => [String(r.home || '').replace(/\/+$/, ''), r]));
  const all = new Map();
  for (const h of homes) all.set(h.home, { id: h.id, home: h.home });
  for (const r of records) {
    const home = String(r.home || '').replace(/\/+$/, '');
    if (!home) continue;
    if (!all.has(home)) all.set(home, { id: r.id, home });
    else if (!all.get(home).id) all.get(home).id = r.id;
  }
  const out = [];
  for (const entry of all.values()) {
    const rec = byHome.get(entry.home);
    const remote = Boolean(rec && rec.remote);
    const fromCache = Boolean(rec && rec.provenance && rec.provenance.summary_source === 'remote-ledger-cache');
    let ledger = { id: entry.id || (rec && rec.id) || basename(entry.home), home: entry.home, remote, cached: fromCache, summary: null, error: null, generatedAt: null };
    if (!remote) {
      const read = readLedger(entry.home);
      ledger = { ...ledger, ...read };
    }
    if (!ledger.summary && rec) {
      ledger.summary = {
        active_children: rec.active_children || [],
        endpoints: rec.endpoints || [],
        decisions_open: rec.decisions_open || [],
        holds: Array.isArray(rec.holds) ? rec.holds : [],
        landed: Array.isArray(rec.landed) ? rec.landed : [],
        queued: Array.isArray(rec.queued) ? rec.queued : [],
        contributions: rec.contributions && typeof rec.contributions === 'object' ? rec.contributions : null,
      };
      ledger.cached = true;
      ledger.generatedAt = rec.freshness && rec.freshness.observed_at ? Math.floor(Date.parse(rec.freshness.observed_at) / 1000) || null : null;
      if (!remote) ledger.error = ledger.error || null;
    }
    out.push(ledger);
  }
  return out;
}
