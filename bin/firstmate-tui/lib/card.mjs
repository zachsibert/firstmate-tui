// lib/card.mjs - the hold card and the footer prompts, pure. Data in,
// Markdown text or a small state object out; nothing here reads a file,
// spawns a process or touches a terminal. lib/sources.mjs reads the files a
// card shows, lib/hold.mjs writes the card to a temp file and runs
// firstmate's fm-captain-hold.sh, lib/controller.mjs drives the prompts and
// lib/render.mjs draws them in the footer.
//
// The card: one Markdown document per task, built from durable records only
// (the backlog record fm-fleet-snapshot.sh --json emits, the files under
// data/<id>/ and the tail of state/<id>.status), in this order: a partial
// notice when the record is not the home's own, the title, a facts table,
// the hold reason verbatim, the backlog body verbatim, the PR URL, the
// report path with its first CARD_REPORT_LINES lines, the brief path, the
// other files under data/<id>/ and the last CARD_STATUS_LINES status-log
// lines. A section with nothing to show says so in one line.
//
// The prompts (view.prompt in lib/controller.mjs):
//   { kind: 'discard', row, id }                    d: y discards, esc cancels
//   { kind: 'defer', row, id, reason, value }       D: digits and dashes edit
//                                                   the date, backspace deletes,
//                                                   enter defers, esc cancels
//   { kind: 'accept', row, id, title, options,      a: the card is drawn in the
//     picked, value, release, card }                frame (lib/render.mjs
//                                                   renderAccept) while the footer
//                                                   takes the answer. options are
//                                                   the lettered choices parsed
//                                                   from the full hold reason
//                                                   (parseOptions); with nothing
//                                                   typed, a lower-case letter that
//                                                   names one picks it (picked) and
//                                                   backspace unpicks; any other
//                                                   printable key starts a typed
//                                                   answer (value), after which
//                                                   every printable key types and
//                                                   backspace deletes; enter records
//                                                   the pick or the trimmed line,
//                                                   esc cancels; up/down, pageup/
//                                                   pagedown scroll the card.
//                                                   release says whether the answer
//                                                   frees a work item (--release)
//                                                   or closes a question
//                                                   (acceptRelease); card is the
//                                                   card's Markdown text
//   { kind: 'search', value, index }                f: printable characters and
//                                                   space append to the query,
//                                                   backspace deletes, up/down,
//                                                   pageup/pagedown and tab/S-tab
//                                                   move through the matches
//                                                   (index), enter jumps to the
//                                                   selected match, esc closes.
//                                                   j and k type, since a query
//                                                   may carry them ("token");
//                                                   the matches are ranked by
//                                                   lib/search.mjs over
//                                                   model.search
// Every other key is ignored while a prompt is up (ctrl-c still quits).

import { charWidth, width } from './text.mjs';

export const CARD_REPORT_LINES = 40;
export const CARD_STATUS_LINES = 10;
export const DEFER_DEFAULT_DAYS = 14;
export const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

