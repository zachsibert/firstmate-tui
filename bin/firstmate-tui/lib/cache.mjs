// lib/cache.mjs - the state cache: the last facts the board rendered, kept in
// the board's own directory so a relaunch can draw them at once instead of
// spinners while the launch refresh runs. The third file the board owns,
// beside view-state.json (lib/viewstate.mjs) and config.json (lib/config.mjs);
// like them it is never inside FM_HOME, a project or a state directory.
//
// Location: --cache <path>, else state-cache.json in the directory of the
// resolved view-state path (so a test that points --view-state at a scratch
// directory gets the cache there too), else nowhere (no cache is read or
// written). A --cache path inside FM_HOME is refused the way --view-state is,
// and the default beside the view state is used instead.
//
// File shape (fm-board-state-cache.v1):
//   { "schema": "fm-board-state-cache.v1",
//     "fetched_at": ISO time,        when the data landed (the age the panes show)
//     "saved_at": ISO time,          when the file was written (a tick, or quit)
//     "fm_home": path,               the home the data describes
//     "snapshot": fm-fleet-snapshot.v1 document,
//     "snapshot_at": epoch seconds,
//     "ledgers": [ ... ],            lib/sources.mjs collectLedgers
//     "prs": { ... },                facts.prs (lib/model.mjs), identity included
//     "identity": { login, source, reason } | null,
//     "herdr": { "agents": { <pane id>: { agent_status, title, workspace_id } } } }
// What goes in is what came from outside (the snapshot, the ledgers, the PR
// data with its identity, the herdr agents); the view state and the refresh
// bookkeeping do not. The app writes it after every refresh that landed
// cleanly and on quit (lib/app.mjs); a failed refresh never overwrites it.
//
// Reading: loadStateCache() returns the parsed facts when the file exists,
// parses, names this schema and this home, and its fetched_at is younger than
// the max age (--cache-max-age, default 3600 s); `stale` is true for an older
// one (the board cold-starts with spinners), `error` names a damaged file (bad
// JSON, another schema, not an object, no time), which the board reports in
// the footer once and overwrites on the next clean tick. A cache written for
// another home is ignored with a reason too.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

export const STATE_CACHE_SCHEMA = 'fm-board-state-cache.v1';
export const CACHE_FILE = 'state-cache.json';
export const DEFAULT_CACHE_MAX_AGE = 3600; // seconds

function insideHome(path, fmHome) {
  if (!fmHome) return false;
  const home = fmHome.replace(/\/+$/, '');
  return path === home || path.startsWith(`${home}/`);
}

// The path the board reads and writes, or null when there is nowhere safe;
// `problem` names a refused explicit path so the caller can say so once.
export function resolveCachePath({ explicit = null, viewStatePath = null, fmHome = null } = {}) {
  const fallback = viewStatePath ? `${dirname(viewStatePath)}/${CACHE_FILE}` : null;
  if (explicit) {
    if (insideHome(explicit, fmHome)) return { path: fallback && !insideHome(fallback, fmHome) ? fallback : null, problem: `refusing --cache inside FM_HOME (${explicit})` };
    return { path: explicit, problem: null };
  }
  if (fallback && insideHome(fallback, fmHome)) return { path: null, problem: `refusing a state cache inside FM_HOME (${fallback})` };
  return { path: fallback, problem: null };
}

