// lib/config.mjs - the board's config file: who the captain is on GitHub and
// which labels a pull request must carry to be listed in To review. It sits
// beside view-state.json so there is one place to look, and like view state
// it is never inside FM_HOME, a project or a state directory.
//
// Location, first match wins (lib/viewstate.mjs uses the same chain):
//   --config <path>                                      (the wrapper passes
//       $(herdr plugin config-dir firstmate.board)/config.json when herdr is
//       present; tests pass a temp file)
//   $XDG_CONFIG_HOME/fm-board/config.json
//   ~/.config/fm-board/config.json
// A path inside FM_HOME is refused and the default is used instead.
//
// File shape (firstmate-tui-config.v1), the documented example being
// docs/config.example.json, which the board writes to the path above once
// when no file is there yet:
//   { "schema": "firstmate-tui-config.v1",
//     "identity": { "github_login": null },
//     "review": { "default_labels": [],
//                 "repos": { "<owner/name>": { "labels": [ "<label>", ... ] } } } }
// identity.github_login names the captain's GitHub login; null means "ask gh,
// then git" (lib/identity.mjs). review.repos adds each named repository to
// the To review scope and gives it a label rule: a PR there is listed only
// when it carries one of the labels (an empty list means unfiltered);
// review.default_labels is the rule for every repository without its own
// entry. Unknown keys are ignored. A malformed file is reported once and the
// board runs with the defaults (no login from the file, no label rules, no
// configured repositories); the file is never overwritten once it exists.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

export const CONFIG_SCHEMA = 'firstmate-tui-config.v1';

// The documented example, byte for byte what docs/config.example.json holds
// and what the board writes on a first launch: the captain's rule for the
// gemini repository.
export const EXAMPLE_CONFIG = {
  schema: CONFIG_SCHEMA,
  identity: { github_login: null },
  review: { default_labels: [], repos: { 'MatthewsREIS/gemini': { labels: ['ready-to-merge'] } } },
};

export function exampleConfigText() {
  return `${JSON.stringify(EXAMPLE_CONFIG, null, 2)}\n`;
}

// The defaults the board runs with when there is no usable file.
export function defaultConfig() {
  return { schema: CONFIG_SCHEMA, identity: { github_login: null }, review: { default_labels: [], repos: {} } };
}

export function defaultConfigPath(env = process.env) {
  const base = env.XDG_CONFIG_HOME && env.XDG_CONFIG_HOME.startsWith('/') ? env.XDG_CONFIG_HOME : env.HOME ? `${env.HOME.replace(/\/+$/, '')}/.config` : null;
  return base ? `${base.replace(/\/+$/, '')}/fm-board/config.json` : null;
}

function insideHome(path, fmHome) {
  if (!fmHome) return false;
  const home = fmHome.replace(/\/+$/, '');
  return path === home || path.startsWith(`${home}/`);
}

// The path the board will read (and write once), or null when there is
// nowhere safe. `problem` names a refused explicit path so the caller can say
// so once.
export function resolveConfigPath({ explicit = null, fmHome = null, env = process.env } = {}) {
  const fallback = defaultConfigPath(env);
  if (explicit) {
    if (insideHome(explicit, fmHome)) return { path: fallback && !insideHome(fallback, fmHome) ? fallback : null, problem: `refusing --config inside FM_HOME (${explicit})` };
    return { path: explicit, problem: null };
  }
  if (fallback && insideHome(fallback, fmHome)) return { path: null, problem: `refusing a config file inside FM_HOME (${fallback})` };
  return { path: fallback, problem: null };
}

function isObject(v) {
  return Boolean(v) && typeof v === 'object' && !Array.isArray(v);
}

function stringList(v) {
  return Array.isArray(v) ? v.filter((s) => typeof s === 'string' && s.trim()).map((s) => s.trim()) : [];
}