// YYYY-MM-DD of `ms` in the local time zone: the date the captain reads on
// the clock, which is the one the decision text and the deferral carry.
export function localDate(ms = Date.now()) {
  const d = new Date(ms);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

// `date` (YYYY-MM-DD) plus `days`, as YYYY-MM-DD; the arithmetic runs in UTC
// so a daylight-saving change never moves the day.
export function plusDays(date, days) {
  const m = DATE_RE.exec(String(date || ''));
  if (!m) return date;
  const [y, mo, d] = date.split('-').map(Number);
  const t = new Date(Date.UTC(y, mo - 1, d + days));
  const p = (n) => String(n).padStart(2, '0');
  return `${t.getUTCFullYear()}-${p(t.getUTCMonth() + 1)}-${p(t.getUTCDate())}`;
}

// Why `value` cannot be the date a hold is deferred to, or null when it can:
// it must be YYYY-MM-DD, a real calendar date, and after `today`.
export function checkDeferDate(value, today) {
  const v = String(value || '');
  if (!DATE_RE.test(v)) return `${v || '(empty)'}: not a YYYY-MM-DD date`;
  const [y, mo, d] = v.split('-').map(Number);
  const t = new Date(Date.UTC(y, mo - 1, d));
  if (t.getUTCFullYear() !== y || t.getUTCMonth() !== mo - 1 || t.getUTCDate() !== d) return `${v}: not a real date`;
  if (v <= today) return `${v}: not after today (${today})`;
  return null;
}

// The exact words a discard records as the captain's decision.
export function discardDecision(login, date) {
  return `Discarded by ${login} from firstmate-tui on ${date}: no action; closed as not wanted.`;
}

// The exact words an accept records: the picked option's letter and text, or
// the line the captain typed. `answer` is acceptAnswer's { option } or { text }.
export function acceptDecision(login, date, answer) {
  const head = `Accepted by ${login} from firstmate-tui on ${date}:`;
  if (answer && answer.option) return `${head} option ${answer.option.letter} ${answer.option.text}`;
  return `${head} ${answer ? String(answer.text || '') : ''}`;
}

// The fm-captain-hold.sh arguments behind the three actions (bin/fm-captain-hold.sh
// usage: `answer <task-id> --decision-file <path> [--release]`, `hold <task-id>
// --reason <reason> --until YYYY-MM-DD`). --release lifts the hold so a
// captain-gated work item resumes; without it the answer closes the task.
export function discardArgs(id, decisionFile) {
  return ['answer', id, '--decision-file', decisionFile];
}

export function acceptArgs(id, decisionFile, release) {
  return ['answer', id, '--decision-file', decisionFile, ...(release ? ['--release'] : [])];
}

export function deferArgs(id, reason, until) {
  return ['hold', id, '--reason', reason, '--until', until];
}

// The lettered options of a hold reason, or []: the text after the first
// `Options:` (any case) holds markers of one letter followed by `.` or `)`
// and a space (`a.`, `a)`, `A.`, `A)`), the letters running a, b, c... in
// order from a; each option's text runs to the next marker or the end of the
// reason, with the spaces around it and one trailing `;` or `,` removed. The
// letters come back lower case, the keys the accept prompt listens for.
// Anything else in the reason (an `e.g.`, a letter mid-sentence) is not an
// option, and a list that does not start at `a` is left alone. Pure.
export function parseOptions(reason) {
  const text = String(reason || '');
  const at = text.search(/\boptions:/i);
  if (at < 0) return [];
  const rest = text.slice(at).replace(/^options:/i, '');
  const markers = [];
  const re = /(^|\s)([A-Za-z])[.)](?=\s)/g;
  let m;
  while ((m = re.exec(rest)) !== null) markers.push({ letter: m[2].toLowerCase(), start: m.index, end: m.index + m[0].length });
  const out = [];
  for (const [i, mk] of markers.entries()) {
    const expected = String.fromCharCode('a'.charCodeAt(0) + out.length);
    if (mk.letter !== expected) {
      if (out.length) break;
      continue;
    }
    const next = markers.slice(i + 1).find((x) => x.letter === String.fromCharCode('a'.charCodeAt(0) + out.length + 1));
    const body = rest
      .slice(mk.end, next ? next.start : rest.length)
      .trim()
      .replace(/[;,]$/, '')
      .trim();
    out.push({ letter: mk.letter, text: body });
  }
  return out;
}

// Whether an accepted answer frees the task to proceed (`--release`) or
// closes it: fm-captain-hold.sh creates a question-shaped call with
// `tasks-axi add --kind captain`, so a record of that kind is a question and
// its answer closes it; any other kind (ship, scout, docs, task...) is a work
// item the hold gated, released to resume as approved work. The caller checks
// acceptProblem first: a record without a kind is never guessed at.
export function acceptRelease(record) {
  return String((record && record.kind) || '').trim() !== 'captain';
}

// Why an accept cannot start on this record, or null: the kind must be there
// to read, since it alone tells a question from work.
export function acceptProblem(row, record) {
  const kind = record && record.kind;
  if (typeof kind !== 'string' || !kind.trim()) return `${row.name}: the backlog record carries no kind, so the board cannot tell a question from work; answer it with fm-captain-hold.sh in ${row.hold.homeId}`;
  return null;
}

