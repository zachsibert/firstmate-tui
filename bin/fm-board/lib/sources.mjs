// lib/sources.mjs - every read the board performs against firstmate homes.
// Read-only by contract: it runs the snapshot scripts, reads ledgers and
// stats files. It never writes into FM_HOME, a project or a state directory.

import { spawn } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { basename } from './text.mjs';

function runJson(cmd, args, { env, timeoutMs, cwd }) {
  return new Promise((resolve) => {
    let out = '';
    let err = '';
    let done = false;
    const child = spawn(cmd, args, { env, cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    const timer = setTimeout(() => {
      if (done) return;
      done = true;
      child.kill('SIGKILL');
      resolve({ value: null, error: `timed out after ${Math.round(timeoutMs / 1000)} s` });
    }, timeoutMs);
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('error', (e) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ value: null, error: e.message });
    });
    child.on('close', (code) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (code !== 0) {
        resolve({ value: null, error: `exit ${code}: ${err.trim().split('\n').slice(-1)[0] || 'no stderr'}` });
        return;
      }
      try {
        resolve({ value: JSON.parse(out), error: null });
      } catch (e) {
        resolve({ value: null, error: `bad JSON: ${e.message}` });
      }
    });
  });
}

export function mtime(path) {
  try {
    return Math.floor(statSync(path).mtimeMs / 1000);
  } catch {
    return null;
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

export async function runBearingsPrs(fmHome, { timeoutMs }) {
  const script = `${fmHome}/bin/fm-bearings-snapshot.sh`;
  const r = await runJson('bash', [script, '--json', '--include-prs'], {
    env: { ...process.env, FM_HOME: fmHome },
    cwd: fmHome,
    timeoutMs,
  });
  if (r.error) return { candidate_prs: [], error: r.error };
  // Without gh the script still exits 0, lists nothing and says so in its prs
  // status line ("unavailable (gh not found)"). Since PR data is on by default,
  // the board treats that as a failed fetch and names it, not as an empty list.
  const status = typeof r.value.prs === 'string' ? r.value.prs : '';
  if (/^unavailable\b/.test(status)) return { candidate_prs: [], error: status };
  return { candidate_prs: Array.isArray(r.value.candidate_prs) ? r.value.candidate_prs : [], error: null };
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