// Parse the file's text into a config. Returns { config, error }: on any
// error the config is the defaults and `error` says what was wrong, so the
// caller can report it once and carry on.
export function parseConfig(text) {
  let doc;
  try {
    doc = JSON.parse(text);
  } catch (e) {
    return { config: defaultConfig(), error: `bad JSON (${e.message})` };
  }
  if (!isObject(doc)) return { config: defaultConfig(), error: 'not an object' };
  if (doc.schema !== undefined && doc.schema !== CONFIG_SCHEMA) return { config: defaultConfig(), error: `unexpected schema ${doc.schema}` };
  const config = defaultConfig();
  if (doc.identity !== undefined) {
    if (!isObject(doc.identity)) return { config: defaultConfig(), error: 'identity is not an object' };
    const login = doc.identity.github_login;
    if (login !== undefined && login !== null && typeof login !== 'string') return { config: defaultConfig(), error: 'identity.github_login is not a string' };
    config.identity.github_login = typeof login === 'string' && login.trim() ? login.trim() : null;
  }
  if (doc.review !== undefined) {
    if (!isObject(doc.review)) return { config: defaultConfig(), error: 'review is not an object' };
    if (doc.review.default_labels !== undefined && !Array.isArray(doc.review.default_labels)) return { config: defaultConfig(), error: 'review.default_labels is not a list' };
    config.review.default_labels = stringList(doc.review.default_labels);
    if (doc.review.repos !== undefined) {
      if (!isObject(doc.review.repos)) return { config: defaultConfig(), error: 'review.repos is not an object' };
      for (const [repo, entry] of Object.entries(doc.review.repos)) {
        if (!/^[^/\s]+\/[^/\s]+$/.test(repo)) return { config: defaultConfig(), error: `review.repos: "${repo}" is not owner/name` };
        if (!isObject(entry)) return { config: defaultConfig(), error: `review.repos["${repo}"] is not an object` };
        if (entry.labels !== undefined && !Array.isArray(entry.labels)) return { config: defaultConfig(), error: `review.repos["${repo}"].labels is not a list` };
        config.review.repos[repo] = { labels: stringList(entry.labels) };
      }
    }
  }
  return { config, error: null };
}

// The labels a PR in `repo` must carry one of to be listed in To review, or
// an empty list when it is unfiltered: the repository's own entry when the
// file has one (its empty list means unfiltered even with default labels
// set), else review.default_labels. Repository names compare without case,
// as GitHub treats them, so `matthewsreis/gemini` in the file still rules
// the PRs GitHub reports under `MatthewsREIS/gemini`.
export function labelsFor(config, repo) {
  const repos = config && config.review && config.review.repos ? config.review.repos : {};
  const want = String(repo || '').toLowerCase();
  const key = Object.keys(repos).find((k) => k.toLowerCase() === want);
  if (key) return Array.isArray(repos[key].labels) ? repos[key].labels : [];
  return config && config.review && Array.isArray(config.review.default_labels) ? config.review.default_labels : [];
}

export function passesLabelRule(config, repo, labels) {
  const want = labelsFor(config, repo);
  if (!want.length) return true;
  const have = new Set(Array.isArray(labels) ? labels : []);
  return want.some((l) => have.has(l));
}

// The repositories the file names under review.repos, in file order.
export function configuredRepos(config) {
  return config && config.review && config.review.repos ? Object.keys(config.review.repos) : [];
}

// Read the file at `path`. Returns { config, status, error } where status is
// 'loaded' (the file was read), 'absent' (no file there), 'defaults' (the
// file is unusable: `error` says why) or 'none' (no path at all).
export function loadConfig(path) {
  if (!path) return { config: defaultConfig(), status: 'none', error: null };
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (e) {
    if (e.code === 'ENOENT') return { config: defaultConfig(), status: 'absent', error: null };
    return { config: defaultConfig(), status: 'defaults', error: `${path}: ${e.message}` };
  }
  const parsed = parseConfig(text);
  if (parsed.error) return { config: parsed.config, status: 'defaults', error: `${path}: ${parsed.error}` };
  return { config: parsed.config, status: 'loaded', error: null };
}

// Write the example to `path` (temp file in the same directory, then rename,
// the way view state is saved). Returns null or an error message. Only called
// when loadConfig said 'absent', so an existing file is never touched.
export function writeExampleConfig(path) {
  if (!path) return 'no config path';
  try {
    mkdirSync(dirname(path), { recursive: true });
    const tmp = `${path}.${process.pid}.tmp`;
    writeFileSync(tmp, exampleConfigText());
    renameSync(tmp, path);
    return null;
  } catch (e) {
    return `${path}: ${e.message}`;
  }
}

// Read the file, writing the example first when none is there: what the app
// and a live one-shot render do at startup. Returns { path, problem, config,
// status, error } with status 'loaded', 'created' (the example was written
// and is in effect), 'defaults' (unusable file, or the example could not be
// written) or 'none' (no path). `error` is the text to report once.
export function loadOrCreateConfig({ explicit = null, fmHome = null, env = process.env } = {}) {
  const where = resolveConfigPath({ explicit, fmHome, env });
  const loaded = loadConfig(where.path);
  if (loaded.status !== 'absent') return { ...where, ...loaded };
  const err = writeExampleConfig(where.path);
  if (err) return { ...where, config: defaultConfig(), status: 'defaults', error: `could not write the example config: ${err}` };
  return { ...where, config: parseConfig(exampleConfigText()).config, status: 'created', error: null };
}