// The reserved answer fm-captain-hold.sh refuses: it means "re-check reality".
export const RESERVED_ANSWER = 'reconcile';
export const ACCEPT_MAX_LENGTH = 200;

// The accept prompt over a row's full record (the home's own, never the
// ledger's cut copy) and the card text the frame shows meanwhile.
export function acceptPrompt(row, record, cardText) {
  return {
    kind: 'accept',
    row,
    id: row.hold.id,
    title: (record && record.title) || row.hold.id,
    options: parseOptions(record && record.hold_reason),
    picked: null,
    value: '',
    release: acceptRelease(record),
    card: String(cardText || ''),
  };
}

// What the prompt answers with: the picked option, else the typed line trimmed.
export function acceptAnswer(prompt) {
  if (prompt.picked) {
    const option = prompt.options.find((o) => o.letter === prompt.picked) || { letter: prompt.picked, text: '' };
    return { option };
  }
  return { text: String(prompt.value || '').trim() };
}

// Why the answer cannot be recorded, or null: it must say something, and it
// must not be the reserved word.
export function checkAcceptAnswer(answer) {
  if (answer.option) return null;
  if (!answer.text) return 'an empty answer is refused; pick an option or type one';
  if (answer.text === RESERVED_ANSWER) return `"${RESERVED_ANSWER}" is reserved by fm-captain-hold.sh (it means re-check reality); type another answer`;
  return null;
}

// Why a, d or D cannot act on this row, or null: the row's task must carry a
// captain hold (`row.hold`, lib/model.mjs) recorded in a home whose files are
// readable here. `verb` is the word the notice uses.
export function holdActionProblem(row, verb = 'discard') {
  if (!row) return `nothing selected to ${verb}`;
  if (!row.hold) return `${row.name}: no captain hold to ${verb}`;
  if (row.hold.remote) return `${row.name}: hold lives on another host (${row.home}); cannot ${verb} from here`;
  return null;
}

export function discardPrompt(row) {
  return { kind: 'discard', row, id: row.hold.id };
}

// The defer prompt, prefilled with today plus DEFER_DEFAULT_DAYS. `reason` is
// the hold's full reason, the one --reason repeats.
export function deferPrompt(row, reason, today) {
  return { kind: 'defer', row, id: row.hold.id, reason, value: plusDays(today, DEFER_DEFAULT_DAYS) };
}

// The search prompt, empty, with the cursor on the first match.
export function searchPrompt() {
  return { kind: 'search', value: '', index: 0 };
}

export const SEARCH_MAX_LENGTH = 80;

// The letters the accept prompt's options answer to, as the footer names
// them: `a`, or `a-c`.
function optionLetters(options) {
  if (!options.length) return '';
  return options.length === 1 ? options[0].letter : `${options[0].letter}-${options[options.length - 1].letter}`;
}

// The last `w` columns of `s`, led by an ellipsis when something was cut, so a
// long typed answer shows its end, where the captain is typing.
function tailFit(s, w) {
  const str = String(s);
  if (w <= 0) return '';
  if (width(str) <= w) return str;
  const chars = [...str];
  let out = '';
  let used = 0;
  for (let i = chars.length - 1; i >= 0; i -= 1) {
    const cw = charWidth(chars[i].codePointAt(0));
    if (used + cw > w - 1) break;
    out = chars[i] + out;
    used += cw;
  }
  return `…${out}`;
}

// The accept prompt's footer: the pick, the typed answer so far, or what the
// captain may do next, then the keys. `cols` bounds the line so a long answer
// is cut from the left (tailFit) and the keys stay in view.
export function acceptFooterText(prompt, cols = Infinity) {
  const head = ` accept ${prompt.id}: `;
  const tail = prompt.picked ? '  enter records  backspace unpicks  esc cancels' : '  enter records  esc cancels';
  let body;
  if (prompt.picked) {
    const o = acceptAnswer(prompt).option;
    body = `option ${o.letter} (${o.text})`;
  } else if (prompt.value) body = prompt.value;
  else if (prompt.options.length) body = `${optionLetters(prompt.options)} picks an option, or type an answer`;
  else body = 'type an answer';
  const room = cols - width(head) - width(tail);
  if (Number.isFinite(room) && width(body) > room) body = tailFit(body, room);
  return `${head}${body}${tail}`;
}

