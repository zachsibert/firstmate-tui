// lib/sources.mjs - every read the board performs against firstmate homes and
// GitHub. Read-only by contract: it runs the fleet snapshot script, reads
// ledgers, stats files and asks GitHub through `gh pr list`. It never writes
// into FM_HOME, a project or a state directory, and every command is an argv
// spawn, never a shell string.

import { spawn } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { basename, parseTime } from './text.mjs';
import { whichOnPath } from './viewer.mjs';
import { parseReleases, RELEASES_PER_PAGE } from './settings.mjs';
import { TERMINAL_WINDOW_SECONDS } from './model.mjs';

// Run a command to completion, bounded by timeoutMs. Resolves to { out, error }:
// stdout on exit 0, else the last stderr line (or the timeout / spawn failure).
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
      resolve({ out: null, error: `timed out after ${Math.round(timeoutMs / 1000)} s` });
    }, timeoutMs);
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('error', (e) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ out: null, error: e.message });
    });
    child.on('close', (code) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (code !== 0) {
        resolve({ out: null, error: `exit ${code}: ${err.trim().split('\n').slice(-1)[0] || 'no stderr'}` });
        return;
      }
      resolve({ out, error: null });
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

// ------------------------------------------------------------- live PR data
//
// Ready for review's live check state, status, title, base branch and, since
// the PR age landed, each PR's creation time. The board asks GitHub itself
// through `gh pr list`, with the candidate rule and the checks mapping of
// firstmate's bin/fm-bearings-snapshot.sh (its --include-prs block). Since the
// pane keeps a merged or closed PR on screen for TERMINAL_WINDOW_SECONDS after
// it finished, the call asks for every state (`--state all`), newest-updated
// first, so a PR that just merged is near the top whatever its age, and the
// filter below drops the finished PRs outside that window before they reach
// the model. `--search "sort:updated-desc"` is GitHub's search syntax, which
// gh passes through: verified on gh 2.96.0 against a live repository, the list
// comes back ordered by updatedAt descending with --state all. Fetching here
// also stops the fleet snapshot running twice per tick: the script runs its
// own before it asks GitHub. The script stays as the fallback when gh is not
// on PATH; it lists open PRs only and carries none of the new fields.

export const PR_REPOS = 10; // FM_BEARINGS_PR_REPOS: candidate repositories per fetch
export const PR_LIMIT = 50; // PRs kept per repository (every state, newest-updated first); one more is requested to see the cap
export const GH_TIMEOUT_MS = 20000; // FM_BEARINGS_PR_TIMEOUT: bound on one gh call
export const GH_PR_FIELDS = ['number', 'title', 'url', 'headRefName', 'baseRefName', 'reviewDecision', 'mergeable', 'statusCheckRollup', 'createdAt', 'isDraft', 'state', 'mergedAt', 'closedAt'];
export const GH_PR_SORT = 'sort:updated-desc';

// owner/name from a GitHub URL or remote (https://github.com/o/r/pull/1,
// git@github.com:o/r.git), or null, the way the script's repo_slug reads them.
export function repoSlug(url) {
  const m = /github\.com[:/]([^/\s]+\/[^/\s]+)/.exec(String(url || ''));
  if (!m) return null;
  return m[1].replace(/\.git$/, '') || null;
}

// The CHECKS cell of one PR from gh's statusCheckRollup, mapped exactly as the
// script maps it: no checks is none; any failure-like conclusion is failing;
// any check neither completed nor successful is pending; else passing.
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
// model can fall back to the recorded task's title and a '-' cell.
export function projectPr(pr, repo) {
  const head = typeof pr.headRefName === 'string' ? pr.headRefName : '';
  const text = (v) => (typeof v === 'string' && v.trim() ? v : null);
  return {
    num: pr.number === null || pr.number === undefined ? '-' : String(pr.number),
    repo,
    task: head.startsWith('fm/') ? head.slice(3) : '-',
    url: pr.url ?? '-',
    title: text(pr.title),
    base: text(pr.baseRefName),
    review: pr.reviewDecision ?? 'none',
    mergeable: pr.mergeable ?? 'UNKNOWN',
    checks: checksState(pr.statusCheckRollup),
    created_at: text(pr.createdAt),
    draft: pr.isDraft === true,
    state: text(pr.state) ? String(pr.state).toUpperCase() : null,
    merged_at: text(pr.mergedAt),
    closed_at: text(pr.closedAt),
  };
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

async function ghPrList(repo, { timeoutMs, env, now = () => Math.floor(Date.now() / 1000) }) {
  const args = ['pr', 'list', '--repo', repo, '--state', 'all', '--search', GH_PR_SORT, '--limit', String(PR_LIMIT + 1), '--json', GH_PR_FIELDS.join(',')];
  const r = await runJson('gh', args, { env: { ...env, GH_PROMPT_DISABLED: '1', GH_NO_UPDATE_NOTIFIER: '1' }, timeoutMs: Math.min(timeoutMs, GH_TIMEOUT_MS) });
  if (r.error) return { repo, rows: [], capped: false, error: r.error };
  const list = Array.isArray(r.value) ? r.value : [];
  const at = now();
  const rows = list
    .slice(0, PR_LIMIT)
    .map((p) => projectPr(p, repo))
    .filter((p) => keepFetchedPr(p, at));
  return { repo, rows, capped: list.length > PR_LIMIT, error: null };
}

// The board's own fetch: one gh pr list per candidate repository, all started
// at once. Every repository failing is a failed fetch (the previous data stays
// on screen); some failing is a success whose note names them, since the other
// repositories' rows are good.
export async function runGhPrs(snapshot, { timeoutMs, env = process.env }) {
  const repos = await candidateRepos(snapshot, { timeoutMs, env });
  const results = await Promise.all(repos.map((repo) => ghPrList(repo, { timeoutMs, env })));
  const failed = results.filter((r) => r.error);
  if (repos.length && failed.length === repos.length) {
    return { candidate_prs: [], error: `gh pr list ${failed[0].repo}: ${failed[0].error}`, note: null };
  }
  const notes = [];
  if (failed.length) notes.push(`${failed.length} of ${repos.length} repositories unavailable (${failed[0].repo}: ${failed[0].error})`);
  const capped = results.filter((r) => r.capped).map((r) => r.repo);
  if (capped.length) notes.push(`PR list capped at ${PR_LIMIT} newest-updated in ${capped.join(', ')}`);
  return { candidate_prs: results.flatMap((r) => r.rows), error: null, note: notes.length ? `PR fetch: ${notes.join('; ')}` : null };
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
  return { candidate_prs: Array.isArray(r.value.candidate_prs) ? r.value.candidate_prs : [], error: null, note: null };
}

// The live PR data of one refresh: { candidate_prs, error, note }. With gh on
// PATH it is the board's own fetch against the snapshot just taken (or the
// last good one when this tick's failed); without gh the firstmate script
// runs instead and `note` says so, for the footer to show once. `note` is
// advisory: fetchedAt and error are handled exactly as before.
export async function fetchPrs(fmHome, snapshot, { timeoutMs, env = process.env }) {
  if (!whichOnPath('gh', env)) {
    const r = await runBearingsPrs(fmHome, { timeoutMs });
    return { ...r, note: r.error ? null : 'gh not on PATH: PR data from fm-bearings-snapshot.sh, open PRs only, without titles, base branches or PR creation times' };
  }
  if (!snapshot) return { candidate_prs: [], error: 'no fleet snapshot to name the candidate repositories', note: null };
  return runGhPrs(snapshot, { timeoutMs, env });
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
        landed: Array.isArray(rec.landed) ? rec.landed : [],
        queued: Array.isArray(rec.queued) ? rec.queued : [],
      };
      ledger.cached = true;
      ledger.generatedAt = rec.freshness && rec.freshness.observed_at ? Math.floor(Date.parse(rec.freshness.observed_at) / 1000) || null : null;
      if (!remote) ledger.error = ledger.error || null;
    }
    out.push(ledger);
  }
  return out;
}
