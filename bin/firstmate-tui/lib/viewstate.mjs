// lib/viewstate.mjs - the file the board owns besides the pane record and its
// config (lib/config.mjs): which rows the captain hid (`x`), which panes he
// switched off (`1`-`6`) and the column widths he dragged
// (lib/controller.mjs). Hiding is view state,
// not firstmate state: firstmate retires Done rows on its own (done_keep per
// home, archived to data/done-archive.md), so nothing here is ever written
// into FM_HOME, a project or a state directory.
//
// Location, first match wins:
//   --view-state <path>                                  (the wrapper passes
//       $(herdr plugin config-dir firstmate.board)/view-state.json when herdr
//       is present; tests pass a temp file)
//   $XDG_CONFIG_HOME/fm-board/view-state.json
//   ~/.config/fm-board/view-state.json
// A path inside FM_HOME is refused and the default is used instead.
//
// File shape (fm-board-view-state.v1):
//   { "schema": "fm-board-view-state.v1",
//     "hidden": [ "<pane>:<home>:<row id>[:<completion date>]", ... ],
//     "hidden_panes": [ "landed", ... ],
//     "columns": { "<pane id>": { "<column key>": <width>, ... }, ... },
//     "updated": ISO time }
// The row key is built by lib/model.mjs (hideKey); Landed keys carry the
// completion date so an item that lands again reappears. `columns` holds the
// dragged widths by pane id (lib/layout.mjs PANES) and column key
// (COLUMN_KEYS); a pane or column the board does not know, or a width that is
// not a positive integer, is dropped on read, so an older or a newer board
// reading the file loses nothing else. The `columns` key was added after the
// first release and is optional on read. Up to 0.3.x the second pane's id was
// `review` (Ready for review); a file written then is read with that id
// mapped to `mine` in every three places, so the captain's hidden rows,
// hidden pane and dragged widths survive the rename.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { COLUMN_KEYS, PANES } from './layout.mjs';

export const VIEW_STATE_SCHEMA = 'fm-board-view-state.v1';

const RENAMED_PANES = { review: 'mine' };

function paneIdOf(id) {
  return RENAMED_PANES[id] || id;
}

function renameHideKey(key) {
  const i = key.indexOf(':');
  return i > 0 ? `${paneIdOf(key.slice(0, i))}${key.slice(i)}` : key;
}

export function defaultViewStatePath(env = process.env) {
  const base = env.XDG_CONFIG_HOME && env.XDG_CONFIG_HOME.startsWith('/') ? env.XDG_CONFIG_HOME : env.HOME ? `${env.HOME.replace(/\/+$/, '')}/.config` : null;
  return base ? `${base.replace(/\/+$/, '')}/fm-board/view-state.json` : null;
}

function insideHome(path, fmHome) {
  if (!fmHome) return false;
  const home = fmHome.replace(/\/+$/, '');
  return path === home || path.startsWith(`${home}/`);
}

// The path the board will read and write, or null when there is nowhere safe.
// `problem` names a refused explicit path so the caller can say so once.
export function resolveViewStatePath({ explicit = null, fmHome = null, env = process.env } = {}) {
  const fallback = defaultViewStatePath(env);
  if (explicit) {
    if (insideHome(explicit, fmHome)) return { path: fallback && !insideHome(fallback, fmHome) ? fallback : null, problem: `refusing --view-state inside FM_HOME (${explicit})` };
    return { path: explicit, problem: null };
  }
  if (fallback && insideHome(fallback, fmHome)) return { path: null, problem: `refusing view state inside FM_HOME (${fallback})` };
  return { path: fallback, problem: null };
}

export function emptyViewState() {
  return { hidden: new Set(), hiddenPanes: new Set(), columns: {} };
}

// The saved column widths that name a known pane and column with a positive
// integer width; everything else is left out.
export function sanitizeColumns(doc) {
  const out = {};
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return out;
  for (const pane of PANES) {
    const cols = doc[pane.id] || Object.entries(RENAMED_PANES).filter(([, to]) => to === pane.id).map(([from]) => doc[from]).find(Boolean);
    if (!cols || typeof cols !== 'object' || Array.isArray(cols)) continue;
    for (const key of COLUMN_KEYS) {
      const w = cols[key];
      if (Number.isInteger(w) && w > 0) {
        if (!out[pane.id]) out[pane.id] = {};
        out[pane.id][key] = w;
      }
    }
  }
  return out;
}

// Read the file; a missing file is an empty state, a damaged one is reported
// and treated as empty (the board never overwrites it until the captain hides
// something, so a hand edit can be repaired).
export function loadViewState(path) {
  const state = emptyViewState();
  if (!path) return { state, error: null };
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (e) {
    return { state, error: e.code === 'ENOENT' ? null : `${path}: ${e.message}` };
  }
  let doc;
  try {
    doc = JSON.parse(text);
  } catch (e) {
    return { state, error: `${path}: bad JSON (${e.message})` };
  }
  if (!doc || typeof doc !== 'object') return { state, error: `${path}: not an object` };
  if (doc.schema && doc.schema !== VIEW_STATE_SCHEMA) return { state, error: `${path}: unexpected schema ${doc.schema}` };
  for (const k of Array.isArray(doc.hidden) ? doc.hidden : []) if (typeof k === 'string' && k) state.hidden.add(renameHideKey(k));
  for (const p of Array.isArray(doc.hidden_panes) ? doc.hidden_panes : []) if (typeof p === 'string' && p) state.hiddenPanes.add(paneIdOf(p));
  state.columns = sanitizeColumns(doc.columns);
  return { state, error: null };
}

export function serializeViewState(state, now = new Date()) {
  const columns = {};
  for (const paneId of Object.keys(sanitizeColumns(state.columns)).sort()) {
    columns[paneId] = {};
    for (const key of Object.keys(state.columns[paneId]).sort()) columns[paneId][key] = state.columns[paneId][key];
  }
  return `${JSON.stringify(
    {
      schema: VIEW_STATE_SCHEMA,
      hidden: [...state.hidden].sort(),
      hidden_panes: [...state.hiddenPanes].sort(),
      columns,
      updated: now.toISOString(),
    },
    null,
    2,
  )}\n`;
}

// Write atomically (temp file in the same directory, then rename). Returns
// null or an error message.
export function saveViewState(path, state) {
  if (!path) return 'no view-state path';
  try {
    mkdirSync(dirname(path), { recursive: true });
    const tmp = `${path}.${process.pid}.tmp`;
    writeFileSync(tmp, serializeViewState(state));
    renameSync(tmp, path);
    return null;
  } catch (e) {
    return `${path}: ${e.message}`;
  }
}