// The footer's text while a prompt is up. `matches` is the search prompt's
// match count (the renderer and the controller compute it from model.search).
export function promptText(prompt, matches = null) {
  if (!prompt) return '';
  if (prompt.kind === 'discard') return ` discard ${prompt.id}? y to discard, esc to cancel`;
  if (prompt.kind === 'accept') return acceptFooterText(prompt);
  if (prompt.kind === 'search') {
    const n = Number.isInteger(matches) ? matches : 0;
    return ` search: ${prompt.value}  ${n} match${n === 1 ? '' : 'es'}  enter jumps  esc cancels`;
  }
  return ` defer ${prompt.id} until (YYYY-MM-DD): ${prompt.value}  enter defers  esc cancels`;
}

// The keys that move through the search matches, and how far: the arrows,
// the page keys and tab / shift-tab. j and k are typed into the query.
const SEARCH_MOVES = { up: -1, down: 1, tab: 1, 'S-tab': -1, pageup: -10, pagedown: 10 };
// The keys that scroll the card behind the accept prompt, and how far; j and
// k type, as in the search.
const ACCEPT_MOVES = { up: -1, down: 1, pageup: -10, pagedown: 10 };
const hasOwn = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

// The meaning of a key while a prompt is up. Pure on (prompt, key).
export function promptKeyAction(prompt, key) {
  if (key === 'ctrl-c') return { type: 'quit' };
  if (key === 'escape') return prompt.kind === 'search' ? { type: 'search-cancel' } : { type: 'prompt-cancel' };
  if (prompt.kind === 'discard') return key === 'y' ? { type: 'discard', row: prompt.row } : { type: 'none' };
  if (prompt.kind === 'search') {
    if (key === 'enter') return { type: 'search-jump' };
    if (key === 'backspace') return { type: 'search-edit', value: prompt.value.slice(0, -1) };
    if (hasOwn(SEARCH_MOVES, key)) return { type: 'search-move', by: SEARCH_MOVES[key] };
    if (typeof key === 'string' && key.length === 1 && key >= ' ' && prompt.value.length < SEARCH_MAX_LENGTH) return { type: 'search-edit', value: prompt.value + key };
    return { type: 'none' };
  }
  if (prompt.kind === 'accept') {
    if (key === 'enter') return { type: 'accept-submit' };
    if (key === 'backspace') {
      if (prompt.value) return { type: 'accept-edit', value: prompt.value.slice(0, -1) };
      if (prompt.picked) return { type: 'accept-pick', letter: null };
      return { type: 'none' };
    }
    if (hasOwn(ACCEPT_MOVES, key)) return { type: 'accept-scroll', by: ACCEPT_MOVES[key] };
    if (typeof key === 'string' && key.length === 1 && key >= ' ') {
      // A pick waits for enter or backspace; nothing types over it.
      if (prompt.picked) return { type: 'none' };
      if (!prompt.value && prompt.options.some((o) => o.letter === key)) return { type: 'accept-pick', letter: key };
      if (prompt.value.length < ACCEPT_MAX_LENGTH) return { type: 'accept-edit', value: prompt.value + key };
    }
    return { type: 'none' };
  }
  if (key === 'enter') return { type: 'defer-submit' };
  if (key === 'backspace') return { type: 'defer-edit', value: prompt.value.slice(0, -1) };
  if (/^[0-9-]$/.test(key) && prompt.value.length < 10) return { type: 'defer-edit', value: prompt.value + key };
  return { type: 'none' };
}

// ----------------------------------------------------------------- the card
const dash = (v) => (v === null || v === undefined || v === '' ? '-' : String(v));

function days(n) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return '-';
  const d = Number(n);
  return `${d} day${d === 1 ? '' : 's'}`;
}

// Strip the home prefix so a path reads data/<id>/report.md.
function rel(path, home) {
  const h = String(home || '').replace(/\/+$/, '');
  return h && String(path).startsWith(`${h}/`) ? String(path).slice(h.length + 1) : String(path);
}

