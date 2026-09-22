// lib/search.mjs - the f key's fuzzy matcher, pure. A query and a row's search
// text in, a score out; a query and the board's rows in, the ranked matches
// out. Nothing here reads a file or knows a pane's shape: lib/model.mjs fills
// each row's `searchText` (its id, title or what text, repo, home label,
// report path and PR URL, in that order) and `searchHead` (how many of those
// characters are the id and the title), and lib/controller.mjs and
// lib/render.mjs read the ranked list this module returns.
//
// The match is VS Code quick-open style, loose on purpose: the query splits on
// whitespace into tokens, every token must appear in the text as a
// subsequence (its characters in order, any distance apart), case does not
// matter and the tokens may come in any order. Among the rows that match, the
// score prefers a token found as one contiguous run over one scattered across
// the text, a hit that starts a word (after a space, dash, slash, underscore,
// dot or colon, or where the text changes from lower to upper case) over one
// inside a word, and a hit in the id or title over one in a path or URL. The
// score of a row is the sum of its tokens' best scores, so "mdm gap" ranks the
// task whose id carries both words as whole runs first, and a scattered match
// in a long URL last. Ties keep the caller's order (pane order, then row
// order), which is what a stable sort gives.

// Points per matched character: one for the hit, more when it continues the
// previous hit (CONTIGUOUS), starts a word (WORD_START) or falls inside the
// id and title part of the text (HEAD). CONTIGUOUS outweighs WORD_START by
// enough that a run inside a word ("xxgapx", 18) beats the same letters each
// starting a word of their own ("g-a-p", 15), and a run at a word start
// ("x-gap", 21) beats both.
export const CONTIGUOUS = 6;
export const WORD_START = 3;
export const HEAD = 1;

const SEPARATORS = new Set([' ', '-', '/', '_', '.', ':', '#', '(', ')', '[', ']', ',', '\u00b7']); // the last is the middle dot the WHAT texts join with

// Whether position `i` of `text` starts a word: the first character, one
// after a separator, or an upper-case letter after a lower-case one
// (camelCase), measured on the original text so the case change is seen.
export function wordStart(text, i) {
  if (i === 0) return true;
  const prev = text[i - 1];
  if (SEPARATORS.has(prev)) return true;
  const c = text[i];
  return c !== c.toLowerCase() && prev === prev.toLowerCase() && prev !== prev.toUpperCase();
}

// The best score of `token` (already lower-cased, non-empty) as a
// subsequence of `text`, or null when it is not one. `lower` is the
// lower-cased text and `head` the length of its id-and-title prefix. Dynamic
// programming over (token position, text position): the best score of the
// token's first i+1 characters with the (i+1)th at text position j is the
// character's own points plus the best of the previous character ending
// anywhere before j, with CONTIGUOUS added when that was j-1. Two running
// maxima keep it linear in the text per token character.
function tokenScore(token, text, lower, head) {
  const n = lower.length;
  const m = token.length;
  if (m === 0 || m > n) return null;
  const points = (j) => 1 + (wordStart(text, j) ? WORD_START : 0) + (j < head ? HEAD : 0);
  let prev = null; // best[j] for the previous token character, or null before the first
  for (let i = 0; i < m; i += 1) {
    const c = token[i];
    const cur = new Array(n).fill(-Infinity);
    let bestBefore = -Infinity; // max prev[k] for k <= j-2
    for (let j = 0; j < n; j += 1) {
      if (j >= 2 && prev) bestBefore = Math.max(bestBefore, prev[j - 2]);
      if (lower[j] !== c) continue;
      if (!prev) {
        cur[j] = points(j);
        continue;
      }
      const adjacent = j >= 1 ? prev[j - 1] : -Infinity;
      const from = Math.max(bestBefore, adjacent === -Infinity ? -Infinity : adjacent + CONTIGUOUS);
      if (from === -Infinity) continue;
      cur[j] = from + points(j);
    }
    prev = cur;
  }
  const best = Math.max(...prev);
  return best === -Infinity ? null : best;
}

// The query's tokens: lower-cased, split on whitespace, empty ones dropped.
export function tokens(query) {
  return String(query || '')
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean);
}

// The score of `query` against `text`, or null when some token is not a
// subsequence of it. An empty query matches everything with score 0. `head`
// is the length of the id-and-title prefix (the whole text when absent).
export function matchScore(query, text, { head = null } = {}) {
  const words = tokens(query);
  const s = String(text || '');
  if (!words.length) return 0;
  const lower = s.toLowerCase();
  const h = Number.isInteger(head) ? head : s.length;
  let total = 0;
  for (const w of words) {
    const score = tokenScore(w, s, lower, h);
    if (score === null) return null;
    total += score;
  }
  return total;
}

// The rows that match `query`, best first, each as { ...entry, score }. An
// entry is whatever the caller lists (lib/model.mjs `model.search`: { pane,
// paneId, paneTitle, row }) and its row carries searchText and searchHead;
// an entry whose row has no searchText is matched on its id and text. The
// sort is stable, so equal scores keep the caller's order.
export function rankRows(query, entries) {
  const list = Array.isArray(entries) ? entries : [];
  const scored = [];
  for (const entry of list) {
    const row = entry.row || entry;
    const text = typeof row.searchText === 'string' ? row.searchText : `${row.id || ''} ${row.text || ''}`;
    const head = Number.isInteger(row.searchHead) ? row.searchHead : null;
    const score = matchScore(query, text, { head });
    if (score === null) continue;
    scored.push({ ...entry, score });
  }
  return scored.sort((a, b) => b.score - a.score);
}

// The search text of one row and the length of its head: the id (and the
// undecorated name when the id is decorated, as a group row's is), the title
// or what text, then the repo, the home label, the report path and the PR
// URL, joined by single spaces. Fields that read `-` or are absent are left
// out, so a dash never matches.
export function searchTextOf(row) {
  const keep = (v) => (typeof v === 'string' && v && v !== '-' ? v : null);
  const headParts = [keep(row.id), row.name !== row.id ? keep(row.name) : null, keep(row.text)].filter(Boolean);
  const tailParts = [keep(row.repo), keep(row.home), keep(row.reportPath), keep(row.url)].filter(Boolean);
  const head = headParts.join(' ');
  const text = tailParts.length ? `${head} ${tailParts.join(' ')}` : head;
  return { searchText: text, searchHead: head.length };
}
