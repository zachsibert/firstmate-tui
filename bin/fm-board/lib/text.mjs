// lib/text.mjs - pure text helpers shared by the model, layout and renderer.
// No terminal library here: every function takes strings and numbers and
// returns strings and numbers, so tests can pin behavior through the
// --render-once frame without a TTY.

// Display width of one code point: 0 for control/combining marks, 2 for wide
// East Asian and emoji ranges, 1 otherwise. A small table is enough for the
// titles and paths the board shows; exotic scripts fall back to width 1.
export function charWidth(cp) {
  if (cp === 0 || cp < 32 || (cp >= 0x7f && cp < 0xa0)) return 0;
  if (cp >= 0x300 && cp <= 0x36f) return 0;
  if (cp === 0x200b || cp === 0x200d || cp === 0xfe0f) return 0;
  if (
    (cp >= 0x1100 && cp <= 0x115f) ||
    (cp >= 0x2e80 && cp <= 0xa4cf) ||
    (cp >= 0xac00 && cp <= 0xd7a3) ||
    (cp >= 0xf900 && cp <= 0xfaff) ||
    (cp >= 0xfe30 && cp <= 0xfe4f) ||
    (cp >= 0xff00 && cp <= 0xff60) ||
    (cp >= 0xffe0 && cp <= 0xffe6) ||
    (cp >= 0x1f300 && cp <= 0x1f64f) ||
    (cp >= 0x1f900 && cp <= 0x1f9ff) ||
    (cp >= 0x20000 && cp <= 0x3fffd)
  ) {
    return 2;
  }
  return 1;
}

export function width(s) {
  let w = 0;
  for (const ch of String(s)) w += charWidth(ch.codePointAt(0));
  return w;
}

// One line of clean text: tabs, newlines and control characters become
// spaces and runs of whitespace collapse, so a multi-line status note never
// breaks the grid.
export function clean(s) {
  if (s === null || s === undefined) return '';
  return String(s)
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

// Truncate to a display width, appending an ellipsis when something was cut.
export function truncate(s, w) {
  const str = String(s);
  if (w <= 0) return '';
  if (width(str) <= w) return str;
  if (w === 1) return '…';
  let out = '';
  let used = 0;
  for (const ch of str) {
    const cw = charWidth(ch.codePointAt(0));
    if (used + cw > w - 1) break;
    out += ch;
    used += cw;
  }
  return out + '…';
}

export function padRight(s, w) {
  const str = String(s);
  const missing = w - width(str);
  return missing > 0 ? str + ' '.repeat(missing) : str;
}

export function padLeft(s, w) {
  const str = String(s);
  const missing = w - width(str);
  return missing > 0 ? ' '.repeat(missing) + str : str;
}

// Exactly w columns wide: truncated when longer, padded when shorter.
export function fit(s, w, align = 'left') {
  const t = truncate(clean(s), w);
  return align === 'right' ? padLeft(t, w) : padRight(t, w);
}

// Same as fit() for text that is already one clean line (for example a row
// whose cells were padded by fit()): truncate and pad without collapsing the
// column padding.
export function fitRaw(s, w, align = 'left') {
  const t = truncate(String(s), w);
  return align === 'right' ? padLeft(t, w) : padRight(t, w);
}

// Compact age: 12s, 5m, 3h, 2d. null/undefined/NaN -> "-".
export function fmtAge(seconds) {
  if (seconds === null || seconds === undefined || Number.isNaN(seconds)) return '-';
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

// ISO-8601 or YYYY-MM-DD -> epoch seconds, or null when unparseable.
export function parseTime(s) {
  if (!s || typeof s !== 'string') return null;
  const ms = Date.parse(/^\d{4}-\d{2}-\d{2}$/.test(s) ? `${s}T00:00:00Z` : s);
  return Number.isNaN(ms) ? null : Math.floor(ms / 1000);
}

// owner/repo and number from a GitHub pull, issue or discussion URL, or null.
export function repoFromUrl(url) {
  const m = /^https?:\/\/[^/]+\/([^/]+)\/([^/]+)\/(?:pull|issues|discussions)\/(\d+)/.exec(String(url || ''));
  return m ? { repo: `${m[1]}/${m[2]}`, num: m[3] } : null;
}

// Strip a home prefix from an absolute path so reports read as data/x/report.md.
export function relativeTo(path, home) {
  if (!path) return '';
  if (home && path.startsWith(`${home}/`)) return path.slice(home.length + 1);
  return path;
}

export function basename(path) {
  const parts = String(path || '').replace(/\/+$/, '').split('/');
  return parts[parts.length - 1] || '';
}