// A fence no report is likely to contain, so an inlined report's own ``` blocks
// stay inside it.
const FENCE = '````';

function fenced(lines) {
  return [FENCE, ...lines, FENCE];
}

// input:
//   id          the task id
//   home        the home path the record and files belong to
//   homeLabel   the home's label on the board (main, delegate-a, remote-sm (remote))
//   record      the backlog record (fm-fleet-snapshot.v1 backlog.records[]), or
//               a ledger-shaped stand-in, or null when no record was found
//   partial     null, or one sentence saying why the record is not the home's
//               own full record (a remote home, a failed read); it leads the card
//   materials   from lib/sources.mjs readHoldMaterials: { dataDir, files,
//               report: { path, head, total } | null, brief: { path } | null,
//               status: { path, tail, total } | null }, or null when the home's
//               files are not readable here
export function buildHoldCard({ id, home, homeLabel, record = null, partial = null, materials = null }) {
  const r = record || {};
  const out = [];
  if (partial) out.push(`> Partial record: ${partial}`, '');
  out.push(`# ${r.title || id}`, '');
  out.push('| Field | Value |', '| --- | --- |');
  out.push(`| id | ${id} |`);
  out.push(`| home | ${homeLabel || '-'} (${home}) |`);
  out.push(`| repo | ${dash(r.repo)} |`);
  out.push(`| state | ${dash(r.state)} |`);
  out.push(`| kind | ${dash(r.kind)} |`);
  out.push(`| hold kind | ${dash(r.hold_kind)} |`);
  out.push(`| bucket | ${dash(r.hold_bucket)} |`);
  out.push(`| until | ${dash(r.hold_until)} |`);
  out.push(`| set | ${dash(r.hold_set)} |`);
  out.push(`| age | ${days(r.hold_age_days)} |`);
  if (!record) out.push('', `No backlog record for ${id} was found in this home.`);
  out.push('', '## Hold reason', '');
  out.push(r.hold_reason ? String(r.hold_reason) : 'no hold reason recorded');
  out.push('', '## Backlog body', '');
  const body = Array.isArray(r.body_lines) ? r.body_lines.map((l) => String(l)) : [];
  if (body.length) out.push(...body);
  else out.push('no body lines');
  out.push('', '## Pull request', '');
  out.push(r.pr_url ? String(r.pr_url) : 'no PR recorded');
  const dataDir = `data/${id}`;
  out.push('', '## Report', '');
  if (!materials) out.push(`${dataDir}/report.md: not readable from here`);
  else if (materials.report) {
    const rep = materials.report;
    const shown = rep.head.length;
    out.push(`${rel(rep.path, home)} (${rep.total} line${rep.total === 1 ? '' : 's'}; the first ${shown} follow)`, '');
    out.push(...fenced(rep.head));
    const more = rep.total - shown;
    if (more > 0) out.push('', `${more} more line${more === 1 ? '' : 's'} in the file`);
  } else out.push(`no report at ${dataDir}/report.md`);
  out.push('', '## Brief', '');
  if (!materials) out.push(`${dataDir}/brief.md: not readable from here`);
  else if (materials.brief) out.push(rel(materials.brief.path, home));
  else out.push(`no brief at ${dataDir}/brief.md`);
  out.push('', `## Other files under ${dataDir}/`, '');
  if (!materials) out.push('not readable from here');
  else if (materials.files === null) out.push(`no ${dataDir}/ directory`);
  else if (materials.files.length) out.push(...materials.files.map((f) => `- ${rel(f, home)}`));
  else out.push(`no other files under ${dataDir}/`);
  out.push('', '## Status log', '');
  const statusPath = `state/${id}.status`;
  if (!materials) out.push(`${statusPath}: not readable from here`);
  else if (materials.status) {
    const st = materials.status;
    out.push(`${rel(st.path, home)}, the last ${st.tail.length} of ${st.total} line${st.total === 1 ? '' : 's'}:`, '');
    out.push(...fenced(st.tail));
  } else out.push(`no status log at ${statusPath}`);
  out.push('');
  return out.join('\n');
}
