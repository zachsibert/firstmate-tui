// lib/hold.mjs - the I/O behind the hold card and the board's two write
// actions. The card is written to a fresh mkdtemp directory under the OS
// temp directory as <id>.md, handed to the viewer by the host (lib/app.mjs,
// index.mjs) and removed afterwards; removeTempDir() only ever deletes a
// directory makeTempDir() returned, never anything else. The two writes,
// discard (`fm-captain-hold.sh answer <id> --decision-file <tmp>`) and defer
// (`fm-captain-hold.sh hold <id> --reason <reason> --until <date>`), run
// firstmate's own command in the home that owns the hold: an argv spawn of
// `bash <home>/bin/fm-captain-hold.sh ...` with FM_HOME=<home> added to the
// environment, cwd <home>, stdout and stderr captured and a HOLD_TIMEOUT_MS
// bound. The board edits no backlog or state file itself; the command's own
// guards decide, and a refusal comes back verbatim for the footer.

import { spawn as nodeSpawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildHoldCard, deferArgs, discardArgs, discardDecision, localDate } from './card.mjs';
import { readHoldMaterials, readHoldRecord } from './sources.mjs';

export const HOLD_TIMEOUT_MS = 60000;
const TEMP_PREFIX = 'firstmate-tui-';
const created = new Set();

export function makeTempDir() {
  const dir = mkdtempSync(join(tmpdir(), TEMP_PREFIX));
  created.add(dir);
  return dir;
}

// Remove a directory this module created, and only such a directory. Returns
// whether anything was removed.
export function removeTempDir(dir) {
  if (typeof dir !== 'string' || !created.has(dir) || !dir.startsWith(join(tmpdir(), TEMP_PREFIX))) return false;
  created.delete(dir);
  rmSync(dir, { recursive: true, force: true });
  return true;
}

// Run `bash <home>/bin/fm-captain-hold.sh <args>` in `home` to completion.
// Resolves to { code, signal, stdout, stderr, error }: error is the spawn
// failure or the timeout, else null; code is the exit status (null when the
// child was killed).
export function runCaptainHold(home, args, { timeoutMs = HOLD_TIMEOUT_MS, env = process.env, spawn = nodeSpawn } = {}) {
  return new Promise((resolve) => {
    let out = '';
    let err = '';
    let done = false;
    let child;
    const finish = (r) => {
      if (done) return;
      done = true;
      resolve({ code: null, signal: null, stdout: out, stderr: err, error: null, ...r });
    };
    try {
      child = spawn('bash', [`${home}/bin/fm-captain-hold.sh`, ...args], { cwd: home, env: { ...env, FM_HOME: home }, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      finish({ error: e.message });
      return;
    }
    const timer = setTimeout(() => {
      if (done) return;
      child.kill('SIGKILL');
      finish({ error: `timed out after ${Math.round(timeoutMs / 1000)} s` });
    }, timeoutMs);
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('error', (e) => {
      clearTimeout(timer);
      // ENOENT here is bash missing or, far more often, a home directory that
      // does not exist on this host; the message names the home either way.
      finish({ error: `cannot start bash ${home}/bin/fm-captain-hold.sh in ${home} (${e.code || e.message})` });
    });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      finish({ code, signal });
    });
  });
}

export function firstLine(text) {
  const line = String(text || '')
    .split('\n')
    .map((l) => l.trim())
    .find(Boolean);
  return line || '';
}

// What the footer shows for a failed run: the command's stderr verbatim,
// stdout when stderr is empty, else the spawn error or the exit status.
export function holdFailureText(r) {
  const err = String(r.stderr || '').trim();
  if (err) return err;
  const out = String(r.stdout || '').trim();
  if (out) return out;
  if (r.error) return r.error;
  return r.signal ? `fm-captain-hold.sh killed by ${r.signal}` : `fm-captain-hold.sh exited ${r.code}`;
}

// A task id as a file name: ids are slugs, but nothing else may reach the
// temp directory's path.
function fileNameFor(id) {
  return String(id || 'card').replace(/[^A-Za-z0-9._-]/g, '_');
}

// The card of one row (row.card, lib/model.mjs), written to a temp file:
// { dir, path, text, partial }. A main-home row's record is the snapshot's;
// a delegate home's is read from that home on demand through its own
// fm-fleet-snapshot.sh (readHoldRecord), and when that read fails, or the
// home is remote, the card is built from the ledger's fields and leads with
// a partial notice saying why. onBusy(text) is called before a read that can
// take a while. The caller runs the viewer on `path` and then calls
// removeTempDir(dir).
export async function prepareHoldCard(card, { timeoutMs, onBusy = () => {} } = {}) {
  let record = card.record || null;
  let partial = null;
  const cut = 'the title, the reason (cut at 160 characters) and the hold fields come from its ledger';
  if (card.source !== 'snapshot') {
    if (card.remote) partial = `${card.homeId} is a remote home whose files are not readable here; ${cut}.`;
    else {
      onBusy(`reading the record of ${card.id} from ${card.homeId}...`);
      const r = await readHoldRecord(card.home, card.id, { timeoutMs });
      if (r.record) record = r.record;
      else partial = `${card.homeId}'s fm-fleet-snapshot.sh gave no record for ${card.id} (${r.error}); ${cut}.`;
    }
  }
  const materials = card.remote ? null : readHoldMaterials(card.home, card.id);
  const text = buildHoldCard({ id: card.id, home: card.home, homeLabel: card.homeLabel || card.homeId, record, partial, materials });
  const dir = makeTempDir();
  const path = join(dir, `${fileNameFor(card.id)}.md`);
  writeFileSync(path, text);
  return { dir, path, text, partial };
}

// Discard a hold: write the decision text to a temp file, run `answer` in the
// owning home, remove the file. Resolves to the run's result plus { ok,
// decision }.
export async function discardHold({ home, id, login, timeoutMs = HOLD_TIMEOUT_MS, now = Date.now(), run = runCaptainHold }) {
  const decision = discardDecision(login, localDate(now));
  const dir = makeTempDir();
  const file = join(dir, 'decision.txt');
  writeFileSync(file, `${decision}\n`);
  try {
    const r = await run(home, discardArgs(id, file), { timeoutMs });
    return { ...r, ok: r.code === 0 && !r.error, decision };
  } finally {
    removeTempDir(dir);
  }
}

// Defer a hold to `until`, repeating its full reason (a repeated hold keeps
// the original hold-set stamp; the command's own rule).
export async function deferHold({ home, id, reason, until, timeoutMs = HOLD_TIMEOUT_MS, run = runCaptainHold }) {
  const r = await run(home, deferArgs(id, reason, until), { timeoutMs });
  return { ...r, ok: r.code === 0 && !r.error };
}