// The parse alone, pure: text -> { facts, fetchedAt, error, stale }. `now` and
// `maxAge` are seconds; `fmHome` is the home the board runs against.
export function parseStateCache(text, { now, maxAge = DEFAULT_CACHE_MAX_AGE, fmHome = null } = {}) {
  const none = { facts: null, fetchedAt: null, error: null, stale: false };
  let doc;
  try {
    doc = JSON.parse(text);
  } catch (e) {
    return { ...none, error: `bad JSON (${e.message})` };
  }
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return { ...none, error: 'not an object' };
  if (doc.schema !== STATE_CACHE_SCHEMA) return { ...none, error: `unexpected schema ${doc.schema === undefined ? '(none)' : JSON.stringify(doc.schema)}` };
  const fetchedMs = typeof doc.fetched_at === 'string' ? Date.parse(doc.fetched_at) : NaN;
  if (Number.isNaN(fetchedMs)) return { ...none, error: 'no fetched_at time' };
  const fetchedAt = Math.floor(fetchedMs / 1000);
  if (fmHome && typeof doc.fm_home === 'string' && doc.fm_home.replace(/\/+$/, '') !== fmHome.replace(/\/+$/, '')) return { ...none, error: `written for another home (${doc.fm_home})` };
  if (!doc.snapshot || typeof doc.snapshot !== 'object') return { ...none, error: 'no snapshot' };
  if (now - fetchedAt > maxAge) return { ...none, fetchedAt, stale: true };
  const prs = doc.prs && typeof doc.prs === 'object' && !Array.isArray(doc.prs) ? doc.prs : null;
  const agents = doc.herdr && doc.herdr.agents && typeof doc.herdr.agents === 'object' && !Array.isArray(doc.herdr.agents) ? doc.herdr.agents : {};
  return {
    facts: {
      snapshot: doc.snapshot,
      snapshotAt: Number.isFinite(Number(doc.snapshot_at)) ? Number(doc.snapshot_at) : fetchedAt,
      ledgers: Array.isArray(doc.ledgers) ? doc.ledgers : [],
      prs,
      identity: doc.identity && typeof doc.identity === 'object' ? doc.identity : null,
      herdr: { agents },
    },
    fetchedAt,
    error: null,
    stale: false,
  };
}

// Read the file: a missing file is no cache and no error; a damaged one is
// reported and treated as none.
export function loadStateCache(path, opts = {}) {
  const none = { facts: null, fetchedAt: null, error: null, stale: false };
  if (!path) return none;
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (e) {
    return e.code === 'ENOENT' ? none : { ...none, error: `${path}: ${e.message}` };
  }
  const parsed = parseStateCache(text, opts);
  return parsed.error ? { ...parsed, error: `${path}: ${parsed.error}` } : parsed;
}

// facts: { fmHome, snapshot, snapshotAt, ledgers, prs, identity, herdr }, the
// board's own facts shape; fetchedAt in epoch seconds, `now` a Date.
export function serializeStateCache(facts, { fetchedAt, now = new Date() }) {
  return `${JSON.stringify(
    {
      schema: STATE_CACHE_SCHEMA,
      fetched_at: new Date(fetchedAt * 1000).toISOString(),
      saved_at: now.toISOString(),
      fm_home: facts.fmHome || null,
      snapshot: facts.snapshot,
      snapshot_at: facts.snapshotAt ?? fetchedAt,
      ledgers: Array.isArray(facts.ledgers) ? facts.ledgers : [],
      prs: facts.prs || null,
      identity: facts.identity || (facts.prs && facts.prs.identity) || null,
      herdr: { agents: facts.herdr && facts.herdr.agents ? facts.herdr.agents : {} },
    },
    null,
    2,
  )}\n`;
}

// Write atomically (temp file in the same directory, then rename). Returns
// null or an error message.
export function saveStateCache(path, facts, opts) {
  if (!path) return 'no cache path';
  try {
    mkdirSync(dirname(path), { recursive: true });
    const tmp = `${path}.${process.pid}.tmp`;
    writeFileSync(tmp, serializeStateCache(facts, opts));
    renameSync(tmp, path);
    return null;
  } catch (e) {
    return `${path}: ${e.message}`;
  }
}

// The cached-marker facts for lib/model.mjs, from a loaded cache: every source
// starts cached; the app clears each as its live data lands. `prs` is per PR
// pane and only when the cached PR block had that pane's data.
export function cachedFlags(loaded, { prsEnabled }) {
  if (!loaded || !loaded.facts) return null;
  const prs = loaded.facts.prs;
  const paneCached = (id) => Boolean(prsEnabled && prs && prs.enabled && ((prs[id] && prs[id].fetchedAt) || prs.fetchedAt));
  return { at: loaded.fetchedAt, snapshot: true, prs: { mine: paneCached('mine'), toreview: paneCached('toreview') } };
}
