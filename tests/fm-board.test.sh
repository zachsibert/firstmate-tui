#!/usr/bin/env bash
# tests/fm-board.test.sh - behavior tests for firstmate-tui through its
# executable interface: `bin/firstmate-tui.sh --render-once --fixture <json>
# --no-herdr` prints
# one frame, and every assertion reads that frame. No firstmate home, herdr
# server or TTY is needed. Row assertions are anchored regexes over one frame
# line (`+` absorbs column padding) so they pin column order and content, not
# exact widths. Each check's comment names what to delete or change to make it
# fail (the "falsification" column in the PR body).
#
# Key-driven checks use `--keys <list>` (pressed through lib/controller.mjs
# before the frame renders) and `--expand <all|ids>`; a PR open goes to
# `--opener-cmd`, here tests/fake-opener.sh, which only appends its argv to
# FM_BOARD_TEST_OPENER_LOG. No browser is ever launched. A Findings enter
# goes to `--viewer-cmd`, here tests/fake-viewer.sh (argv to
# FM_BOARD_TEST_VIEWER_LOG); without --viewer-cmd a one-shot render only
# reports the viewer the PATH chain resolved to, so the suite shadows glow with
# the fake on PATH and no real viewer ever runs. Mouse gestures go through
# `--mouse <list>` (click:X,Y, dblclick:X,Y, tripleclick:X,Y, wheel:up:X,Y,
# wheel:down:X,Y, drag:X1,Y->X2 (press, motion in steps, release), move:X,Y,
# release:X,Y and key names, in order with --keys; X the column and Y the
# line, from 0 at the top-left cell), which feeds lib/controller.mjs
# handleMouse the same event objects the terminal adapter would, measured
# against the frame the app would have drawn, so no terminal library and no
# pointer is involved; what the adapter itself makes of the library's mouse
# events is checked by calling its pure functions. Hidden rows and panes go to
# `--view-state <temp file>` (a saved selection in that file is restored, never
# recorded, by a one-shot render), the state cache to `--cache <temp file>` (a
# render over a fixture that has everything writes it, a cold-start fixture
# reads it), the config file to `--config <temp file>` or a
# temporary XDG_CONFIG_HOME. The r key is checked against a stand-in firstmate
# home whose bin/fm-fleet-snapshot.sh and bin/fm-bearings-snapshot.sh only log
# that they ran and print canned JSON (the populated fixture's snapshot;
# tests/fixtures/bearings-prs.json), with tests/fake-gh.sh first on PATH as
# `gh` (it logs each call and answers `api user` with a login and `api
# graphql` with canned PRs, dispatched on the search string or the lookup's
# aliases; it fails on `pr list`), so a live --render-once with --keys r shows
# exactly which fetches a refresh triggers without GitHub or a real home; a run
# under a PATH holding no gh proves the fallback to the firstmate script, and a
# config file with prs.source firstmate proves the opt-in to it with gh there.
# Every live render must put the fake gh first on PATH, or the board's own
# fetch reaches the real GitHub CLI. The identity chain (the config file, then gh,
# then git) runs against a temporary config directory, the fake gh and a fake
# git that answers `config --get github.user` alone. The refresh schedule
# itself (the local cycle runs the snapshot on the tick and asks for one
# GitHub cycle without awaiting it; a tick during a running snapshot is
# skipped, a landing during a running fetch leaves one follow-up) is checked
# by running the app with --headless against a stand-in whose snapshot sleeps
# and against one whose gh sleeps (FAKE_GH_SLEEP), then stopping it with a
# signal; --headless draws nothing, reads no key and never loads neo-blessed.
# The wrapper checks that touch the detached routes run with a fake `herdr` on
# HERDR_BIN_PATH and PATH (herdr sets HERDR_BIN_PATH inside its panes, so PATH
# alone would still reach the captain's live server); the fake logs its argv
# and fails, and the suite asserts it was never called.
# The Settings page (`.`) is checked with --install-root pointing at a fake
# install prefix (a package.json version, an install-record and
# tests/fake-upgrade.sh as its bin/firstmate-tui.sh, which logs its argv and prints
# installer-like lines) or at a directory with no record for the checkout
# case, and with `--curl-cmd bash tests/fake-curl.sh` serving the releases API
# from tests/fixtures/releases/api, so no upgrade, download or GitHub call is
# ever real. The launcher's relaunch loop (exit 75 starts the board again) runs
# against tests/fake-node.sh on PATH, which logs its calls and runs nothing.
# The terminal adapter's key mapping (lib/tui-blessed.mjs normalizeKey) is
# checked directly for the one case a one-shot render cannot reach: the two
# keypress events the library emits for one Enter press must become one key.
# The last section then runs the interactive board itself on a
# pseudo-terminal (tests/pty-keys.py, python3) and types raw bytes into it,
# so the library's input path is covered end to end: one carriage return on
# a PR row is one opener call, one on a Settings entry is one pending
# prompt, under each TERM the host has terminfo for. It is skipped with a
# note without python3 or bin/firstmate-tui/node_modules.
#
# Fixtures (tests/fixtures/):
#   populated.json  160x44, every pane has rows: a blocked worker, a keyed
#                   decision, a live captain hold, a secondmate hold and a
#                   secondmate-relayed decision, a green-unmerged PR, a done
#                   task with a merged PR, recorded PRs (one live candidate
#                   with a creation time), herdr statuses, a tmux task, a
#                   remote cached home, reports and landed rows, an empty
#                   Teammates' PRs pane, and a refresh block ({"next_in": 18}) standing
#                   in for the app's schedule; the refreshing, failed and
#                   herdr-state variants are derived from it at run time
#                   (variant). 44 rows: six panes need the room; the mouse and
#                   line-number checks name lines on this frame
#   my-prs.json     160x44, My PRs as the union: the identity's own open PR in
#                   a repository no task touches, a bot-authored PR recorded on
#                   a task, the identity's PRs merged and closed inside the
#                   window, a recorded PR the fetch did not return, and a
#                   Teammates' PRs row that must stay out of My PRs
#   to-review.json  160x44, Teammates' PRs: one PR per STATUS word (DRAFT, IN
#                   REVIEW, CHANGES REQUESTED, APPROVED, MERGED), a request
#                   through a team, a labelled portal PR, a PR merged outside
#                   the window and the identity's own PR, both dropped, the
#                   AUTHOR column (a long login, a null author) and the scope
#                   the fetch searched
#   pr-ages.json    160x40, My PRs AGE sources: candidates with a
#                   creation time, without one, with a future and a malformed
#                   one, the camel-case alias, no-task candidates and a
#                   recorded PR missing from the live list
#   pr-status.json  160x44, My PRs STATUS: one PR per status (DRAFT,
#                   IN REVIEW, APPROVED, CLOSED, MERGED), a merged PR 11h59m and
#                   one 12h01m before now, an open PR of a done task, a closed PR
#                   with no time stamp, a closed draft and an unlisted recorded PR
#   review-rows.json  160x60, Captain's Call review rows and the words that go
#                   with them: a done and a paused main-home task with clean
#                   open PRs, a task repairing a conflicting PR after a done
#                   line (status_logs), one on its first pass, a closed and a
#                   merged PR inside the tail, a secondmate ledger naming a
#                   parked child's PR and a repairing child's through
#                   contributions.captain, and a blocked worker, a keyed
#                   decision and a live hold for the sort
#   column-widths.json  160x40, the column-spacing screenshot's shape: three
#                   captain holds with a long organisation/repo name and HOME
#                   main, seven live PRs with long titles and BASE main, three
#                   workers on one repository, Findings and Recently Landed empty
#   grouped.json    160x44, Underway grouping: two secondmate homes, one with
#                   four children (a keyed decision, a blocked child with a hold
#                   reason) plus live and dated captain holds, one quiet
#   inflight-live.json  160x60, Underway from live work only: six delegate
#                   homes whose own records all read done (no children; two
#                   working children; endpoints only, one done, one unknown
#                   on tmux, one unknown with its pane gone, one unknown with a
#                   pane; one relayed decision; one ledger captain hold; one
#                   failed child), a failed main-home task under a live captain
#                   hold, a done one with an unmerged PR, and a merged one whose
#                   record was cleaned up (Recently Landed only)
#   empty.json      120x40, every pane empty, no herdr block
#   narrow.json     70x24, list mode with section headers, a cached local home
#   lost.json       160x40, a main worker and a secondmate child whose panes
#                   are absent from the herdr block (pane lost), a live one, a
#                   main scout report and a secondmate landed report
#   lost-disconnected.json  160x30, the same lost pane with herdr disconnected
#   landed-targets.json  160x44, one Recently Landed row per target shape for the enter
#                   fallback: main-home done rows with a PR (and a lost pane),
#                   a report only, a live pane only and nothing; a local
#                   secondmate's landed entries with a PR, a live pane, a report
#                   and nothing; a remote home's report-only entry
#   holds.json      160x60, the hold cards and the d / D actions: a keyed
#                   decision on a working task with a pane, two live captain
#                   holds (one with a PR, a report, a brief, other files and a
#                   status log on disk, one with none), a review row, a paused
#                   task whose record is a dated captain hold (Underway), a
#                   done task that was a captain hold (Recently Landed), a delegate
#                   home with two captain holds and a remote home with one;
#                   its two home paths are placeholders the suite rewrites to
#                   scratch homes holding the files, a fake fm-fleet-snapshot.sh
#                   and tests/fake-captain-hold.sh (the hold section below)
#   accept.json     160x44, the a key over the same two placeholder homes as
#                   holds.json: option-hold (kind captain, a reason with
#                   Options: a. b. c.), work-hold (kind ship), nokind-hold (no
#                   kind), the delegate's and the remote home's holds and a
#                   review row (the accept section below)
#   search.json     160x44, the f key: a delegate home (delegate-a) whose
#                   two live captain-hold decisions, portal-mdm-gap-analysis
#                   and portal-ingest-expired-token-scout, are Captain's
#                   Call rows drawn from its ledger, and whose two live
#                   children sit behind a collapsed Underway group; one
#                   queued main item, Charted Next's row; twenty-three
#                   Recently Landed rows (merges, reported scouts, a hold's
#                   report and the delegate's two) so the pane caps with +8
#                   more and its oldest, ship-17 and the reported
#                   archive-owner-scout, sit below the fold; the test hides
#                   legacy-import-scout through a view-state file
#   bearings-prs.json  not a frame: what the stand-in home's
#                   fm-bearings-snapshot.sh prints, three rows in the script's
#                   shape, one carrying the head commit's contexts (its _note
#                   says what each proves)
#   cold-start.json 120x40, the first refresh in flight with nothing landed:
#                   no snapshot, no prs block, no herdr block, so every pane
#                   shows its loading spinner (the two PR panes each naming
#                   their own GitHub source, since a fixture without an
#                   identity stands for a known login); the landed, failed,
#                   frame, narrow and identity-pending (prs.identity null:
#                   both PR panes spin on the identity instead) variants are
#                   derived from it at run time
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BOARD="$ROOT/bin/firstmate-tui.sh"
FIX="$ROOT/tests/fixtures"
FAKE_OPENER="bash $ROOT/tests/fake-opener.sh"
FAKE_VIEWER="bash $ROOT/tests/fake-viewer.sh"
OPENER_LOG=$(mktemp "${TMPDIR:-/tmp}/fm-board-opener.XXXXXX")
VIEWER_LOG=$(mktemp "${TMPDIR:-/tmp}/fm-board-viewer.XXXXXX")
FETCH_LOG=$(mktemp "${TMPDIR:-/tmp}/fm-board-fetch.XXXXXX")
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-board-test.XXXXXX")
rm -f "$OPENER_LOG" "$VIEWER_LOG" "$FETCH_LOG"
trap 'rm -rf "$OPENER_LOG" "$VIEWER_LOG" "$FETCH_LOG" "$SCRATCH"' EXIT
# Fake on PATH: `glow` (the viewer chain's first rung).
FAKE_BIN="$SCRATCH/bin"
mkdir -p "$FAKE_BIN"
cp "$ROOT/tests/fake-viewer.sh" "$FAKE_BIN/glow"
chmod +x "$FAKE_BIN/glow"
# Fake on PATH: `gh` (the board's own PR fetch and its identity rung), logging each call to
# FM_BOARD_TEST_FETCH_LOG and answering `api user` and the `api graphql` searches and lookup with
# canned PRs (tests/fake-gh.sh names them). Every live render below puts FAKE_BIN first on PATH so
# that no fetch reaches GitHub.
cp "$ROOT/tests/fake-gh.sh" "$FAKE_BIN/gh"
chmod +x "$FAKE_BIN/gh"
# Fake on HERDR_BIN_PATH and PATH: `herdr`, for the wrapper checks and the Recently Landed focus checks: it logs every call to
# FM_BOARD_TEST_HERDR_LOG, answers `plugin config-dir` with a scratch directory and fails
# everything else, so no wrapper path can reach the captain's live server.
HERDR_LOG="$SCRATCH/herdr-calls.log"
PLUGIN_DIR="$SCRATCH/plugin-config"
# shellcheck disable=SC2016 # the fake expands $FM_BOARD_TEST_HERDR_LOG at run time, not here
printf '#!/usr/bin/env bash\necho "herdr $*" >> "$FM_BOARD_TEST_HERDR_LOG"\nif [ "${1:-} ${2:-}" = "plugin config-dir" ]; then echo "%s"; exit 0; fi\nexit 1\n' "$PLUGIN_DIR" > "$FAKE_BIN/herdr"
chmod +x "$FAKE_BIN/herdr"
# fake_herdr_env <command...>: run with the fake herdr reachable and the call log reset
fake_herdr_env() {
  rm -f "$HERDR_LOG"
  FM_BOARD_TEST_HERDR_LOG="$HERDR_LOG" HERDR_BIN_PATH="$FAKE_BIN/herdr" PATH="$FAKE_BIN:$PATH" "$@"
}
# A stand-in firstmate home for the live-refresh checks: both snapshot scripts
# append one line to FM_BOARD_TEST_FETCH_LOG and print canned JSON (the
# populated fixture's snapshot; the three PR rows of
# tests/fixtures/bearings-prs.json). Nothing reaches GitHub.
FAKE_HOME="$SCRATCH/firstmate"
mkdir -p "$FAKE_HOME/bin"
node -e 'process.stdout.write(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).snapshot))' "$FIX/populated.json" > "$FAKE_HOME/snapshot.json"
# shellcheck disable=SC2016 # the fakes expand $FM_BOARD_TEST_FETCH_LOG at run time, not here
printf '#!/usr/bin/env bash\necho snapshot >> "$FM_BOARD_TEST_FETCH_LOG"\ncat "%s"\n' "$FAKE_HOME/snapshot.json" > "$FAKE_HOME/bin/fm-fleet-snapshot.sh"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "prs $*" >> "$FM_BOARD_TEST_FETCH_LOG"\ncat "%s"\n' "$FIX/bearings-prs.json" > "$FAKE_HOME/bin/fm-bearings-snapshot.sh"
chmod +x "$FAKE_HOME/bin/fm-fleet-snapshot.sh" "$FAKE_HOME/bin/fm-bearings-snapshot.sh"
# The stand-in's fm-captain-hold.sh is the fake too, so the pty section's D prompt never reaches a
# real firstmate command (tests/fake-captain-hold.sh logs to FM_BOARD_TEST_HOLD_LOG).
cp "$ROOT/tests/fake-captain-hold.sh" "$FAKE_HOME/bin/fm-captain-hold.sh"
chmod +x "$FAKE_HOME/bin/fm-captain-hold.sh"
HOLD_LOG="$SCRATCH/hold-calls.log"
FAKE_HOME_REAL=$(cd "$FAKE_HOME" && pwd -P) # the cwd the fake logs, the temp directory's symlink resolved

fails=0
checks=0

pass() { checks=$((checks + 1)); }
fail() {
  fails=$((fails + 1))
  checks=$((checks + 1))
  printf 'FAIL: %s\n' "$*" >&2
}

# assert_contains <frame> <fixed string> <label>
assert_contains() {
  if printf '%s\n' "$1" | grep -Fq -- "$2"; then pass; else fail "$3: expected to find '$2'"; fi
}
assert_not_contains() {
  if printf '%s\n' "$1" | grep -Fq -- "$2"; then fail "$3: did not expect '$2'"; else pass; fi
}
# assert_row <frame> <extended regex> <label>: some frame line matches
assert_row() {
  if printf '%s\n' "$1" | grep -Eq -- "$2"; then pass; else fail "$3: no line matches /$2/"; fi
}
assert_no_row() {
  if printf '%s\n' "$1" | grep -Eq -- "$2"; then fail "$3: a line matches /$2/"; else pass; fi
}
# assert_before <frame> <regex a> <regex b> <label>: first match of a precedes first match of b
assert_before() {
  local a b
  a=$(printf '%s\n' "$1" | grep -En -- "$2" | head -n 1 | cut -d: -f1)
  b=$(printf '%s\n' "$1" | grep -En -- "$3" | head -n 1 | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then pass; else fail "$4: expected /$2/ (line ${a:-none}) before /$3/ (line ${b:-none})"; fi
}
# assert_count <frame> <fixed string> <n> <label>: exactly n lines contain the string
assert_count() {
  local n
  n=$(printf '%s\n' "$1" | grep -Fc -- "$2")
  if [ "$n" -eq "$3" ]; then pass; else fail "$4: expected $3 lines with '$2', got $n"; fi
}
# The cursor bar's tags (lib/tui-blessed.mjs `selected`): the terminal's inverse video, as before
# 0.6.1, never a colour of the board's own; the amber 0.6.1 put behind the row marks the focused pane's
# border instead ({bold}{214-fg}, palette colour 214 named by its index because neo-blessed 0.2.0 turns
# a hex tag into a basic colour; the pty section checks the bytes a terminal gets). SEL and SEL_END are
# the ERE-escaped open and close for assert_row, SEL_TAG the plain open for a fixed-string count.
SEL='\{inverse\}'
SEL_END='\{/inverse\}'
SEL_TAG='{inverse}'
# assert_lines <frame> <n> <label>
assert_lines() {
  local n
  n=$(printf '%s\n' "$1" | wc -l | tr -d ' ')
  if [ "$n" -eq "$2" ]; then pass; else fail "$3: expected $2 lines, got $n"; fi
}
# assert_widths <frame> <cols> <label>: every line is exactly cols display columns
assert_widths() {
  local bad
  bad=$(printf '%s\n' "$1" | node --input-type=module -e "
    import { width } from '$ROOT/bin/firstmate-tui/lib/text.mjs';
    let src = '';
    process.stdin.on('data', (d) => (src += d));
    process.stdin.on('end', () => {
      const lines = src.replace(/\n\$/, '').split('\n');
      const bad = lines.map((l, i) => [i + 1, width(l)]).filter(([, w]) => w !== $2);
      process.stdout.write(bad.map(([i, w]) => i + ':' + w).join(' '));
    });")
  if [ -z "$bad" ]; then pass; else fail "$3: lines with width != $2 -> $bad"; fi
}

render() { # <fixture name under tests/fixtures, or an absolute path> [extra flags...]
  local fixture=$1
  shift
  case $fixture in /*) ;; *) fixture="$FIX/$fixture" ;; esac
  "$BOARD" --render-once --fixture "$fixture" --no-herdr "$@"
}
# variant <fixture> <name> <json patch>: a copy of the fixture under SCRATCH with the patch's
# top-level keys replacing the fixture's, an object value merged one level deep (so a herdr or prs
# patch keeps the fixture's agents or candidate list); prints the copy's path for render()
variant() {
  local out="$SCRATCH/variant-$2.json"
  node -e '
    const fs = require("fs");
    const [src, dst, patchText] = process.argv.slice(1);
    const fx = JSON.parse(fs.readFileSync(src, "utf8"));
    const patch = JSON.parse(patchText);
    const isObj = (v) => v && typeof v === "object" && !Array.isArray(v);
    for (const [k, v] of Object.entries(patch)) fx[k] = isObj(v) && isObj(fx[k]) ? { ...fx[k], ...v } : v;
    fs.writeFileSync(dst, JSON.stringify(fx));
  ' "$FIX/$1" "$out" "$3"
  printf '%s\n' "$out"
}
# render_open <fixture> <keys>: render with the fake opener recording into OPENER_LOG (reset first)
render_open() {
  rm -f "$OPENER_LOG"
  FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" "$BOARD" --render-once --fixture "$FIX/$1" --no-herdr --keys "$2" --opener-cmd "$FAKE_OPENER"
}
# assert_opened <expected file content> <label>: the fake opener was called exactly with these lines
assert_opened() {
  if [ -f "$OPENER_LOG" ] && [ "$(cat "$OPENER_LOG")" = "$1" ]; then pass; else fail "$2: opener log is '$(cat "$OPENER_LOG" 2>/dev/null || echo '<absent>')', expected '$1'"; fi
}
assert_not_opened() {
  if [ -e "$OPENER_LOG" ]; then fail "$1: opener was called with '$(cat "$OPENER_LOG")'"; else pass; fi
}
# render_view <fixture> <keys> [viewer argv]: render with the fake viewer recording into VIEWER_LOG (reset first)
render_view() {
  rm -f "$VIEWER_LOG"
  FM_BOARD_TEST_VIEWER_LOG="$VIEWER_LOG" "$BOARD" --render-once --fixture "$FIX/$1" --no-herdr --keys "$2" --viewer-cmd "${3:-$FAKE_VIEWER}"
}
assert_viewed() {
  if [ -f "$VIEWER_LOG" ] && [ "$(cat "$VIEWER_LOG")" = "$1" ]; then pass; else fail "$2: viewer log is '$(cat "$VIEWER_LOG" 2>/dev/null || echo '<absent>')', expected '$1'"; fi
}
assert_not_viewed() {
  if [ -e "$VIEWER_LOG" ]; then fail "$1: viewer was called with '$(cat "$VIEWER_LOG")'"; else pass; fi
}
# assert_file_contains <file> <fixed string> <label>
assert_file_contains() {
  if [ -f "$1" ] && grep -Fq -- "$2" "$1"; then pass; else fail "$3: expected '$2' in $1 (content: $(tr -d '\n' < "$1" 2>/dev/null || echo '<absent>'))"; fi
}
assert_file_not_contains() {
  if [ -f "$1" ] && grep -Fq -- "$2" "$1"; then fail "$3: did not expect '$2' in $1"; else pass; fi
}
# render_mouse <fixture> <mouse list> [extra flags...]: render with --mouse, the fake opener and the
# fake viewer both recording (their logs reset first), so a gesture can never reach a browser or editor
render_mouse() {
  local fixture=$1 mouse=$2
  shift 2
  rm -f "${OPENER_LOG:?}" "${VIEWER_LOG:?}"
  FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" FM_BOARD_TEST_VIEWER_LOG="$VIEWER_LOG" "$BOARD" --render-once --fixture "$FIX/$fixture" --no-herdr --mouse "$mouse" --opener-cmd "$FAKE_OPENER" --viewer-cmd "$FAKE_VIEWER" "$@"
}
# render_live [flags]: a one-shot render of the stand-in home (no fixture), fetch log reset first, the
# fake gh first on PATH
render_live() {
  rm -f "${FETCH_LOG:?}"
  FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" PATH="$FAKE_BIN:$PATH" "$BOARD" --render-once --no-herdr "$@"
}
# assert_fetch_log <expected lines> <label>: the gh calls of one refresh start together, so their log
# lines land in any order; both sides are compared sorted.
assert_fetch_log() {
  if [ -f "$FETCH_LOG" ] && [ "$(sort "$FETCH_LOG")" = "$(printf '%s\n' "$1" | sort)" ]; then pass; else fail "$2: fetch log is '$(cat "$FETCH_LOG" 2>/dev/null || echo '<absent>')', expected (in any order) '$1'"; fi
}

# ------------------------------------------------------------- populated
frame=$(render populated.json) || fail "populated: render exited non-zero"

# Pane order and counts (falsify: reorder PANES in lib/layout.mjs, or delete a row source in the fixture).
# Captain's Call lists every home's live calls: four main-home rows plus the delegate's hold and its
# relayed decision; Underway is the live workers only: four main rows, the delegate-a group and the
# remote home's one worker; Charted Next is the dated hold; Recently Landed is four completions plus
# the report whose task has no Done row.
assert_contains "$frame" "Captain's Call (6)" "populated Captain's Call count (every home's live calls)"
assert_contains "$frame" "My PRs (3)" "populated review count (two recorded PRs plus the live candidate; live PR data is the default)"
assert_contains "$frame" "Underway (6)" "populated Underway count (four main rows, one group, one delegate worker drawn directly)"
assert_contains "$frame" "Charted Next (1)" "populated Charted Next count (the dated hold)"
assert_contains "$frame" "Recently Landed (5)" "populated Recently Landed count (four completions and one report)"
assert_before "$frame" "Captain's Call \(6\)" "Underway \(6\)" "pane order 1: Captain's Call leads (falsify: put inflight first in PANES)"
assert_before "$frame" "Underway \(6\)" "My PRs \(3\)" "pane order 2"
assert_before "$frame" "My PRs \(3\)" "Charted Next \(1\)" "pane order 3"
assert_before "$frame" "Charted Next \(1\)" "Recently Landed \(5\)" "pane order 4"

# Every pane title leads with its toggle key, btop-style (falsify: drop the badge segment from the
# top border in renderPanes, or change paneBadge).
assert_contains "$frame" "┌─ [1] Captain's Call (6) ─" "badge on Captain's Call"
assert_contains "$frame" "┌─ [3] My PRs (3) ─" "badge on My PRs"
assert_contains "$frame" "┌─ [2] Underway (6) ─" "badge on Underway"
assert_contains "$frame" "┌─ [5] Charted Next (1) ─" "badge on Charted Next"
assert_contains "$frame" "┌─ [6] Recently Landed (5) ─" "badge on Recently Landed"
assert_count "$frame" "┌─ [" 6 "exactly six badges, one per pane"
assert_no_row "$frame" '^┌─ \[[1-6]\] Findings' "no Findings pane: reports live in Recently Landed (falsify: put findings back in PANES)"
# With --tags the badge is its own grey segment between the border segments (falsify: give the badge the
# border style, or drop `badge` from STYLE_TAGS).
tags=$(render populated.json --tags) || fail "populated --tags: render exited non-zero"
assert_row "$tags" '\{blue-fg\}┌─ \{/blue-fg\}\{grey-fg\}\[3\]\{/grey-fg\}\{blue-fg\} My PRs \(3\)' "--tags: the badge is grey and the title keeps the border color"
assert_count "$tags" "{grey-fg}[" 6 "--tags: six grey badges"
# The focused pane's whole border is bold amber 214 (Captain's Call holds the focus at start), its badge
# still grey between the border segments, and an unfocused border is plain blue; no cyan is left
# anywhere (falsify: put {cyan-fg} back in STYLE_TAGS['border-focus'], or give the badge the border
# style).
assert_row "$tags" '\{bold\}\{214-fg\}┌─ \{/214-fg\}\{/bold\}\{grey-fg\}\[1\]\{/grey-fg\}\{bold\}\{214-fg\} Captain.s Call \(6\)' "--tags: the focused pane's title line is bold amber around a grey badge"
assert_row "$tags" '\{bold\}\{214-fg\}│ \{/214-fg\}\{/bold\}.*\{bold\}\{214-fg\} │\{/214-fg\}\{/bold\}$' "--tags: the focused pane's side borders are bold amber"
assert_row "$tags" '^\{bold\}\{214-fg\}└─+┘\{/214-fg\}\{/bold\}$' "--tags: the focused pane's bottom border is bold amber"
assert_not_contains "$tags" "{cyan-fg}" "--tags: no cyan anywhere in the frame (falsify: keep the cyan focus border)"
# The cursor bar is the terminal's inverse video on every cell of the selected row, as before 0.6.1,
# and nothing in a frame carries the amber background or, beyond the title line's black on white, the
# black text 0.6.1 drew the bar with. A selected row's base style is `selected` alone (lib/render.mjs
# rowSegments), so a selected flagged row's yellow gives way to the plain inverse bar, while a
# cell with its own colour keeps it inside the bar: a selected pane-lost cell stays red, a selected
# unknown HERDR cell stays grey; the unselected rows keep their colours (falsify: put
# {214-bg}{black-fg} back in STYLE_TAGS.selected, or filter names out of tagsFor for a selected cell).
# The flagged row is Underway's delegate-a group, whose home has a call in Captain's Call.
assert_row "$tags" "^.*${SEL}blocked *${SEL_END}.*${SEL}scout-beta +${SEL_END}.*${SEL} 2h${SEL_END}" "--tags: the selected Captain's Call row is drawn inverse, first cell to last"
assert_count "$tags" "$SEL_TAG" 1 "--tags: one row carries the bar"
assert_not_contains "$tags" "{214-bg}" "--tags: nothing is drawn on the amber background (falsify: keep the 0.6.1 bar)"
assert_count "$tags" "{black-fg}" 1 "--tags: the title line is the one line with black text (falsify: keep the 0.6.1 bar's black text)"
assert_row "$tags" '\{yellow-fg\}working +\{/yellow-fg\}\{yellow-fg\} +\{/yellow-fg\}\{yellow-fg\}1 live' "--tags: the unselected flagged group row is yellow (falsify: drop flag from ledgerEntry's group row)"
assert_no_row "$tags" '\{yellow-fg\}decide' "--tags: a Captain's Call decide row is not yellow: the flag marks a worker whose task is also the captain's, never a call (falsify: set flag on taskDecisionRows)"
tags_sel=$(render populated.json --tags --keys "tab,j,j") || fail "populated --tags tab,j,j: render exited non-zero"
assert_row "$tags_sel" "${SEL}working +${SEL_END}.*${SEL}!▸ delegate-a *${SEL_END}" "--tags: the selected flagged group row is plain inverse, its yellow given way"
assert_no_row "$tags_sel" "${SEL}\{yellow-fg\}" "--tags: no yellow text inside the bar"
tags_sel=$(render populated.json --tags --rows 48 --keys "tab,j,j,l,j,j") || fail "populated --tags lost row: render exited non-zero"
assert_row "$tags_sel" "${SEL}\{red-fg\}pane lost\{/red-fg\}${SEL_END}" "--tags: a selected row's pane-lost cell keeps its red text inside the bar"
assert_row "$tags_sel" "${SEL}failed +${SEL_END}" "--tags: the rest of that row is plain inverse"
tags_sel=$(render lost-disconnected.json --tags --keys "tab,j") || fail "lost-disconnected --tags tab,j: render exited non-zero"
assert_row "$tags_sel" "${SEL}\{grey-fg\}unknown *\{/grey-fg\}${SEL_END}" "--tags: a selected row's unknown HERDR cell keeps its grey text inside the bar"
assert_row "$(render lost-disconnected.json --tags)" '\{grey-fg\}unknown *\{/grey-fg\}' "--tags: the same cell unselected is still grey"

# Pane headers are `[n] Name (count)` and nothing else: the snapshot and checks ages, and the herdr
# state, are gone from them (falsify: put snapshotLabel or herdrLabel back into paneHeader in
# lib/model.mjs). The countdown and the herdr warning have their own section below.
assert_no_row "$frame" '^┌─ \[[1-6]\] [^─]*(ago|snapshot|herdr|checks)' "no pane header carries an age, a snapshot, herdr or checks word"
assert_count "$frame" " ago" 0 "nothing on the populated frame says N ago: no header age, and the title counts down instead"
assert_row "$frame" '^ firstmate-tui · /fixture/firstmate · 3 homes ' "the title line leads with firstmate-tui and counts the main home plus two secondmate homes (falsify: put fm-board back in titleLine)"

# Captain's Call rows (falsify: remove scout-beta's blocked_event, ship-alpha's open_decisions entry,
# decide-vendor's hold_bucket=live, or ship-gamma's pr.url).
assert_row "$frame" '^│ blocked +- +scout-beta +blocked: gh auth expired +acme/api +main +2h │$' "blocked worker row with repo, home and age"
assert_row "$frame" '^│ decide +db-choice +ship-alpha +Postgres or SQLite for the cache\? +acme/widgets +main +5m │$' "keyed decision row shows key, task, summary"
assert_row "$frame" '^│ hold +- +decide-vendor +Pick the vendor for the address API · Two quotes in the report +acme/api +main +3d │$' "live captain hold row with title and reason"
assert_row "$frame" '^│ review +#7 +ship-gamma +acme/api#7 · Retry on 429 from the address API +acme/api +main +1m~ │$' "green-unmerged PR row: a review row on the task state alone, since the fetch does not carry PR 7, so its age is marked ~ (falsify: bring the merge? row back, or drop the fallback in reviewRow)"
assert_no_row "$frame" '^│ (hold|decide|blocked|review) +[^│]*later-hold' "dated hold is not actionable and stays out of Captain's Call"
assert_row "$frame" '^│ dated +until 10-01 +later-hold +Revisit the pricing page after launch · Deferred until launch +acme/web +main +09-13 │$' "the dated hold is one Charted Next row: STATE its bucket, WHY its until date, FILED its since date (falsify: drop the dated branch from chartedWhy, or let chartedItem take a live hold)"
assert_count "$frame" "later-hold" 1 "a captain hold sits in exactly one pane"
assert_before "$frame" '^│ blocked +- +scout-beta' '^│ decide +db-choice' "blocked sorts before decide"
assert_before "$frame" '^│ decide +db-choice' '^│ hold +- +decide-vendor' "decide sorts before hold"
assert_before "$frame" '^│ hold +- +decide-vendor' '^│ review ' "hold sorts before review"
# Every home's live calls list here by default: the delegate's ledger hold and the decision its task
# record relays into the main home, each once, both labelled with the delegate's home (falsify: put
# the opts.allHomesNeeds guard back in needsRows, drop relayedDecisionRows, or drop the home fields it
# passes to taskDecisionRows).
assert_row "$frame" '^│ hold +- +etl-cutover +Cut over the nightly ETL on Friday\? +acme/etl +delegate-a +1d │$' "the delegate's captain hold, labelled with its home, by default"
assert_row "$frame" '^│ decide +etl-window +delegate-a +Which maintenance window for the ETL cutover\? +acme/etl +delegate-a +- │$' "the keyed decision the delegate's record relays and its ledger does not carry, labelled with the delegate's home (the KEY column grows to fit the key; falsify: cap extra below 10 in columnSpec)"
assert_count "$frame" "etl-cutover" 1 "the delegate's hold is one row on the whole board: not under its Underway group, not in Charted Next"
assert_before "$frame" '^│ hold +- +etl-cutover' '^│ review ' "a delegate's hold sorts with the holds, before review"
assert_row "$frame" '^│ working +1 live +!▸ delegate-a ' "the home with a live call is flagged with ! in Underway; its STATE comes from its workers, never from the call (falsify: rank hold or decide in STATE_RANK)"
frame_all=$(render populated.json --all-homes-needs) || fail "populated --all-homes-needs: render exited non-zero"
if [ "$frame_all" = "$frame" ]; then pass; else fail "--all-homes-needs changes the frame although every home's calls list by default: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_all") | head -n 5)"; fi

# My PRs with --no-prs: the recorded PRs only, tagged PR and marked off (falsify: drop the
# --no-prs case in parseArgs, or the !prs.enabled branch in unlistedChecks).
frame_noprs=$(render populated.json --no-prs) || fail "populated --no-prs: render exited non-zero"
assert_contains "$frame_noprs" "My PRs (2)" "--no-prs lists the two recorded PRs only"
assert_contains "$frame_noprs" "┌─ [3] My PRs (2) ─" "--no-prs: the review header is bare; the rows say checks: off (falsify: put checksLabel back into paneHeader)"
assert_row "$frame_noprs" '^│ PR +- +ship-alpha +https://github.com/acme/widgets/pull/41 · checks: off[^│]* - +5m~ │$' "recorded PR 41 row: with the fetch off STATUS and BASE are unknown (-) and the AGE is the status-log age marked ~ (falsify: keep the PR age without the fetch)"
assert_row "$frame_noprs" '^│ PR +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: off \(--no-prs\) +- +1m~ │$' "recorded PR 7 row names the flag"
assert_not_contains "$frame_noprs" "passing" "no live check state with --no-prs"
assert_not_contains "$frame_noprs" "fetching" "--no-prs never says fetching"
# Finished work stays out (falsify: drop the taskBacklogState or the secondmate check in recordedPrs).
assert_no_row "$frame_noprs" '^│ PR +- +ship-old ' "a task whose backlog row is done does not list its PR without a fetched record"
assert_no_row "$frame_noprs" '^│ PR +- +delegate-a ' "a PR mentioned on a secondmate record is not ready for review"

# Underway rows: state, herdr join, tmux (falsify: remove the herdr agents block, or change
# tmux-task's endpoint target).
assert_row "$frame" '^│ STATE +HERDR +ID +WHAT +REPO +HOME +AGE │$' "in-flight column headers"
assert_row "$frame" '^│ working +working +ship-alpha +Add the widget cache · harness busy \(claude-hook\) +acme/widgets +main +5m │$' "task with herdr working and status-log age; WHAT leads with the task's title, then what it is doing (falsify: drop the title from whatText)"
assert_row "$frame" '^│ blocked +blocked +scout-beta +\(scout\) Scout: rate limits on the address API · gh auth expired +acme/api +main +2h │$' "task with herdr blocked"
assert_row "$frame" '^│ awaiting merge +done +ship-gamma +Retry on 429 from the address API · PR https://github.com/acme/api/pull/7 ch… +acme/api +main +1m │$' "worker said done with an unmerged PR: STATE reads awaiting merge (falsify: drop awaitingMerge from mainTaskRow)"
assert_no_row "$frame" '^│ done +[^│]*ship-old ' "a done task whose backlog row is done is finished work: no Underway row, only its Recently Landed row (falsify: drop the done skip from mainTaskRow)"
assert_row "$frame" '^│ working +tmux +tmux-task +Migrate the legacy import · running the migration +acme/legacy +main +- │$' "tmux-backed task shows tmux in HERDR"
assert_row "$frame" '^│ STATE {11}HERDR ' "Underway's STATE column widens to fit awaiting merge, then the two-cell gutter (falsify: cap tag below 14 in columnSpec, or change GUTTER)"
assert_row "$frame" '^│ STATE {4}KEY ' "Captain's Call's STATE column is only as wide as its own widest word, blocked: fixed columns size per pane (falsify: size tag over the whole board again)"
assert_row "$frame" '^│ CHECKS +STATUS +ID +TITLE +BASE  AGE │$' "My PRs: BASE hugs its widest value, main, and AGE its ages, so TITLE gets the rest (falsify: give base or age a fixed width)"
assert_before "$frame" '^│ working +working +ship-alpha' '^│ blocked +blocked +scout-beta' "in flight: working sorts before blocked"
assert_before "$frame" '^│ blocked +blocked +scout-beta' '^│ awaiting merge +done +ship-gamma' "in flight: blocked sorts before awaiting merge"

# Underway delegate homes, collapsed: a home with two or more live worker rows draws one group row with
# the worst worker state, the live count, the child ids, the shared repo and the newest child age; a
# home with one live worker draws that row directly, HOME naming the home; the mate's own agent row is
# folded away either way (falsify: remove child-one from delegate-a's active_children, w2A:p2 from the
# herdr block, the mateTaskFor fold in inflightRows, or the one-worker branch of ledgerEntry).
assert_row "$frame" '^│ working +1 live +!▸ delegate-a +child-one, child-failed +acme/etl +delegate-a +1h │$' "delegate-a group: two worker rows make a group, STATE working from its workers (the failed child does not rank), one live, flagged for its live call, newest age 1h"
assert_row "$frame" '^│ working +remote +remote-child +Remote child · porting the login screen +acme/mobile +remote-sm \(remote\) +- │$' "remote home with one live worker: the worker row drawn directly, HOME naming the home, HERDR remote"
assert_no_row "$frame" '▸ remote-sm' "no group row over a home with one worker (falsify: draw a group over one worker)"
assert_no_row "$frame" '^│ working +idle +delegate-a ' "the secondmate agent row is folded into its group when collapsed"
assert_not_contains "$frame" "child-one  " "children are hidden while collapsed (id appears only in the group text)"
assert_not_contains "$frame" "↳" "no child rows while collapsed"
assert_before "$frame" '^│ working +remote +remote-child' '^│ blocked +blocked +scout-beta' "a delegate's working row sorts with the working rows, before blocked"
assert_before "$frame" '^│ working +1 live +!▸ delegate-a' '^│ blocked +blocked +scout-beta' "a working group sorts with the working rows: its live call flags it and never sets its STATE"

# Underway groups, expanded with --expand all: the worker rows and nothing else (falsify: list
# decisions or relays among ledgerEntry's children).
frame_x=$(render populated.json --expand all --rows 48) || fail "populated --expand all: render exited non-zero"
assert_contains "$frame_x" "Underway (8)" "expanding adds delegate-a's two worker rows: no decision, no relay, no delegate record"
assert_row "$frame_x" '^│ working +1 live +!▾ delegate-a +child-one, child-failed +acme/etl +delegate-a +1h │$' "expanded group row shows ▾"
assert_no_row "$frame_x" '↳ delegate-a +\(secondmate\)' "expanded: the delegate's own task record is not a child row (falsify: list mateRow among ledgerEntry's children)"
assert_no_row "$frame_x" '↳ delegate-a +Which maintenance' "expanded: the relayed decision is not a child row; it is Captain's Call's"
assert_row "$frame_x" '^│ working +working +↳ child-one +Child one · writing the loader +acme/etl +delegate-a +3d │$' "expanded: active child with its title, its doing and the age from its home state file"
assert_row "$frame_x" '^│ failed +pane lost +↳ child-failed +endpoint default:w2B:p2 \(run-step\) +- +delegate-a +1h │$' "expanded: failed endpoint child whose pane is gone reads pane lost"
assert_no_row "$frame_x" '↳ etl-cutover' "expanded: the home's live captain hold is not a child row; it is Captain's Call's"
assert_before "$frame_x" '!▾ delegate-a' '↳ child-one' "children follow their group row"
assert_before "$frame_x" '↳ child-failed' '^│ working +remote +remote-child' "the next top-level row starts after the group's children"
assert_before "$frame_x" '↳ child-one' '↳ child-failed' "children sort working before failed"

# Reports fold into Recently Landed: a report whose task has no Done row lists as VERB report, dated
# by the file, once (falsify: remove scout_reports[0], the mobile-fix report_path, the report mtimes,
# or the `reported` set in landedRows).
assert_row "$frame" '^│ report +09-16 +scout-beta +Scout: rate limits on the address API · data/scout-beta/report.md +acme/api +main +10m │$' "a report with no Done row: VERB report, the file's date, the title from the backlog record, the path in WHAT"
assert_row "$frame" '^│ reported +09-12 +mobile-fix +Fix the crash on launch · https://github.com/acme/mobile/pull/3 +acme/mobile +remote-sm \(remote\) +4d │$' "a remote home's reported row names its PR first"
assert_row "$frame" '^│ reported +09-06 +old-scout +Scout: legacy import path · data/old-scout/report.md +acme/legacy +main +10d │$' "older scout report with its backlog verb and its report path"
assert_count "$frame" "data/scout-beta/report.md" 1 "a report lists once on the board"
assert_count "$frame" "data/old-scout/report.md" 1 "a report with a Done row lists through that row alone (falsify: list scout_reports beside the Done row that names the same report)"
assert_before "$frame" '^│ report +09-16 +scout-beta' '^│ merged +09-15 +etl-index' "a report dated by its file sorts with the completions, newest first"

# Recently Landed (falsify: change ship-old's state from done, or etl-index's completion date).
assert_row "$frame" '^│ merged +09-14 +ship-old +Rename the widget table · https://github.com/acme/widgets/pu' "landed merged row with PR (text truncated to the flex column at 160 cols)"
assert_row "$frame" '^│ merged +09-14 +ship-old .* acme/widgets +main +2d │$' "landed merged row keeps repo, home and age"
assert_row "$frame" '^│ merged +09-15 +etl-index +Add the ETL index · https://github.com/acme/etl/pull/12 +acme/etl +delegate-a +1d │$' "secondmate landed row"
assert_row "$frame" '^│ reported +09-06 +old-scout +Scout: legacy import path · data/old-scout/report.md +acme/legacy +main +10d │$' "reported row in landed names its report, the target enter falls back to (falsify: drop the report rung from landedWhat)"
assert_before "$frame" '^│ merged +09-15 +etl-index' '^│ merged +09-14 +ship-old' "landed newest first"

# Frame geometry (falsify: change the fixture cols/rows, or break padding in render.mjs).
assert_lines "$frame" 44 "populated frame is 44 lines"
assert_widths "$frame" 160 "populated frame lines are 160 columns"
# Teammates' PRs sits between My PRs and Underway, so the two PR panes read side by side, with the
# empty text of a pane whose scope has PRs but no request (falsify: reorder PANES in lib/layout.mjs,
# or change the toreview empty text).
assert_before "$frame" "My PRs \(3\)" "Teammates' PRs \(0\)" "pane order 5: Teammates' PRs is the fourth pane, below My PRs"
assert_before "$frame" "Teammates' PRs \(0\)" "Charted Next \(1\)" "pane order 6: Charted Next follows Teammates' PRs"
assert_contains "$frame" "┌─ [4] Teammates' PRs (0) ─" "badge on Teammates' PRs"
assert_row "$frame" '^│ no pull requests waiting for your review +│$' "populated: Teammates' PRs is empty (no toreview rows in the fixture)"
assert_row "$frame" '^│ CHECKS +STATUS +ID +AUTHOR +TITLE +BASE +AGE │$' "populated: the empty Teammates' PRs pane still heads its AUTHOR column (falsify: size the column set by the rows present)"
assert_row "$frame" '^│ STATE +KEY +ID +WHAT +REPO +HOME +AGE │$' "wide layout keeps REPO and AGE"
assert_row "$frame" '^│ STATE +WHY +ID +WHAT +REPO +HOME +FILED │$' "Charted Next heads WHY and FILED in the KEY and AGE slots (falsify: drop AGE_LABEL or the charted labels in lib/layout.mjs)"
# Captain's Call's first row, where the board starts, is scout-beta's blocked row: it carries a hold
# card and a pane, so the footer names enter card and F focus in place of enter open/focus/view and,
# with no captain hold on that task, no d or D (falsify: drop . settings from FOOTER_KEYS, or the card branch from boardHints).
assert_row "$(render populated.json)" '^ j/k move  tab pane  enter card  F focus  x hide  H hidden  r refresh  \. settings  \? help  q quit +$' "footer keys on a card row with a pane (no l/h expand: a card row is never a group; no 1-6 panes: the card row's full hint gives them up for a accept)"
assert_row "$(render populated.json --keys "tab,tab")" '^ j/k move  tab pane  enter open/focus/view  f search  a accept  x hide  H hidden  1-6 panes  r refresh  \. settings  \? help  q quit +$' "footer keys on a PR row (falsify: drop . settings, f search or a accept from FOOTER_KEYS; l/h expand gave way to a accept so the hint fits 136 columns)"

# Keys through --render-once --keys (falsify: change keyAction in lib/controller.mjs). The board starts
# on Captain's Call's first row, so an Underway row is one tab away; its group is the third row.
frame_k=$(render populated.json --keys "tab,j,j,l") || fail "keys l: render exited non-zero"
assert_row "$frame_k" '^│ working +1 live +!▾ delegate-a ' "l on the third Underway row expands the delegate-a group"
assert_contains "$frame_k" "↳ child-one" "expanded by key: child rows appear"
assert_contains "$frame_k" "Underway (8)" "expanded by key: only delegate-a's rows are added"
frame_k=$(render populated.json --keys "tab,j,j,l,j,h") || fail "keys h: render exited non-zero"
assert_not_contains "$frame_k" "▾" "h from a child row collapses its group"
assert_contains "$frame_k" "Underway (6)" "collapsed again by key"
frame_k=$(render populated.json --keys "tab,j,j,enter") || fail "keys enter group: render exited non-zero"
assert_row "$frame_k" '^│ working +1 live +!▾ delegate-a ' "enter on a group row expands it"
frame_k=$(render populated.json --keys "tab,enter") || fail "keys enter worker: render exited non-zero"
assert_contains "$frame_k" "herdr is off (--no-herdr); cannot focus" "enter on an Underway worker still means herdr focus"
frame_k=$(render populated.json --keys "?") || fail "keys ?: render exited non-zero"
assert_contains "$frame_k" "enter        My PRs, Teammates' PRs, Recently Landed or Captain's Call PR row: open it in the browser" "help overlay documents enter on Recently Landed and names the two PR panes"
assert_not_contains "$frame_k" "open the PR of the selected row" "help overlay no longer documents o"
assert_contains "$frame_k" "l / right    expand the selected Underway group" "help overlay documents l/right"
# The help lists the pane keys the way the badges show them (falsify: change the 1 - 6 lines in HELP_LINES).
assert_contains "$frame_k" "each pane title carries its key: [1] Captain's Call" "help overlay ties the 1-6 keys to the title badges"
assert_contains "$frame_k" "[2] Underway  [3] My PRs  [4] Teammates' PRs  [5] Charted Next  [6] Recently Landed" "help overlay lists every badge in screen order (falsify: leave the old order in HELP_LINES)"
assert_contains "$frame_k" "0            show every pane (with all six hidden the board lists these keys)" "help overlay documents 0 and the landing page"

# Opening a PR: enter in My PRs, on a Captain's Call PR row and on a Recently Landed row with a PR,
# through the injected opener only (falsify: drop the url field from fetchedPrRow, reviewRow or
# landedRows, drop the PR rung from landedTarget, or drop the 'open' case in keyAction). The opener
# receives the exact URL as its only argument.
frame_o=$(render_open populated.json "tab,tab,enter") || fail "open review: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "enter on the first My PRs row (the newest IN REVIEW PR, joined to its task) opens its PR"
assert_contains "$frame_o" "opened https://github.com/acme/widgets/pull/41 (ship-alpha)" "footer notice names the task, not the candidate"
frame_o=$(render_open populated.json "tab,tab,j,enter") || fail "open review second row: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/8" "enter on the second My PRs row (the failing live candidate nobody recorded) opens its PR"
assert_contains "$frame_o" "opened https://github.com/acme/api/pull/8 (api#8)" "footer notice names the opened URL"
frame_o=$(render_open populated.json "j,j,j,j,j,enter") || fail "open needs enter: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/7" "enter on the Captain's Call review row, its sixth row, opens its PR"
frame_o=$(render_open populated.json "tab,tab,tab,tab,j,enter") || fail "open landed enter: render exited non-zero"
assert_opened "https://github.com/acme/etl/pull/12" "enter on the second Recently Landed row (four tabs reach the pane past the empty Teammates' PRs) opens its PR"
assert_contains "$frame_o" "opened https://github.com/acme/etl/pull/12 (etl-index)" "footer notice names the Recently Landed URL"
frame_o=$(render_open populated.json "tab,tab,tab,tab,enter") || fail "open landed report: render exited non-zero"
assert_not_opened "enter on the first Recently Landed row, the report, calls no opener"
assert_contains "$frame_o" "would view /fixture/firstmate/data/scout-beta/report.md" "enter on a report row falls to the viewer (the landed targets section below)"
frame_o=$(render_open populated.json "tab,tab,tab,tab,j,j,j,j,enter") || fail "open landed no url: render exited non-zero"
assert_not_opened "enter on a Recently Landed row without a PR URL calls no opener"
assert_not_contains "$frame_o" "no PR URL on this row" "a Recently Landed row without a PR is no longer an error: enter falls back to its report (the landed targets section below)"
frame_o=$(render_open populated.json "tab,enter") || fail "enter inflight: render exited non-zero"
assert_not_opened "enter on an Underway worker calls no opener"
rm -f "$OPENER_LOG"
frame_o=$(render populated.json --keys "tab,tab,enter") || fail "open without opener: render exited non-zero"
assert_contains "$frame_o" "would open https://github.com/acme/widgets/pull/41" "without --opener-cmd, --render-once only reports the open"
assert_not_opened "without --opener-cmd nothing is launched"

# Live PR data (falsify: remove candidate_prs from the fixture or the enabled branch in reviewRows).
# --prs is accepted and changes nothing, since it is the default (falsify: give --prs an effect in
# parseArgs, or flip the default).
frame_prs=$(render populated.json --prs) || fail "populated --prs: render exited non-zero"
if [ "$frame_prs" = "$frame" ]; then pass; else fail "--prs renders a different frame from the default: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_prs") | head -n 5)"; fi
assert_contains "$frame_prs" "My PRs (3)" "live PR data adds the unrecorded candidate"
assert_row "$frame_prs" '^│ CHECKS +STATUS +ID +TITLE +BASE +AGE │$' "My PRs draws its own six columns (falsify: drop the review branch from columns in lib/layout.mjs)"
assert_no_row "$frame_prs" '^│ CHECKS [^│]*(REPO|HOME|WHAT|REVIEW)' "the review pane draws no REPO, HOME, WHAT or REVIEW column"
assert_row "$frame_prs" '^│ failing +IN REVIEW +api#8 +Retry on 429 +main +- │$' "failing candidate nobody recorded: changes requested reads IN REVIEW, the title and base branch come from the fetch, no age without a creation time (falsify: map CHANGES_REQUESTED to its own word in prStatus)"
assert_row "$frame_prs" '^│ passing +IN REVIEW +ship-alpha +Add the widget cache +main +3h │$' "passing candidate joined to its task, AGE from its created_at (falsify: drop prCreatedAt from reviewRows)"
assert_row "$frame_prs" '^│ unlisted +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: not fetched +- +1m~ │$' "recorded PR missing from the live list: STATUS -, the URL and note in TITLE, BASE -, AGE from the status log marked ~"
assert_no_row "$frame_prs" '^│ (passing|failing|pending|none|unlisted|PR) +[^│]* ship-old ' "a candidate GitHub reports MERGED with no merge time cannot be placed in the 12-hour window and is dropped (falsify: return true from insideWindow when the stamp is missing)"
assert_no_row "$frame_prs" '^│ (passing|failing|pending|none|unlisted|PR) +[^│]*Rename the widget table' "the merged PR's title appears nowhere in My PRs"
assert_before "$frame_prs" '^│ passing +IN REVIEW +ship-alpha' '^│ failing +IN REVIEW +api#8' "inside IN REVIEW the PR with a creation time sorts before the one without (newest first, no age last; falsify: sort by the CHECKS word)"

# Medium width: REPO and AGE drop below 100 columns (falsify: change WIDE_BREAKPOINT in lib/layout.mjs).
frame_med=$(render populated.json --cols 90 --rows 30) || fail "medium: render exited non-zero"
assert_contains "$frame_med" "Captain's Call (6)" "medium keeps the six panes"
assert_contains "$frame_med" "Teammates' PRs (0)" "medium: Teammates' PRs is drawn too"
assert_row "$frame_med" '^│ STATE +HERDR +ID +WHAT +HOME +│$' "medium keeps the HERDR column and drops REPO and AGE"
assert_no_row "$frame_med" ' REPO +HOME' "medium drops REPO"
assert_no_row "$frame_med" ' HOME +AGE' "medium drops AGE"
assert_row "$frame_med" '^│ CHECKS +STATUS +ID +TITLE +AGE │$' "medium: My PRs drops BASE and keeps AGE (falsify: drop AGE with BASE in the review branch of columns)"
assert_no_row "$frame_med" ' TITLE +BASE' "medium: no BASE column"
assert_widths "$frame_med" 90 "medium frame lines are 90 columns"
assert_lines "$frame_med" 30 "medium frame is 30 lines"
assert_row "$(render populated.json --cols 90 --rows 30)" '^ enter card  F focus  x hide  H  1-6 panes  r  \. settings  \? help  q quit +$' "medium width uses the short footer (the card form: the board starts on scout-beta's card row with a pane)"
assert_row "$(render populated.json --cols 90 --rows 30 --keys "tab,tab")" '^ j/k  tab  enter  f search  a accept  x hide  H  1-6  r  \. settings  \? help  q quit +$' "medium width uses the short footer on a PR row (no l/h and 1-6 alone: the short hint must fit 90 columns and sit beside a long notice at 160)"

# Minimum height (falsify: change MIN_ROWS in lib/layout.mjs).
frame_tiny=$(render populated.json --rows 10) || fail "tiny: render exited non-zero"
assert_lines "$frame_tiny" 20 "frame never shrinks below 20 rows"
assert_row "$frame_tiny" '\+[0-9]+ more ──┘$' "tiny frame marks hidden rows on the pane border"

# ----------------------------------------------------------------- empty
frame_empty=$(render empty.json) || fail "empty: render exited non-zero"
assert_contains "$frame_empty" "Captain's Call (0)" "empty Captain's Call count"
assert_row "$frame_empty" '^│ nothing needs your action right now +│$' "empty Captain's Call message"
assert_row "$frame_empty" '^│ no pull requests of yours +│$' "empty My PRs message"
assert_row "$frame_empty" '^│ nothing is underway +│$' "empty Underway message"
assert_row "$frame_empty" '^│ nothing is queued +│$' "empty Charted Next message"
assert_row "$frame_empty" '^│ no recent completions +│$' "empty Recently Landed message"
assert_row "$frame_empty" '^│ no pull requests waiting for your review +│$' "empty Teammates' PRs message (falsify: change the toreview empty text in PANES)"
# No herdr block under --no-herdr is the state "off" with the reason --no-herdr: the title line warns
# once and no pane header says anything about herdr (falsify: drop the detail from factsFromFixture's
# no-block branch, or the 'off' case from herdrWarning).
assert_row "$frame_empty" '^ firstmate-tui · /fixture/firstmate · 1 home +herdr disconnected \(--no-herdr\) $' "empty: the title line warns herdr disconnected with --no-herdr as the reason"
assert_count "$frame_empty" "herdr" 1 "empty: the title warning is the only herdr text; no pane header carries one"
assert_no_row "$frame_empty" '^ firstmate-tui .*refresh' "empty: no refresh block in the fixture, so the title line has no refresh label"
assert_contains "$frame_empty" "· 1 home " "empty board counts one home"
assert_widths "$frame_empty" 120 "empty frame lines are 120 columns"
assert_lines "$frame_empty" 40 "empty frame is 40 lines"

# ---------------------------------------------------------------- narrow
frame_narrow=$(render narrow.json) || fail "narrow: render exited non-zero"
# Section headers carry the same key badge as the pane titles (falsify: drop `badge` from the section
# entry in flattenRows, or the badge segment in renderList).
assert_row "$frame_narrow" '^── \[1\] Captain.s Call \(1\) ─+$' "narrow: section header with its badge and count only, padded with dashes"
assert_contains "$frame_narrow" "── [3] My PRs (0)" "narrow: My PRs section badge"
assert_contains "$frame_narrow" "── [4] Teammates' PRs (0)" "narrow: Teammates' PRs section badge, fourth in screen order"
assert_contains "$frame_narrow" "── [2] Underway (2)" "narrow: Underway section badge, second in screen order"
assert_contains "$frame_narrow" "── [5] Charted Next (0)" "narrow: Charted Next section badge"
assert_contains "$frame_narrow" "── [6] Recently Landed (1)" "narrow: Recently Landed section badge"
assert_count "$frame_narrow" "── [" 6 "narrow: six badges, one per section"
assert_not_contains "$frame_narrow" "┌" "narrow: no pane borders"
assert_row "$frame_narrow" '^ STATE +ID +WHAT +HOME +$' "narrow: single shared column header without REPO, AGE, HERDR or AUTHOR"
assert_row "$frame_narrow" '^ hold +decide-vendor +Pick the vendor for the addr… +main +$' "narrow: hold row in list mode, text truncated to the flex column (which is what the fixed columns leave after sizing to their values)"
assert_row "$frame_narrow" '^ working +ship-alpha +Add the widget cache · harne… +main +$' "narrow: Underway row, its title first"
assert_row "$frame_narrow" '^ working +notes-child +Notes child · summarizing Mo… +notes \(cached\) *$' "narrow: a cached home with one worker draws that worker directly with the cached home label (falsify: draw a group row over one worker)"
frame_narrow_x=$(render narrow.json --expand all) || fail "narrow --expand all: render exited non-zero"
if [ "$frame_narrow_x" = "$frame_narrow" ]; then pass; else fail "narrow --expand all: a home with one worker has no group to expand, so the frame should not change"; fi
assert_contains "$frame_narrow" "firstmate-tui · firstmate · 2 homes" "narrow: title uses the home basename"
assert_widths "$frame_narrow" 70 "narrow frame lines are 70 columns"
assert_lines "$frame_narrow" 24 "narrow frame is 24 lines"

# --------------------------------------------------------------- grouped
frame_g=$(render grouped.json) || fail "grouped: render exited non-zero"

# No prs block in the fixture is the state before the first fetch of a session lands: the recorded
# PR row says fetching, never "not fetched", and the header stays bare (falsify: drop the fetching
# branch in unlistedChecks).
assert_contains "$frame_g" "┌─ [3] My PRs (1) ─" "grouped: the review header is bare before the first fetch"
assert_row "$frame_g" '^│ PR +- +ship-alpha +https://github.com/acme/widgets/pull/41 · checks: fetching +- +5m~ │$' "grouped: recorded PR row says checks fetching before the first fetch, STATUS unknown, AGE marked as the fallback"
assert_not_contains "$frame_g" "not fetched" "grouped: nothing reads not fetched before the first fetch"

# Captain's Call lists the delegate's two live decisions by default, and never its dated hold (falsify:
# put the opts.allHomesNeeds guard back in needsRows, or drop the dated-hold filter in liveDecisions).
assert_contains "$frame_g" "Captain's Call (2)" "grouped: the delegate's two live decisions"
assert_row "$frame_g" '^│ decide +cutover-day +etl-cutover-runbook +Cut over Friday or Monday\? +- +delegate-a +- │$' "grouped: the keyed child decision, labelled with its home"
assert_row "$frame_g" '^│ hold +- +etl-vendor +Pick the ETL vendor · Two quotes in the report +acme/etl +delegate-a +2d │$' "grouped: the delegate's captain hold with the repo from its queued entry"
assert_no_row "$frame_g" '^│ (hold|decide) +[^│]*etl-later' "grouped: the dated hold is not a Captain's Call row"
# The dated hold is one Charted Next row, its until date read from the ledger's decision when the
# queued entry lacks it (falsify: drop the decisions_open merge in chartedRows).
assert_contains "$frame_g" "Charted Next (1)" "grouped: the dated hold is Charted Next's one row"
assert_row "$frame_g" '^│ dated +until 10-01 +etl-later +Revisit ETL pricing +acme/etl +delegate-a +- │$' "grouped: the delegate's dated hold with its until date, no filed date in the ledger"
assert_count "$frame_g" "etl-later" 1 "grouped: the dated hold sits in exactly one pane"

# Collapsed groups: a home's rows are its workers, a group over two or more (falsify: remove
# etl-backfill from delegate-a's endpoints (state), or the notes ledger).
assert_contains "$frame_g" "Underway (3)" "grouped: one main worker plus two home groups"
assert_row "$frame_g" '^│ STATE {4}HERDR ' "STATE column stays 8 wide when no longer state word is on the board"
assert_row "$frame_g" '^│ working +working +ship-alpha +Add the widget cache · harness busy \(claude-hook\) +acme/widgets +main +5m │$' "grouped: main-home worker stays one row"
assert_row "$frame_g" '^│ blocked +4 live +!▸ delegate-a +etl-loader, etl-schema, etl-cutover-runbook, etl-backfill +acme/etl +delegate-a +5m │$' "delegate-a group: blocked is the worst worker state, four live, flagged for its live calls, newest child 5m"
assert_row "$frame_g" '^│ working +2 live +▸ notes +brag-week-37, notes-monday +acme/brag +notes +40m │$' "notes group: working, two live, no flag"
assert_before "$frame_g" '^│ working +2 live +▸ notes' '^│ blocked +4 live +!▸ delegate-a' "grouped: working group sorts before blocked group"
assert_not_contains "$frame_g" "↳" "grouped: collapsed by default"

# Expanded: the worker rows only; a child with a keyed decision keeps its worker state and its doing,
# a blocked child shows its hold title and reason (falsify: draw decision text on a worker row, drop
# the hold text lookup in ledgerChildRows, or list decisions among ledgerEntry's children).
frame_gx=$(render grouped.json --expand all) || fail "grouped --expand all: render exited non-zero"
assert_contains "$frame_gx" "Underway (9)" "grouped expanded: 3 top rows + 4 under delegate-a + 2 under notes"
assert_not_contains "$frame_gx" "(secondmate)" "expanded: neither delegate's own record is a row (falsify: list mateRow among ledgerEntry's children)"
assert_row "$frame_gx" '^│ working +working +↳ etl-loader +writing the loader +acme/etl +delegate-a +3h │$' "expanded: working child with doing"
assert_row "$frame_gx" '^│ working +working +↳ etl-schema +adding the schema migration +acme/etl +delegate-a +20m │$' "expanded: second working child"
assert_row "$frame_gx" '^│ working +idle +↳ etl-cutover-runbook +drafting the cutover runbook +acme/etl +delegate-a +5m │$' "expanded: the child with a keyed decision keeps its worker state and doing; the decision is Captain's Call's"
assert_row "$frame_gx" '^│ blocked +blocked +↳ etl-backfill +Backfill the ETL history · waiting on the prod snapshot +- +delegate-a +1h │$' "expanded: blocked child shows its hold title and reason"
assert_no_row "$frame_gx" '↳ etl-vendor' "expanded: the home's live captain hold is not a child row"
assert_not_contains "$(printf '%s\n' "$frame_gx" | sed -n '/\[2\] Underway/,/^└/p')" "etl-later" "expanded: the dated hold is not a child row either"
assert_row "$frame_gx" '^│ working +working +↳ brag-week-37 +drafting week 37 +acme/brag +notes +2h │$' "expanded: notes child"
assert_before "$frame_gx" '↳ etl-loader' '↳ etl-cutover-runbook' "children: working rows in ledger order"
assert_before "$frame_gx" '↳ etl-cutover-runbook' '↳ etl-backfill' "children: working before blocked"
frame_gh=$(render grouped.json --expand delegate-a) || fail "grouped --expand delegate-a: render exited non-zero"
assert_contains "$frame_gh" "!▾ delegate-a" "--expand by id expands that home"
assert_contains "$frame_gh" "▸ notes" "--expand by id leaves the other home collapsed"
assert_not_contains "$frame_gh" "↳ brag-week-37" "--expand by id: no children of the collapsed home"

# --all-homes-needs is accepted and changes nothing (falsify: give the flag an effect again).
frame_ga=$(render grouped.json --all-homes-needs) || fail "grouped --all-homes-needs: render exited non-zero"
if [ "$frame_ga" = "$frame_g" ]; then pass; else fail "--all-homes-needs changes the grouped frame: $(diff <(printf '%s\n' "$frame_g") <(printf '%s\n' "$frame_ga") | head -n 5)"; fi

# Geometry (falsify: change the fixture cols/rows).
assert_widths "$frame_g" 160 "grouped frame lines are 160 columns"
assert_lines "$frame_g" 44 "grouped frame is 44 lines"

# ---------------------------------------------------------- inflight-live
# Underway is built from live work only: a group's STATE, rows and count come from its live children,
# never from the delegate's own task record, whose state is the last verb of its own status log and
# reads done after any done relay, and never from the home's calls, which are Captain's Call's. Every
# delegate record in the fixture reads done with a done relay as its detail, so any row built from one
# brings the word done into the pane.
pane_lines() { # <frame> <pane key 1-6>: that pane's lines, title to bottom border
  printf '%s\n' "$1" | sed -n "/^┌─ \[$2\]/,/^└/p"
}
frame_il=$(render inflight-live.json) || fail "inflight-live: render exited non-zero"
inflight_il=$(pane_lines "$frame_il" 2)
# Underway is the live workers alone: the busy home's group, the awaiting-merge main task and the
# failed home's one child drawn directly. An idle home, a home whose ledger lists only done and
# unknown endpoints, a home with only a call and a held failed task have no worker and draw nothing
# here (falsify: put mateRow back into ledgerEntry, drop the done or the unknown skip from the
# endpoint loop of ledgerChildRows, drop the held or the done skip from mainTaskRow, or draw a group
# over a home with no worker).
assert_contains "$frame_il" "Underway (3)" "inflight-live: one group, one main row and one delegate worker drawn directly, none for the delegates' own records"
assert_not_contains "$inflight_il" "done" "inflight-live: nothing in Underway reads done, in STATE or in WHAT"
assert_not_contains "$inflight_il" "(secondmate)" "inflight-live: no delegate record row"
assert_not_contains "$inflight_il" "idle-home" "idle delegate: no Underway row, however its record reads"
assert_row "$frame_il" '^│ working +2 live +▸ busy-home +child-a, child-b +acme/etl +busy-home +20m │$' "delegate with two working children and a stale done relay: working, 2 live, newest child 20m"
assert_not_contains "$inflight_il" "stale-home" "delegate whose ledger lists only done and unknown endpoints: no worker, no Underway row"
assert_not_contains "$inflight_il" "ask-home" "delegate with no children and one relayed decision: no Underway row; the decision is Captain's Call's"
assert_not_contains "$inflight_il" "held-home" "delegate with a ledger captain hold and no children: no Underway row; the hold is Captain's Call's"
assert_row "$frame_il" '^│ failed +pane lost +backfill +endpoint default:w10A:p1 \(run-step\) +- +failed-home +1h │$' "delegate with one failed child: the child drawn directly, HOME naming the home, its lost pane in red"
assert_not_contains "$inflight_il" "fix-checks" "failed main-home task under a live captain hold has no Underway row: nothing runs, and the hold is Captain's Call's"
assert_row "$frame_il" '^│ awaiting merge +idle +ship-unmerged +Retry on 429 from the address API · PR https://github.com/acme/api/pull/9 checks green +acme/api +main +1m │$' "done main-home task with an unmerged PR and an open backlog row still reads awaiting merge"
assert_not_contains "$inflight_il" "ship-merged" "done-and-merged main-home task whose record was cleaned up has no Underway row"
assert_before "$frame_il" '▸ busy-home' '^│ awaiting merge' "a working group sorts before awaiting merge"
assert_before "$frame_il" '^│ awaiting merge' '^│ failed +pane lost +backfill' "awaiting merge sorts before failed"
# Captain's Call carries every home's calls once: the relayed decision of a home whose ledger does not
# hold it, the held failed main task, the delegate's ledger hold and the review row (falsify: drop
# relayedDecisionRows, or the ledger loop in needsRows).
assert_contains "$frame_il" "Captain's Call (4)" "inflight-live: a relayed decision, two holds and a review row"
assert_row "$frame_il" '^│ decide +vendor-pick +ask-home +Which vendor for the address API\? +ask-home +ask-home +1d │$' "the relayed decision of a home whose ledger does not carry it lists once, labelled with that home"
assert_row "$frame_il" '^│ hold +- +fix-checks +Judge only the newest run of each check · The fix is ready but cannot be pushed: pull-o… +acme/firstmate +main +2d │$' "the held failed task is one hold row"
assert_row "$frame_il" '^│ hold +- +price-hold +Revisit the pricing tiers · Two quotes in the report +acme/billing +held-home +2d │$' "the delegate's captain hold lists once, labelled with its home"
assert_row "$(render inflight-live.json --keys j)" '^ j/k move  tab pane  enter card  a accept  d discard  D defer  x hide ' "the held failed task's row carries the card and both hold actions, and no pane (a hold row is built from the backlog record)"
# Charted Next warns about what Underway no longer lists: the two endpoints whose panes are gone and
# the one whose state is unavailable; a done endpoint and a live child with a lost pane are not warnings
# (falsify: warn on a done or a live endpoint in warningRows).
assert_contains "$frame_il" "Charted Next (0, 3 warnings)" "inflight-live: three warnings, no queued work; the count leaves the warnings out"
assert_row "$frame_il" '^│ warning +- +ghost-tmux +endpoint 0:fm-ghost-tmux is gone \(exists: false\) +- +stale-home +- │$' "an unknown endpoint on a tmux target that no longer exists is a warning"
assert_row "$frame_il" '^│ warning +- +ghost-lost +endpoint default:w9B:p1 is gone \(exists: false\) +- +stale-home +- │$' "an unknown endpoint whose pane is gone is a warning"
assert_row "$frame_il" '^│ warning +- +peek +child current state unavailable \(endpoint default:w9C:p1, none\) +- +stale-home +- │$' "an unknown endpoint whose pane exists is a warning about its state, not an Underway row"
assert_no_row "$frame_il" '^│ warning +- +(stale-done|backfill|child-a) ' "no warning for a done endpoint or a live worker"
frame_ilx=$(render inflight-live.json --expand all) || fail "inflight-live --expand all: render exited non-zero"
inflight_ilx=$(pane_lines "$frame_ilx" 2)
assert_contains "$frame_ilx" "Underway (5)" "expanded: the busy home's two children join the three rows, and nothing else"
assert_not_contains "$inflight_ilx" "done" "expanded: still nothing reads done"
assert_not_contains "$inflight_ilx" "(secondmate)" "expanded: no delegate record row among the children"
assert_count "$inflight_ilx" "↳" 2 "expanded: two child rows in all"
assert_row "$frame_ilx" '^│ working +working +↳ child-a +writing the loader +acme/etl +busy-home +3h │$' "expanded: the first working child"
assert_row "$frame_ilx" '^│ working +working +↳ child-b +adding the schema migration +acme/etl +busy-home +20m │$' "expanded: the second working child"
assert_not_contains "$inflight_ilx" "stale-done" "expanded: a done endpoint is not listed"
assert_not_contains "$inflight_ilx" "ghost-tmux" "expanded: an unknown endpoint on a tmux target is not listed"
assert_not_contains "$inflight_ilx" "ghost-lost" "expanded: an unknown endpoint whose herdr pane is gone is not listed"
assert_not_contains "$inflight_ilx" "peek" "expanded: an unknown endpoint with a herdr pane is not listed either; it is a Charted Next warning"
assert_not_contains "$inflight_ilx" "vendor-pick" "expanded: the relayed decision is not a child row"
assert_not_contains "$inflight_ilx" "price-hold" "expanded: the ledger's captain hold is not a child row"
frame_ilk=$(render inflight-live.json --keys "tab,l") || fail "inflight-live keys l: render exited non-zero"
assert_contains "$frame_ilk" "▾ busy-home" "l on the busy group marks it expanded"
assert_contains "$frame_ilk" "Underway (5)" "expanding the busy group adds its two children"
# Recently Landed is the one place the finished children appear (falsify: filter Recently Landed by the Underway rule).
assert_contains "$frame_il" "Recently Landed (4)" "inflight-live: the cleaned-up main task and the three delegate landed entries"
assert_row "$frame_il" '^│ merged +09-20 +ship-merged +Add the widget cache · https://github.com/acme/widgets/pull/41 +acme/widgets +main +1d │$' "Recently Landed: the cleaned-up merged task lists from its backlog record"
assert_row "$frame_il" '^│ merged +09-20 +stale-done +Ship the loader · https://github.com/acme/etl/pull/14 +acme/etl +stale-home +1d │$' "Recently Landed: the delegate's done endpoint lists from its ledger's landed entries"
assert_row "$frame_il" '^│ merged +09-19 +child-c +Add the ETL index · https://github.com/acme/etl/pull/12 +acme/etl +busy-home +2d │$' "Recently Landed: the busy delegate's finished child"
assert_widths "$frame_il" 160 "inflight-live frame lines are 160 columns"
assert_lines "$frame_il" 60 "inflight-live frame is 60 lines"
assert_widths "$frame_gx" 160 "grouped expanded frame lines are 160 columns"


# ------------------------------------------------------------ report viewer
# The chain (falsify: reorder the rungs in resolveViewer, or drop the executable check in whichOnPath).
chain_dir="$SCRATCH/chain"
mkdir -p "$chain_dir/a" "$chain_dir/b" "$chain_dir/none"
printf '#!/bin/sh\n' > "$chain_dir/a/glow"; chmod +x "$chain_dir/a/glow"
printf '#!/bin/sh\n' > "$chain_dir/b/vim"; chmod +x "$chain_dir/b/vim"
: > "$chain_dir/b/glow" # present but not executable: skipped
chain=$(node --input-type=module -e "
  import { resolveViewer } from '$ROOT/bin/firstmate-tui/lib/viewer.mjs';
  const d = '$chain_dir';
  const show = (env, cmd = null) => { const r = resolveViewer({ env, cmd }); console.log(r.source + ' ' + r.argv.join(' ')); };
  show({ PATH: d + '/a:' + d + '/b', EDITOR: 'nano' });
  show({ PATH: d + '/b', EDITOR: 'code --wait' });
  show({ PATH: d + '/b' });
  show({ PATH: d + '/none', EDITOR: '   ' });
  show({ PATH: d + '/a' }, ['bash', 'fake']);
")
assert_row "$chain" "^glow $chain_dir/a/glow -p\$" "chain: glow on PATH wins and is returned as the path found, with -p"
assert_row "$chain" '^EDITOR code --wait$' "chain: without glow, \$EDITOR is used and split on whitespace"
assert_row "$chain" "^vim $chain_dir/b/vim\$" "chain: without glow or EDITOR, vim on PATH (a non-executable glow is skipped)"
assert_row "$chain" '^less less$' "chain: less is the last resort"
assert_row "$chain" '^viewer-cmd bash fake$' "chain: --viewer-cmd overrides everything"

# Enter on a Recently Landed report row without --viewer-cmd only reports the viewer the chain resolved to,
# naming the fake glow shadowing PATH; nothing runs (falsify: run the viewer without --viewer-cmd in
# driveOnce, or drop whichOnPath). In lost.json the two PR panes and Charted Next are empty, so two tabs
# from Captain's Call reach Recently Landed, whose first row is the scout-beta report.
rm -f "$VIEWER_LOG"
frame_v=$(FM_BOARD_TEST_VIEWER_LOG="$VIEWER_LOG" PATH="$FAKE_BIN:$PATH" render lost.json --keys "tab,tab,enter") || fail "viewer report-only: render exited non-zero"
assert_contains "$frame_v" "would view /fixture/firstmate/data/scout-beta/report.md with $FAKE_BIN/glow -p (glow)" "fake glow on PATH is the resolved viewer, reported with its path and -p"
assert_not_viewed "without --viewer-cmd the resolved viewer is never spawned"
# With --viewer-cmd the report path is the only appended argument (falsify: drop reportPath from the
# report rows of landedRows).
frame_v=$(render_view lost.json "tab,tab,enter") || fail "viewer main: render exited non-zero"
assert_viewed "/fixture/firstmate/data/scout-beta/report.md" "enter on a main-home scout report hands its absolute path to the viewer"
assert_contains "$frame_v" "viewed /fixture/firstmate/data/scout-beta/report.md (viewer-cmd)" "footer names the viewed report"
frame_v=$(render_view lost.json "tab,tab,j,j,enter") || fail "viewer secondmate: render exited non-zero"
assert_viewed "/fixture/homes/delegate-a/data/etl-report/report.md" "a secondmate report resolves against its own home, not FM_HOME (falsify: use fmHome for ledger reports)"
frame_v=$(render_view lost.json "tab,tab,enter" "$FAKE_VIEWER -p") || fail "viewer flags: render exited non-zero"
assert_viewed "-p
/fixture/firstmate/data/scout-beta/report.md" "viewer flags stay separate argv elements, the path last (falsify: join argv into one string)"
frame_v=$(render_view lost.json "tab,enter") || fail "viewer wrong pane: render exited non-zero"
assert_not_viewed "enter on an Underway worker row never runs the viewer (a Captain's Call row would show its hold card through it; the hold section covers that)"
frame_v=$(render lost.json --keys "?") || fail "help: render exited non-zero"
assert_contains "$frame_v" "Recently Landed row without a PR: view its report (glow, \$EDITOR, vim, less), else" "help overlay documents the viewer"
assert_contains "$frame_v" "x            hide the selected row from view" "help overlay documents x"
assert_contains "$frame_v" "1 - 6        show or hide a pane" "help overlay documents 1-5"
assert_contains "$frame_v" "r            refresh now: the fleet snapshot and the PR checks (unless --no-prs)" "help overlay documents r"
# The board never moves the firstmate pane; the captain splits panes himself, and F focuses the
# selected row's pane instead (falsify: bring a pane-move line back into HELP_LINES, or drop the f, d
# or D lines).
assert_not_contains "$frame_v" "firstmate pane" "help overlay does not mention the firstmate pane"
assert_contains "$frame_v" "F            focus the selected row's herdr pane, in any pane" "help overlay documents F as the focus (falsify: leave the f line for the focus)"
assert_contains "$frame_v" "f            search all panes: type loosely (any order, any case, letters apart), enter jumps, esc closes" "help overlay documents f as the search (falsify: drop the search line from HELP_LINES)"
assert_contains "$frame_v" "d            discard the selected hold: asks y first, then runs fm-captain-hold.sh answer" "help overlay documents d"
assert_contains "$frame_v" "D            defer the selected hold to a date (default today + 14 days): fm-captain-hold.sh hold" "help overlay documents D"
assert_contains "$frame_v" "show its card in the viewer" "help overlay documents enter on a held row"
assert_contains "$frame_v" "Its three writes, a, d and D," "help overlay names the board's three writes (falsify: put the read-only sentence back)"

# ------------------------------------------------------------- lost panes
frame_l=$(render lost.json --expand all) || fail "lost: render exited non-zero"
tags_l=$(render lost.json --expand all --tags) || fail "lost --tags: render exited non-zero"
# A recorded pane absent from the herdr overlay reads "pane lost" (falsify: drop the lost branch in herdrColumn).
assert_row "$frame_l" '^│ working +pane lost +ship-lost +Retry on 429 from the address API · adding the retry loop +acme/api +main +10m │$' "main worker whose pane is gone: HERDR reads pane lost"
assert_row "$frame_l" '^│ working +pane lost +↳ child-lost +Child lost · indexing the warehouse +acme/etl +delegate-a +1h │$' "secondmate child whose pane is gone: HERDR reads pane lost"
assert_row "$frame_l" '^│ working +working +ship-alpha ' "a worker whose pane is present keeps its agent status"
assert_count "$tags_l" "{red-fg}pane lost{/red-fg}" 2 "--tags: both lost HERDR cells carry the red tag (falsify: drop the lost style in rowSegments)"
# Captain's Call has no HERDR column, so the whole lost row is red; the live decision row is not (falsify: drop
# the `row.lost && !herdrCell` term from bad in rowSegments).
assert_row "$tags_l" '\{red-fg\}decide.*\{red-fg\}ship-lost' "Captain's Call row of the lost worker is red"
assert_no_row "$tags_l" '\{red-fg\}decide.*ship-alpha' "Captain's Call row of the live worker is not red"
# Enter on a lost row: a footer notice, never a focus (falsify: drop the lost check in focusProblem).
frame_k=$(render lost.json --keys "tab,j,enter") || fail "lost enter inflight: render exited non-zero"
assert_contains "$frame_k" "ship-lost: pane w1L:p1 is gone from herdr (pane lost); nothing to focus" "enter on the lost Underway row says pane lost"
frame_k=$(render lost.json --keys "j,F") || fail "lost F needs: render exited non-zero"
assert_contains "$frame_k" "ship-lost: pane w1L:p1 is gone from herdr (pane lost); nothing to focus" "F on the lost Captain's Call row says pane lost (enter there shows the hold card since 0.6.0)"
# Disconnected herdr: absence is unproved, so the cell reads unknown in grey and nothing is red (falsify: drop
# the unknown branch in herdrColumn, or the grey style in rowSegments).
frame_d=$(render lost-disconnected.json) || fail "disconnected: render exited non-zero"
tags_d=$(render lost-disconnected.json --tags) || fail "disconnected --tags: render exited non-zero"
assert_row "$frame_d" '^ firstmate-tui · /fixture/firstmate · 1 home +herdr disconnected \(ECONNREFUSED\) $' "disconnected fixture: the title line warns with the socket error as the reason"
assert_row "$frame_d" '^│ working +unknown +ship-lost +Retry on 429 from the address API · adding the retry loop ' "disconnected: the missing pane reads unknown, not pane lost"
assert_row "$tags_d" '\{grey-fg\}unknown *\{/grey-fg\}' "disconnected: the unknown cell is grey"
assert_count "$tags_d" "{red-fg}" 1 "disconnected: the title warning is the only red text; no row is red"
assert_contains "$tags_d" "{red-fg}herdr disconnected (ECONNREFUSED){/red-fg}" "disconnected: the warning carries the red tag the lost cell uses (falsify: give the warning the title style only)"
assert_widths "$frame_l" 160 "lost frame lines are 160 columns"

# ---------------------------------------------------------- landed targets
# Enter on a Recently Landed row takes the first target the row has that this board can reach: its PR, else
# its report on this host, else its worker pane while herdr lists it, else an ordinary footer notice
# (landedTarget in lib/controller.mjs). landed-targets.json at 160x44: Recently Landed's rows are lines
# 34-42 (etl-index, ship-done, etl-pane, ship-old, etl-report, plain-done, mobile-fix, etl-none,
# old-scout) and tab reaches the pane in four presses from Captain's Call (Underway, My PRs, then the
# empty Teammates' PRs and Charted Next are skipped). The WHAT text names the first target that exists
# (falsify: drop a rung from landedWhat in lib/model.mjs, the task or endpoint lookup that gives a
# done row its pane, or the report_path resolution).
frame_t=$(render landed-targets.json) || fail "landed targets: render exited non-zero"
assert_contains "$frame_t" "┌─ [6] Recently Landed (9) ─" "landed targets: nine rows, one per target shape"
assert_row "$frame_t" '^│ merged +09-15 +etl-index +Add the ETL index · https://github.com/acme/etl/pull/12 +acme/etl +delegate-a +1d │$' "secondmate row with a PR names the PR"
assert_row "$frame_t" '^│ done +09-14 +ship-done +Apply the widget migration · pane w1F:p1 +acme/widgets +main +2d │$' "main row whose done task still has its pane names the pane"
assert_row "$frame_t" '^│ done +09-13 +etl-pane +Backfill the ETL audit table · pane w2C:p2 +- +delegate-a +3d │$' "secondmate row whose ledger endpoint herdr lists names the pane"
assert_row "$frame_t" '^│ merged +09-12 +ship-old +Rename the widget table · https://github.com/acme/widgets/pull/30 +acme/widgets +main +4d │$' "main row with a PR and a lost pane names the PR"
assert_row "$frame_t" '^│ reported +09-11 +etl-report +Scout: warehouse index options · data/etl-report/report.md +- +delegate-a +5d │$' "secondmate row with a report names it relative to its home"
assert_row "$frame_t" '^│ done +09-10 +plain-done +Rotate the API keys +acme/api +main +6d │$' "main row with no PR, report or pane is the bare title"
assert_row "$frame_t" '^│ reported +09-09 +mobile-fix +Fix the crash on launch · data/mobile-fix/report.md +- +remote-sm \(remote\) +7d │$' "remote home's report-only row still names the report"
assert_row "$frame_t" '^│ done +09-08 +etl-none +Rotate the warehouse credentials +- +delegate-a +8d │$' "secondmate row with nothing is the bare title"
assert_row "$frame_t" '^│ reported +09-06 +old-scout +Scout: legacy import path · data/old-scout/report.md +acme/legacy +main +10d │$' "main row with a report names it relative to the main home"
assert_widths "$frame_t" 160 "landed targets frame lines are 160 columns"
# The pane text needs a pane herdr lists: the same fixture with the herdr block's agents emptied
# proves every listed pane gone, and both pane-only rows fall to the bare title (falsify: show
# `pane <id>` for a lost pane in landedWhat).
frame_t=$(render "$(variant landed-targets.json landed-nopanes '{"herdr": {"agents": []}}')") || fail "landed targets no panes: render exited non-zero"
assert_row "$frame_t" '^│ done +09-14 +ship-done +Apply the widget migration +acme/widgets +main +2d │$' "with the pane lost the main pane-only row is the bare title"
assert_row "$frame_t" '^│ done +09-13 +etl-pane +Backfill the ETL audit table +- +delegate-a +3d │$' "with the pane lost the secondmate pane-only row is the bare title"
assert_not_contains "$frame_t" "pane w" "no Recently Landed row names a pane once every pane is lost"

# render_targets <keys> [flags]: enter on a Recently Landed row of landed-targets.json with the fake opener
# and the fake viewer recording (logs reset first) and --no-herdr unless the flags say otherwise
render_targets() {
  local keys=$1
  shift
  rm -f "${OPENER_LOG:?}" "${VIEWER_LOG:?}"
  FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" FM_BOARD_TEST_VIEWER_LOG="$VIEWER_LOG" "$BOARD" --render-once --fixture "$FIX/landed-targets.json" --keys "$keys" --opener-cmd "$FAKE_OPENER" --viewer-cmd "$FAKE_VIEWER" "$@"
}
# Rung 1, a PR: the opener gets the URL, the viewer nothing (falsify: drop the PR rung from
# landedTarget, or order the report rung first).
frame_t=$(render_targets "tab,tab,tab,enter" --no-herdr) || fail "landed enter PR: render exited non-zero"
assert_opened "https://github.com/acme/etl/pull/12" "enter on a secondmate Recently Landed row with a PR opens it"
assert_not_viewed "a Recently Landed row with a PR never reaches the viewer"
assert_contains "$frame_t" "opened https://github.com/acme/etl/pull/12 (etl-index)" "footer names the opened PR"
frame_t=$(render_targets "tab,tab,tab,j,j,j,enter" --no-herdr) || fail "landed enter PR lost pane: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/30" "enter on a main Recently Landed row with a PR and a lost pane opens the PR"
assert_not_contains "$frame_t" "nothing to focus" "the lost pane is not reported when the PR opens"
# Rung 2, a report on this host: the viewer gets the absolute path resolved against the owning home,
# the opener nothing (falsify: drop reportPath from landedRows, or the report rung from landedTarget).
frame_t=$(render_targets "tab,tab,tab,j,j,j,j,enter" --no-herdr) || fail "landed enter secondmate report: render exited non-zero"
assert_viewed "/fixture/homes/delegate-a/data/etl-report/report.md" "enter on a secondmate Recently Landed row with a report views it against its own home"
assert_not_opened "a Recently Landed row with a report and no PR calls no opener"
assert_contains "$frame_t" "viewed /fixture/homes/delegate-a/data/etl-report/report.md (viewer-cmd)" "footer names the viewed report"
frame_t=$(render_targets "tab,tab,tab,j,j,j,j,j,j,j,j,enter" --no-herdr) || fail "landed enter main report: render exited non-zero"
assert_viewed "/fixture/firstmate/data/old-scout/report.md" "enter on a main Recently Landed row with a report views it against the main home"
assert_not_contains "$frame_t" "no PR URL" "a report-only Recently Landed row is no longer an error"
# A remote home's report is skipped, not refused: nothing here can show it, so with no pane either
# the row ends at the notice (falsify: let the report rung ignore reportRemote, or make the notice
# bad).
frame_t=$(render_targets "tab,tab,tab,j,j,j,j,j,j,enter" --no-herdr) || fail "landed enter remote report: render exited non-zero"
assert_not_viewed "a remote home's Recently Landed report is never opened"
assert_not_opened "a remote home's Recently Landed report calls no opener"
assert_contains "$frame_t" "mobile-fix: nothing to open (no PR, report or pane)" "remote report-only row: the plain notice, not the Findings refusal"
assert_not_contains "$frame_t" "lives on another host" "the remote report is skipped silently, no red notice"
# Rung 3, a live pane: without --no-herdr a fixture render reports the focus it would run (a fixture
# render makes no herdr call of its own; the fake herdr on HERDR_BIN_PATH and PATH proves it) and the
# opener and viewer stay idle (falsify: drop the pane rung from landedTarget, or the task lookup in
# landedRows).
frame_t=$(fake_herdr_env render_targets "tab,tab,tab,j,enter") || fail "landed enter main pane: render exited non-zero"
assert_contains "$frame_t" "would focus w1F:p1 (ship-done); --render-once never runs herdr agent focus" "enter on a main Recently Landed row whose done task still has its pane focuses it"
assert_not_opened "a pane-only Recently Landed row calls no opener"
assert_not_viewed "a pane-only Recently Landed row runs no viewer"
if [ -e "$HERDR_LOG" ]; then fail "a fixture render with herdr on called herdr: $(cat "$HERDR_LOG")"; else pass; fi
frame_t=$(fake_herdr_env render_targets "tab,tab,tab,j,j,enter") || fail "landed enter secondmate pane: render exited non-zero"
assert_contains "$frame_t" "would focus w2C:p2 (etl-pane); --render-once never runs herdr agent focus" "enter on a secondmate Recently Landed row whose endpoint herdr lists focuses it"
if [ -e "$HERDR_LOG" ]; then fail "a fixture render with herdr on called herdr: $(cat "$HERDR_LOG")"; else pass; fi
# Under --no-herdr the pane rung is skipped, so a pane-only row ends at the notice rather than the
# focus refusal (falsify: pass true for herdrOn under --no-herdr, or drop the herdrOn check from
# landedTarget).
frame_t=$(render_targets "tab,tab,tab,j,enter" --no-herdr) || fail "landed enter pane no-herdr: render exited non-zero"
assert_contains "$frame_t" "ship-done: nothing to open (no PR, report or pane)" "with --no-herdr a pane-only Recently Landed row reads nothing to open"
assert_not_contains "$frame_t" "cannot focus" "with --no-herdr the pane rung is skipped, not refused"
# A lost pane is skipped the same way: ship-old's pane is lost but its PR wins; with the herdr block's
# agents emptied ship-done's pane is lost too and the row ends at the notice (falsify: drop the lost
# check from landedTarget).
frame_t=$(fake_herdr_env "$BOARD" --render-once --fixture "$(variant landed-targets.json landed-nopanes '{"herdr": {"agents": []}}')" --keys "tab,tab,tab,j,enter") || fail "landed enter lost pane: render exited non-zero"
assert_contains "$frame_t" "ship-done: nothing to open (no PR, report or pane)" "a pane-only Recently Landed row whose pane is lost reads nothing to open"
assert_not_contains "$frame_t" "would focus" "a lost pane is never focused"
# Rung 4, nothing: an ordinary notice, not red (falsify: set bad: true on the notice, or fall through
# to the Ready for review text).
frame_t=$(render_targets "tab,tab,tab,j,j,j,j,j,enter" --no-herdr) || fail "landed enter none main: render exited non-zero"
assert_contains "$frame_t" "plain-done: nothing to open (no PR, report or pane)" "enter on a main Recently Landed row with nothing reads nothing to open"
assert_not_opened "a Recently Landed row with nothing calls no opener"
assert_not_viewed "a Recently Landed row with nothing runs no viewer"
tags_t=$(render landed-targets.json --keys "tab,tab,tab,j,j,j,j,j,enter" --tags) || fail "landed enter none --tags: render exited non-zero"
assert_not_contains "$tags_t" "{red-fg}plain-done: nothing to open" "the nothing-to-open notice is not red"
frame_t=$(render_targets "tab,tab,tab,j,j,j,j,j,j,j,enter" --no-herdr) || fail "landed enter none secondmate: render exited non-zero"
assert_contains "$frame_t" "etl-none: nothing to open (no PR, report or pane)" "enter on a secondmate Recently Landed row with nothing reads nothing to open"
# A double-click follows the same rungs, because mouseAction reuses keyAction enter (falsify: give
# 'activate' a PR-only action of its own). Line 37 is etl-report, the report-only secondmate row.
frame_t=$(render_mouse landed-targets.json "dblclick:60,37") || fail "landed dblclick report: render exited non-zero"
assert_viewed "/fixture/homes/delegate-a/data/etl-report/report.md" "double-click on a report-only Recently Landed row views the report"
assert_not_opened "double-click on a report-only Recently Landed row calls no opener"
assert_contains "$frame_t" "viewed /fixture/homes/delegate-a/data/etl-report/report.md (viewer-cmd)" "double-click: the footer names the viewed report"
# The other panes keep their enter (falsify: route every pane through landedTarget, or widen
# viewProblem / focusProblem beyond Recently Landed): an Underway worker asks herdr.
frame_t=$(render_targets "tab,enter" --no-herdr) || fail "landed fixture inflight enter: render exited non-zero"
assert_contains "$frame_t" "herdr is off (--no-herdr); cannot focus" "enter on an Underway worker still means herdr focus, refused under --no-herdr"
assert_not_opened "enter on an Underway worker calls no opener"
assert_not_viewed "enter on an Underway worker runs no viewer"
# The pane checks in viewProblem and focusProblem still refuse the panes they always refused
# (falsify: drop the pane check from either helper).
problems=$(node --input-type=module -e "
  import { focusProblem, viewProblem, landedTarget } from '$ROOT/bin/firstmate-tui/lib/controller.mjs';
  const row = { name: 'r', paneId: 'w1:p1', focusable: true, reportPath: '/x/report.md', url: null };
  console.log(focusProblem({ id: 'review' }, row, true));
  console.log(viewProblem({ id: 'review' }, row));
  console.log(focusProblem({ id: 'landed' }, row, true));
  console.log(viewProblem({ id: 'landed' }, row));
  console.log(focusProblem({ id: 'landed' }, { name: 'r', paneId: null }, true));
  console.log(viewProblem({ id: 'landed' }, { name: 'r', reportPath: null }));
  console.log(landedTarget({ url: 'https://x/pr/1', reportPath: '/x', paneId: 'w1:p1', focusable: true }, true));
  console.log(landedTarget({ url: null, reportPath: '/x', reportRemote: false, paneId: 'w1:p1', focusable: true }, true));
  console.log(landedTarget({ url: null, reportPath: null, reportRemote: true, paneId: 'w1:p1', focusable: true }, true));
  console.log(landedTarget({ url: null, reportPath: null, paneId: 'w1:p1', focusable: true }, false));
  console.log(landedTarget({ url: null, reportPath: null, paneId: 'w1:p1', lost: true, focusable: true }, true));
  console.log(landedTarget({ url: null, reportPath: null, paneId: 'w1:p1', focusable: false }, true));
  console.log(landedTarget({ url: null, reportPath: null, paneId: null }, true));
")
assert_row "$problems" '^enter focuses a worker: pick a row in Underway$' "focusProblem still refuses Ready for review"
assert_row "$problems" '^enter views a report: pick a Recently Landed row with one$' "viewProblem still refuses Ready for review"
if [ "$(printf '%s\n' "$problems" | sed -n 3p)" = "null" ]; then pass; else fail "focusProblem allows a Recently Landed row with a pane: got '$(printf '%s\n' "$problems" | sed -n 3p)'"; fi
if [ "$(printf '%s\n' "$problems" | sed -n 4p)" = "null" ]; then pass; else fail "viewProblem allows a Recently Landed row with a report: got '$(printf '%s\n' "$problems" | sed -n 4p)'"; fi
if [ "$(printf '%s\n' "$problems" | sed -n 5p)" = "enter focuses a worker: pick a row in Underway" ]; then pass; else fail "focusProblem refuses a Recently Landed row without a pane"; fi
if [ "$(printf '%s\n' "$problems" | sed -n 6p)" = "enter views a report: pick a Recently Landed row with one" ]; then pass; else fail "viewProblem refuses a Recently Landed row without a report"; fi
if [ "$(printf '%s\n' "$problems" | sed -n '7,13p' | tr '\n' ' ')" = "open view focus null null null null " ]; then pass; else fail "landedTarget rung order (PR, local report, live focusable pane with herdr on, a remote report skipped over to the pane, else null): got '$(printf '%s\n' "$problems" | sed -n '7,13p' | tr '\n' ' ')'"; fi

# --------------------------------------------------------- hold cards, d and D
# tests/fixtures/holds.json names two placeholder homes; HOLD_FIX is a copy with them rewritten to
# HOLD_HOME and HOLD_DELEGATE, scratch homes this section fills. HOLD_HOME holds the main hold's files
# (a 45-line report, a brief, two other entries under data/main-hold/, a 13-line status log, and a scout
# report for the Findings check) and tests/fake-captain-hold.sh as bin/fm-captain-hold.sh; HOLD_DELEGATE
# holds a fake bin/fm-fleet-snapshot.sh that logs `snapshot FM_HOME=<home>` to HOLD_LOG and prints the
# delegate's two full records (or fails under FAKE_SNAPSHOT_FAIL), a 3-line report and the same fake
# hold command. The fake hold command logs FM_HOME, its cwd, its argv and the decision file's contents
# to HOLD_LOG and answers as the real one does, or refuses with one stderr line under FAKE_HOLD_FAIL.
# A one-shot render really runs the home's bin/fm-captain-hold.sh, which is why the homes are scratch.
# Captain's Call rows: decide-task, main-hold, bare-hold, then the delegate homes' holds delegate-hold,
# child-held and remote-hold, then ship-review. Underway: decide-task, the delegate's one worker
# child-held drawn directly, ship-review. Charted Next: held-worker, the dated hold. Recently Landed:
# plain-landed, landed-hold (answered), the scout-x report.
HOLD_HOME="$SCRATCH/holds-main"
HOLD_DELEGATE="$SCRATCH/holds-delegate"
HOLD_CARD="$SCRATCH/hold-card.md"
HOLD_FIX="$SCRATCH/holds.json"
mkdir -p "$HOLD_HOME/data/main-hold/attachments" "$HOLD_HOME/data/scout-x" "$HOLD_HOME/state" "$HOLD_HOME/bin" "$HOLD_DELEGATE/bin" "$HOLD_DELEGATE/data/delegate-hold"
# The fake logs the cwd the command ran in as the kernel reports it (bash's PWD after node's cwd),
# which on macOS resolves the temp directory's /var symlink; the FM_HOME line keeps the path as given.
HOLD_HOME_REAL=$(cd "$HOLD_HOME" && pwd -P)
HOLD_DELEGATE_REAL=$(cd "$HOLD_DELEGATE" && pwd -P)
for i in $(seq 1 45); do echo "# Report line $i"; done > "$HOLD_HOME/data/main-hold/report.md"
printf 'the brief\n' > "$HOLD_HOME/data/main-hold/brief.md"
printf 'notes\n' > "$HOLD_HOME/data/main-hold/notes.md"
printf '# scout report\n' > "$HOLD_HOME/data/scout-x/report.md"
for i in $(seq 1 13); do echo "working: status line $i"; done > "$HOLD_HOME/state/main-hold.status"
printf 'one\ntwo\nthree\n' > "$HOLD_DELEGATE/data/delegate-hold/report.md"
cp "$ROOT/tests/fake-captain-hold.sh" "$HOLD_HOME/bin/fm-captain-hold.sh"
cp "$ROOT/tests/fake-captain-hold.sh" "$HOLD_DELEGATE/bin/fm-captain-hold.sh"
# shellcheck disable=SC2016 # the template literal is node's, not the shell's
node -e '
  const fs = require("fs");
  const [fixture, out, mainHome, delegateHome] = process.argv.slice(1);
  fs.writeFileSync(out, fs.readFileSync(fixture, "utf8").split("/fixture/holds-main").join(mainHome).split("/fixture/holds-delegate").join(delegateHome));
  const record = (id, state, title, kind, reason, set, age, report, body) => ({ id, state, title, repo: "acme/etl", kind, hold_kind: "captain", hold_reason: reason, hold_until: null, hold_set: set, hold_bucket: "live", hold_age_days: age, captain_actionable: true, since: set.slice(0, 10), pr_url: null, report_path: report, body_lines: body, links: [], completion: { verb: null, date: null } });
  const snapshot = { schema: "fm-fleet-snapshot.v1", fm_home: delegateHome, tasks: [], backlog: { records: [
    record("delegate-hold", "queued", "Approve the warehouse index", "task", "The full delegate reason, longer than the ledger keeps: approve the warehouse index before the nightly loader is scheduled", "2026-09-15T08:00:00Z", 1, "data/delegate-hold/report.md", ["Captain hold set: 2026-09-15T08:00:00Z", "Index plan attached in the report."]),
    record("child-held", "in_flight", "Cut over the nightly ETL", "ship", "The full child-held reason from the delegate home", "2026-09-14T08:00:00Z", 2, null, []),
  ] } };
  fs.writeFileSync(`${delegateHome}/snapshot.json`, JSON.stringify(snapshot));
' "$FIX/holds.json" "$HOLD_FIX" "$HOLD_HOME" "$HOLD_DELEGATE"
# shellcheck disable=SC2016 # the fake expands $FM_HOME and $FM_BOARD_TEST_HOLD_LOG at run time, not here
printf '#!/usr/bin/env bash\n[ -z "${FM_BOARD_TEST_HOLD_LOG:-}" ] || echo "snapshot FM_HOME=$FM_HOME" >> "$FM_BOARD_TEST_HOLD_LOG"\nif [ -n "${FAKE_SNAPSHOT_FAIL:-}" ]; then echo "fm-fleet-snapshot: jq not found" >&2; exit 1; fi\ncat "%s"\n' "$HOLD_DELEGATE/snapshot.json" > "$HOLD_DELEGATE/bin/fm-fleet-snapshot.sh"
chmod +x "$HOLD_HOME/bin/fm-captain-hold.sh" "$HOLD_DELEGATE/bin/fm-captain-hold.sh" "$HOLD_DELEGATE/bin/fm-fleet-snapshot.sh"
# HOLD_LIVE: a stand-in main home for the live-render checks of a dismissal followed by the refresh a
# success starts. Its bin/fm-fleet-snapshot.sh logs `snapshot FM_HOME=<home>` to HOLD_LOG on every call
# and prints the holds fixture's snapshot (main-hold live, no secondmate records) on the first call of a
# render, and on later calls the file HOLD_LIVE_SECOND names, else the same snapshot again; a counter
# file under the home tells the calls apart and is reset before each render. snapshot-answered.json is
# the same snapshot with main-hold done (completion answered), as firstmate leaves a discarded item.
HOLD_LIVE="$SCRATCH/holds-live"
mkdir -p "$HOLD_LIVE/bin"
cp "$ROOT/tests/fake-captain-hold.sh" "$HOLD_LIVE/bin/fm-captain-hold.sh"
# shellcheck disable=SC2016 # the template literal is node's, not the shell's
node -e '
  const fs = require("fs");
  const [fixture, home] = process.argv.slice(1);
  const snap = JSON.parse(fs.readFileSync(fixture, "utf8").split("/fixture/holds-main").join(home)).snapshot;
  snap.fm_home = home;
  snap.secondmate_current = { records: [] };
  fs.writeFileSync(`${home}/snapshot-held.json`, JSON.stringify(snap));
  const rec = snap.backlog.records.find((r) => r.id === "main-hold");
  Object.assign(rec, { state: "done", hold_bucket: null, captain_actionable: false, completion: { verb: "answered", date: "2026-09-21" } });
  fs.writeFileSync(`${home}/snapshot-answered.json`, JSON.stringify(snap));
' "$FIX/holds.json" "$HOLD_LIVE"
# shellcheck disable=SC2016 # the fake expands its variables at run time, not here
printf '%s\n' '#!/usr/bin/env bash' \
  '[ -z "${FM_BOARD_TEST_HOLD_LOG:-}" ] || echo "snapshot FM_HOME=$FM_HOME" >> "$FM_BOARD_TEST_HOLD_LOG"' \
  'n=$(cat "$FM_HOME/calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FM_HOME/calls"' \
  'if [ "$n" -gt 1 ] && [ -n "${HOLD_LIVE_SECOND:-}" ]; then cat "$HOLD_LIVE_SECOND"; else cat "$FM_HOME/snapshot-held.json"; fi' > "$HOLD_LIVE/bin/fm-fleet-snapshot.sh"
chmod +x "$HOLD_LIVE/bin/fm-captain-hold.sh" "$HOLD_LIVE/bin/fm-fleet-snapshot.sh"
HOLD_LIVE_REAL=$(cd "$HOLD_LIVE" && pwd -P)
# render_hold_live <second snapshot file or empty> <keys>: a live one-shot render of HOLD_LIVE with the
# PR fetch off (so gh is never asked; the fake gh is first on PATH all the same), its own view-state file,
# the hold log and the call counter reset first.
render_hold_live() {
  local second=$1 keys=$2
  rm -f "${HOLD_LOG:?}" "${HOLD_LIVE:?}/calls"
  HOLD_LIVE_SECOND="$second" FM_BOARD_TEST_HOLD_LOG="$HOLD_LOG" FM_HOME="$HOLD_LIVE" XDG_CONFIG_HOME="$SCRATCH/xdg" PATH="$FAKE_BIN:$PATH" \
    "$BOARD" --render-once --no-herdr --no-prs --keys "$keys" --view-state "$SCRATCH/holds-live-view-state.json"
}
# render_hold <keys> [flags]: HOLD_FIX with every fake wired and every log reset first; the fake viewer
# copies the file it is given to HOLD_CARD, since the board removes a card's temp file as soon as the
# viewer exits.
render_hold() {
  local keys=$1
  shift
  rm -f "${HOLD_LOG:?}" "${HOLD_CARD:?}" "${VIEWER_LOG:?}" "${OPENER_LOG:?}"
  FM_BOARD_TEST_HOLD_LOG="$HOLD_LOG" FM_BOARD_TEST_VIEWER_LOG="$VIEWER_LOG" FM_BOARD_TEST_VIEWER_COPY="$HOLD_CARD" FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" \
    "$BOARD" --render-once --fixture "$HOLD_FIX" --no-herdr --keys "$keys" --viewer-cmd "$FAKE_VIEWER" --opener-cmd "$FAKE_OPENER" "$@"
}
assert_hold_log() { # <expected content> <label>: the fake hold command (and the delegate snapshot) logged exactly these lines
  if [ -f "$HOLD_LOG" ] && [ "$(cat "$HOLD_LOG")" = "$1" ]; then pass; else fail "$2: hold log is '$(tr '\n' '|' < "$HOLD_LOG" 2>/dev/null || echo '<absent>')', expected '$(printf '%s' "$1" | tr '\n' '|')'"; fi
}
assert_no_hold() { # <label>
  if [ -e "$HOLD_LOG" ]; then fail "$1: the hold command ran: $(tr '\n' '|' < "$HOLD_LOG")"; else pass; fi
}
card() { cat "$HOLD_CARD" 2>/dev/null || echo '<no card copied>'; }
# The dates the board computes from the wall clock, in the local zone, as the board does (the offset
# travels in the environment: node would read a `-1` argument as one of its own options).
# shellcheck disable=SC2016 # the template literal is node's, not the shell's
local_date() { DAYS="$1" node -e 'const p = (n) => String(n).padStart(2, "0"); const d = new Date(); d.setDate(d.getDate() + Number(process.env.DAYS)); console.log(`${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`);'; }
TODAY=$(local_date 0)
PLUS14=$(local_date 14)
YESTERDAY=$(local_date -1)
CLEAR="backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace,backspace"
spell() { printf '%s' "$1" | sed 's/./&,/g; s/,$//'; } # a date as key tokens: 2,0,2,7,-,0,1,-,1,5

# The rows and the footer (falsify: drop mainCard from the hold rows or taskDecisionRows, heldForCaptain
# from mainTaskRow or landedRows, ledgerCard from decisionRow, or the card branch of boardHints).
frame_h=$(render "$HOLD_FIX") || fail "holds: render exited non-zero"
assert_contains "$frame_h" "Captain's Call (7)" "holds: a decision, two main live holds, three delegate holds and a review row"
assert_row "$frame_h" '^│ decide +db-choice +decide-task +Postgres or SQLite for the cache\? +acme/api +main +- │$' "holds: the keyed decision row"
assert_row "$frame_h" '^│ hold +- +main-hold +Pick the vendor for the address API · Two quotes arrived; pick the vendor for the a… +acme/api +main +3d │$' "holds: the main hold row"
assert_row "$frame_h" '^│ hold +- +bare-hold +Keep or drop the legacy importer · Decide whether the legacy importer stays +acme/legacy +main +2d │$' "holds: the bare hold row"
assert_row "$frame_h" '^│ hold +- +delegate-hold +Approve the warehouse index · Ledger copy of the reason, cut at 160 characters +acme/etl +delegate +1d │$' "holds: the delegate's hold lists by default, labelled with its home"
assert_row "$frame_h" '^│ hold +- +remote-hold +Rotate the mobile signing key\? · Remote ledger reason +acme/mobile +remote-sm \(remote\) +4d │$' "holds: the remote home's hold lists by default with the remote label"
assert_row "$frame_h" '^│ review +#7 +ship-review ' "holds: the review row"
# The paused worker whose record is a dated hold is not a worker row: nothing runs, and the hold is one
# Charted Next row with its until date (falsify: drop the held skip from mainTaskRow, or the dated
# branch from chartedWhy).
assert_no_row "$frame_h" '^│ paused +[^│]*held-worker ' "holds: the paused worker under a dated hold has no Underway row"
assert_row "$frame_h" '^│ dated +until 10-01 +held-worker +Move the cache to the new vendor · Waiting for the vendor contract before the cache lands +acme/api +main +09-09 │$' "holds: the dated hold is Charted Next's row, WHY its until date, FILED its since date"
assert_row "$frame_h" '^│ paused +idle +!child-held +Child held · waiting on the captain +acme/etl +delegate +- │$' "holds: the delegate's one worker, held for the captain, draws directly with the ! marker"
assert_row "$frame_h" '^│ answered +09-14 +landed-hold +Rename the widget table +acme/widgets +main +2d │$' "holds: the finished hold lists in Recently Landed as usual"
assert_row "$(render_hold "k")" '^ j/k move  tab pane  enter card  F focus  x hide ' "holds footer: the decision row has a card and a pane, no hold to act on"
assert_row "$(render_hold "j")" '^ j/k move  tab pane  enter card  a accept  d discard  D defer  x hide ' "holds footer: the main hold row has a card, d and D, and no pane"
# held-worker is Charted Next's first row, three tabs away (Underway, My PRs, then Teammates' PRs is empty).
assert_row "$(render_hold "tab,tab,tab")" '^ j/k move  tab pane  enter card  a accept  d discard  D defer  x hide ' "holds footer: the dated hold in Charted Next has the card and both actions, no pane (a hold row is built from the backlog record)"
assert_row "$(render_hold "tab,j")" '^ j/k move  tab pane  enter card  F focus  a accept  d discard  D defer  x hide ' "holds footer: the held worker in Underway has the card, the focus and both actions"
assert_row "$(render_hold "j,j,j,j,j,j")" '^ j/k move  tab pane  enter open/focus/view  f search  a accept ' "holds footer: the review row keeps the standard hints (falsify: give reviewRow a card)"
assert_row "$(render_hold "tab,tab,tab,tab,j")" '^ j/k move  tab pane  enter card  x hide ' "holds footer: the finished hold in Recently Landed has its card, no pane and nothing to act on"
assert_widths "$frame_h" 160 "holds frame lines are 160 columns"

# The card of the main hold: every section, read from the scratch home, shown through the fake viewer
# from a temp file that is gone once the viewer exits (falsify: drop a section from buildHoldCard, read
# the report whole in readHoldMaterials, tail the status log by another count, or skip removeTempDir).
frame_h=$(render_hold "j,enter") || fail "holds card main: render exited non-zero"
assert_contains "$frame_h" "viewed the hold card of main-hold (viewer-cmd)" "card main: the footer names the card and the viewer"
assert_row "$(cat "$VIEWER_LOG")" '/firstmate-tui-[^/]+/main-hold\.md$' "card main: the viewer got a temp file named after the task under a firstmate-tui temp directory"
if [ -e "$(cat "$VIEWER_LOG")" ]; then fail "card main: the temp file $(cat "$VIEWER_LOG") is still there after the viewer exited"; else pass; fi
assert_row "$(card)" '^# Pick the vendor for the address API$' "card main: the title line"
assert_contains "$(card)" "| id | main-hold |" "card main: the id"
assert_contains "$(card)" "| home | main ($HOLD_HOME) |" "card main: the home label and path"
assert_contains "$(card)" "| repo | acme/api |" "card main: the repo"
assert_contains "$(card)" "| state | queued |" "card main: the state"
assert_contains "$(card)" "| kind | task |" "card main: the kind"
assert_contains "$(card)" "| hold kind | captain |" "card main: the hold kind"
assert_contains "$(card)" "| bucket | live |" "card main: the bucket"
assert_contains "$(card)" "| until | - |" "card main: no until date reads -"
assert_contains "$(card)" "| set | 2026-09-13T12:00:00Z |" "card main: the hold-set stamp"
assert_contains "$(card)" "| age | 3 days |" "card main: the age in days"
assert_row "$(card)" '^Two quotes arrived; pick the vendor for the address API$' "card main: the hold reason verbatim"
assert_row "$(card)" '^Two vendors quoted; the report compares them\.$' "card main: a body line verbatim"
assert_row "$(card)" '^Prefer the one with the EU region\.$' "card main: the last body line"
assert_row "$(card)" '^https://github\.com/acme/api/pull/77$' "card main: the PR URL"
assert_contains "$(card)" "data/main-hold/report.md (45 lines; the first 40 follow)" "card main: the report path with its line count and the head size"
assert_contains "$(card)" "# Report line 40" "card main: the 40th report line is inlined"
assert_not_contains "$(card)" "# Report line 41" "card main: the 41st report line is not"
assert_contains "$(card)" "5 more lines in the file" "card main: the more-lines line"
assert_row "$(card)" '^data/main-hold/brief\.md$' "card main: the brief path"
assert_row "$(card)" '^- data/main-hold/attachments$' "card main: another entry under data/<id>/"
assert_row "$(card)" '^- data/main-hold/notes\.md$' "card main: the other file"
assert_no_row "$(card)" '^- data/main-hold/(report|brief)\.md$' "card main: the report and the brief are not listed as other files"
assert_contains "$(card)" "state/main-hold.status, the last 10 of 13 lines:" "card main: the status log path and counts"
assert_contains "$(card)" "working: status line 4" "card main: the earliest of the last 10 status lines"
assert_contains "$(card)" "working: status line 13" "card main: the last status line"
assert_not_contains "$(card)" "working: status line 3" "card main: the 11th-from-last status line is not inlined"
assert_count "$(card)" "working: status line" 10 "card main: exactly ten status lines"
assert_before "$(card)" '^## Hold reason' '^## Backlog body' "card main: the reason precedes the body"
assert_before "$(card)" '^## Pull request' '^## Report' "card main: the PR precedes the report"
assert_before "$(card)" '^## Brief' '^## Other files under data/main-hold/' "card main: the brief precedes the other files"
assert_before "$(card)" '^## Other files' '^## Status log' "card main: the other files precede the status log"
assert_not_contains "$(card)" "Partial record" "card main: a main-home record is never partial"
assert_not_opened "card main: the card opens no PR"
assert_no_hold "card main: the card runs no hold command"
# The hold with nothing on disk: one line per empty section (falsify: crash on a missing data/<id>/, or
# leave a section out).
frame_h=$(render_hold "j,j,enter") || fail "holds card bare: render exited non-zero"
assert_contains "$frame_h" "viewed the hold card of bare-hold (viewer-cmd)" "card bare: the footer names the card"
assert_row "$(card)" '^# Keep or drop the legacy importer$' "card bare: the title"
assert_contains "$(card)" "| set | - |" "card bare: no hold-set stamp reads -"
assert_contains "$(card)" "| age | - |" "card bare: no age reads -"
assert_row "$(card)" '^no body lines$' "card bare: the empty body line"
assert_row "$(card)" '^no PR recorded$' "card bare: the empty PR line"
assert_row "$(card)" '^no report at data/bare-hold/report\.md$' "card bare: the empty report line"
assert_row "$(card)" '^no brief at data/bare-hold/brief\.md$' "card bare: the empty brief line"
assert_row "$(card)" '^no data/bare-hold/ directory$' "card bare: the missing directory line"
assert_row "$(card)" '^no status log at state/bare-hold\.status$' "card bare: the empty status line"
# The other card rows: the decision row's card is its task's record without a hold, the dated hold's
# card in Charted Next, the finished hold's card in Recently Landed with its done state, and a Recently
# Landed row without a hold keeps enter = open its PR (falsify: route Recently Landed's enter through the
# card for every row, or drop mainCard from chartedRow's fields).
frame_h=$(render_hold "k,enter") || fail "holds card decision: render exited non-zero"
assert_contains "$frame_h" "viewed the hold card of decide-task (viewer-cmd)" "card decision: enter on the keyed decision row shows its task's card"
assert_contains "$(card)" "| hold kind | - |" "card decision: a task without a hold reads - for the hold kind"
assert_row "$(card)" '^no hold reason recorded$' "card decision: the empty reason line"
assert_row "$(card)" '^Cache the widget lookups; the vendor question gates the design\.$' "card decision: the body comes from the backlog record"
frame_h=$(render_hold "tab,tab,tab,enter") || fail "holds card charted: render exited non-zero"
assert_contains "$frame_h" "viewed the hold card of held-worker (viewer-cmd)" "card charted: enter on the Charted Next row whose record is a dated hold shows the card"
assert_contains "$(card)" "| bucket | dated |" "card charted: the dated bucket"
assert_contains "$(card)" "| until | 2026-10-01 |" "card charted: the until date"
frame_h=$(render_hold "tab,tab,tab,tab,j,enter") || fail "holds card landed: render exited non-zero"
assert_contains "$frame_h" "viewed the hold card of landed-hold (viewer-cmd)" "card landed: enter on the finished hold in Recently Landed shows its card"
assert_contains "$(card)" "| state | done |" "card landed: the done state"
assert_row "$(card)" '^Answered: keep the old name$' "card landed: the recorded reason"
frame_h=$(render_hold "tab,tab,tab,tab,enter") || fail "holds landed PR: render exited non-zero"
assert_opened "https://github.com/acme/etl/pull/12" "a Recently Landed row without a hold still opens its PR on enter"
assert_not_viewed "a Recently Landed row without a hold runs no viewer"
# The delegate home's card: the full record read through that home's own fm-fleet-snapshot.sh (the log
# names the home), the home on the card, the report head from that home's files (falsify: build a
# delegate card from the ledger alone, or run the main home's snapshot instead).
frame_h=$(render_hold "j,j,j,enter") || fail "holds card delegate: render exited non-zero"
assert_contains "$frame_h" "viewed the hold card of delegate-hold (viewer-cmd)" "card delegate: the footer names the card, not partial"
assert_hold_log "snapshot FM_HOME=$HOLD_DELEGATE" "card delegate: the delegate home's snapshot script ran once, with FM_HOME set to that home, and no hold command"
assert_row "$(card)" '^# Approve the warehouse index$' "card delegate: the title"
assert_contains "$(card)" "| home | delegate ($HOLD_DELEGATE) |" "card delegate: the delegate home's label and path"
assert_row "$(card)" '^The full delegate reason, longer than the ledger keeps: approve the warehouse index before the nightly loader is scheduled$' "card delegate: the full reason from the home's record, not the ledger's cut"
assert_not_contains "$(card)" "Ledger copy of the reason" "card delegate: the ledger's truncated reason is not on the card"
assert_contains "$(card)" "data/delegate-hold/report.md (3 lines; the first 3 follow)" "card delegate: the report head from the delegate home's files"
assert_not_contains "$(card)" "more line" "card delegate: a report shorter than the head has no more-lines line"
assert_not_contains "$(card)" "Partial record" "card delegate: a record the home answered is not partial"
# The same card when the delegate's snapshot fails: the ledger's fields under a partial notice that
# names the failure, the files still read (falsify: refuse the card, or drop the partial line).
frame_h=$(FAKE_SNAPSHOT_FAIL=1 render_hold "j,j,j,enter") || fail "holds card delegate fail: render exited non-zero"
assert_contains "$frame_h" "viewed the hold card of delegate-hold (partial record) (viewer-cmd)" "card delegate fail: the footer says partial"
assert_row "$(card)" "^> Partial record: delegate's fm-fleet-snapshot.sh gave no record for delegate-hold \(exit 1: fm-fleet-snapshot: jq not found\); the title, the reason \(cut at 160 characters\) and the hold fields come from its ledger\.$" "card delegate fail: the first line says why the record is partial"
assert_row "$(card)" '^Ledger copy of the reason, cut at 160 characters$' "card delegate fail: the ledger's reason stands in"
assert_contains "$(card)" "data/delegate-hold/report.md (3 lines; the first 3 follow)" "card delegate fail: the home's files are still read"
# A remote home's hold: the card from the ledger, marked partial, with no file read (falsify: try to
# read a remote home's files).
frame_h=$(render_hold "j,j,j,j,j,enter") || fail "holds card remote: render exited non-zero"
assert_contains "$frame_h" "viewed the hold card of remote-hold (partial record) (viewer-cmd)" "card remote: the footer says partial"
assert_row "$(card)" '^> Partial record: remote-sm is a remote home whose files are not readable here; the title, the reason \(cut at 160 characters\) and the hold fields come from its ledger\.$' "card remote: the first line names the remote home"
assert_row "$(card)" '^Remote ledger reason$' "card remote: the ledger's reason"
assert_row "$(card)" '^data/remote-hold/report\.md: not readable from here$' "card remote: no file is read"
assert_no_hold "card remote: no snapshot and no command runs for a remote home"
# A held worker drawn directly in Underway carries the same card (falsify: drop ledgerCard from
# ledgerChildRows).
frame_h=$(render_hold "tab,j,enter") || fail "holds card child: render exited non-zero"
assert_contains "$frame_h" "viewed the hold card of child-held (viewer-cmd)" "card child: enter on the held worker's Underway row shows its card"
assert_row "$(card)" '^# Cut over the nightly ETL$' "card child: the title from the delegate's record"
assert_row "$(card)" '^The full child-held reason from the delegate home$' "card child: the full reason"
# Review rows and report rows keep their enter (falsify: give reviewRow a card, or route a report row
# through it).
frame_h=$(render_hold "j,j,j,j,j,j,enter") || fail "holds review enter: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/7" "enter on the review row still opens its PR"
assert_not_viewed "enter on the review row runs no viewer"
frame_h=$(render_hold "tab,tab,tab,tab,j,j,enter") || fail "holds report enter: render exited non-zero"
assert_viewed "$HOLD_HOME/data/scout-x/report.md" "enter on the report row of Recently Landed views its report"
assert_no_hold "neither enter runs a hold command"
# F (falsify: drop the F case from keyAction).
frame_h=$(render_hold "k,F") || fail "holds F: render exited non-zero"
assert_contains "$frame_h" "herdr is off (--no-herdr); cannot focus" "F on the decision row asks for its pane, refused under --no-herdr"
frame_h=$(fake_herdr_env "$BOARD" --render-once --fixture "$HOLD_FIX" --keys "F") || fail "holds F herdr: render exited non-zero"
assert_contains "$frame_h" "would focus w1A:p1 (decide-task); --render-once never runs herdr agent focus" "F on the decision row focuses its worker's pane through the fixture overlay"
if [ -e "$HERDR_LOG" ]; then fail "holds F: a fixture render with herdr on called herdr: $(cat "$HERDR_LOG")"; else pass; fi
frame_h=$(render_hold "j,F") || fail "holds F hold row: render exited non-zero"
assert_contains "$frame_h" "main-hold: no herdr pane to focus" "F on a hold row without a pane says so"

# d: the prompt, the confirmation, the cancel paths and the refusals (falsify: drop the prompt branch
# from handleKey, let x act while the prompt is up, run the command before y, or drop holdActionProblem).
frame_h=$(render_hold "j,d") || fail "holds d: render exited non-zero"
assert_row "$frame_h" '^ discard main-hold\? y to discard, esc to cancel +$' "d on a hold row puts the prompt in the footer"
assert_no_hold "d alone runs nothing"
frame_h=$(render_hold "j,d,y") || fail "holds d,y: render exited non-zero"
assert_hold_log "FM_HOME=$HOLD_HOME
cwd=$HOLD_HOME_REAL
argv=answer main-hold --decision-file $(grep -o -- '--decision-file .*' "$HOLD_LOG" 2>/dev/null | cut -d' ' -f2)
decision=Discarded by captain from firstmate-tui on $TODAY: no action; closed as not wanted." "d,y runs fm-captain-hold.sh answer once in the hold's home, FM_HOME and cwd that home, with the fixed decision text naming the fixture's login and today"
assert_row "$(cat "$HOLD_LOG")" '^argv=answer main-hold --decision-file /.*/firstmate-tui-[^/]+/decision\.txt$' "d,y: the decision file lives in a firstmate-tui temp directory"
if [ -e "$(grep -o -- '--decision-file .*' "$HOLD_LOG" | cut -d' ' -f2)" ]; then fail "d,y: the decision file is still there after the command exited"; else pass; fi
assert_contains "$frame_h" "discarded main-hold · answered: main-hold" "d,y: the footer names the discard and the command's first output line"
assert_not_contains "$frame_h" "y to discard" "d,y: the prompt is gone from the footer"
# The row leaves the same frame the command succeeded in, before any refresh: it is out of Captain's Call,
# the pane count is one less, it is not counted hidden, and the cursor sits on the row that took its
# place (falsify: drop applyDismissed from buildModel, drop dismissRow from holdDiscard, or add the hide
# key to view.hidden instead, which counts it hidden and lets H bring it back).
assert_contains "$frame_h" "Captain's Call (6)" "d,y: the pane count drops by one in the same frame"
assert_no_row "$frame_h" '^│ hold +- +main-hold ' "d,y: the discarded hold row is gone from Captain's Call at once"
assert_not_contains "$frame_h" "hidden" "d,y: the dismissed row is not counted as hidden"
assert_row "$frame_h" '^│ hold +- +bare-hold ' "d,y: the other hold stays"
tags_h=$(render_hold "j,d,y" --tags) || fail "holds d,y --tags: render exited non-zero"
assert_row "$tags_h" "${SEL}hold +${SEL_END}${SEL} +${SEL_END}${SEL}- +${SEL_END}${SEL} +${SEL_END}${SEL}bare-hold +${SEL_END}" "d,y: the selection lands on bare-hold, the row that took the discarded one's place"
assert_no_row "$tags_h" "${SEL}[^{]*main-hold" "d,y: the discarded row is not the selection"
frame_h=$(render_hold "j,d,y,H") || fail "holds d,y,H: render exited non-zero"
assert_contains "$frame_h" "showing hidden rows (greyed); H hides them again" "d,y,H: H toggles as usual"
assert_contains "$frame_h" "Captain's Call (6)" "d,y,H: the dismissed row is not among the hidden rows H shows (falsify: dismiss through view.hidden)"
assert_not_contains "$frame_h" "(hidden) Pick the vendor" "d,y,H: the dismissed row is not drawn greyed"
assert_no_row "$frame_h" '^│ hold +- +main-hold ' "d,y,H: the dismissed row stays out under H"
# The same task listed in Underway as well: a variant whose held-worker is a live, actionable hold on a
# working task, so Captain's Call lists it (second row, ahead of main-hold in backlog order) and its
# Underway row, marked !, carries the same card. Discarding it from Captain's Call drops both rows in
# the same frame (falsify: match the dismissal on the Captain's Call pane alone, or on the hide key,
# which differs per pane).
node -e '
  const fs = require("fs");
  const [src, dst] = process.argv.slice(1);
  const fx = JSON.parse(fs.readFileSync(src, "utf8"));
  const rec = fx.snapshot.backlog.records.find((r) => r.id === "held-worker");
  Object.assign(rec, { hold_bucket: "live", hold_until: null, captain_actionable: true });
  const task = fx.snapshot.tasks.find((t) => t.id === "held-worker");
  task.current_state = { ...task.current_state, state: "working", detail: "harness busy (claude-hook)" };
  fs.writeFileSync(dst, JSON.stringify(fx));
' "$HOLD_FIX" "$SCRATCH/holds-inflight.json"
frame_h=$(FM_BOARD_TEST_HOLD_LOG="$HOLD_LOG" "$BOARD" --render-once --fixture "$SCRATCH/holds-inflight.json" --no-herdr --keys "j") || fail "holds inflight: render exited non-zero"
assert_contains "$frame_h" "Captain's Call (8)" "holds inflight: the live held worker joins Captain's Call"
assert_contains "$frame_h" "Underway (4)" "holds inflight: Underway lists the working held task"
assert_row "$frame_h" '^│ hold +- +held-worker +Move the cache to the new vendor · Waiting for the vendor contract before the cache' "holds inflight: the held worker's Captain's Call row"
assert_row "$frame_h" '^│ working +idle +!held-worker +Move the cache to the new vendor · harness busy \(claude-hook\) ' "holds inflight: the held worker's Underway row, marked ! (falsify: drop the flag or the marker from mainTaskRow)"
assert_row "$frame_h" '^ j/k move  tab pane  enter card  a accept  d discard  D defer  x hide ' "holds inflight: j selects the held worker's Captain's Call row, a hold row built from the backlog record and so without the worker's pane"
rm -f "${HOLD_LOG:?}"
frame_h=$(FM_BOARD_TEST_HOLD_LOG="$HOLD_LOG" "$BOARD" --render-once --fixture "$SCRATCH/holds-inflight.json" --no-herdr --keys "j,d,y") || fail "holds inflight d,y: render exited non-zero"
assert_file_contains "$HOLD_LOG" "argv=answer held-worker --decision-file" "holds inflight d,y: the command ran for the held worker"
assert_contains "$frame_h" "discarded held-worker · answered: held-worker" "holds inflight d,y: the footer names the discard"
assert_contains "$frame_h" "Captain's Call (7)" "holds inflight d,y: Captain's Call drops the hold row"
assert_contains "$frame_h" "Underway (3)" "holds inflight d,y: Underway drops the same task's row in the same frame"
assert_no_row "$frame_h" '^│ [^│]*held-worker' "holds inflight d,y: no pane lists the task any more (the footer notice alone names it)"
assert_row "$frame_h" '^│ hold +- +main-hold ' "holds inflight d,y: the other holds stay"
frame_h=$(render_hold "j,d,escape") || fail "holds d,escape: render exited non-zero"
assert_no_hold "d,escape runs nothing"
assert_contains "$frame_h" "cancelled; main-hold is unchanged" "d,escape: the footer says cancelled"
frame_h=$(render_hold "j,d,x,escape") || fail "holds d,x,escape: render exited non-zero"
assert_no_hold "d,x,escape runs nothing"
assert_contains "$frame_h" "Captain's Call (7)" "d,x,escape: x is ignored while the prompt is up, so the row is not hidden"
assert_not_contains "$frame_h" "hidden main-hold" "d,x,escape: no hide notice"
frame_h=$(render_hold "j,d,q,j,k") || fail "holds d,q: render exited non-zero"
assert_row "$frame_h" '^ discard main-hold\? y to discard, esc to cancel +$' "d then other keys: the prompt stays up and q does not quit"
assert_no_hold "d then other keys runs nothing"
frame_h=$(FAKE_HOLD_FAIL=1 render_hold "j,d,y") || fail "holds d fail: render exited non-zero"
assert_contains "$frame_h" "fm-captain-hold: task main-hold is not held for the captain; hold it first or name the right task" "a refusing command's stderr line is the footer, verbatim"
assert_not_contains "$frame_h" "discarded" "a refused discard is not reported as done"
assert_file_contains "$HOLD_LOG" "argv=answer main-hold --decision-file" "the refused command did run once"
assert_contains "$frame_h" "Captain's Call (7)" "a refused discard leaves the pane count as it was (falsify: dismiss before the exit status is known)"
assert_row "$frame_h" '^│ hold +- +main-hold ' "a refused discard leaves the row on the board"
tags_h=$(FAKE_HOLD_FAIL=1 FM_BOARD_TEST_HOLD_LOG="$HOLD_LOG" "$BOARD" --render-once --fixture "$HOLD_FIX" --no-herdr --keys "j,d,y" --tags) || fail "holds d fail --tags: render exited non-zero"
assert_row "$tags_h" '\{red-fg\}[^{]*fm-captain-hold: task main-hold is not held for the captain' "the refusal is red (falsify: pass bad=false on a failed run)"
frame_h=$(render_hold "j,j,j,j,j,j,d") || fail "holds d review: render exited non-zero"
assert_contains "$frame_h" "ship-review: no captain hold to discard" "d on a review row is refused with a notice"
assert_no_hold "d on a review row runs nothing"
frame_h=$(render_hold "k,d") || fail "holds d decision: render exited non-zero"
assert_contains "$frame_h" "decide-task: no captain hold to discard" "d on a decision row whose task has no hold is refused"
frame_h=$(render_hold "j,j,j,j,j,d") || fail "holds d remote: render exited non-zero"
assert_contains "$frame_h" "remote-hold: hold lives on another host (remote-sm (remote)); cannot discard from here" "d on a remote home's hold is refused with the host reason"
assert_no_hold "d on a remote hold runs nothing"
frame_h=$(render_hold "tab,tab,tab,tab,j,d") || fail "holds d landed: render exited non-zero"
assert_contains "$frame_h" "landed-hold: no captain hold to discard" "d on a finished hold in Recently Landed is refused: the task is done"
# The login: with the identity unknown the OS user signs the decision and the footer says so (falsify:
# fall back to `captain` or an empty login).
node -e '
  const fs = require("fs");
  const [src, dst] = process.argv.slice(1);
  const fx = JSON.parse(fs.readFileSync(src, "utf8"));
  fx.prs = { candidate_prs: [], identity: { login: null, source: "unknown", reason: "fixture" } };
  fs.writeFileSync(dst, JSON.stringify(fx));
' "$HOLD_FIX" "$SCRATCH/holds-noid.json"
rm -f "${HOLD_LOG:?}"
frame_h=$(FM_BOARD_TEST_HOLD_LOG="$HOLD_LOG" "$BOARD" --render-once --fixture "$SCRATCH/holds-noid.json" --no-herdr --keys "j,d,y") || fail "holds d no identity: render exited non-zero"
assert_file_contains "$HOLD_LOG" "decision=Discarded by $(id -un) from firstmate-tui on $TODAY: no action; closed as not wanted." "with the identity unknown the decision names the OS user"
assert_contains "$frame_h" "discarded main-hold as OS user $(id -un) (GitHub login unknown)" "with the identity unknown the footer says who signed"

# D: the date prompt, the default, typed dates, the refusals and the delegate's full reason (falsify:
# change DEFER_DEFAULT_DAYS, let checkDeferDate accept a bad or past date, pass the ledger's truncated
# reason, or drop the delegate record read).
frame_h=$(render_hold "j,D") || fail "holds D: render exited non-zero"
assert_row "$frame_h" "^ defer main-hold until \(YYYY-MM-DD\): $PLUS14  enter defers  esc cancels +\$" "D on a hold row puts the date prompt in the footer, prefilled with today plus 14 days"
assert_no_hold "D alone runs nothing"
frame_h=$(render_hold "j,D,enter") || fail "holds D,enter: render exited non-zero"
assert_hold_log "FM_HOME=$HOLD_HOME
cwd=$HOLD_HOME_REAL
argv=hold main-hold --reason Two quotes arrived; pick the vendor for the address API --until $PLUS14" "D,enter runs fm-captain-hold.sh hold once in the hold's home with the record's full reason and the default date"
assert_contains "$frame_h" "deferred main-hold until $PLUS14 · main-hold" "D,enter: the footer names the deferral and the command's output"
# A deferral leaves the frame the same way a discard does (falsify: drop dismissRow from holdDefer).
assert_contains "$frame_h" "Captain's Call (6)" "D,enter: the pane count drops by one in the same frame"
assert_no_row "$frame_h" '^│ hold +- +main-hold ' "D,enter: the deferred hold row is gone from Captain's Call at once"
assert_not_contains "$frame_h" "hidden" "D,enter: the dismissed row is not counted as hidden"
assert_no_row "$frame_h" '^│ dated +[^│]*main-hold ' "D,enter: the deferred hold is not yet a Charted Next row either; the refresh the deferral starts brings it there once the snapshot agrees (falsify: leave the dismissal off the Charted Next rows)"
tags_h=$(render_hold "j,D,enter" --tags) || fail "holds D,enter --tags: render exited non-zero"
assert_row "$tags_h" "${SEL}hold +${SEL_END}${SEL} +${SEL_END}${SEL}- +${SEL_END}${SEL} +${SEL_END}${SEL}bare-hold +${SEL_END}" "D,enter: the selection lands on the row that took the deferred one's place"
frame_h=$(render_hold "j,D,$CLEAR,$(spell 2027-01-15),enter") || fail "holds D typed: render exited non-zero"
assert_hold_log "FM_HOME=$HOLD_HOME
cwd=$HOLD_HOME_REAL
argv=hold main-hold --reason Two quotes arrived; pick the vendor for the address API --until 2027-01-15" "backspaces clear the default and typed digits and dashes make the date the command gets"
assert_contains "$frame_h" "deferred main-hold until 2027-01-15" "D typed: the footer names the typed date"
frame_h=$(render_hold "j,D,$CLEAR,$(spell 2026-13-40),enter") || fail "holds D bad date: render exited non-zero"
assert_no_hold "an impossible date runs nothing"
assert_contains "$frame_h" "2026-13-40: not a real date" "an impossible date is refused by name"
assert_row "$frame_h" '^ defer main-hold until \(YYYY-MM-DD\): 2026-13-40  enter defers  esc cancels ' "an impossible date keeps the prompt open with the value to fix"
frame_h=$(render_hold "j,D,$CLEAR,$(spell "$YESTERDAY"),enter") || fail "holds D yesterday: render exited non-zero"
assert_no_hold "yesterday runs nothing"
assert_contains "$frame_h" "$YESTERDAY: not after today ($TODAY)" "a date not after today is refused"
frame_h=$(render_hold "j,D,$CLEAR,2,0,2,enter") || fail "holds D short: render exited non-zero"
assert_no_hold "a partial date runs nothing"
assert_contains "$frame_h" "202: not a YYYY-MM-DD date" "a partial date is refused by shape"
frame_h=$(render_hold "j,D,escape") || fail "holds D,escape: render exited non-zero"
assert_no_hold "D,escape runs nothing"
assert_contains "$frame_h" "cancelled; main-hold is unchanged" "D,escape: the footer says cancelled"
frame_h=$(FAKE_HOLD_FAIL=1 render_hold "j,D,enter") || fail "holds D fail: render exited non-zero"
assert_contains "$frame_h" "fm-captain-hold: task main-hold is not held for the captain" "a refused defer shows the command's stderr verbatim"
assert_not_contains "$frame_h" "deferred" "a refused defer is not reported as done"
assert_contains "$frame_h" "Captain's Call (7)" "a refused defer leaves the pane count as it was"
assert_row "$frame_h" '^│ hold +- +main-hold ' "a refused defer leaves the row on the board"
frame_h=$(render_hold "j,j,j,j,j,j,D") || fail "holds D review: render exited non-zero"
assert_contains "$frame_h" "ship-review: no captain hold to defer" "D on a review row is refused with a notice"
assert_no_hold "D on a review row runs nothing"
# A dated hold in Charted Next takes D too: the same prompt, the same command with the record's reason
# (falsify: drop mainCard from chartedRow's fields).
frame_h=$(render_hold "tab,tab,tab,D") || fail "holds D charted: render exited non-zero"
assert_row "$frame_h" "^ defer held-worker until \(YYYY-MM-DD\): $PLUS14  enter defers  esc cancels +\$" "D on a Charted Next hold row puts the same date prompt in the footer"
assert_no_hold "D on a Charted Next row alone runs nothing"
frame_h=$(render_hold "j,j,j,D,enter") || fail "holds D delegate: render exited non-zero"
assert_hold_log "snapshot FM_HOME=$HOLD_DELEGATE
FM_HOME=$HOLD_DELEGATE
cwd=$HOLD_DELEGATE_REAL
argv=hold delegate-hold --reason The full delegate reason, longer than the ledger keeps: approve the warehouse index before the nightly loader is scheduled --until $PLUS14" "D on a delegate hold reads the full reason from that home's snapshot first, then runs the command there with it"
assert_contains "$frame_h" "deferred delegate-hold until $PLUS14" "D delegate: the footer names the deferral"
frame_h=$(FAKE_SNAPSHOT_FAIL=1 render_hold "j,j,j,D") || fail "holds D delegate fail: render exited non-zero"
assert_hold_log "snapshot FM_HOME=$HOLD_DELEGATE" "D on a delegate hold whose snapshot fails runs no hold command"
assert_contains "$frame_h" "delegate-hold: the full hold reason is not readable (exit 1: fm-fleet-snapshot: jq not found); defer it from delegate itself" "D delegate fail: the defer is refused rather than passing the ledger's cut reason"
assert_not_contains "$frame_h" "defer delegate-hold until" "D delegate fail: no prompt opens"

# The refresh a success starts, against the live stand-in HOLD_LIVE: the hold log reads the first
# snapshot (the render's facts), then the answer call, then a second snapshot, the refresh the discard
# started, all in one render. The refresh's snapshot still lists main-hold as live, so the dismissal
# stays and the row stays gone (falsify: clear the dismissed set on every refresh, or forget the refresh
# after a success). The decision line names whatever login this host resolves, so it is left out of the
# comparison.
hold_log_sans_decision() { grep -v '^decision=' "$HOLD_LOG" 2>/dev/null || echo '<absent>'; }
frame_h=$(render_hold_live "" "j,d,y") || fail "holds live d,y: render exited non-zero"
if [ "$(hold_log_sans_decision)" = "snapshot FM_HOME=$HOLD_LIVE
FM_HOME=$HOLD_LIVE
cwd=$HOLD_LIVE_REAL
argv=answer main-hold --decision-file $(grep -o -- '--decision-file .*' "$HOLD_LOG" 2>/dev/null | cut -d' ' -f2)
snapshot FM_HOME=$HOLD_LIVE" ]; then pass; else fail "holds live d,y: the answer call is not followed by the refresh's snapshot; the log is '$(hold_log_sans_decision | tr '\n' '|')'"; fi
assert_contains "$frame_h" "discarded main-hold" "holds live d,y: the footer keeps the discard notice through the refresh"
assert_contains "$frame_h" "Captain's Call (3)" "holds live d,y: the pane count stays one less after a refresh whose snapshot still lists the hold"
assert_no_row "$frame_h" '^│ hold +- +main-hold ' "holds live d,y: a stale snapshot does not bring the discarded row back"
assert_contains "$frame_h" "Recently Landed (3)" "holds live d,y: Recently Landed is as the snapshot has it (two completions and the scout-x report)"
# The same with a refresh whose snapshot has firstmate's answer (main-hold done, completion answered): the
# entry is cleared, so the Recently Landed row that task now has, which carries the same card, is drawn (falsify:
# keep an entry for a task the snapshot no longer lists as live, and Recently Landed stays at 3).
frame_h=$(render_hold_live "$HOLD_LIVE/snapshot-answered.json" "j,d,y") || fail "holds live d,y answered: render exited non-zero"
assert_contains "$frame_h" "Captain's Call (3)" "holds live answered: the hold is out of Captain's Call"
assert_no_row "$frame_h" '^│ hold +- +main-hold ' "holds live answered: no hold row"
assert_contains "$frame_h" "Recently Landed (4)" "holds live answered: Recently Landed gains the answered item"
assert_row "$frame_h" '^│ answered +09-21 +main-hold +Pick the vendor for the address API ' "holds live answered: the dismissal is cleared, so the task's Recently Landed row is drawn"
# A refusal in a live render refreshes nothing: one snapshot, the refused call, no second snapshot
# (falsify: refresh on any exit status).
frame_h=$(FAKE_HOLD_FAIL=1 render_hold_live "" "j,d,y") || fail "holds live d fail: render exited non-zero"
assert_count "$(cat "$HOLD_LOG")" "snapshot FM_HOME=" 1 "holds live d fail: a refused command starts no refresh"
assert_row "$frame_h" '^│ hold +- +main-hold ' "holds live d fail: the row stays"
# r after a dismissal takes the same path: a stale snapshot keeps the row out, an answered one clears the
# entry (falsify: prune only in the hold's own refresh).
frame_h=$(render_hold_live "$HOLD_LIVE/snapshot-answered.json" "j,d,y,r") || fail "holds live d,y,r: render exited non-zero"
assert_count "$(cat "$HOLD_LOG")" "snapshot FM_HOME=" 3 "holds live d,y,r: the start, the discard's refresh and r each ran the snapshot"
assert_contains "$frame_h" "Recently Landed (4)" "holds live d,y,r: the answered item is in Recently Landed after r"

# The pure pieces, straight from lib/card.mjs (falsify: change any of them).
pure_h=$(node --input-type=module -e "
  import { checkDeferDate, discardDecision, plusDays, promptKeyAction } from '$ROOT/bin/firstmate-tui/lib/card.mjs';
  console.log(plusDays('2026-12-25', 14));
  console.log(checkDeferDate('2026-02-29', '2026-01-01'));
  console.log(checkDeferDate('2026-09-20', '2026-09-20'));
  console.log(checkDeferDate('2026-09-21', '2026-09-20'));
  console.log(discardDecision('zachsibert', '2026-09-19'));
  const p = { kind: 'defer', row: {}, id: 'x', reason: 'r', value: '2026-10-0' };
  console.log(promptKeyAction(p, 'x').type, promptKeyAction(p, 'q').type, promptKeyAction(p, '5').value, promptKeyAction(p, 'backspace').value, promptKeyAction(p, 'ctrl-c').type);
  console.log(promptKeyAction({ ...p, value: '2026-10-03' }, '5').type);
  console.log(promptKeyAction({ kind: 'discard', row: {}, id: 'x' }, 'Y').type, promptKeyAction({ kind: 'discard', row: {}, id: 'x' }, 'y').type);
")
assert_row "$pure_h" '^2027-01-08$' "plusDays crosses the year end"
assert_row "$pure_h" '^2026-02-29: not a real date$' "checkDeferDate refuses February 29 in a non-leap year"
assert_row "$pure_h" '^2026-09-20: not after today \(2026-09-20\)$' "checkDeferDate refuses today"
assert_row "$pure_h" '^null$' "checkDeferDate accepts tomorrow"
assert_row "$pure_h" '^Discarded by zachsibert from firstmate-tui on 2026-09-19: no action; closed as not wanted\.$' "discardDecision is the fixed sentence"
assert_row "$pure_h" '^none none 2026-10-05 2026-10- quit$' "the defer prompt ignores letters and q, takes a digit, backspaces, and ctrl-c quits"
assert_row "$pure_h" '^none$' "the defer prompt takes no more than ten characters"
assert_row "$pure_h" '^none discard$' "the discard prompt answers only a lower-case y"


# --------------------------------------------------------------- accept (a)
# tests/fixtures/accept.json over the same two scratch homes as holds.json (its placeholders are rewritten
# the same way). Captain's Call, in order: option-hold (kind captain, a question whose reason lists
# Options: a. b. c.), work-hold (kind ship, a held work item), nokind-hold (a record without a kind), the
# delegate's delegate-hold (kind task in that home's own record, read through its fake snapshot), the
# remote home's remote-hold, then the review row ship-review. HOLD_HOME gets a 45-line report under
# data/option-hold/ so that card is longer than the frame and scrolls. A one-shot render really runs the
# home's bin/fm-captain-hold.sh, which is why the homes are scratch.
ACCEPT_FIX="$SCRATCH/accept.json"
mkdir -p "$HOLD_HOME/data/option-hold"
for i in $(seq 1 45); do echo "# Quote line $i"; done > "$HOLD_HOME/data/option-hold/report.md"
# shellcheck disable=SC2016 # the template literal is node's, not the shell's
node -e '
  const fs = require("fs");
  const [fixture, out, mainHome, delegateHome] = process.argv.slice(1);
  fs.writeFileSync(out, fs.readFileSync(fixture, "utf8").split("/fixture/holds-main").join(mainHome).split("/fixture/holds-delegate").join(delegateHome));
' "$FIX/accept.json" "$ACCEPT_FIX" "$HOLD_HOME" "$HOLD_DELEGATE"
# render_accept <keys> [flags]: ACCEPT_FIX with every fake wired and every log reset first.
render_accept() {
  local keys=$1
  shift
  rm -f "${HOLD_LOG:?}" "${HOLD_CARD:?}" "${VIEWER_LOG:?}" "${OPENER_LOG:?}"
  FM_BOARD_TEST_HOLD_LOG="$HOLD_LOG" FM_BOARD_TEST_VIEWER_LOG="$VIEWER_LOG" FM_BOARD_TEST_VIEWER_COPY="$HOLD_CARD" FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" \
    "$BOARD" --render-once --fixture "$ACCEPT_FIX" --no-herdr --keys "$keys" --viewer-cmd "$FAKE_VIEWER" --opener-cmd "$FAKE_OPENER" "$@"
}
type_keys() { printf '%s' "$1" | sed 's/./&,/g; s/,$//; s/ /space/g'; } # a line as key tokens: "go ahead" -> g,o,space,a,h,e,a,d
decision_file() { grep -o -- '--decision-file [^ ]*' "$HOLD_LOG" 2>/dev/null | head -n 1 | cut -d' ' -f2; }

# The rows and the footer (falsify: drop a accept from boardHints, or 1-6 panes back into the card row's
# full hint, which then overflows 136 columns and the short hint draws instead).
frame_a=$(render "$ACCEPT_FIX") || fail "accept: render exited non-zero"
assert_contains "$frame_a" "Captain's Call (6)" "accept: three main holds, the delegate's and the remote home's holds, and the review row"
assert_row "$frame_a" '^│ hold +- +option-hold +Choose the address API vendor · Two quotes arrived\. Options: a\. Vendor North' "accept: the question's row leads"
assert_row "$frame_a" '^│ hold +- +work-hold +Cut over the nightly loader · Approve the cutover plan' "accept: the held work item's row"
assert_row "$frame_a" '^│ hold +- +nokind-hold +Retire the legacy importer' "accept: the row of the record without a kind"
assert_row "$frame_a" '^│ hold +- +delegate-hold ' "accept: the delegate's hold"
assert_row "$frame_a" '^│ hold +- +remote-hold ' "accept: the remote home's hold"
assert_row "$frame_a" '^│ review +#7 +ship-review ' "accept: the review row is last"
assert_row "$frame_a" '^ j/k move  tab pane  enter card  a accept  d discard  D defer  x hide  H hidden  r refresh  \. settings  \? help  q quit +$' "accept footer: a hold row names a accept beside d and D, and the full hint drops 1-6 panes to fit 160 columns"
assert_widths "$frame_a" 160 "accept frame lines are 160 columns"
assert_lines "$frame_a" 44 "accept frame is 44 lines"

# The prompt: the card in the frame with the options listed, the footer, nothing run (falsify: drop
# renderAccept from renderFrame, break parseOptions, or route a through the viewer).
frame_a=$(render_accept "a") || fail "accept a: render exited non-zero"
assert_row "$frame_a" '^ Accept option-hold: Choose the address API vendor  \(card lines 1-37 of [0-9]+; up/down and pageup/pagedown scroll\) +$' "a: the heading names the task, the title and the visible card lines"
assert_row "$frame_a" '^   a\. Vendor North, the cheaper quote +$' "a: option a is listed from the reason"
assert_row "$frame_a" '^   b\. Vendor South, with the EU region +$' "a: option b"
assert_row "$frame_a" '^   c\. Neither; keep the current API +$' "a: option c keeps its inner semicolon"
assert_row "$frame_a" '^ # Choose the address API vendor +$' "a: the card's title line is in the frame"
assert_row "$frame_a" '^ \| kind \| captain \| +$' "a: the card's facts table is in the frame"
assert_row "$frame_a" '^ ## Hold reason +$' "a: the reason section"
assert_row "$frame_a" '^ Two quotes arrived\. Options: a\. Vendor North, the cheaper quote b\. Vendor South, with the EU region c\. Neither; keep the current API +$' "a: the full reason verbatim"
assert_contains "$frame_a" "data/option-hold/report.md (45 lines; the first 40 follow)" "a: the report head is part of the card"
assert_not_contains "$frame_a" "Captain's Call (" "a: the grid gave way to the card"
assert_row "$frame_a" '^ accept option-hold: a-c picks an option, or type an answer  enter records  esc cancels +$' "a: the footer prompt names the letters and the keys"
assert_no_hold "a alone runs nothing"
assert_not_viewed "a runs no viewer: the card is drawn in the frame"
assert_widths "$frame_a" 160 "a: the accept frame lines are 160 columns"
assert_lines "$frame_a" 44 "a: the accept frame is 44 lines"
# Scrolling the card (falsify: drop accept-scroll, or the clamp in renderAccept).
frame_a=$(render_accept "a,pagedown") || fail "accept a,pagedown: render exited non-zero"
assert_row "$frame_a" '^ Accept option-hold: Choose the address API vendor  \(card lines 11-47 of ' "a,pagedown: the card scrolls ten lines"
assert_no_row "$frame_a" '^ # Choose the address API vendor +$' "a,pagedown: the card's title line scrolled off"
assert_row "$frame_a" '^   a\. Vendor North, the cheaper quote +$' "a,pagedown: the options stay in view above the card"
frame_a=$(render_accept "a,pagedown,up") || fail "accept a,pagedown,up: render exited non-zero"
assert_row "$frame_a" '^ Accept option-hold: Choose the address API vendor  \(card lines 10-46 of ' "a,pagedown,up: up scrolls one line back"
frame_a=$(render_accept "a,up") || fail "accept a,up: render exited non-zero"
assert_row "$frame_a" '^ Accept option-hold: Choose the address API vendor  \(card lines 1-37 of ' "a,up: the top stays the top"
# Picking (falsify: let accept-edit run while picked, or drop the unpick from backspace).
frame_a=$(render_accept "a,b") || fail "accept a,b: render exited non-zero"
assert_row "$frame_a" '^ accept option-hold: option b \(Vendor South, with the EU region\)  enter records  backspace unpicks  esc cancels +$' "a,b: a lower-case option letter picks that option"
tags_a=$(render_accept "a,b" --tags) || fail "accept a,b --tags: render exited non-zero"
assert_row "$tags_a" "${SEL}   b\\. Vendor South, with the EU region${SEL_END}" "a,b: the picked option is drawn as the selection"
assert_no_row "$tags_a" "${SEL}   a\\. " "a,b: the other options are not"
assert_no_hold "a,b runs nothing yet"
frame_a=$(render_accept "a,b,x") || fail "accept a,b,x: render exited non-zero"
assert_row "$frame_a" '^ accept option-hold: option b \(' "a,b,x: a printable key does not type over a pick"
assert_not_contains "$frame_a" "hidden option-hold" "a,b,x: x hid nothing"
frame_a=$(render_accept "a,b,backspace") || fail "accept a,b,backspace: render exited non-zero"
assert_row "$frame_a" '^ accept option-hold: a-c picks an option, or type an answer  enter records  esc cancels +$' "a,b,backspace: backspace unpicks"
frame_a=$(render_accept "a,b,backspace,c") || fail "accept a,b,backspace,c: render exited non-zero"
assert_row "$frame_a" '^ accept option-hold: option c \(Neither; keep the current API\)' "a,b,backspace,c: another letter picks again"
# Recording a pick: the fixed decision text with the letter and the option's words, no --release for a
# record of kind captain, the row gone at once (falsify: release every answer, drop the option text, or
# drop dismissRow from holdAnswer).
frame_a=$(render_accept "a,b,enter") || fail "accept a,b,enter: render exited non-zero"
assert_hold_log "FM_HOME=$HOLD_HOME
cwd=$HOLD_HOME_REAL
argv=answer option-hold --decision-file $(decision_file)
decision=Accepted by captain from firstmate-tui on $TODAY: option b Vendor South, with the EU region" "a,b,enter runs fm-captain-hold.sh answer once in the hold's home with the option's letter and text, and no --release for a record of kind captain"
assert_row "$(cat "$HOLD_LOG")" '^argv=answer option-hold --decision-file /.*/firstmate-tui-[^/]+/decision\.txt$' "a,b,enter: the decision file lives in a firstmate-tui temp directory"
if [ -e "$(decision_file)" ]; then fail "a,b,enter: the decision file is still there after the command exited"; else pass; fi
assert_contains "$frame_a" "option-hold: answer recorded; closed · answered: option-hold" "a,b,enter: the footer says the answer is recorded and the question closed, then the command's first line"
assert_not_contains "$frame_a" "firstmate dispatches" "a,b,enter: a closed question is not reported as dispatched"
assert_not_contains "$frame_a" "Accept option-hold" "a,b,enter: the card view is gone"
assert_contains "$frame_a" "Captain's Call (5)" "a,b,enter: the pane count drops by one in the same frame"
assert_no_row "$frame_a" '^│ hold +- +option-hold ' "a,b,enter: the answered row is gone from Captain's Call at once"
assert_not_contains "$frame_a" "(hidden)" "a,b,enter: the dismissed row is not drawn hidden"
tags_a=$(render_accept "a,b,enter" --tags) || fail "accept a,b,enter --tags: render exited non-zero"
assert_row "$tags_a" "${SEL}hold +${SEL_END}${SEL} +${SEL_END}${SEL}- +${SEL_END}${SEL} +${SEL_END}${SEL}work-hold +${SEL_END}" "a,b,enter: the selection lands on work-hold, the row that took the answered one's place"
# A typed answer on a held work item: --release (falsify: close every answer).
frame_a=$(render_accept "j,a") || fail "accept j,a: render exited non-zero"
assert_row "$frame_a" '^ Accept work-hold: Cut over the nightly loader' "j,a: the heading names the work item"
assert_row "$(render_accept "j,a" --rows 60)" '^ Accept work-hold: Cut over the nightly loader +$' "j,a at 60 rows: a card shorter than the frame has no line range"
assert_no_row "$frame_a" '^   a\. ' "j,a: a reason without Options: lists no options"
assert_row "$frame_a" '^ accept work-hold: type an answer  enter records  esc cancels +$' "j,a: the footer asks for a typed answer"
assert_row "$frame_a" '^ \| kind \| ship \| +$' "j,a: the work item's kind is on the card"
frame_a=$(render_accept "j,a,$(type_keys 'go ahead')") || fail "accept j,a typed: render exited non-zero"
assert_row "$frame_a" '^ accept work-hold: go ahead  enter records  esc cancels +$' "j,a typed: printable keys and the space bar type into the answer"
assert_no_hold "typing runs nothing"
frame_a=$(render_accept "j,a,$(type_keys 'go ahead'),enter") || fail "accept j,a typed enter: render exited non-zero"
assert_hold_log "FM_HOME=$HOLD_HOME
cwd=$HOLD_HOME_REAL
argv=answer work-hold --decision-file $(decision_file) --release
decision=Accepted by captain from firstmate-tui on $TODAY: go ahead" "a typed answer on a record of kind ship runs answer with --release: a work item resumes"
assert_contains "$frame_a" "work-hold: answer recorded; firstmate dispatches · answered: work-hold" "typed enter: the footer says firstmate dispatches, never that work started"
assert_not_contains "$frame_a" "answer recorded; closed" "typed enter: a released work item is not reported as closed"
assert_contains "$frame_a" "Captain's Call (5)" "typed enter: the row leaves at once"
assert_no_row "$frame_a" '^│ hold +- +work-hold ' "typed enter: the work item's row is gone"
assert_row "$frame_a" '^│ hold +- +option-hold ' "typed enter: the other holds stay"
# Typing on a reason with options: any key but a lower-case option letter starts the line, and option
# letters then type; the line is trimmed (falsify: pick on every option letter, or skip the trim).
frame_a=$(render_accept "a,$(type_keys 'So b'),enter") || fail "accept typed over options: render exited non-zero"
assert_file_contains "$HOLD_LOG" "decision=Accepted by captain from firstmate-tui on $TODAY: So b" "a capital letter starts a typed answer on a reason with options, and option letters then type"
assert_no_row "$(cat "$HOLD_LOG")" 'release' "a typed answer on the question still closes it"
frame_a=$(render_accept "a,S,o,backspace,backspace,b") || fail "accept backspace to empty: render exited non-zero"
assert_row "$frame_a" '^ accept option-hold: option b \(' "backspaces back to an empty answer let a letter pick again"
frame_a=$(render_accept "j,a,space,$(type_keys ok),space,enter") || fail "accept trimmed: render exited non-zero"
assert_file_contains "$HOLD_LOG" "decision=Accepted by captain from firstmate-tui on $TODAY: ok" "the typed line is trimmed"
# The refusals: an empty answer, spaces alone and the reserved word keep the prompt open and run
# nothing (falsify: drop checkAcceptAnswer).
frame_a=$(render_accept "a,enter") || fail "accept a,enter: render exited non-zero"
assert_no_hold "enter on an empty answer runs nothing"
assert_contains "$frame_a" "option-hold: an empty answer is refused; pick an option or type one" "an empty answer is refused by name"
assert_row "$frame_a" '^ accept option-hold: a-c picks an option' "an empty answer keeps the prompt open"
frame_a=$(render_accept "j,a,space,space,enter") || fail "accept spaces: render exited non-zero"
assert_no_hold "spaces alone run nothing"
assert_contains "$frame_a" "work-hold: an empty answer is refused" "spaces alone are an empty answer"
frame_a=$(render_accept "j,a,$(type_keys reconcile),enter" --cols 200) || fail "accept reconcile: render exited non-zero"
assert_no_hold "reconcile runs nothing"
assert_contains "$frame_a" 'work-hold: "reconcile" is reserved by fm-captain-hold.sh (it means re-check reality); type another answer' "the reserved word is refused by name"
assert_row "$frame_a" '^ accept work-hold: reconcile  enter records  esc cancels' "the reserved word keeps the prompt open with the value to change"
frame_a=$(render_accept "j,a,$(type_keys 'reconcile the ledger'),enter") || fail "accept reconcile phrase: render exited non-zero"
assert_file_contains "$HOLD_LOG" "decision=Accepted by captain from firstmate-tui on $TODAY: reconcile the ledger" "only the exact word is reserved"
# esc cancels, with or without a pick; a key that is a board key elsewhere types here (falsify: drop
# the prompt branch from handleKey).
frame_a=$(render_accept "a,escape") || fail "accept a,escape: render exited non-zero"
assert_no_hold "a,escape runs nothing"
assert_contains "$frame_a" "cancelled; option-hold is unchanged" "a,escape: the footer says cancelled"
assert_contains "$frame_a" "Captain's Call (6)" "a,escape: the grid is back with every row"
assert_not_contains "$frame_a" "Accept option-hold" "a,escape: the card view is gone"
frame_a=$(render_accept "a,b,escape") || fail "accept a,b,escape: render exited non-zero"
assert_no_hold "a,b,escape runs nothing"
assert_contains "$frame_a" "cancelled; option-hold is unchanged" "a,b,escape: a pick is cancelled too"
frame_a=$(render_accept "a,x,escape") || fail "accept a,x,escape: render exited non-zero"
assert_contains "$frame_a" "Captain's Call (6)" "a,x,escape: x typed into the answer and hid nothing"
assert_not_contains "$frame_a" "hidden option-hold" "a,x,escape: no hide notice"
# The rows a refuses: a record without a kind (never guessed), the review row (the board does not
# merge), a remote home's hold, and rows without a hold (falsify: default acceptRelease to true, or
# give the review row a hold).
frame_a=$(render_accept "j,j,a") || fail "accept nokind: render exited non-zero"
assert_no_hold "a on a record without a kind runs nothing"
assert_contains "$frame_a" "nokind-hold: the backlog record carries no kind, so the board cannot tell a question from work; answer it with fm-captain-hold.sh in main" "a on a record without a kind is refused by name"
assert_contains "$frame_a" "Captain's Call (6)" "a on a record without a kind opens no prompt"
frame_a=$(render_accept "j,j,j,j,j,a") || fail "accept review: render exited non-zero"
assert_no_hold "a on the review row runs nothing"
assert_not_opened "a on the review row opens nothing"
assert_contains "$frame_a" "ship-review: accepting a pull request means merging it, which the board does not do; enter opens it" "a on a review row says the board does not merge"
frame_a=$(render_accept "j,j,j,j,j,enter") || fail "accept review enter: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/7" "enter on the same review row still opens its PR"
frame_a=$(render_accept "j,j,j,j,a") || fail "accept remote: render exited non-zero"
assert_no_hold "a on a remote hold runs nothing"
assert_contains "$frame_a" "remote-hold: hold lives on another host (remote-sm (remote)); cannot accept from here" "a on a remote home's hold is refused with the host reason"
frame_h=$(render_hold "k,a") || fail "accept decision row: render exited non-zero"
assert_contains "$frame_h" "decide-task: no captain hold to accept" "a on a decision row whose task has no hold is refused with the no-hold notice"
assert_no_hold "a on a decision row runs nothing"
frame_h=$(render_hold "tab,tab,tab,tab,j,a") || fail "accept landed: render exited non-zero"
assert_contains "$frame_h" "landed-hold: no captain hold to accept" "a on a finished hold in Recently Landed is refused: the task is done"
frame_h=$(render_hold "tab,tab,tab,a") || fail "accept charted: render exited non-zero"
assert_row "$frame_h" '^ Accept held-worker: Move the cache to the new vendor' "a on a dated hold in Charted Next opens the same prompt: a hold row is a hold row, whatever the pane"
# A delegate hold: the home's own record is read first (the ledger keeps the reason cut and the kind
# is that record's), the answer runs in that home, and a failed read refuses (falsify: answer against
# the ledger's copy).
frame_a=$(render_accept "j,j,j,a") || fail "accept delegate: render exited non-zero"
assert_hold_log "snapshot FM_HOME=$HOLD_DELEGATE" "a on a delegate hold reads that home's own record first and runs no command"
assert_row "$frame_a" '^ Accept delegate-hold: Approve the warehouse index' "a delegate: the prompt opens over the home's record"
assert_row "$frame_a" '^ The full delegate reason, longer than the ledger keeps: approve the warehouse index before the nightly loader is scheduled +$' "a delegate: the card carries the full reason from the home"
assert_not_contains "$frame_a" "Ledger copy of the reason" "a delegate: the ledger's cut reason is not shown"
assert_row "$frame_a" '^ \| kind \| task \| +$' "a delegate: the kind comes from the home's record"
frame_a=$(render_accept "j,j,j,a,$(type_keys approved),enter") || fail "accept delegate enter: render exited non-zero"
assert_hold_log "snapshot FM_HOME=$HOLD_DELEGATE
FM_HOME=$HOLD_DELEGATE
cwd=$HOLD_DELEGATE_REAL
argv=answer delegate-hold --decision-file $(decision_file) --release
decision=Accepted by captain from firstmate-tui on $TODAY: approved" "a delegate hold of kind task is a work item: answered with --release in its own home"
assert_contains "$frame_a" "delegate-hold: answer recorded; firstmate dispatches" "a delegate: the footer says firstmate dispatches"
assert_contains "$frame_a" "Captain's Call (5)" "a delegate: the row leaves at once"
frame_a=$(FAKE_SNAPSHOT_FAIL=1 render_accept "j,j,j,a") || fail "accept delegate fail: render exited non-zero"
assert_hold_log "snapshot FM_HOME=$HOLD_DELEGATE" "a delegate whose snapshot fails runs no command"
assert_contains "$frame_a" "delegate-hold: the full hold reason is not readable (exit 1: fm-fleet-snapshot: jq not found); accept it from delegate itself" "a delegate fail: refused rather than answering against the ledger's cut reason"
assert_not_contains "$frame_a" "Accept delegate-hold" "a delegate fail: no prompt opens"
# A refusal from the command: its stderr in red, the row untouched (falsify: dismiss before the exit
# status is known).
frame_a=$(FAKE_HOLD_FAIL=1 render_accept "a,b,enter") || fail "accept fail: render exited non-zero"
assert_contains "$frame_a" "fm-captain-hold: task option-hold is not held for the captain; hold it first or name the right task" "a refused answer shows the command's stderr verbatim"
assert_not_contains "$frame_a" "answer recorded" "a refused answer is not reported as recorded"
assert_file_contains "$HOLD_LOG" "argv=answer option-hold --decision-file" "the refused command did run once"
assert_contains "$frame_a" "Captain's Call (6)" "a refused answer leaves the pane count as it was"
assert_row "$frame_a" '^│ hold +- +option-hold ' "a refused answer leaves the row"
tags_a=$(FAKE_HOLD_FAIL=1 render_accept "a,b,enter" --tags) || fail "accept fail --tags: render exited non-zero"
assert_row "$tags_a" '\{red-fg\}[^{]*fm-captain-hold: task option-hold is not held for the captain' "the refusal is red"
# The identity unknown: the OS user signs and the footer says so (holds-noid.json, main-hold of kind
# task) (falsify: fall back to `captain`).
rm -f "${HOLD_LOG:?}"
frame_h=$(FM_BOARD_TEST_HOLD_LOG="$HOLD_LOG" "$BOARD" --render-once --fixture "$SCRATCH/holds-noid.json" --no-herdr --keys "j,a,$(type_keys ok),enter") || fail "accept no identity: render exited non-zero"
assert_file_contains "$HOLD_LOG" "decision=Accepted by $(id -un) from firstmate-tui on $TODAY: ok" "with the identity unknown the accept names the OS user"
assert_row "$(cat "$HOLD_LOG")" '^argv=answer main-hold --decision-file .* --release$' "main-hold, kind task, is a work item: released"
assert_contains "$frame_h" "main-hold: answer recorded; firstmate dispatches (signed as OS user $(id -un), GitHub login unknown)" "with the identity unknown the footer says who signed"
# The refresh a success starts, against the live stand-in, as after d (falsify: forget the refresh).
frame_h=$(render_hold_live "" "j,a,$(type_keys ok),enter") || fail "accept live: render exited non-zero"
if [ "$(hold_log_sans_decision)" = "snapshot FM_HOME=$HOLD_LIVE
FM_HOME=$HOLD_LIVE
cwd=$HOLD_LIVE_REAL
argv=answer main-hold --decision-file $(decision_file) --release
snapshot FM_HOME=$HOLD_LIVE" ]; then pass; else fail "accept live: the answer call is not followed by the refresh's snapshot; the log is '$(hold_log_sans_decision | tr '\n' '|')'"; fi
assert_contains "$frame_h" "main-hold: answer recorded; firstmate dispatches" "accept live: the footer keeps the notice through the refresh"
assert_contains "$frame_h" "Captain's Call (3)" "accept live: the row stays gone after a refresh whose snapshot still lists the hold"
# The help and the standard footer name a (falsify: drop the a line from HELP_LINES or a accept from
# FOOTER_KEYS).
frame_a=$(render_accept "?") || fail "accept ?: render exited non-zero"
assert_contains "$frame_a" "a            accept the selected hold: pick an option letter or type a line; fm-captain-hold.sh answer" "help overlay documents a"
assert_contains "$frame_a" "Its three writes, a, d and D," "help overlay counts three writes"
frame_a=$(render_accept "tab") || fail "accept tab: render exited non-zero"
assert_row "$frame_a" '^ j/k move  tab pane  enter open/focus/view  f search  a accept  x hide  H hidden  1-6 panes  r refresh  \. settings  \? help  q quit +$' "the standard footer names a accept on a row without a card"
# The pure pieces, straight from lib/card.mjs (falsify: change any of them).
pure_a=$(node --input-type=module -e "
  import { acceptArgs, acceptDecision, acceptProblem, acceptRelease, checkAcceptAnswer, parseOptions, promptKeyAction } from '$ROOT/bin/firstmate-tui/lib/card.mjs';
  const j = (x) => JSON.stringify(x);
  console.log(j(parseOptions('Pick one. Options: a. keep it; b) drop it, C. wait')));
  console.log(j(parseOptions('no options here, e.g. a. thing')));
  console.log(j(parseOptions('Options: b. starts at b c. then c')));
  console.log(j(parseOptions('OPTIONS: a. first e.g. something b. second')));
  console.log(acceptDecision('zachsibert', '2026-09-19', { option: { letter: 'b', text: 'drop it' } }));
  console.log(acceptDecision('zachsibert', '2026-09-19', { text: 'go ahead' }));
  console.log(j(acceptArgs('x', '/tmp/d', true)), j(acceptArgs('x', '/tmp/d', false)));
  console.log(acceptRelease({ kind: 'captain' }), acceptRelease({ kind: 'ship' }), acceptRelease({ kind: 'task' }));
  console.log(acceptProblem({ name: 'x', hold: { homeId: 'main' } }, { kind: '  ' }));
  console.log(checkAcceptAnswer({ text: '' }), '|', checkAcceptAnswer({ text: 'reconcile' }), '|', checkAcceptAnswer({ option: { letter: 'a', text: '' } }));
  const p = { kind: 'accept', row: {}, id: 'x', options: [{ letter: 'a', text: 'A' }, { letter: 'b', text: 'B' }], picked: null, value: '' };
  console.log(promptKeyAction(p, 'b').type, promptKeyAction(p, 'B').type, promptKeyAction(p, 'c').type, promptKeyAction(p, 'ctrl-c').type, promptKeyAction(p, 'escape').type, promptKeyAction(p, 'down').by);
  console.log(promptKeyAction({ ...p, picked: 'a' }, 'b').type, promptKeyAction({ ...p, picked: 'a' }, 'backspace').letter, promptKeyAction({ ...p, value: 'x' }, 'a').value);
")
assert_row "$pure_a" '^\[\{"letter":"a","text":"keep it"\},\{"letter":"b","text":"drop it"\},\{"letter":"c","text":"wait"\}\]$' "parseOptions takes a. b) and C. markers, drops a trailing ; or , and lower-cases the letters"
assert_count "$pure_a" '[]' 2 "a reason without Options:, and a list not starting at a, give no options"
assert_row "$pure_a" '^\[\{"letter":"a","text":"first e.g. something"\},\{"letter":"b","text":"second"\}\]$' "an e.g. inside an option is not a marker, and OPTIONS: matches in any case"
assert_row "$pure_a" '^Accepted by zachsibert from firstmate-tui on 2026-09-19: option b drop it$' "acceptDecision for a pick"
assert_row "$pure_a" '^Accepted by zachsibert from firstmate-tui on 2026-09-19: go ahead$' "acceptDecision for a typed line"
assert_row "$pure_a" '^\["answer","x","--decision-file","/tmp/d","--release"\] \["answer","x","--decision-file","/tmp/d"\]$' "acceptArgs adds --release only when asked"
assert_row "$pure_a" '^false true true$' "acceptRelease: captain closes, any other kind releases"
assert_row "$pure_a" '^x: the backlog record carries no kind' "acceptProblem refuses a blank kind"
assert_row "$pure_a" '^an empty answer is refused; pick an option or type one \| "reconcile" is reserved by fm-captain-hold.sh \(it means re-check reality\); type another answer \| null$' "checkAcceptAnswer: empty and reconcile refused, a pick accepted"
assert_row "$pure_a" '^accept-pick accept-edit accept-edit quit prompt-cancel 1$' "the accept prompt: a lower-case option letter picks, a capital or another letter types, ctrl-c quits, esc cancels, down scrolls"
assert_row "$pure_a" '^none null xa$' "while picked a letter is ignored and backspace unpicks; while typing an option letter types"


# --------------------------------------------------------- placement rules
# The four fleet panes follow the bearings digest's placement rules, one check per row type of the
# README's Using the board section. relayed-hold.json is the duplicate-hold shape the 0.6.x board drew
# twice: the delegate home holds etl-cutover for the captain and the parent channel relayed the same
# hold into the delegate's task record as captain-hold-etl-cutover-1; a second relay,
# captain-hold-orphan-call-1, names a task the ledger does not carry (falsify: compare the relayed key
# against the task id as before 0.7.0, drop relayedDecisionRows, or list decisions under ledgerEntry).
frame_rh=$(render relayed-hold.json) || fail "relayed-hold: render exited non-zero"
assert_contains "$frame_rh" "Captain's Call (2)" "relayed-hold: the delegate's hold and the orphan relay, one row each"
assert_row "$frame_rh" '^│ hold +- +etl-cutover +Cut over the nightly ETL on Friday\? · Two windows fit +acme-corp/widgets +delegate-a +1d │$' "relayed-hold: the delegate's hold comes from its ledger, labelled with its home"
assert_count "$frame_rh" "etl-cutover" 1 "relayed-hold: the hold the parent channel relayed is one row on the whole board"
assert_not_contains "$frame_rh" "captain-hold-etl" "relayed-hold: the relayed key is not drawn while the ledger carries the task"
assert_row "$frame_rh" '^│ decide +captain-hold-or[^ ]* +delegate-a +captain hold orphan-call: Rotate the ETL signing key\? +acme-corp/widgets +delegate-a +15m │$' "relayed-hold: a relay naming a task the ledger does not carry draws once, as the fallback, labelled with the delegate's home"
assert_contains "$frame_rh" "Underway (2)" "relayed-hold: the main worker and the delegate's one worker"
assert_row "$frame_rh" '^│ working +working +etl-loader +Write the ETL loader · writing the loader +acme-corp/widgets +delegate-a +3h │$' "relayed-hold: the delegate's one worker draws directly, its title first, HOME naming the home"
assert_no_row "$frame_rh" '▸ delegate-a' "relayed-hold: no group row over one worker"
assert_not_contains "$(pane_lines "$frame_rh" 2)" "hold" "relayed-hold: no hold row in Underway"
assert_contains "$frame_rh" "Charted Next (0)" "relayed-hold: nothing queued, no warning"
# With the ledger unreadable the relays are the only record of the home's calls, so both draw, and
# the home is a Charted Next warning (falsify: drop the unreadable branch from relayedDecisionRows'
# ledgerHoldsTask, or the unreadable warning from warningRows).
frame_rh=$(render "$(variant relayed-hold.json relayed-unreadable '{"ledgers": [{"id": "delegate-a", "home": "/fixture/homes/delegate-a", "remote": false, "cached": false, "summary": null, "error": "no ledger"}]}')") || fail "relayed-hold unreadable: render exited non-zero"
assert_contains "$frame_rh" "Captain's Call (2)" "relayed-hold unreadable: both relayed calls draw"
assert_row "$frame_rh" '^│ decide +captain-hold-etl[^ ]* +delegate-a +captain hold etl-cutover: Cut over the nightly ETL on Friday\? ' "relayed-hold unreadable: the relayed hold draws from the task record when its ledger cannot be read"
assert_contains "$frame_rh" "Underway (1)" "relayed-hold unreadable: no worker rows from a home without a ledger"
assert_row "$frame_rh" '^│ warning +- +delegate-a +structured state unreadable: no ledger +- +delegate-a +- │$' "relayed-hold unreadable: the home is a Charted Next warning"
assert_contains "$frame_rh" "Charted Next (0, 1 warning)" "relayed-hold unreadable: one warning, not counted"

# charted.json (its _comment names every row): the Charted Next rules, one row type each, warnings
# first and left out of the count, items newest filed first with undated items last, a captain hold in
# exactly one pane (falsify: drop a bucket from chartedState or chartedWhy, let chartedItem take a live
# or a worked held item, sort by record order, count the warnings, or warn on a live or done endpoint).
frame_ch=$(render charted.json) || fail "charted: render exited non-zero"
charted_ch=$(pane_lines "$frame_ch" 5)
assert_contains "$frame_ch" "Charted Next (9, 6 warnings)" "charted: nine items and six warnings, the warnings left out of the count"
assert_row "$frame_ch" '^│ STATE +WHY +ID +WHAT +REPO +HOME +FILED │$' "charted: the pane's columns"
assert_row "$frame_ch" '^│ warning +- +main inventory +main in-flight backlog item has no child metadata: orphan-item +- +main +- │$' "charted: the invalid main inventory is a warning"
assert_row "$frame_ch" '^│ warning +- +child-gone +endpoint default:w2B:p2 is gone \(exists: false\) +- +delegate-a +- │$' "charted: an unknown endpoint whose pane is gone is a warning"
assert_row "$frame_ch" '^│ warning +- +child-lost +child current state unavailable \(endpoint default:w2C:p2, run-step\) +- +delegate-a +- │$' "charted: an unknown endpoint under a home with no home-level warning is a warning of its own"
assert_row "$frame_ch" '^│ warning +- +delegate-b +in-flight backlog item has terminal child state: old-child=done +- +delegate-b +- │$' "charted: an invalid ledger is one home-level warning; its done endpoint draws nothing"
assert_row "$frame_ch" '^│ warning +- +delegate-c +structured state unreadable: no ledger +- +delegate-c +- │$' "charted: a home with no ledger is a warning"
assert_row "$frame_ch" '^│ warning +- +delegate-d +child current state unavailable: ghost-child +- +delegate-d +- │$' "charted: a home the canonical snapshot reads unknown is a warning carrying its reason"
assert_no_row "$charted_ch" '^│ warning +- +ghost-child ' "charted: the unknown child of a home with a home-level warning draws no row of its own"
assert_no_row "$frame_ch" '^│ [a-z]+ +[^│]*  old-child +[A-Za-z]' "charted: a done endpoint is neither a warning nor a worker row"
assert_row "$frame_ch" '^│ queued +- +del-queued +Index the warehouse table +acme-corp/widgets +delegate-a +09-16 │$' "charted: a delegate's queued item, FILED its since date"
assert_row "$frame_ch" '^│ blocked +by queue-plain \+1 +queue-blocked +Ship the export report · needs the export button first +example-org/example-repo +main +09-15 │$' "charted: a queued item with two unresolved blockers reads blocked, WHY the first blocker plus the count"
assert_row "$frame_ch" '^│ queued +- +queue-plain +Add the export button +example-org/example-repo +main +09-14 │$' "charted: a plain queued item"
assert_row "$frame_ch" '^│ blocked +by hold-dated +hold-blocked +Announce the new pricing · After the pricing call +acme-corp/widgets +main +09-12 │$' "charted: a captain hold in the blocked bucket, WHY its blocker, WHAT its title and reason"
assert_row "$frame_ch" '^│ queued +- +held-external +Vendor cutover · waiting on the vendor +example-org/example-repo +main +09-11 │$' "charted: an in-flight item held from outside whose worker is not working is a gate"
assert_row "$frame_ch" '^│ dated +until 10-01 +hold-dated +Revisit the pricing page · Revisit after launch +acme-corp/widgets +main +09-10 │$' "charted: a dated hold, WHY its until date"
assert_row "$frame_ch" '^│ aged +held 16d +del-aged +Retire the old importer · Waiting on the captain since August +acme-corp/widgets +delegate-a +08-31 │$' "charted: a delegate's aged hold from its queued entry, its age from the ledger's decision"
assert_row "$frame_ch" '^│ aged +held 20d +hold-aged +Keep or drop the legacy importer · No answer yet +acme-corp/widgets +main +08-27 │$' "charted: an aged hold, WHY its age in days"
assert_row "$frame_ch" '^│ queued +- +undated-queue +Tidy the release notes +example-org/example-repo +main +- │$' "charted: an item with no filed date reads - and sorts last"
assert_before "$frame_ch" '^│ warning +- +delegate-d' '^│ queued +- +del-queued' "charted: warnings come before every item"
assert_before "$frame_ch" '^│ queued +- +del-queued' '^│ blocked +by queue-plain' "charted: newest filed first (1)"
assert_before "$frame_ch" '^│ blocked +by queue-plain' '^│ queued +- +queue-plain' "charted: newest filed first (2)"
assert_before "$frame_ch" '^│ queued +- +queue-plain' '^│ blocked +by hold-dated' "charted: newest filed first (3)"
assert_before "$frame_ch" '^│ dated +until 10-01' '^│ aged +held 16d' "charted: newest filed first (4)"
assert_before "$frame_ch" '^│ aged +held 20d' '^│ queued +- +undated-queue' "charted: an undated item sorts after every dated one"
assert_not_contains "$charted_ch" "hold-live" "charted: a live hold is never here"
assert_row "$frame_ch" '^│ hold +- +hold-live +Pick the vendor for the address API · Two quotes in the report +acme-corp/widgets +main +3d │$' "charted: the live hold is Captain's Call's row"
assert_count "$frame_ch" "hold-live" 1 "charted: a captain hold sits in exactly one pane"
assert_not_contains "$charted_ch" "worked-held" "charted: a held item whose worker is working is not a gate"
assert_row "$frame_ch" '^│ working +working +worked-held +Vendor cutover, part two · harness busy \(claude-hook\) +example-org/example-repo +main +1m │$' "charted: the worked held item is an Underway row, unmarked since the hold is not the captain's"
assert_no_row "$frame_ch" '^│ paused +[^│]*held-external' "charted: an item held from outside with nothing working has no Underway row (falsify: skip only captain holds in mainTaskRow)"
assert_row "$frame_ch" '^│ working +working +child-work +Write the ETL loader · writing the loader +acme-corp/widgets +delegate-a +3h │$' "charted: the delegate's one worker draws directly"
assert_contains "$frame_ch" "Underway (2)" "charted: two workers"
assert_not_contains "$charted_ch" "done-item" "charted: a done item is never a gate"
assert_row "$frame_ch" '^│ merged +09-15 +done-item +Add the ETL index · https://github.com/example-org/example-repo/pull/12 +example-org/example-repo +main +1d │$' "charted: the done item is Recently Landed's row"
assert_widths "$frame_ch" 160 "charted frame lines are 160 columns"
assert_lines "$frame_ch" 60 "charted frame is 60 lines"
# Charted Next rows act: a warning row has nothing to open and takes neither d nor D; a queued row has
# its card; a held row has its card and both hold actions, and D opens the same date prompt as in
# Captain's Call. The two PR panes are empty here, so two tabs reach the pane (falsify: drop the
# charted case from keyAction, or mainCard from chartedRow's fields).
frame_ch=$(render charted.json --keys "tab,tab") || fail "charted footer warning: render exited non-zero"
assert_row "$frame_ch" '^ j/k move  tab pane  enter open/focus/view  f search  a accept ' "charted: a warning row keeps the standard hints"
frame_ch=$(render charted.json --keys "tab,tab,enter") || fail "charted enter warning: render exited non-zero"
assert_contains "$frame_ch" "main inventory: a warning row; nothing to open" "charted: enter on a warning is a plain notice"
frame_ch=$(render charted.json --keys "tab,tab,d") || fail "charted d warning: render exited non-zero"
assert_contains "$frame_ch" "main inventory: no captain hold to discard" "charted: d on a warning is refused"
frame_ch=$(render charted.json --keys "tab,tab,j,j,j,j,j,j") || fail "charted footer queued: render exited non-zero"
assert_row "$frame_ch" '^ j/k move  tab pane  enter card  x hide ' "charted: a queued row carries its card and nothing to act on"
frame_ch=$(render charted.json --keys "tab,tab,j,j,j,j,j,j,j,j,j") || fail "charted footer held: render exited non-zero"
assert_row "$frame_ch" '^ j/k move  tab pane  enter card  a accept  d discard  D defer  x hide ' "charted: a held row carries its card and both hold actions"
frame_ch=$(render charted.json --keys "tab,tab,j,j,j,j,j,j,j,j,j,D") || fail "charted D held: render exited non-zero"
assert_row "$frame_ch" "^ defer hold-blocked until \(YYYY-MM-DD\): $PLUS14  enter defers  esc cancels +\$" "charted: D on a held row opens the date prompt"
frame_ch=$(render_view charted.json "tab,tab,j,j,j,j,j,j,j,j,j,enter") || fail "charted card: render exited non-zero"
assert_contains "$frame_ch" "viewed the hold card of hold-blocked (viewer-cmd)" "charted: enter on a held row shows its card"

# -------------------------------------------------------------------- hide
vs="$SCRATCH/view-state.json"
rm -f "$vs"
# x hides the selected row and persists its key (falsify: drop the filter in applyHidden, or the date from the
# Recently Landed hideKey).
# Recently Landed is four tabs from Captain's Call (Underway, My PRs, then Charted Next; the empty
# Teammates' PRs is skipped) and its second row is etl-index.
frame_h=$(render populated.json --view-state "$vs" --keys "tab,tab,tab,tab,j,x") || fail "hide: render exited non-zero"
assert_contains "$frame_h" "Recently Landed (4, 1 hidden)" "x on the second Recently Landed row: header counts it hidden"
assert_no_row "$frame_h" '^│ merged +09-15 +etl-index ' "the hidden row is out of view"
assert_contains "$frame_h" "hidden etl-index · H shows hidden rows, X unhides this pane" "x leaves a notice"
assert_file_contains "$vs" '"landed:delegate-a:etl-index:2026-09-15"' "the key is pane:home:id:completion date, so a re-landed item reappears"
assert_file_contains "$vs" '"schema": "fm-board-view-state.v1"' "the file names its schema"
# Restart: the file is loaded again (falsify: drop loadViewState from driveOnce).
frame_h=$(render populated.json --view-state "$vs") || fail "hide reload: render exited non-zero"
assert_contains "$frame_h" "Recently Landed (4, 1 hidden)" "after a restart the row stays hidden"
assert_no_row "$frame_h" '^│ merged +09-15 +etl-index ' "after a restart the row is still out of view"
# H shows hidden rows greyed with a marker (falsify: drop showHidden from applyHidden, or the grey style).
frame_h=$(render populated.json --view-state "$vs" --keys "H") || fail "hide H: render exited non-zero"
tags_h=$(render populated.json --view-state "$vs" --keys "H" --tags) || fail "hide H --tags: render exited non-zero"
assert_contains "$frame_h" "Recently Landed (5, 1 hidden shown)" "H: header says the hidden row is shown"
assert_row "$frame_h" '^│ merged +09-15 +etl-index +\(hidden\) Add the ETL index ' "H: the hidden row is listed with a (hidden) marker"
assert_row "$tags_h" '\{grey-fg\}\(hidden\) Add the ETL index' "H: the hidden row is grey"
assert_contains "$frame_h" "showing hidden rows (greyed); H hides them again" "H leaves a notice"
# x on a shown hidden row unhides it (falsify: drop the unhide action in keyAction).
frame_h=$(render populated.json --view-state "$vs" --keys "H,tab,tab,tab,tab,j,x") || fail "hide toggle: render exited non-zero"
assert_contains "$frame_h" "unhidden etl-index" "x on the shown hidden row unhides it"
assert_contains "$frame_h" "Recently Landed (5)" "after unhiding the header shows the plain count"
assert_file_not_contains "$vs" "etl-index" "unhiding removes the key from the file"
# X clears the pane (falsify: drop the prefix filter in unhide-pane).
frame_h=$(render populated.json --view-state "$vs" --keys "tab,tab,tab,tab,j,x,j,x,X") || fail "hide X: render exited non-zero"
assert_contains "$frame_h" "unhidden 2 rows in Recently Landed" "X unhides every hidden row of the pane"
assert_contains "$frame_h" "Recently Landed (5)" "X: all five Recently Landed rows are back"
assert_file_contains "$vs" '"hidden": []' "X empties the hidden list in the file"
# A hidden group takes its children with it (falsify: drop the parent lookup in applyHidden).
frame_h=$(render populated.json --rows 48 --keys "tab,j,j,l,x") || fail "hide group: render exited non-zero"
assert_contains "$frame_h" "Underway (5, 3 hidden)" "hiding the expanded delegate-a group hides its two children too"
assert_not_contains "$frame_h" "↳ child-one" "hidden group: children are out of view"
# A fixture render without --view-state loads and saves nothing (falsify: drop the fixture guard in viewStateFor).
fake_home_dir="$SCRATCH/home"
mkdir -p "$fake_home_dir"
frame_h=$(HOME="$fake_home_dir" XDG_CONFIG_HOME='' render populated.json --keys "tab,tab,tab,tab,j,x") || fail "hide no file: render exited non-zero"
assert_contains "$frame_h" "Recently Landed (4, 1 hidden)" "without --view-state hiding still works for the frame"
if [ -e "$fake_home_dir/.config/fm-board/view-state.json" ]; then fail "a fixture render without --view-state wrote the default view-state file"; else pass; fi
# A view-state path inside FM_HOME is refused (falsify: drop insideHome from resolveViewStatePath).
frame_h=$(XDG_CONFIG_HOME="$SCRATCH/xdg" render populated.json --view-state /fixture/firstmate/state/view-state.json) || fail "hide FM_HOME guard: render exited non-zero"
assert_contains "$frame_h" "refusing --view-state inside FM_HOME (/fixture/firstmate/state/view-state.json)" "a view-state path inside FM_HOME is refused with a notice"
frame_h=$(XDG_CONFIG_HOME="$SCRATCH/xdg" render populated.json --view-state /fixture/firstmate/state/view-state.json --keys "tab,tab,tab,tab,x") || fail "hide FM_HOME fallback: render exited non-zero"
if [ -f "$SCRATCH/xdg/fm-board/view-state.json" ]; then pass; else fail "the refused path falls back to \$XDG_CONFIG_HOME/fm-board/view-state.json"; fi
if [ -e /fixture/firstmate/state/view-state.json ]; then fail "the refused path was written"; else pass; fi

# ------------------------------------------------------------ pane toggles
rm -f "$vs"
# 6 hides Recently Landed; its rows go to the other panes; the title lists it (falsify: drop the visible list from
# paneHeights, or the hidden skip in renderPanes).
frame_p=$(render populated.json --view-state "$vs" --keys "6") || fail "panes 6: render exited non-zero"
assert_contains "$frame_p" "· panes hidden: 6" "title lists the hidden pane number"
assert_not_contains "$frame_p" "Recently Landed (" "the hidden pane draws nothing"
assert_count "$frame_p" "┌─" 5 "five pane frames remain"
assert_lines "$frame_p" 44 "one pane hidden: the frame is still 44 lines"
assert_widths "$frame_p" 160 "one pane hidden: lines are 160 columns"
assert_contains "$frame_p" "pane hidden: Recently Landed · 6 or 0 shows it again" "6 leaves a notice"
assert_file_contains "$vs" '"landed"' "the hidden pane is persisted"
frame_p=$(render populated.json --view-state "$vs") || fail "panes reload: render exited non-zero"
assert_count "$frame_p" "┌─" 5 "after a restart the pane stays hidden (falsify: drop hidden_panes from loadViewState)"
# 4 hides Teammates' PRs, the fourth pane (falsify: drop the '4' case from keyAction, or move toreview in PANES).
frame_p=$(render populated.json --view-state "$vs" --keys "4") || fail "panes 4: render exited non-zero"
assert_contains "$frame_p" "· panes hidden: 4,6" "4 hides Teammates' PRs and the title lists it"
assert_not_contains "$frame_p" "Teammates' PRs (" "the hidden Teammates' PRs pane draws nothing"
assert_contains "$frame_p" "pane hidden: Teammates' PRs · 4 or 0 shows it again" "4 leaves a notice naming its key"
assert_file_contains "$vs" '"toreview"' "the hidden Teammates' PRs pane is persisted under its id, never its key"
frame_p=$(render populated.json --view-state "$vs" --keys "4") || fail "panes 4 again: render exited non-zero"
assert_contains "$frame_p" "┌─ [4] Teammates' PRs (0)" "4 again brings Teammates' PRs back"
assert_contains "$frame_p" "pane shown: Teammates' PRs" "4 again leaves the shown notice"
assert_file_not_contains "$vs" '"toreview"' "the shown pane leaves the persisted list"
# 1 hides Captain's Call, the first pane, and 2 Underway, the second (falsify: put inflight back first in PANES).
frame_p=$(render populated.json --view-state "$vs" --keys "1") || fail "panes 1: render exited non-zero"
assert_not_contains "$frame_p" "Captain's Call (" "1 hides Captain's Call"
assert_contains "$frame_p" "pane hidden: Captain's Call · 1 or 0 shows it again" "1 leaves a notice naming its key"
assert_contains "$frame_p" "┌─ [2] Underway (6)" "with Captain's Call hidden Underway is still drawn under key 2"
frame_p=$(render populated.json --view-state "$vs" --keys "1,2") || fail "panes 1 back, 2: render exited non-zero"
assert_contains "$frame_p" "┌─ [1] Captain's Call (6)" "1 again brings Captain's Call back at the top"
assert_not_contains "$frame_p" "Underway (" "2 hides Underway"
assert_contains "$frame_p" "pane hidden: Underway · 2 or 0 shows it again" "2 leaves a notice naming its key"
assert_file_contains "$vs" '"inflight"' "the hidden Underway pane is persisted under its id"
frame_p=$(render populated.json --view-state "$vs" --keys "2") || fail "panes 2 again: render exited non-zero"
assert_contains "$frame_p" "┌─ [2] Underway (6)" "2 again brings Underway back"
frame_p=$(render populated.json --view-state "$vs" --keys "2,3,4,5") || fail "panes 2,3,4,5: render exited non-zero"
assert_contains "$frame_p" "· panes hidden: 2,3,4,5,6" "five panes hidden: the title lists all five"
assert_count "$frame_p" "┌─" 1 "five panes hidden: one frame"
assert_contains "$frame_p" "Captain's Call (6)" "five panes hidden: Captain's Call remains"
assert_lines "$frame_p" 44 "five panes hidden: still 44 lines"
assert_widths "$frame_p" 160 "five panes hidden: lines are 160 columns"
assert_row "$frame_p" '^│ hold +- +decide-vendor ' "five panes hidden: Captain's Call rows render in the freed space"
# The last pane goes too: with every pane hidden the grid gives way to the landing page, a centered key
# list between the title line and the footer (falsify: bring back a shown <= 1 guard in toggle-pane, or
# drop the landing branch from renderFrame).
frame_p=$(render populated.json --view-state "$vs" --keys "1") || fail "panes last: render exited non-zero"
assert_count "$frame_p" "┌─" 0 "all panes hidden: no pane frame is drawn"
assert_not_contains "$frame_p" "Captain's Call (" "all panes hidden: no pane header"
assert_not_contains "$frame_p" "Underway (" "all panes hidden: no pane header for the last one hidden"
assert_row "$frame_p" '^ +all panes hidden +$' "landing page heading"
assert_row "$frame_p" '^ firstmate-tui · /fixture/firstmate · 3 homes · all panes hidden ' "landing page: the title line leads with firstmate-tui (falsify: put fm-board back in titleLine)"
assert_row "$frame_p" '^ +1  Captain.s Call +$' "landing page: 1 brings Captain's Call back"
assert_row "$frame_p" '^ +2  Underway +$' "landing page: 2 brings Underway back"
assert_row "$frame_p" '^ +3  My PRs +$' "landing page: 3 brings My PRs back"
assert_row "$frame_p" "^ +4  Teammates' PRs +\$" "landing page: 4 brings Teammates' PRs back (falsify: drop the fourth pane from landingEntries)"
assert_row "$frame_p" '^ +5  Charted Next +$' "landing page: 5 brings Charted Next back"
assert_row "$frame_p" '^ +6  Recently Landed +$' "landing page: 6 brings Recently Landed back"
assert_row "$frame_p" '^ +0  show all +$' "landing page: 0 shows all"
assert_row "$frame_p" '^ +r  refresh +$' "landing page: r"
assert_row "$frame_p" '^ +\.  settings +$' "landing page: . settings (falsify: drop the settings entry from landingEntries)"
assert_row "$frame_p" '^ +\?  help +$' "landing page: ?"
assert_row "$frame_p" '^ +q  quit +$' "landing page: q"
assert_before "$frame_p" '^ +all panes hidden +$' '^ +1  Captain.s Call +$' "landing page: heading first"
assert_before "$frame_p" '^ +1  Captain.s Call +$' '^ +2  Underway +$' "landing page: Underway after Captain's Call"
assert_before "$frame_p" '^ +3  My PRs +$' "^ +4  Teammates' PRs +\$" "landing page: Teammates' PRs after My PRs"
assert_before "$frame_p" "^ +4  Teammates' PRs +\$" '^ +5  Charted Next +$' "landing page: Charted Next after Teammates' PRs"
assert_before "$frame_p" '^ +6  Recently Landed +$' '^ +0  show all +$' "landing page: 0 after the six panes"
assert_before "$frame_p" '^ +0  show all +$' '^ +r  refresh +$' "landing page: r after 0"
assert_before "$frame_p" '^ +r  refresh +$' '^ +\.  settings +$' "landing page: . after r, the footer's order"
assert_before "$frame_p" '^ +\.  settings +$' '^ +\?  help +$' "landing page: ? after ."
assert_contains "$frame_p" "3 homes · all panes hidden " "all panes hidden: the title says so instead of listing six numbers (falsify: drop allHidden from titleLine)"
assert_not_contains "$frame_p" "panes hidden: 1,2,3,4,5,6" "all panes hidden: the title does not list the six numbers"
assert_contains "$frame_p" "pane hidden: Captain's Call · every pane hidden; 1-6 or 0 shows them" "hiding the last pane leaves a notice naming the way back"
assert_row "$frame_p" '^ j/k .* q quit +pane hidden' "the footer stays on the landing page"
assert_lines "$frame_p" 44 "landing page: the frame is still 44 lines"
assert_widths "$frame_p" 160 "landing page: lines are 160 columns"
for id in needs mine inflight charted landed toreview; do
  assert_file_contains "$vs" "\"$id\"" "all six pane ids are persisted ($id)"
done
assert_file_not_contains "$vs" '"findings"' "the retired Findings id is never written (falsify: keep findings in PANES)"
# A restart with an all-hidden file lands on the page again (falsify: drop hidden_panes from loadViewState,
# or make the landing depend on view.notice).
frame_p=$(render populated.json --view-state "$vs") || fail "panes landing reload: render exited non-zero"
assert_row "$frame_p" '^ +all panes hidden +$' "after a restart the landing page is shown"
assert_count "$frame_p" "┌─" 0 "after a restart no pane is drawn"
assert_not_contains "$frame_p" "pane hidden:" "after a restart there is no toggle notice"
# Keys on the landing page: 1-6 and 0 act as always; a key that would move or act on a row nobody can see
# only repeats the reminder and runs nothing; an unbound key such as o stays silent (falsify: drop
# LANDING_KEYS or ROW_KEYS from keyAction, or the !pane.hidden term on the row lookup).
frame_o=$(render_open populated.json "1,2,3,4,5,6,enter") || fail "landing enter: render exited non-zero"
assert_not_opened "enter on the landing page opens nothing"
assert_contains "$frame_o" "all panes hidden · 1-6 shows a pane, 0 shows all" "enter on the landing page only reminds"
frame_o=$(render_open populated.json "1,2,3,4,5,6,j,tab,enter") || fail "landing move+enter: render exited non-zero"
assert_not_opened "moving on the landing page then enter opens nothing"
frame_p=$(render populated.json --keys "1,2,3,4,5,6,o") || fail "landing o: render exited non-zero"
assert_not_contains "$frame_p" "all panes hidden · 1-6 shows a pane" "o on the landing page is the same silent no-op as elsewhere"
assert_row "$frame_p" '^ +all panes hidden +$' "o on the landing page leaves the page in place"
frame_p=$(render populated.json --view-state "$vs" --keys "x") || fail "landing x: render exited non-zero"
assert_contains "$frame_p" "all panes hidden · 1-6 shows a pane, 0 shows all" "x on the landing page only reminds"
assert_file_contains "$vs" '"hidden": []' "x on the landing page hides no row"
frame_p=$(render populated.json --view-state "$vs" --keys "?") || fail "landing ?: render exited non-zero"
assert_contains "$frame_p" "firstmate-tui keys" "? opens the help over the landing page"
frame_p=$(render populated.json --view-state "$vs" --keys "1") || fail "landing 1: render exited non-zero"
assert_count "$frame_p" "┌─" 1 "1 on the landing page brings Captain's Call back alone"
assert_contains "$frame_p" "┌─ [1] Captain's Call (6)" "the returned pane carries its badge"
assert_contains "$frame_p" "pane shown: Captain's Call" "1 on the landing page leaves the usual notice"
assert_contains "$frame_p" "· panes hidden: 2,3,4,5,6" "one pane back: the title lists the five still hidden"
assert_file_contains "$vs" '"hidden_panes": [' "the returned pane is persisted"
frame_p=$(render populated.json --view-state "$vs" --keys "4") || fail "landing then 4: render exited non-zero"
assert_count "$frame_p" "┌─" 2 "4 after the landing page brings Teammates' PRs back beside Captain's Call"
assert_contains "$frame_p" "┌─ [4] Teammates' PRs (0)" "Teammates' PRs carries its badge when it returns"
assert_before "$frame_p" "Captain's Call \(6\)" "Teammates' PRs \(0\)" "the returned pane draws below Captain's Call, in its screen position"
frame_p=$(render populated.json --view-state "$vs" --keys "0") || fail "panes 0: render exited non-zero"
assert_count "$frame_p" "┌─" 6 "0 shows every pane again"
assert_contains "$frame_p" "all panes shown" "0 leaves a notice"
assert_not_contains "$frame_p" "panes hidden" "0 clears the title note"
assert_file_contains "$vs" '"hidden_panes": []' "0 empties the persisted list"
# The same in one sitting and without a file: 1,2,3,4,5,6 lands, 0 restores (falsify: make the landing
# depend on the view-state file).
frame_p=$(render populated.json --keys "1,2,3,4,5,6") || fail "panes 1-6: render exited non-zero"
assert_row "$frame_p" '^ +all panes hidden +$' "1,2,3,4,5,6 in one sitting lands on the page"
assert_count "$frame_p" "┌─" 0 "1,2,3,4,5,6: nothing else is drawn"
frame_p=$(render populated.json --keys "1,2,3,4,5") || fail "panes 1-5: render exited non-zero"
assert_count "$frame_p" "┌─" 1 "1,2,3,4,5 alone leaves Recently Landed on screen: six panes must go before the landing page (falsify: land with five hidden)"
assert_contains "$frame_p" "┌─ [6] Recently Landed (5)" "1,2,3,4,5: the one pane left is Recently Landed"
frame_p=$(render populated.json --keys "1,2,3,4,5,6,0") || fail "panes 1-6,0: render exited non-zero"
assert_count "$frame_p" "┌─" 6 "0 after 1,2,3,4,5,6 restores all six"
assert_not_contains "$frame_p" "all panes hidden" "0 after 1,2,3,4,5,6 leaves the landing page"
# A hand-written all-hidden file is enough to land (falsify: require the ids in a particular order, or
# only honor a file the board wrote itself).
vs_all="$SCRATCH/view-state-all.json"
printf '{"schema":"fm-board-view-state.v1","hidden":[],"hidden_panes":["toreview","landed","charted","inflight","mine","needs"]}\n' > "$vs_all"
frame_p=$(render populated.json --view-state "$vs_all") || fail "panes hand-written all-hidden: render exited non-zero"
assert_row "$frame_p" '^ +all panes hidden +$' "a hand-written all-hidden view-state file renders the landing page"
assert_count "$frame_p" "┌─" 0 "hand-written all-hidden file: no pane drawn"
# A file from before 0.7.0 naming the retired Findings pane: its entries are dropped on read, so five
# hidden ids plus findings leave Charted Next on screen, and a hidden findings: row key hides nothing
# (falsify: drop DROPPED_PANES from loadViewState).
vs_findings="$SCRATCH/view-state-findings.json"
printf '{"schema":"fm-board-view-state.v1","hidden":["findings:main:scout-beta"],"hidden_panes":["toreview","landed","findings","inflight","mine","needs"],"scroll":{"findings":3}}\n' > "$vs_findings"
frame_p=$(render populated.json --view-state "$vs_findings") || fail "panes old findings id: render exited non-zero"
assert_count "$frame_p" "┌─" 1 "an old file's findings id is dropped: Charted Next stays on screen"
assert_contains "$frame_p" "┌─ [5] Charted Next (1)" "the pane left is Charted Next"
frame_p=$(render populated.json --view-state "$vs_findings" --keys "6") || fail "panes old findings row key: render exited non-zero"
assert_contains "$frame_p" "Recently Landed (5)" "an old findings: row key hides no Recently Landed row (its report lists once there)"
assert_file_not_contains "$vs_findings" 'findings' "the next save drops every findings entry"
# A file written by a board before 0.4.0 names the second pane review: it is read as mine, in the
# hidden panes, the hidden row keys and the dragged widths (falsify: drop RENAMED_PANES from
# loadViewState or sanitizeColumns).
vs_old="$SCRATCH/view-state-old.json"
printf '{"schema":"fm-board-view-state.v1","hidden":["review:main:api#8"],"hidden_panes":["review"],"columns":{"review":{"id":20}}}\n' > "$vs_old"
frame_p=$(render populated.json --view-state "$vs_old") || fail "panes old id: render exited non-zero"
assert_contains "$frame_p" "· panes hidden: 3" "an old file's hidden pane review hides My PRs"
frame_p=$(render populated.json --view-state "$vs_old" --keys "3") || fail "panes old id shown: render exited non-zero"
assert_contains "$frame_p" "My PRs (2, 1 hidden)" "an old file's review:... hidden row key hides the same My PRs row"
assert_row "$frame_p" '^│ CHECKS    STATUS     ID {20}TITLE ' "an old file's review column width applies to My PRs"
assert_file_contains "$vs_old" '"mine:main:api#8"' "the next save writes the row key under the new pane id"
assert_file_not_contains "$vs_old" 'review' "the next save drops the old pane id"
# A file written while Teammates' PRs was the sixth pane, under key 6, keeps its meaning now that the
# pane is fourth under key 4: hidden_panes, the hidden row key and the dragged width are all stored by
# the pane id toreview, which did not change, so the pane comes back hidden at its new position, 4
# shows it with its row still hidden and its ID column 20 wide, and the next save writes the same ids
# and never a key number (falsify: key hidden_panes or columns by pane index, or rename the id).
vs_moved="$SCRATCH/view-state-moved.json"
printf '{"schema":"fm-board-view-state.v1","hidden":["toreview:main:api#16"],"hidden_panes":["toreview"],"columns":{"toreview":{"id":20}},"updated":"2026-09-17T00:00:00.000Z"}\n' > "$vs_moved"
frame_p=$(render to-review.json --view-state "$vs_moved") || fail "panes moved id hidden: render exited non-zero"
assert_not_contains "$frame_p" "Teammates' PRs (" "a file from before the reorder hides Teammates' PRs at its new position"
assert_contains "$frame_p" "· panes hidden: 4" "the title lists the hidden pane under its new key"
assert_count "$frame_p" "┌─" 5 "five panes are drawn"
assert_before "$frame_p" "My PRs \(1\)" "Charted Next \([0-9]" "with Teammates' PRs hidden, Charted Next follows My PRs"
frame_p=$(render to-review.json --view-state "$vs_moved" --keys "4") || fail "panes moved id shown: render exited non-zero"
assert_contains "$frame_p" "┌─ [4] Teammates' PRs (6, 1 hidden) ─" "4 shows the pane at its new position with the old file's hidden row still hidden"
assert_before "$frame_p" "My PRs \(1\)" "Teammates' PRs \(6, 1 hidden\)" "the shown pane sits below My PRs"
assert_before "$frame_p" "Teammates' PRs \(6, 1 hidden\)" "Charted Next \([0-9]" "and above Charted Next"
assert_not_contains "$frame_p" "api#16" "the row hidden under the old key stays hidden"
assert_row "$frame_p" '^│ CHECKS +STATUS +ID {20}AUTHOR +TITLE ' "the old file's dragged ID width, 20, applies to the pane at its new position"
assert_file_contains "$vs_moved" '"toreview:main:api#16"' "the next save keeps the row key under the same pane id"
assert_file_contains "$vs_moved" '"toreview": {' "the next save keeps the column widths under the same pane id"
assert_file_contains "$vs_moved" '"id": 20' "and the width itself"
assert_file_contains "$vs_moved" '"hidden_panes": []' "the shown pane leaves hidden_panes"
frame_p=$(render to-review.json --view-state "$vs_moved" --keys "4") || fail "panes moved id hidden again: render exited non-zero"
if grep -Eq '^    "toreview"$' "$vs_moved"; then pass; else fail "hiding it again writes the pane id to hidden_panes"; fi
assert_file_not_contains "$vs_moved" '"4"' "and never its key number"
# The same for the pane ids that kept their place through the 0.7.0 retitle: a file written while In
# flight was the first pane under key 1 still names the id inflight, which is now Underway under key 2,
# so the file hides Underway at its new position, 2 shows it with its hidden row still hidden and its
# dragged ID width applied, and the next save writes the id inflight, never a key number; a file hiding
# needs hides Captain's Call, now the first pane under key 1 (falsify: key hidden_panes, hidden or
# columns by pane index, or rename the ids with the titles).
vs_first="$SCRATCH/view-state-first.json"
printf '{"schema":"fm-board-view-state.v1","hidden":["inflight:main:ship-alpha"],"hidden_panes":["inflight"],"columns":{"inflight":{"id":20}},"updated":"2026-09-19T00:00:00.000Z"}\n' > "$vs_first"
frame_p=$(render populated.json --view-state "$vs_first") || fail "panes inflight moved hidden: render exited non-zero"
assert_not_contains "$frame_p" "Underway (" "a file from before the retitle hides Underway at its new position"
assert_contains "$frame_p" "· panes hidden: 2" "the title lists Underway under its new key"
assert_row "$(printf '%s\n' "$frame_p" | sed -n 2p)" '^┌─ \[1\] Captain.s Call \(6\) ─' "with Underway hidden Captain's Call is the first pane drawn, under key 1"
frame_p=$(render populated.json --view-state "$vs_first" --keys "2") || fail "panes inflight moved shown: render exited non-zero"
assert_contains "$frame_p" "┌─ [2] Underway (5, 1 hidden) ─" "2 shows Underway under its new key with the old file's hidden row still hidden"
assert_before "$frame_p" "Captain's Call \(6\)" "Underway \(5, 1 hidden\)" "the shown pane draws below Captain's Call"
assert_no_row "$frame_p" '^│ working +working +ship-alpha ' "the row hidden under the old key stays hidden"
assert_row "$frame_p" '^│ STATE +HERDR +ID {20}WHAT ' "the old file's dragged ID width, 20, applies to Underway at its new position"
assert_file_contains "$vs_first" '"inflight:main:ship-alpha"' "the next save keeps the row key under the same pane id"
assert_file_contains "$vs_first" '"inflight": {' "the next save keeps the column width under the same pane id"
assert_file_contains "$vs_first" '"hidden_panes": []' "the shown pane leaves hidden_panes"
frame_p=$(render populated.json --view-state "$vs_first" --keys "2") || fail "panes inflight moved hidden again: render exited non-zero"
if grep -Eq '^    "inflight"$' "$vs_first"; then pass; else fail "hiding Underway again writes the pane id to hidden_panes"; fi
assert_file_not_contains "$vs_first" '"2"' "and never its key number"
vs_needs="$SCRATCH/view-state-needs.json"
printf '{"schema":"fm-board-view-state.v1","hidden":[],"hidden_panes":["needs"]}\n' > "$vs_needs"
frame_p=$(render populated.json --view-state "$vs_needs") || fail "panes needs moved hidden: render exited non-zero"
assert_not_contains "$frame_p" "Captain's Call (" "a file hiding needs hides Captain's Call at its new position"
assert_contains "$frame_p" "· panes hidden: 1" "the title lists Captain's Call under its new key, 1"
assert_row "$(printf '%s\n' "$frame_p" | sed -n 2p)" '^┌─ \[2\] Underway \(6\) ─' "with Captain's Call hidden Underway is the first pane drawn, still under key 2"
frame_p=$(render populated.json --view-state "$vs_needs" --keys "1") || fail "panes needs moved shown: render exited non-zero"
assert_contains "$frame_p" "┌─ [1] Captain's Call (6) ─" "1 shows Captain's Call again under its new key"
assert_before "$frame_p" "Captain's Call \(6\)" "Underway \(6\)" "and it sits above Underway"
# The landing page replaces the narrow list too (falsify: pick the layout mode before the all-hidden check).
frame_p=$(render narrow.json --keys "1,2,3,4,5,6") || fail "panes narrow landing: render exited non-zero"
assert_row "$frame_p" '^ +all panes hidden +$' "narrow: the landing page replaces the list"
assert_not_contains "$frame_p" "── [" "narrow: no section header on the landing page"
assert_not_contains "$frame_p" " STATE " "narrow: no column header on the landing page"
assert_widths "$frame_p" 70 "narrow landing page: lines are 70 columns"
assert_lines "$frame_p" 24 "narrow landing page: 24 lines"
# Hiding the selected pane moves the selection to the next shown pane (falsify: drop the shown() clamp in
# moveSelection): tab to Underway, 2 hides it, then enter opens the first My PRs PR.
frame_o=$(render_open populated.json "tab,2,enter") || fail "panes selection: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "after hiding the selected pane, enter acts on the next shown pane"
frame_p=$(render narrow.json --keys "6") || fail "panes narrow: render exited non-zero"
assert_not_contains "$frame_p" "[6] Recently Landed" "list mode: the hidden pane's section is gone (falsify: drop the hidden skip in flattenRows)"
assert_contains "$frame_p" "panes hidden: 6" "list mode: the title lists the hidden pane"
assert_widths "$frame_p" 70 "list mode with a hidden pane: lines are 70 columns"

# ---------------------------------------------------------- o is a no-op, F focuses
# o used to open the selected row's PR in any pane; enter does that now, so
# the key does nothing, not even a notice (falsify: give 'o' a case in keyAction).
frame_o=$(render_open populated.json "tab,o") || fail "keys o: render exited non-zero"
assert_not_opened "o on a My PRs row calls no opener"
frame_o=$(render populated.json --keys "o") || fail "keys o plain: render exited non-zero"
if [ "$frame_o" = "$frame" ]; then pass; else fail "o changed the frame: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_o") | head -n 5)"; fi
assert_not_contains "$frame_o" "no PR URL" "o leaves no PR notice"
assert_no_row "$frame" '^ j/k move .* o open' "footer offers no o key"
# f used to move the firstmate pane beside the board; the captain splits panes himself, so since 0.6.0
# the focus key focuses the selected row's herdr pane in any pane and never moves one, and since the
# search took f the focus is F, the same letter shifted (falsify: bring the pane move back, drop the F
# case from keyAction, or drop `any` from focusProblem). scout-beta, the default selection, has a pane:
# under --no-herdr the focus is refused with the herdr-off words, with the fixture's herdr overlay it is
# reported as it would run; a row without a pane is told so.
frame_f=$(render populated.json --keys "F") || fail "keys F: render exited non-zero"
assert_contains "$frame_f" "herdr is off (--no-herdr); cannot focus" "F on a Captain's Call row with a pane asks for the focus, refused under --no-herdr"
assert_not_contains "$frame_f" "firstmate pane" "F leaves no firstmate-pane notice"
frame_f=$(fake_herdr_env "$BOARD" --render-once --fixture "$FIX/populated.json" --keys "j,F") || fail "keys F herdr: render exited non-zero"
assert_contains "$frame_f" "would focus w1A:p1 (ship-alpha); --render-once never runs herdr agent focus" "F on a Captain's Call decision row focuses its worker's pane, the pane rule of enter skipped"
if [ -e "$HERDR_LOG" ]; then fail "a fixture render with herdr on called herdr: $(cat "$HERDR_LOG")"; else pass; fi
frame_f=$(render populated.json --keys "j,j,j,F") || fail "keys F no pane: render exited non-zero"
assert_contains "$frame_f" "decide-vendor: no herdr pane to focus" "F on a hold row, which has no pane, says so"
frame_f=$(fake_herdr_env "$BOARD" --render-once --fixture "$FIX/populated.json" --keys "tab,F") || fail "keys F underway herdr: render exited non-zero"
assert_contains "$frame_f" "would focus w1A:p1 (ship-alpha); --render-once never runs herdr agent focus" "F on an Underway worker focuses its pane too"
# f no longer focuses: on the same row it opens the search prompt and the frame is the results list
# (falsify: give f the focus case back).
frame_f=$(render populated.json --keys "f") || fail "keys f search: render exited non-zero"
assert_not_contains "$frame_f" "cannot focus" "f asks for no focus"
assert_row "$frame_f" '^ Search:  \([0-9]+ matches\) +$' "f opens the search prompt with an empty query"
if grep -Fq -- "-firstmate" "$ROOT/bin/firstmate-tui/herdr-plugin.toml"; then fail "herdr-plugin.toml still declares a firstmate pane action"; else pass; fi

# ------------------------------------------------------------------ search (f)
# f opens a search over every pane at once (lib/search.mjs, the results view in lib/render.mjs
# renderSearch, the prompt in lib/card.mjs). The matcher first, through its pure functions: a token
# is a subsequence of the text, and among matches a contiguous run beats letters scattered over word
# starts, a run at a word start beats one inside a word, a hit in the id-and-title head beats the same
# hit in a path, the tokens may come in any order, case never matters, a token that is no subsequence
# fails the row and an empty query matches everything at 0 (falsify: drop the CONTIGUOUS bonus, the
# wordStart bonus, the head bonus, the lower-casing, or the null return from tokenScore). The checks
# below read pane titles and ids from lib/layout.mjs PANES rather than spelling them, so a retitled
# or reordered pane moves nothing here.
pane_title() { # <pane id>: its title as PANES spells it
  node --input-type=module -e "import { PANES } from '$ROOT/bin/firstmate-tui/lib/layout.mjs'; process.stdout.write(PANES.find((p) => p.id === process.argv[1]).title);" "$1"
}
T_NEEDS=$(pane_title needs)
T_INFLIGHT=$(pane_title inflight)
T_CHARTED=$(pane_title charted)
T_LANDED=$(pane_title landed)
ALL_PANE_IDS=$(node --input-type=module -e "import { PANES } from '$ROOT/bin/firstmate-tui/lib/layout.mjs'; process.stdout.write(JSON.stringify(PANES.map((p) => p.id)));")
search_rules=$(node --input-type=module -e "
  import { matchScore, rankRows, searchTextOf } from '$ROOT/bin/firstmate-tui/lib/search.mjs';
  const gt = (a, b) => Number.isFinite(a) && Number.isFinite(b) && a > b;
  const out = {
    contiguous: gt(matchScore('gap', 'the-gap-x'), matchScore('gap', 'g-a-p')),
    midWordRun: gt(matchScore('gap', 'xxgapx'), matchScore('gap', 'g-a-p')),
    wordStart: gt(matchScore('gap', 'x-gap'), matchScore('gap', 'xxgapx')),
    head: gt(matchScore('gap', 'gap widgets/gap', { head: 3 }), matchScore('gap', 'zzz widgets/gap', { head: 3 })),
    anyOrder: matchScore('gap mdm', 'mdm-gap') === matchScore('mdm gap', 'mdm-gap') && matchScore('gap mdm', 'mdm-gap') > 0,
    caseless: matchScore('MDM Gap', 'x-mdm-gap') === matchScore('mdm gap', 'x-mdm-gap'),
    camel: matchScore('expired token', 'ExpiredToken') !== null,
    none: matchScore('zzz', 'mdm-gap') === null && matchScore('mdm zzz', 'mdm-gap') === null,
    empty: matchScore('', 'anything') === 0,
    text: JSON.stringify(searchTextOf({ id: 'x', name: 'x', text: 'T', repo: '-', home: 'main', reportPath: null, url: 'https://u' })) === JSON.stringify({ searchText: 'x T main https://u', searchHead: 3 }),
    rank: rankRows('b', [{ row: { id: 'a', text: 'zzb' } }, { row: { id: 'b', text: 'x' } }, { row: { id: 'c', text: 'zzz' } }]).map((e) => e.row.id).join(',') === 'b,a',
  };
  console.log(Object.entries(out).filter(([, v]) => v !== true).map(([k]) => k).join(' ') || 'ok');
")
if [ "$search_rules" = "ok" ]; then pass; else fail "search matcher rules broken: $search_rules"; fi
# The results view over search.json: f, then the letters and the space bar (the key list spells the
# space bar `space`) type the query; the header counts the matches and the list leads with the best,
# the PANE column first; "mdm gap" finds portal-mdm-gap-analysis, the delegate's live hold drawn in
# Captain's Call from its ledger, and "expired token" finds the ExpiredToken scout beside it; the
# footer is the prompt with the same count (falsify: drop the space mapping from lib/args.mjs
# keyName, or the head bonus that ranks the id's runs over the URLs' scattered letters).
frame_s=$(render search.json --keys "f,m,d,m,space,g,a,p") || fail "search mdm gap: render exited non-zero"
assert_row "$frame_s" '^ Search: mdm gap \([0-9]+ matches\) +$' "search: the header carries the query and the match count"
assert_row "$frame_s" '^ PANE +STATE +INFO +ID +WHAT +REPO +HOME +AGE$' "search: PANE leads the shared column header"
assert_row "$frame_s" "^ $T_NEEDS +hold +- +portal-mdm-gap-analysis " "search: 'mdm gap' ranks the delegate's held gap-analysis scout first (falsify: drop CONTIGUOUS or HEAD)"
assert_before "$frame_s" '^ Search: mdm gap' "^ $T_NEEDS +hold +- +portal-mdm-gap-analysis " "search: the best match is the first row under the header"
assert_row "$frame_s" '^ search: mdm gap  [0-9]+ matches  enter jumps  esc cancels' "search: the footer is the prompt with the count"
assert_not_contains "$frame_s" "┌─" "search: the results list replaces the grid"
tags_s=$(render search.json --keys "f,m,d,m,space,g,a,p" --tags) || fail "search mdm gap --tags: render exited non-zero"
assert_row "$tags_s" "${SEL}$T_NEEDS" "search: the cursor bar is on the first match (falsify: draw the list without the selected style)"
frame_s=$(render search.json --keys "f,e,x,p,i,r,e,d,space,t,o,k,e,n") || fail "search expired token: render exited non-zero"
assert_row "$frame_s" '^ Search: expired token \(1 match\) +$' "search: 'expired token' finds one row, and one reads match, not matches"
assert_row "$frame_s" "^ $T_NEEDS +hold +- +portal-ingest-expired" "search: the ExpiredToken scout is that row (its summary says ExpiredToken; the id says expired-token)"
# Enter jumps: the prompt closes, the grid is back and the row is selected in Captain's Call, so
# enter would show its card next (falsify: drop the rebuild before the row is found again, or leave
# view.row where it was).
frame_s=$(render search.json --keys "f,m,d,m,space,g,a,p,enter") || fail "search jump: render exited non-zero"
assert_not_contains "$frame_s" "Search:" "search jump: the prompt is closed"
assert_contains "$frame_s" "portal-mdm-gap-analysis in $T_NEEDS" "search jump: the notice names the row and its pane"
assert_row "$frame_s" '^ enter card  a accept  d discard  D defer  x hide  H  1-6 panes ' "search jump: the footer offers the row's card and hold actions, as on any selected card row (the short form: the notice takes the full hint's room)"
tags_s=$(render search.json --keys "f,m,d,m,space,g,a,p,enter" --tags) || fail "search jump --tags: render exited non-zero"
assert_row "$tags_s" "${SEL}hold.*${SEL}portal-mdm-gap-analysis" "search jump: the cursor bar is on the found row in its pane"
# The children of a collapsed Underway group are searched through the index built with every group
# open: "sync job" matches the delegate's child portal-owner-sync alone (its doing text), a row the
# grid shows only inside the collapsed delegate-a group, and the jump expands the group for it
# (falsify: drop the expandAll build of the index in buildModel, or the expanded.add from
# jumpToResult).
frame_g=$(render search.json) || fail "search grid: render exited non-zero"
assert_row "$frame_g" '^│ working +2 live +!▸ delegate-a +portal-owner-sync, portal-owner-audit ' "search grid: the delegate's two workers sit behind a collapsed group row"
assert_not_contains "$frame_g" "↳ portal-owner-sync" "search grid: the child row is not drawn"
frame_s=$(render search.json --keys "f,s,y,n,c,space,j,o,b") || fail "search sync job: render exited non-zero"
assert_row "$frame_s" '^ Search: sync job \(1 match\) +$' "search: the collapsed group's child is found by its doing text"
assert_row "$frame_s" "^ $T_INFLIGHT +working +working +↳ portal-owner-sync +Owner sync · writing the sync job " "search: the child row is listed as the expanded group would draw it"
frame_s=$(render search.json --keys "f,s,y,n,c,space,j,o,b,enter") || fail "search child jump: render exited non-zero"
assert_row "$frame_s" '^│ working +2 live +!▾ delegate-a ' "search child jump: the collapsed group is expanded"
assert_contains "$frame_s" "portal-owner-sync in $T_INFLIGHT · group expanded" "search child jump: the notice names the row, its pane and the expansion"
tags_s=$(render search.json --keys "f,s,y,n,c,space,j,o,b,enter" --tags) || fail "search child jump --tags: render exited non-zero"
assert_row "$tags_s" "${SEL}working.*${SEL}↳ portal-owner-sync" "search child jump: the cursor bar is on the child in its pane"
# A Charted Next row is searched like any other: "export report" finds the queued portal-export-report
# first (its title carries both words as runs) and the jump selects it there, where enter shows its
# card (falsify: leave the charted builder out of the index, or drop the card from chartedRow).
frame_s=$(render search.json --keys "f,e,x,p,o,r,t,space,r,e,p,o,r,t") || fail "search export report: render exited non-zero"
assert_row "$frame_s" "^ $T_CHARTED +queued +- +portal-export-report +Ship the export report " "search: the queued item ranks first for its title's words"
assert_before "$frame_s" '^ Search: export report' "^ $T_CHARTED +queued +- +portal-export-report " "search: the Charted Next row is the first match"
frame_s=$(render search.json --keys "f,e,x,p,o,r,t,space,r,e,p,o,r,t,enter") || fail "search charted jump: render exited non-zero"
assert_contains "$frame_s" "portal-export-report in $T_CHARTED" "search charted jump: the notice names the row and Charted Next"
assert_row "$frame_s" '^ j/k move  tab pane  enter card  x hide ' "search charted jump: the queued row's footer offers its card"
tags_s=$(render search.json --keys "f,e,x,p,o,r,t,space,r,e,p,o,r,t,enter" --tags) || fail "search charted jump --tags: render exited non-zero"
assert_row "$tags_s" "${SEL}queued.*${SEL}portal-export-report" "search charted jump: the queued row is selected in Charted Next"
# Esc closes with the selection untouched: the frame after tab, j, f, a query and esc is the frame
# after tab, j (falsify: move view.pane or view.row while the prompt is up, or leave a notice).
frame_a=$(render search.json --keys "tab,j") || fail "search esc base: render exited non-zero"
frame_b=$(render search.json --keys "tab,j,f,x,y,z,escape") || fail "search esc: render exited non-zero"
if [ "$frame_a" = "$frame_b" ]; then pass; else fail "esc did not restore the frame: $(diff <(printf '%s\n' "$frame_a") <(printf '%s\n' "$frame_b") | head -n 6)"; fi
# A query with no match says so and enter does nothing: the prompt stays up (falsify: jump on an
# empty result list, or close the prompt on enter regardless). q and j are typed, not obeyed.
frame_s=$(render search.json --keys "f,x,y,z,q,q,enter") || fail "search no match: render exited non-zero"
assert_row "$frame_s" '^ Search: xyzqq \(0 matches\) +$' "search: no match counts 0, and q types into the query"
assert_row "$frame_s" '^ no matches +$' "search: the list reads no matches"
assert_row "$frame_s" '^ search: xyzqq  0 matches  enter jumps  esc cancels' "search: enter on no match leaves the prompt up"
assert_row "$(render search.json --keys "f,j,k")" '^ Search: jk \(' "search: j and k type into the query (a query may carry them)"
# up/down move the cursor through the matches and enter jumps to the one under it: 'ship' lists
# ship-cache (Underway), ship-cache (My PRs), then the Charted Next item whose title starts with Ship,
# then the Recently Landed ship-NN rows; two downs land on the third and enter selects it in Charted
# Next (falsify: drop the search-move case, or read index 0 on jump).
frame_s=$(render search.json --keys "f,s,h,i,p,down,down") || fail "search move: render exited non-zero"
assert_row "$frame_s" "^ $T_INFLIGHT +working +working +ship-cache " "search move: the Underway worker leads the ship matches"
third=$(printf '%s\n' "$frame_s" | sed -n 6p | grep -oE 'portal-export-report|ship-[a-z0-9-]+' | head -n 1)
tags_s=$(render search.json --keys "f,s,h,i,p,down,down" --tags) || fail "search move --tags: render exited non-zero"
assert_row "$tags_s" "${SEL}$T_CHARTED.*${SEL}${third} " "search move: two downs put the bar on the third match, the Charted Next row ($third)"
assert_contains "$(render search.json --keys "f,s,h,i,p,down,down,enter")" "$third in $T_CHARTED" "search move: enter jumps to the match under the cursor, not the first"
# A row below a pane's fold is found and the jump scrolls the pane to it: ship-17 is Recently Landed's
# oldest merge, behind +8 more on the grid, and nowhere on it (falsify: search the drawn rows instead
# of the builders' full lists, or leave the scroll where it was).
assert_contains "$frame_g" "+8 more" "search grid: Recently Landed is capped"
assert_not_contains "$frame_g" "ship-17" "search grid: ship-17 is below the fold"
frame_s=$(render search.json --keys "f,s,h,i,p,-,1,7") || fail "search capped: render exited non-zero"
assert_row "$frame_s" '^ Search: ship-17 \(1 match\) +$' "search: the row below the fold is found"
assert_row "$frame_s" "^ $T_LANDED +merged +09-05 +ship-17 " "search: it is the Recently Landed row"
tags_s=$(render search.json --keys "f,s,h,i,p,-,1,7,enter" --tags) || fail "search capped jump --tags: render exited non-zero"
assert_row "$tags_s" "${SEL}merged.*${SEL}ship-17 " "search capped jump: ship-17 is selected in Recently Landed, the pane scrolled to it"
assert_contains "$tags_s" " above" "search capped jump: the pane's foot counts the rows scrolled above"
# A report folded into Recently Landed is a row like any other, below the fold too: archive-owner-scout,
# the oldest reported scout, is behind the foot and "archive owner" finds it; the jump scrolls the
# pane to it, where enter views the report (falsify: leave the reported rows out of landedRows'
# full list, or index the drawn rows).
assert_not_contains "$frame_g" "archive-owner-scout" "search grid: the oldest report is below the fold"
frame_s=$(render search.json --keys "f,a,r,c,h,i,v,e,space,o,w,n,e,r") || fail "search archive owner: render exited non-zero"
assert_row "$frame_s" "^ $T_LANDED +reported +08-22 +archive-owner-scout +Scout: who owns the archive bucket · data/archive-owner-scout" "search: the folded report row is found first, with its path"
frame_s=$(render search.json --keys "f,a,r,c,h,i,v,e,space,o,w,n,e,r,enter") || fail "search report jump: render exited non-zero"
assert_contains "$frame_s" "archive-owner-scout in $T_LANDED" "search report jump: the notice names the report row and Recently Landed"
assert_row "$frame_s" '^│ reported +08-22 +archive-owner-scout +Scout: who owns the archive bucket · data/archive-owner-scout/report.md ' "search report jump: the report row is on the grid, the pane scrolled to it"
assert_contains "$frame_s" "8 above" "search report jump: the pane's foot counts the rows scrolled above"
tags_s=$(render search.json --keys "f,a,r,c,h,i,v,e,space,o,w,n,e,r,enter" --tags) || fail "search report jump --tags: render exited non-zero"
assert_row "$tags_s" "${SEL}reported.*${SEL}archive-owner-scout" "search report jump: the report row is selected in Recently Landed"
# A hidden row is found, listed greyed and marked (hidden), and the jump turns H on for the session so
# the selection is visible, the notice saying so; the view-state file keeps the row hidden and never
# records the search (falsify: build the index with showHidden false, or unhide the row on the jump).
# The hidden row is Recently Landed's legacy-import-scout, whose `legacy import path` words no other
# row has as runs, so it ranks first.
vs_s="$SCRATCH/search-view-state.json"
printf '{"schema":"fm-board-view-state.v1","hidden":["landed:main:legacy-import-scout:2026-09-12"]}\n' > "$vs_s"
q_hidden="f,l,e,g,a,c,y,space,i,m,p,o,r,t,space,p,a,t,h"
frame_s=$(render search.json --view-state "$vs_s" --keys "$q_hidden") || fail "search hidden: render exited non-zero"
assert_row "$frame_s" "^ $T_LANDED +reported +09-12 +legacy-import-scout +\(hidden\) Scout: legacy import path" "search hidden: the hidden Recently Landed row is listed first and marked"
tags_s=$(render search.json --view-state "$vs_s" --keys "$q_hidden,down" --tags) || fail "search hidden --tags: render exited non-zero"
assert_row "$tags_s" "\{grey-fg\}$T_LANDED.*legacy-import-scout" "search hidden: the hidden row is greyed once the bar moves off it, as H draws it"
frame_s=$(render search.json --view-state "$vs_s" --keys "$q_hidden,enter") || fail "search hidden jump: render exited non-zero"
assert_contains "$frame_s" "$T_LANDED (23, 1 hidden shown)" "search hidden jump: H is on, the pane header says shown"
assert_contains "$frame_s" "legacy-import-scout in $T_LANDED · hidden row: H is on for this session" "search hidden jump: the notice says H was switched on"
tags_s=$(render search.json --view-state "$vs_s" --keys "$q_hidden,enter" --tags) || fail "search hidden jump --tags: render exited non-zero"
assert_row "$tags_s" "${SEL}reported.*${SEL}legacy-import-scout" "search hidden jump: the hidden row is selected in its pane"
assert_file_contains "$vs_s" '"landed:main:legacy-import-scout:2026-09-12"' "search hidden jump: the row stays hidden in the view-state file"
assert_file_not_contains "$vs_s" 'search' "search: nothing of the search reaches the view-state file"
# A hidden pane's rows are found too and the jump shows the pane, saved like its number key would;
# with every pane hidden f still opens the search from the landing page (falsify: skip the hidden
# panes in the index, drop f from LANDING_KEYS, or drop the hiddenPanes.delete from jumpToResult).
printf '{"schema":"fm-board-view-state.v1","hidden_panes":["landed"]}\n' > "$vs_s"
frame_s=$(render search.json --view-state "$vs_s" --keys "f,s,h,i,p,-,1,7,enter") || fail "search hidden pane: render exited non-zero"
assert_contains "$frame_s" "ship-17 in $T_LANDED · pane shown: $T_LANDED" "search hidden pane: the jump shows the pane and says so"
assert_contains "$frame_s" "$T_LANDED (23)" "search hidden pane: Recently Landed is drawn again"
assert_file_contains "$vs_s" '"hidden_panes": []' "search hidden pane: the shown pane is saved, as 6 would save it"
printf '{"schema":"fm-board-view-state.v1","hidden_panes":%s}\n' "$ALL_PANE_IDS" > "$vs_s"
frame_s=$(render search.json --view-state "$vs_s" --keys "f") || fail "search landing: render exited non-zero"
assert_row "$frame_s" '^ Search:  \([0-9]+ matches\) +$' "search landing: f opens the search over every pane from the landing page, an empty query listing every row"
assert_row "$frame_s" "^ $T_INFLIGHT +working +working +ship-cache " "search landing: the rows of the hidden panes are listed"
frame_s=$(render search.json --view-state "$vs_s" --keys "f,s,h,i,p,-,c,a,c,h,e,enter") || fail "search landing jump: render exited non-zero"
assert_contains "$frame_s" "ship-cache in $T_INFLIGHT · pane shown: $T_INFLIGHT" "search landing jump: the jump shows the row's pane"
assert_contains "$frame_s" "$T_INFLIGHT (2)" "search landing jump: the grid is back with that pane"
# The mouse over the results: a click selects the result under the pointer (y counts from the title
# line: 0 title, 1 header, 2 column header, 3 the first match), a double-click jumps to it, the wheel
# moves the cursor three rows (falsify: drop searchMouseAction from handleMouse, or the result zones
# from renderSearch). An empty query lists the rows in pane order, so the first three results are
# Captain's Call's three holds.
tags_s=$(render search.json --mouse "f,click:10,5" --tags) || fail "search click --tags: render exited non-zero"
assert_row "$tags_s" "^ ${SEL}$T_NEEDS" "search click: the third result is under y=5 and takes the bar"
if [ "$(printf '%s\n' "$tags_s" | grep -n "$SEL_TAG" | head -n 1 | cut -d: -f1)" = "6" ]; then pass; else fail "search click: the bar is not on frame line 6 (y=5)"; fi
frame_s=$(render search.json --mouse "f,dblclick:10,4") || fail "search dblclick: render exited non-zero"
assert_contains "$frame_s" "portal-ingest-expired-token-scout in $T_NEEDS" "search dblclick: a double-click on the second result (the delegate's ExpiredToken hold) jumps to it"
assert_not_contains "$frame_s" "Search:" "search dblclick: the prompt is closed by the jump"
tags_s=$(render search.json --mouse "f,wheel:down:10,5" --tags) || fail "search wheel --tags: render exited non-zero"
if [ "$(printf '%s\n' "$tags_s" | grep -n "$SEL_TAG" | head -n 1 | cut -d: -f1)" = "7" ]; then pass; else fail "search wheel: one wheel step down did not move the bar three rows, to frame line 7"; fi

# ------------------------------------------------------------------ PR ages
# My PRs' AGE is the time since the PR was opened when the live fetch carries created_at,
# else the task's status-log age with a trailing ~ (falsify: drop prCreatedAt or the ageFallback
# marker in lib/model.mjs; the rows below then read 2d for 2d~, or 3h~ for 3h). These candidates
# carry no title or base branch, as the script fallback's do not: TITLE falls back to the recorded
# task's backlog title (the URL for a PR no task recorded) and BASE reads - (falsify: drop the
# rec.title fallback from reviewRows).
frame_age=$(render pr-ages.json) || fail "pr-ages: render exited non-zero"
assert_contains "$frame_age" "My PRs (8)" "pr-ages: seven live candidates plus one unlisted recorded PR"
assert_row "$frame_age" '^│ passing +IN REVIEW +pr-fresh +Paginate the address API +- +3h │$' "created_at 3h before now: AGE 3h with no marker, the backlog title in TITLE (falsify: read the status-log age first)"
assert_row "$frame_age" '^│ passing +IN REVIEW +pr-nodate +Cache the geocoder +- +2d~ │$' "no creation time: the status-log age with ~ (falsify: drop ageFallback from reviewAge)"
assert_row "$frame_age" '^│ passing +IN REVIEW +pr-future +Rate-limit headers +- +4h~ │$' "a future created_at counts as absent (falsify: drop the created > now check in prCreatedAt)"
assert_row "$frame_age" '^│ passing +IN REVIEW +pr-bad +Retry budget +- +30m~ │$' "a malformed created_at counts as absent (falsify: return 0 instead of null from parseTime)"
assert_row "$frame_age" '^│ passing +APPROVED +pr-camel +Bulk lookup endpoint +- +5d │$' "the camel-case createdAt is read too, and an APPROVED review decision reads APPROVED (falsify: drop the alias in prCreatedAt)"
assert_row "$frame_age" '^│ passing +IN REVIEW +api#107 +https://github.com/acme/api/pull/107 +- +2h │$' "a candidate with no task and no title shows its URL and its PR age"
assert_row "$frame_age" '^│ passing +IN REVIEW +api#108 +https://github.com/acme/api/pull/108 +- +- │$' "no creation time and no task: - with no marker (falsify: append ~ to a null age)"
assert_row "$frame_age" '^│ unlisted +- +pr-unlisted +https://github.com/acme/api/pull/106 · checks: not fetched +- +45m~ │$' "a recorded PR missing from the live list falls back with ~"
assert_count "$frame_age" "~ │" 4 "exactly the four fallback rows carry the marker (falsify: mark every review row)"
# Only the display text carries the marker: the Underway row of the same task shows the plain
# file-time age (falsify: put the marker into ageSeconds or fmtAge).
assert_row "$frame_age" '^│ working +- +pr-nodate +Cache the geocoder · fixing the flaky test +acme/api +main +2d │$' "Underway shows the same status-log age unmarked"
# --no-prs: every recorded row falls back (falsify: skip the marker when prs.enabled is false).
frame_age_np=$(render pr-ages.json --no-prs) || fail "pr-ages --no-prs: render exited non-zero"
assert_contains "$frame_age_np" "My PRs (6)" "--no-prs: the six recorded PRs"
assert_row "$frame_age_np" '^│ PR +- +pr-fresh +https://github.com/acme/api/pull/101 · checks: off \(--no-prs\) +- +10m~ │$' "--no-prs: the PR that had a live creation time shows its status-log age with ~ instead"
assert_count "$frame_age_np" "~ │" 6 "--no-prs: every My PRs row carries the marker"
assert_no_row "$frame_age_np" '^│ PR .* (3h|5d|2h) │$' "--no-prs: no PR age survives without the fetch"
# The marker fits the AGE column at every breakpoint: at the wide breakpoint (100 columns) the column
# still holds 30m~ whole with BASE beside it; below it My PRs drops BASE and keeps AGE, so
# the marker still shows there while the other panes lose their AGE; in the narrow list AGE is gone
# everywhere (falsify: narrow the AGE column in lib/layout.mjs, render the age into another column,
# or drop AGE with BASE in the review branch of columns).
frame_age_100=$(render pr-ages.json --cols 100 --rows 30) || fail "pr-ages 100: render exited non-zero"
assert_row "$frame_age_100" '^│ passing +IN REVIEW +pr-bad +[^│]* - +30m~ │$' "100 columns: the widest fallback age fits the AGE column beside BASE"
assert_row "$frame_age_100" '^│ passing +IN REVIEW +pr-fresh +[^│]* - +3h │$' "100 columns: the PR age fits"
assert_widths "$frame_age_100" 100 "100-column frame lines are 100 columns"
frame_age_90=$(render pr-ages.json --cols 90 --rows 30) || fail "pr-ages 90: render exited non-zero"
assert_row "$frame_age_90" '^│ passing +IN REVIEW +pr-bad +[^│]* 30m~ │$' "medium width: My PRs keeps AGE, so the marker still shows"
assert_no_row "$frame_age_90" ' BASE ' "medium width: BASE is dropped"
assert_no_row "$frame_age_90" '^│ working [^│]*~ │$' "medium width: the other panes have no AGE column, so no marker outside My PRs"
assert_widths "$frame_age_90" 90 "medium PR-ages frame lines are 90 columns"
frame_age_70=$(render pr-ages.json --cols 70 --rows 30) || fail "pr-ages 70: render exited non-zero"
assert_not_contains "$frame_age_70" "~" "narrow width: no marker in list mode"
assert_widths "$frame_age_70" 70 "narrow PR-ages frame lines are 70 columns"

# ------------------------------------------------------------------ PR status
# My PRs' STATUS column, its 12-hour window on finished PRs and its sort, from
# tests/fixtures/pr-status.json: one PR per status, a PR merged 11h59m and one 12h01m before now, an
# open PR of a done task, a closed PR with no time stamp, a closed draft and an unlisted recorded PR.
frame_st=$(render pr-status.json) || fail "pr-status: render exited non-zero"
# The six columns, in order, and nothing else; the other panes keep theirs (falsify: drop the review
# branch from columns in lib/layout.mjs, reorder its pushes, or apply it to every pane).
assert_row "$frame_st" '^│ CHECKS +STATUS +ID +TITLE +BASE +AGE │$' "pr-status: the header reads CHECKS, STATUS, ID, TITLE, BASE, AGE"
assert_no_row "$frame_st" '^│ CHECKS [^│]*(REPO|HOME|WHAT|REVIEW)' "pr-status: the review pane draws no REPO, HOME, WHAT or REVIEW column"
assert_row "$frame_st" '^│ STATE +HERDR +ID +WHAT +REPO +HOME +AGE │$' "pr-status: the other panes keep the shared columns"
assert_count "$frame_st" "AUTHOR" 1 "pr-status: AUTHOR heads the empty Teammates' PRs pane only; My PRs, whose rows carry authors too, draws none (falsify: add author to every PR pane in columnSpec)"
# One row per status (falsify: change a branch of prStatus in lib/model.mjs).
assert_row "$frame_st" '^│ pending +DRAFT +st-draft +Rework the geocoder cache with a two-tier LRU +main +2h │$' "isDraft reads DRAFT, with the title, base branch and PR age from the fetch"
assert_row "$frame_st" '^│ passing +IN REVIEW +st-review +Paginate the address API: cursor tokens, [^│]*… +main +5h │$' "an open PR awaiting review reads IN REVIEW, and a long title ends in an ellipsis inside the TITLE column (falsify: pad instead of truncate in fit)"
assert_row "$frame_st" '^│ failing +IN REVIEW +api#203 +Retry on 429 +develop +1h │$' "changes requested reads IN REVIEW too; a PR nobody recorded is named repo#number and shows its base branch"
assert_row "$frame_st" '^│ passing +APPROVED +st-approved +Rate-limit headers on every list endpoint +main +1d │$' "an open PR whose review decision is APPROVED reads APPROVED"
assert_row "$frame_st" '^│ none +CLOSED +st-closed +Retry budget for the geocoder +main +8h │$' "a PR closed unmerged 3h ago reads CLOSED and is still listed"
assert_row "$frame_st" '^│ passing +MERGED +st-merged +Bulk lookup endpoint +main +6h │$' "a PR merged 30m ago reads MERGED, and the row of its done task is shown for it (falsify: skip done tasks in recordedPrs)"
assert_row "$frame_st" '^│ none +CLOSED +api#212 +Draft closed unmerged +main +1h │$' "a draft closed unmerged reads CLOSED, not DRAFT, so it leaves with the window (falsify: test the draft flag before the state in prStatus)"
assert_row "$frame_st" '^│ unlisted +- +st-unlisted +https://github.com/acme/api/pull/209 · checks: not fetched +- +45m~ │$' "a recorded PR the fetch did not list keeps its URL, note and file-time age, STATUS unknown"
# The 12-hour window (falsify: change TERMINAL_WINDOW_SECONDS, or compare with <= in insideWindow).
assert_row "$frame_st" '^│ passing +MERGED +api#207 +Fix the flaky geocoder test +release/2026.09 +2d │$' "a PR merged 11h59m before now is still listed"
assert_not_contains "$frame_st" "Split the address migration" "a PR merged 12h01m before now is gone, and its done task with it"
assert_no_row "$frame_st" '^│ (passing|failing|pending|none|unlisted|PR) +[^│]* st-old ' "the done task of the PR outside the window has no review row (its Underway row stays)"
assert_not_contains "$frame_st" "Rename the widget table" "an open PR of a done task is not listed: a done task's PR shows only once terminal (falsify: drop the rec.done check in reviewRows)"
assert_not_contains "$frame_st" "Abandoned spike" "a closed PR with no close time cannot be placed in the window and is dropped"
assert_contains "$frame_st" "My PRs (9)" "the pane count is the rows shown after the window filter (falsify: count candidate_prs instead of rows)"
assert_count "$frame_st" " MERGED " 2 "exactly two MERGED rows"
assert_count "$frame_st" " CLOSED " 2 "exactly two CLOSED rows"
# The sort: DRAFT, IN REVIEW, APPROVED, unknown, CLOSED, MERGED, newest first inside a status (falsify:
# reorder STATUS_ORDER, or sort by ageSeconds descending in byNewest).
assert_before "$frame_st" '^│ pending +DRAFT ' '^│ failing +IN REVIEW +api#203' "DRAFT sorts first"
assert_before "$frame_st" '^│ failing +IN REVIEW +api#203' '^│ passing +IN REVIEW +st-review' "inside IN REVIEW the 1h-old PR sorts before the 5h-old one"
assert_before "$frame_st" '^│ passing +IN REVIEW +st-review' '^│ passing +APPROVED ' "IN REVIEW sorts before APPROVED"
assert_before "$frame_st" '^│ passing +APPROVED ' '^│ unlisted +- ' "APPROVED sorts before the unlisted recorded PR"
assert_before "$frame_st" '^│ unlisted +- ' '^│ none +CLOSED +api#212' "the unlisted recorded PR sorts before CLOSED"
assert_before "$frame_st" '^│ none +CLOSED +api#212' '^│ none +CLOSED +st-closed' "inside CLOSED the 1h-old PR sorts before the 8h-old one"
assert_before "$frame_st" '^│ none +CLOSED +st-closed' '^│ passing +MERGED +st-merged' "CLOSED sorts before MERGED"
assert_before "$frame_st" '^│ passing +MERGED +st-merged' '^│ passing +MERGED +api#207' "inside MERGED the 6h-old PR sorts before the 2d-old one"
assert_widths "$frame_st" 160 "pr-status frame lines are 160 columns"
# enter still opens a row's PR, a finished one included, through the fake opener only (falsify: drop
# url from the review makeRow calls).
frame_o=$(render_open pr-status.json "tab,tab,enter") || fail "pr-status open first: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/201" "enter on the DRAFT row opens its PR"
frame_o=$(render_open pr-status.json "tab,tab,j,j,j,j,j,j,j,enter") || fail "pr-status open merged: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/206" "enter on a MERGED row still opens its PR"
assert_contains "$frame_o" "opened https://github.com/acme/api/pull/206 (st-merged)" "the notice names the task of the merged PR"
# --no-prs: the recorded PRs of unfinished tasks only, STATUS unknown, as before (falsify: list a done
# task's PR without a fetched record).
frame_st_np=$(render pr-status.json --no-prs) || fail "pr-status --no-prs: render exited non-zero"
assert_contains "$frame_st_np" "My PRs (5)" "--no-prs: the five recorded PRs of unfinished tasks"
assert_row "$frame_st_np" '^│ PR +- +st-approved +https://github.com/acme/api/pull/204 · checks: off \(--no-prs\) +- +1h~ │$' "--no-prs: STATUS is unknown without the fetch"
assert_no_row "$frame_st_np" '^│ PR +- +st-merged ' "--no-prs: a done task's PR is not listed without a fetched record"
# Breakpoints: at 100 columns all six columns; below 100 BASE goes and AGE stays; below 80 the list
# shares one header (falsify: drop BASE and AGE together, or keep BASE below WIDE_BREAKPOINT).
frame_st_100=$(render pr-status.json --cols 100 --rows 30) || fail "pr-status 100: render exited non-zero"
assert_row "$frame_st_100" '^│ CHECKS +STATUS +ID +TITLE +BASE +AGE │$' "100 columns: the six columns"
assert_row "$frame_st_100" '^│ pending +DRAFT +st-draft +Rework the geocoder cache with a [^│]*… +main +2h │$' "100 columns: the title truncates with an ellipsis to make room"
assert_widths "$frame_st_100" 100 "100-column pr-status frame lines are 100 columns"
frame_st_90=$(render pr-status.json --cols 90 --rows 30) || fail "pr-status 90: render exited non-zero"
assert_row "$frame_st_90" '^│ CHECKS +STATUS +ID +TITLE +AGE │$' "90 columns: BASE is dropped, AGE stays"
assert_no_row "$frame_st_90" ' BASE ' "90 columns: no BASE column"
assert_row "$frame_st_90" '^│ failing +IN REVIEW +api#203 +Retry on 429 +1h │$' "90 columns: the row loses its base branch and keeps its age"
assert_widths "$frame_st_90" 90 "90-column pr-status frame lines are 90 columns"
frame_st_70=$(render pr-status.json --cols 70 --rows 30) || fail "pr-status 70: render exited non-zero"
assert_row "$frame_st_70" '^ STATE +ID +WHAT +HOME *$' "70 columns: the list shares one header across panes"
assert_row "$frame_st_70" '^ pending +st-draft +Rework the geocoder cache with a two-ti… +main *$' "70 columns: a review row in the shared list (HOME is 4 wide for main and ends the line; the shared STATE column is as wide as the widest state word on the frame, IN REVIEW, so a fixture task reading awaiting merge would narrow WHAT again)"
assert_not_contains "$frame_st_70" "DRAFT" "70 columns: the list has no STATUS column"
assert_widths "$frame_st_70" 70 "70-column pr-status frame lines are 70 columns"

# ------------------------------------------------------------ review rows
# tests/fixtures/review-rows.json: parked tasks with a PR in the main home and in a secondmate
# ledger (PR 21's merge state is BLOCKED with a review required, the merge box of a PR that only
# waits for its review; the others are CLEAN), a task repairing its PR, one on its first pass, a
# closed and a merged PR inside the 12-hour tail, and all four Captain's Call tags.
frame_rv=$(render review-rows.json) || fail "review-rows: render exited non-zero"
frame_rv_x=$(render review-rows.json --expand all) || fail "review-rows --expand all: render exited non-zero"
frame_rv_np=$(render review-rows.json --no-prs) || fail "review-rows --no-prs: render exited non-zero"
# Captain's Call: one review row per task parked for the captain whose PR GitHub reports open and
# mergeable, WHAT `<repo>#<num> · <title> · checks <state>`, AGE the time since the task parked
# with no ~ (falsify: drop the done branch of parkedWithPr, the checks suffix in reviewRow, or
# set ageFallback true for a ready PR).
assert_contains "$frame_rv" "Captain's Call (6)" "review-rows: blocked, decide, hold and three review rows"
assert_row "$frame_rv" '^│ review +#21 +ship-ready +acme/api#21 · Retry on 429 with jitter · checks passing +acme/api +main +10m │$' "a done task's open PR that GitHub marks BLOCKED with a review required is a review row reading ready, with checks passing and a plain age (falsify: treat BLOCKED as not ready in prReadiness)"
assert_row "$frame_rv" '^│ review +#22 +ship-paused +acme/api#22 · Rate-limit headers on every list endpoint · checks pending +acme/api +main +25m │$' "a task firstmate paused on the captain counts as parked (falsify: drop paused from PARKED_STATES)"
assert_row "$frame_rv" '^│ review +#61 +child-ready +acme/etl#61 · ETL: nightly loader · checks passing +acme/etl +delegate-a +40m │$' "a secondmate child parked with the PR its ledger's contributions.captain names is a review row labelled with its home, without --all-homes-needs (falsify: gate the ledger loop behind opts.allHomesNeeds, or read active_children alone)"
assert_no_row "$frame_rv" '^│ review +#23 ' "a task working again on a conflicting PR has no review row (falsify: drop the conflicting return in reviewRow)"
assert_no_row "$frame_rv" '^│ review +#62 ' "a secondmate child repairing its PR has no review row"
assert_no_row "$frame_rv" '^│ review +#24 ' "a PR closed 1h ago, inside the tail, yields no review row (falsify: drop the finished return in reviewRow)"
assert_no_row "$frame_rv" '^│ review +#25 ' "a PR merged 2h ago, inside the tail, yields no review row"
assert_no_row "$frame_rv" '^│ review +#31 ' "a working task on its first pass has no review row (falsify: let parkedForCaptain accept working)"
assert_not_contains "$frame_rv" "merge?" "the merge? row is gone: the review row replaces it (falsify: push the old merge? row in needsRows)"
assert_count "$frame_rv" "#21 " 1 "ship-ready yields exactly one Captain's Call row: never a merge? and a review row for one task"
# The sort: blocked, decide, hold, review (falsify: reorder `order` in needsRows).
assert_before "$frame_rv" '^│ blocked +- +scout-block' '^│ decide +cache-ttl' "review-rows: blocked sorts before decide"
assert_before "$frame_rv" '^│ decide +cache-ttl' '^│ hold +- +hold-vendor' "review-rows: decide sorts before hold"
assert_before "$frame_rv" '^│ hold +- +hold-vendor' '^│ review +#21' "review-rows: hold sorts before review"
# My PRs: READY for a parked task's clean open PR, REPAIRING for a working-again task or a
# conflicting PR, today's words for the rest (falsify: drop fleetStatus from mineRows, or its
# parked / repairing branches).
assert_row "$frame_rv" '^│ passing +READY +ship-ready +Retry on 429 with jitter +main +3h │$' "My PRs reads READY with checks passing for the done task's BLOCKED PR, so both panes agree"
assert_row "$frame_rv" '^│ pending +READY +ship-paused +Rate-limit headers on every list endpoint +main +5h │$' "READY for the paused task's PR"
assert_row "$frame_rv" '^│ passing +READY +etl#61 +ETL: nightly loader +main +1h │$' "READY for the secondmate child's PR the ledger names (falsify: skip the ledgers in fleetPrTasks)"
assert_row "$frame_rv" '^│ passing +REPAIRING +ship-dirty +Bulk lookup endpoint +main +4h │$' "REPAIRING for a task working again on a conflicting PR"
assert_row "$frame_rv" '^│ passing +REPAIRING +etl#62 +ETL: backfill the history +main +30m │$' "REPAIRING for the repairing secondmate child's PR"
assert_row "$frame_rv" '^│ pending +IN REVIEW +ship-first +Widget cache warm-up +main +6h │$' "a working task on its first pass keeps IN REVIEW (falsify: drop the done check in repairingFromLog)"
assert_row "$frame_rv" '^│ none +CLOSED +ship-closed +Abandoned retry budget spike +main +8h │$' "a closed PR of a done task keeps CLOSED"
assert_row "$frame_rv" '^│ passing +MERGED +ship-merged +Geocoder timeout +main +9h │$' "a merged PR of a done task keeps MERGED"
assert_count "$frame_rv" " READY " 3 "exactly three READY rows"
assert_count "$frame_rv" " REPAIRING " 2 "exactly two REPAIRING rows"
# The sort: READY ahead of every other open status, REPAIRING after them, the finished statuses
# at the bottom, newest first inside a status (falsify: reorder STATUS_ORDER).
assert_before "$frame_rv" '^│ passing +READY +etl#61' '^│ passing +READY +ship-ready' "inside READY the 1h-old PR sorts before the 3h-old one"
assert_before "$frame_rv" '^│ pending +READY +ship-paused' '^│ pending +IN REVIEW +ship-first' "READY sorts before IN REVIEW"
assert_before "$frame_rv" '^│ pending +IN REVIEW +ship-first' '^│ passing +REPAIRING +etl#62' "IN REVIEW sorts before REPAIRING"
assert_before "$frame_rv" '^│ passing +REPAIRING +ship-dirty' '^│ none +CLOSED +ship-closed' "REPAIRING sorts before CLOSED"
assert_before "$frame_rv" '^│ none +CLOSED +ship-closed' '^│ passing +MERGED +ship-merged' "CLOSED sorts before MERGED"
# Underway: `repairing PR` for a task with a PR that is working again after a done line in its
# status log, `working` for one on its first pass; the same for a secondmate child through its
# ledger's PR and its home's status log (falsify: drop prStateTag from mainTaskRow or
# ledgerChildRows, or read the current state alone).
assert_row "$frame_rv" '^│ repairing PR +working +ship-dirty +Bulk lookup endpoint · merging main into the branch +acme/api +main +5m │$' "Underway reads repairing PR for the task working again on its PR"
assert_row "$frame_rv" '^│ working +working +ship-first +Widget cache warm-up · waiting for the Test workflow +acme/widgets +main +1h │$' "a first-pass worker with a PR still reads working"
assert_row "$frame_rv" '^│ paused +idle +ship-paused +Rate-limit headers on every list endpoint · awaiting captain approve-and-label +acme/api +main +25m │$' "a paused task keeps its own state word"
assert_row "$frame_rv" '^│ awaiting merge +done +ship-ready +Retry on 429 with jitter · PR https://github.com/acme/api/pull/21 checks green +acme/api +main +10m │$' "awaiting merge is kept for the done task with an unmerged PR"
assert_row "$frame_rv" '^│ repairing PR +working +child-repair +resolving the conflict with main +acme/etl +delegate-a +2m │$' "a delegate's one repairing child draws directly as repairing PR, HOME naming the home (falsify: drop childRepairing from ledgerChildRows)"
assert_no_row "$frame_rv_x" '▾ delegate-a' "a home with one worker has no group row to expand"
assert_before "$frame_rv" '^│ repairing PR +working +ship-dirty' '^│ blocked +blocked +scout-block' "in flight: repairing PR sorts with working, before blocked (falsify: drop repairing PR from INFLIGHT_ORDER)"
# Without PR data the rows fall back to the task state: every parked task with a PR lists,
# finished or not, with the ~ age mark and no checks word; the repairing state still comes from
# the status log (falsify: drop the fallback in reviewRow, or make isRepairing need the fetch).
assert_contains "$frame_rv_np" "Captain's Call (8)" "--no-prs: five review rows on the task state alone"
assert_row "$frame_rv_np" '^│ review +#21 +ship-ready +acme/api#21 · Retry on 429 with jitter +acme/api +main +10m~ │$' "--no-prs: the review row lists with the fallback ~ and no checks word"
assert_row "$frame_rv_np" '^│ review +#24 +ship-closed +acme/api#24 · Abandoned retry budget spike +acme/api +main +2h~ │$' "--no-prs: a closed PR the board cannot see as closed lists on the task state, marked ~"
assert_row "$frame_rv_np" '^│ review +#61 +child-ready +acme/etl#61 +acme/etl +delegate-a +40m~ │$' "--no-prs: the child row has no title to show and reads the label alone"
assert_not_contains "$frame_rv_np" "checks passing" "--no-prs: no checks word on any review row"
assert_row "$frame_rv_np" '^│ repairing PR +working +ship-dirty ' "--no-prs: repairing PR comes from the status log, not GitHub"
frame_rv_nc=$(render "$(variant review-rows.json prs-no-carry '{"prs": {"candidate_prs": []}}')") || fail "review-rows fetched without the PRs: render exited non-zero"
assert_row "$frame_rv_nc" '^│ review +#21 +ship-ready +acme/api#21 · Retry on 429 with jitter +acme/api +main +10m~ │$' "a fetch that does not carry the PR falls back to the task state with ~ (falsify: return null from reviewRow when fetched.get misses)"
# enter on a review row opens its PR through the injected opener, the child's included
# (falsify: drop url from reviewRow).
frame_o=$(render_open review-rows.json "j,j,j,enter") || fail "review-rows open: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/21" "enter on the first review row opens its PR"
frame_o=$(render_open review-rows.json "j,j,j,j,j,enter") || fail "review-rows open child: render exited non-zero"
assert_opened "https://github.com/acme/etl/pull/61" "enter on the secondmate child's review row opens its PR"
assert_widths "$frame_rv" 160 "review-rows frame lines are 160 columns"

# ------------------------------------------------------------------- My PRs
# The pane as the union (tests/fixtures/my-prs.json): the identity's own PRs whatever their
# repository, the recorded PRs of fleet tasks whatever their author, the finished ones inside the
# window, and the recorded PR the fetch did not return; a row of the toreview pane never appears here
# (falsify: filter My PRs on the candidate repositories, drop paneCandidates' pane test, or list a
# toreview row in mineRows).
frame_mp=$(render my-prs.json) || fail "my-prs: render exited non-zero"
assert_contains "$frame_mp" "┌─ [3] My PRs (5) ─" "my-prs: five rows"
assert_row "$frame_mp" '^│ CHECKS +STATUS +ID +TITLE +BASE +AGE │$' "my-prs: the six columns"
assert_row "$frame_mp" '^│ passing +IN REVIEW +dotfiles#5 +Tidy the zsh prompt +main +3h │$' "my-prs: the identity's own PR in a repository no task touches, named repo#number"
assert_row "$frame_mp" '^│ passing +IN REVIEW +ship-alpha +Add the widget cache +main +5h │$' "my-prs: the bot-authored PR recorded on ship-alpha, named by its task"
assert_row "$frame_mp" '^│ unlisted +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: not fetched +- +1m~ │$' "my-prs: a recorded PR the fetch did not return keeps the - row with the file-time age"
assert_row "$frame_mp" '^│ none +CLOSED +api#10 +Old spike +main +8h │$' "my-prs: the identity's PR closed 2h ago is listed as CLOSED"
assert_row "$frame_mp" '^│ passing +MERGED +api#9 +Bump the retry budget +main +6h │$' "my-prs: the identity's PR merged 30m ago is listed as MERGED"
assert_count "$frame_mp" " api#8 " 1 "my-prs: a toreview row draws once on the board (its api#8 id; the Captain's Call review row of ship-gamma repeats the title, not the id)"
assert_before "$frame_mp" "Teammates' PRs \(1\)" '^│ failing +IN REVIEW +api#8 .*Retry on 429' "my-prs: that one row is under the Teammates' PRs header, not in My PRs"
assert_before "$frame_mp" '^│ passing +IN REVIEW +dotfiles#5' '^│ passing +IN REVIEW +ship-alpha' "my-prs: inside IN REVIEW the 3h-old PR sorts before the 5h-old one"
assert_before "$frame_mp" '^│ passing +IN REVIEW +ship-alpha' '^│ unlisted +- +ship-gamma' "my-prs: the unlisted recorded PR sorts after the open rows"
assert_before "$frame_mp" '^│ unlisted +- +ship-gamma' '^│ none +CLOSED ' "my-prs: CLOSED sorts after the unlisted row"
assert_before "$frame_mp" '^│ none +CLOSED ' '^│ passing +MERGED ' "my-prs: MERGED sorts last"
assert_contains "$frame_mp" "┌─ [4] Teammates' PRs (1) ─" "my-prs: the one toreview row is in Teammates' PRs"
assert_row "$frame_mp" '^│ failing +IN REVIEW +api#8 +teammate +Retry on 429 +main +2h │$' "my-prs: the toreview row draws in Teammates' PRs with its author between ID and TITLE"
assert_widths "$frame_mp" 160 "my-prs frame lines are 160 columns"
assert_lines "$frame_mp" 44 "my-prs frame is 44 lines"
# The identity from the fixture reaches the Settings page (falsify: drop identity from prsFromFixture).
frame_mp=$(render my-prs.json --install-root "$SCRATCH/nowhere" --keys ".") || fail "my-prs settings: render exited non-zero"
assert_row "$frame_mp" '^ Identity +captain  \(from config\) +$' "my-prs: the fixture's identity and source show on the Settings page"

# ----------------------------------------------------------- Teammates' PRs
# The pane over tests/fixtures/to-review.json: one row per STATUS word, the identity's own review
# winning over the PR's decision, the request through a team, the labelled portal PR, a PR merged
# outside the window and the identity's own PR both dropped, the seven columns with AUTHOR between ID
# and TITLE (the login, `-` for a null author, content-sized, in this pane alone) and the sort
# (falsify: drop toReviewStatus, the author check or the window from toReviewRows, reorder
# STATUS_ORDER, or drop the author push from columnSpec or the author field from fetchedPrRow).
frame_tr=$(render to-review.json) || fail "to-review: render exited non-zero"
assert_contains "$frame_tr" "┌─ [4] Teammates' PRs (7) ─" "to-review: seven rows under key 4"
assert_contains "$frame_tr" "┌─ [3] My PRs (1) ─" "to-review: the one mine row stays in My PRs"
assert_before "$frame_tr" "My PRs \(1\)" "Teammates' PRs \(7\)" "to-review: the two PR panes are adjacent, My PRs first"
assert_before "$frame_tr" "Underway \(0\)" "My PRs \(1\)" "to-review: Underway, empty here, still leads the two PR panes"
assert_row "$frame_tr" '^│ CHECKS +STATUS +ID +AUTHOR +TITLE +BASE +AGE │$' "to-review: the seven columns, AUTHOR between ID and TITLE"
assert_row "$frame_tr" '^│ CHECKS +STATUS +ID +TITLE +BASE +AGE │$' "to-review: My PRs keeps its six columns and draws no AUTHOR"
assert_count "$frame_tr" "AUTHOR" 1 "to-review: AUTHOR heads one pane only"
assert_row "$frame_tr" '^│ pending +DRAFT +api#16 +teammate +Draft: split the geocoder +main +30m │$' "to-review: a draft reads DRAFT, its author's login beside its id"
assert_row "$frame_tr" '^│ passing +IN REVIEW +portal#120 +portal-dev +Portal: index the parcel table +main +1h │$' "to-review: the labelled portal PR reads IN REVIEW, with its own author"
assert_row "$frame_tr" '^│ failing +IN REVIEW +api#8 +- +Retry on 429 +develop +2h │$' "to-review: changes requested by someone else still reads IN REVIEW, with the base branch and failing checks, and a null author draws as - (falsify: draw an empty cell for a null author)"
assert_row "$frame_tr" '^│ passing +IN REVIEW +etl#15 +teammate +ETL: nightly loader for the team +main +3h │$' "to-review: a request through the identity's team is a row like any other"
assert_row "$frame_tr" '^│ passing +CHANGES REQUESTED +widgets#46 +teammate +Widget: captain asked for changes +main +4h │$' "to-review: the identity's own CHANGES_REQUESTED review reads CHANGES REQUESTED (falsify: read reviewDecision instead of my_review)"
assert_row "$frame_tr" '^│ passing +APPROVED +widgets#45 +teammate +Widget: approved by captain +main +5h │$' "to-review: the identity's own approval reads APPROVED"
assert_row "$frame_tr" '^│ passing +MERGED +etl#14 +teammate +ETL: merged after review +main +6h │$' "to-review: a reviewed PR merged 30m ago is listed as MERGED"
assert_not_contains "$frame_tr" "ETL: merged yesterday" "to-review: a PR merged 13h ago is outside the window"
assert_not_contains "$frame_tr" "Retry budget: ask the API team" "to-review: the identity's own PR never lists, even when its team was asked"
assert_row "$frame_tr" '^│ CHECKS +STATUS {13}ID ' "to-review: STATUS widens to CHANGES REQUESTED, its widest value, plus the gutter (falsify: cap extra below 17 in columnSpec)"
assert_row "$frame_tr" '^│ CHECKS +STATUS +ID +AUTHOR {6}TITLE ' "to-review: AUTHOR is content-sized, as wide as portal-dev, its widest login, plus the gutter (falsify: give author a fixed width, or measure it over the board)"
assert_before "$frame_tr" '^│ pending +DRAFT ' '^│ passing +IN REVIEW +portal#120' "to-review: DRAFT sorts first"
assert_before "$frame_tr" '^│ passing +IN REVIEW +portal#120' '^│ failing +IN REVIEW +api#8' "to-review: inside IN REVIEW the 1h-old PR sorts before the 2h-old one"
assert_before "$frame_tr" '^│ failing +IN REVIEW +api#8' '^│ passing +IN REVIEW +etl#15' "to-review: inside IN REVIEW the 2h-old PR sorts before the 3h-old one"
assert_before "$frame_tr" '^│ passing +IN REVIEW +etl#15' '^│ passing +CHANGES REQUESTED ' "to-review: IN REVIEW sorts before CHANGES REQUESTED (the rows still waiting first)"
assert_before "$frame_tr" '^│ passing +CHANGES REQUESTED ' '^│ passing +APPROVED ' "to-review: CHANGES REQUESTED sorts before APPROVED"
assert_before "$frame_tr" '^│ passing +APPROVED ' '^│ passing +MERGED ' "to-review: MERGED sorts last"
assert_widths "$frame_tr" 160 "to-review frame lines are 160 columns"
assert_lines "$frame_tr" 44 "to-review frame is 44 lines"
# Below WIDE_BREAKPOINT the pane keeps AUTHOR and AGE and drops BASE like My PRs; in the narrow list the
# shared header has no AUTHOR and a row draws without its login (falsify: drop author with base below
# the breakpoint, or add it to the shared column set).
frame_tr=$(render to-review.json --cols 90 --rows 30) || fail "to-review 90: render exited non-zero"
assert_row "$frame_tr" '^│ CHECKS +STATUS +ID +AUTHOR +TITLE +AGE │$' "90 columns: Teammates' PRs keeps AUTHOR and AGE and drops BASE"
assert_row "$frame_tr" '^│ passing +IN REVIEW +portal#120 +portal-dev +Portal: index the parcel tab… +1h │$' "90 columns: the row keeps its author and loses its base branch"
assert_widths "$frame_tr" 90 "90-column to-review frame lines are 90 columns"
frame_tr=$(render to-review.json --cols 70 --rows 30) || fail "to-review 70: render exited non-zero"
assert_row "$frame_tr" '^ STATE +ID +WHAT +HOME *$' "70 columns: the shared list header has no AUTHOR"
assert_not_contains "$frame_tr" "AUTHOR" "70 columns: no AUTHOR anywhere in the list"
assert_row "$frame_tr" '^ passing +portal#120 +Portal: index the parcel table +main *$' "70 columns: a Teammates' PRs row in the shared list draws without its author"
assert_not_contains "$frame_tr" "portal-dev" "70 columns: the login is not drawn"
assert_widths "$frame_tr" 70 "70-column to-review frame lines are 70 columns"
# Keys on Teammates' PRs: 3 hides and shows it, tab reaches it right after My PRs, enter and a
# double-click open its PR through the fake opener, x hides a row under the toreview id (falsify: drop
# 'toreview' from OPEN_PANES, or move the pane in PANES).
frame_tr=$(render to-review.json --keys "4") || fail "to-review 4: render exited non-zero"
assert_not_contains "$frame_tr" "Teammates' PRs (" "4 hides Teammates' PRs"
assert_contains "$frame_tr" "· panes hidden: 4" "4: the title lists the fourth pane"
frame_o=$(render_open to-review.json "tab,tab,enter") || fail "to-review enter: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/16" "two tabs from Captain's Call land on Teammates' PRs, the pane after My PRs, and enter opens its first row, the DRAFT PR"
assert_contains "$frame_o" "opened https://github.com/acme/api/pull/16 (api#16)" "to-review: the footer names the opened PR"
frame_o=$(render_open to-review.json "tab,tab,j,j,j,j,j,j,enter") || fail "to-review enter merged: render exited non-zero"
assert_opened "https://github.com/acme/etl/pull/14" "enter on the MERGED Teammates' PRs row still opens its PR"
vs_tr="$SCRATCH/view-state-toreview.json"
rm -f "${vs_tr:?}"
frame_tr=$(render to-review.json --view-state "$vs_tr" --keys "tab,tab,x") || fail "to-review x: render exited non-zero"
assert_contains "$frame_tr" "Teammates' PRs (6, 1 hidden)" "x hides a Teammates' PRs row and the header counts it"
assert_contains "$frame_tr" "hidden api#16" "x names the hidden Teammates' PRs row"
assert_file_contains "$vs_tr" '"toreview:main:api#16"' "the hidden Teammates' PRs row is keyed under the toreview pane id"
# Mouse: at 160x44 Underway (title 1, empty, and it takes the spare rows: lib/layout.mjs
# SPARE_PRIORITY), Captain's Call (title 17) and My PRs (title 21) sit above it, so Teammates' PRs' title is
# line 25, its column header 26 and its rows 27-33; a double-click on its second row opens the PR as
# enter does (falsify: drop the row zones for the fourth pane).
frame_m=$(render_mouse to-review.json "dblclick:30,28") || fail "to-review dblclick: render exited non-zero"
assert_opened "https://github.com/example-corp/portal/pull/120" "a double-click on Teammates' PRs' second row opens its PR"
# The AUTHOR column resizes like any fixed column and its width persists under the author key: on the
# header line 26 the columns start at x=2 CHECKS (7), 11 STATUS (17), 30 ID (10), 42 AUTHOR (10) and
# 54 TITLE, so the AUTHOR/TITLE gutter is cells 52-53 (falsify: leave author out of COLUMN_KEYS, so
# sanitizeColumns drops the saved width, or out of the fixed columns boundaries() offers).
rm -f "${vs_tr:?}"
frame_tr=$(render to-review.json --view-state "$vs_tr" --mouse "drag:52,26->57") || fail "to-review drag author: render exited non-zero"
assert_row "$frame_tr" '^│ CHECKS +STATUS +ID +AUTHOR {11}TITLE ' "dragging the AUTHOR/TITLE boundary five cells right makes AUTHOR 15 wide"
assert_row "$frame_tr" '^│ passing +IN REVIEW +portal#120 +portal-dev {7}Portal: index the parcel table ' "the rows follow the AUTHOR width"
assert_contains "$frame_tr" "AUTHOR 15 wide" "the footer names the column"
assert_file_contains "$vs_tr" '"toreview": {' "the width is saved under the pane id"
assert_file_contains "$vs_tr" '"author": 15' "and the author column key"
frame_tr=$(render to-review.json --view-state "$vs_tr") || fail "to-review author width reload: render exited non-zero"
assert_row "$frame_tr" '^│ CHECKS +STATUS +ID +AUTHOR {11}TITLE ' "a restart reads the AUTHOR width back"
frame_tr=$(render to-review.json --view-state "$vs_tr" --mouse "dblclick:57,26") || fail "to-review reset author: render exited non-zero"
assert_row "$frame_tr" '^│ CHECKS +STATUS +ID +AUTHOR {6}TITLE ' "a double-click on the moved boundary puts AUTHOR back to its automatic width"
assert_file_not_contains "$vs_tr" '"author"' "the reset width leaves the file"
# The scope text: with no rows and an empty scope the pane says where to add one; with a scope and no
# rows it reads its empty text (falsify: drop SCOPE_EMPTY_TEXT from prPaneEmpty).
frame_tr=$(render "$(variant to-review.json empty-scope '{"prs": {"candidate_prs": [], "toreview": {"scope": []}}}')") || fail "to-review empty scope: render exited non-zero"
assert_row "$frame_tr" '^│ no repositories in scope: see Settings \(\.\) +│$' "an empty Teammates' PRs scope names the Settings page"
frame_tr=$(render "$(variant to-review.json empty-rows '{"prs": {"candidate_prs": []}}')") || fail "to-review empty rows: render exited non-zero"
assert_row "$frame_tr" '^│ no pull requests waiting for your review +│$' "a scope with no requests reads the empty text"
# The identity resolved unknown, on a fixture (an identity object with no login: every rung failed):
# one row in each PR pane, whatever candidates the fixture carries (falsify: drop identityMissing
# from mineRows or toReviewRows).
UNKNOWN_IDENTITY='{"login": null, "source": "unknown", "reason": "fixture: no login"}'
frame_tr=$(render "$(variant to-review.json no-identity "{\"prs\": {\"identity\": $UNKNOWN_IDENTITY}}")") || fail "to-review no identity: render exited non-zero"
assert_count "$frame_tr" "identity unknown: see Settings (.)" 2 "identity unknown in the fixture: one row in each PR pane"
assert_contains "$frame_tr" "┌─ [4] Teammates' PRs (1) ─" "identity unknown: Teammates' PRs counts the one row"
assert_row "$frame_tr" '^│ - +- +- +- +identity unknown: see Settings \(\.\) +- +- │$' "identity unknown: the Teammates' PRs row reads across its seven columns, - under AUTHOR"
assert_contains "$frame_tr" "┌─ [3] My PRs (1) ─" "identity unknown: My PRs counts the one row"
assert_not_contains "$frame_tr" "portal#120" "identity unknown: the fixture's rows are not drawn"
frame_tr=$(render "$(variant to-review.json no-identity "{\"prs\": {\"identity\": $UNKNOWN_IDENTITY}}")" --install-root "$SCRATCH/nowhere" --keys "." --cols 200) || fail "to-review no identity settings: render exited non-zero"
assert_contains "$frame_tr" " Identity       identity unknown: set identity.github_login in the config file, or run gh auth login" "identity unknown: the Settings page warns, naming the config file in general when a fixture render read none"
assert_contains "$frame_tr" "tried: fixture: no login" "identity unknown: the Settings page lists the fixture's reason"
# The same while a refresh runs: the row, never a spinner, once the rungs have answered (falsify:
# spin on !identityKnown in paneLoadingSource, or read a login of null as pending).
frame_tr=$(render "$(variant to-review.json unknown-refreshing "{\"prs\": {\"identity\": $UNKNOWN_IDENTITY}, \"refresh\": {\"refreshing\": true}}")") || fail "to-review unknown refreshing: render exited non-zero"
assert_count "$frame_tr" "identity unknown: see Settings (.)" 2 "identity unknown while refreshing: the row stays in both PR panes"
assert_not_contains "$frame_tr" "resolving" "identity unknown while refreshing: no resolving line over a resolved identity"
# The identity not resolved yet (null in the fixture, the app's state until its first refresh has
# asked the rungs) while that refresh runs: both PR panes spin on it in the shape of the other
# spinner lines, list nothing and count zero, and neither the identity row nor the fetch spinner
# shows (falsify: read null as unknown in identityFromFixture, drop identityResolving from the two
# builders or from paneLoadingSource, or gate the resolving line on the pane's fetchedAt, which
# to-review.json sets).
PENDING_IDENTITY='{"prs": {"identity": null}, "refresh": {"refreshing": true}}'
frame_tr=$(render "$(variant to-review.json identity-pending "$PENDING_IDENTITY")") || fail "to-review identity pending: render exited non-zero"
assert_count "$frame_tr" "⠋ resolving GitHub identity…" 2 "identity pending: both PR panes spin on the identity"
assert_row "$frame_tr" '^│ ⠋ resolving GitHub identity… +│$' "identity pending: the resolving line has the spinner glyph, the verb, the source and the ellipsis, nothing else"
assert_not_contains "$frame_tr" "identity unknown" "identity pending: the identity row is not drawn before the rungs have answered"
assert_not_contains "$frame_tr" "loading GitHub" "identity pending: the fetch spinners wait for the login"
assert_contains "$frame_tr" "┌─ [3] My PRs (0) ─" "identity pending: My PRs counts zero rows"
assert_contains "$frame_tr" "┌─ [4] Teammates' PRs (0) ─" "identity pending: Teammates' PRs counts zero rows"
assert_not_contains "$frame_tr" "portal#120" "identity pending: the fixture's rows are not drawn for nobody"
# Between the first draw and the first refresh (no refresh block) a pending identity reads the empty
# text like the other panes, never the row (falsify: fire identityRow on !identityKnown).
frame_tr=$(render "$(variant to-review.json identity-pending-idle '{"prs": {"identity": null}}')") || fail "to-review identity pending idle: render exited non-zero"
assert_not_contains "$frame_tr" "identity unknown" "identity pending, no refresh: no identity row"
assert_not_contains "$frame_tr" "resolving" "identity pending, no refresh: no spinner outside a refresh"
assert_row "$frame_tr" '^│ no pull requests waiting for your review +│$' "identity pending, no refresh: Teammates' PRs reads its empty text"
# The Settings page while resolving: the Identity line says so, with no tried: line (falsify: default a
# null identity to unknown in settingsInfo).
frame_tr=$(render "$(variant to-review.json identity-pending "$PENDING_IDENTITY")" --install-root "$SCRATCH/nowhere" --keys "." --cols 200) || fail "to-review identity pending settings: render exited non-zero"
assert_row "$frame_tr" '^ Identity +resolving: the config file, then gh api user, then git config github.user +$' "identity pending: the Settings page says the identity is being resolved"
assert_not_contains "$frame_tr" "tried:" "identity pending: nothing has been tried yet"
# --no-prs: Teammates' PRs reads the off text with no identity row (falsify: test the identity before prs.enabled).
frame_tr=$(render to-review.json --no-prs) || fail "to-review --no-prs: render exited non-zero"
assert_row "$frame_tr" '^│ PR fetch off \(--no-prs\) +│$' "--no-prs: Teammates' PRs reads the off text"
assert_not_contains "$frame_tr" "identity unknown" "--no-prs: no identity row"
frame_tr=$(render "$(variant to-review.json identity-pending-noprs "$PENDING_IDENTITY")" --no-prs) || fail "to-review pending --no-prs: render exited non-zero"
assert_not_contains "$frame_tr" "resolving" "--no-prs: no resolving line either, since nothing needs the login (falsify: test identityPending before prs.enabled)"
assert_row "$frame_tr" '^│ PR fetch off \(--no-prs\) +│$' "--no-prs while the identity is pending: Teammates' PRs still reads the off text"
# Without gh (the fixture's unavailable note): Teammates' PRs says what it needs (falsify: drop the
# unavailable branch from prPaneEmpty).
frame_tr=$(render "$(variant to-review.json no-gh '{"prs": {"candidate_prs": [], "toreview": {"unavailable": "gh not on PATH"}}}')") || fail "to-review no gh: render exited non-zero"
assert_row "$frame_tr" "^│ gh not on PATH: Teammates' PRs needs the GitHub CLI +│\$" "without gh Teammates' PRs names the CLI it needs"
# The config's own reason (lib/model.mjs SCRIPT_CONFIGURED, the second `unavailable` reason): the pane
# names the board's own fetch, not the CLI (falsify: one text for every reason in prPaneEmpty).
frame_tr=$(render "$(variant to-review.json script-source '{"prs": {"candidate_prs": [], "toreview": {"unavailable": "config prs.source = firstmate"}}}')") || fail "to-review script source: render exited non-zero"
assert_row "$frame_tr" "^│ config prs.source = firstmate: Teammates' PRs needs the board's own fetch +│\$" "with prs.source firstmate Teammates' PRs names the board's own fetch as what it needs"
# The fixture's prs.source reaches the Settings page's PR source line in each of its shapes; without
# the block a fixture reads the board default whatever PATH holds (the settings section below), so a
# frame never depends on the host's gh (falsify: drop prSourceFromFixture, or ask whichOnPath for a
# fixture render).
frame_tr=$(render "$(variant to-review.json source-firstmate-config '{"prs": {"source": {"kind": "firstmate", "reason": "config"}}}')" --install-root "$SCRATCH/nowhere" --keys ".") || fail "to-review source firstmate settings: render exited non-zero"
assert_row "$frame_tr" '^ PR source +firstmate: fm-bearings-snapshot.sh \(config prs.source\) +$' "Settings: a fixture's prs.source firstmate by config reads on the PR source line"
frame_tr=$(render "$(variant to-review.json source-firstmate-nogh '{"prs": {"source": {"kind": "firstmate", "reason": "gh-missing"}}}')" --install-root "$SCRATCH/nowhere" --keys ".") || fail "to-review source gh-missing settings: render exited non-zero"
assert_row "$frame_tr" '^ PR source +firstmate: fm-bearings-snapshot.sh \(gh not on PATH; the script needs gh too, so both sources fail the same way\) +$' "Settings: the gh-missing reason says both sources fail alike without gh (falsify: reuse the config wording for gh-missing)"
frame_tr=$(render "$(variant to-review.json source-board-config '{"prs": {"source": {"kind": "board", "reason": "config"}}}')" --install-root "$SCRATCH/nowhere" --keys ".") || fail "to-review source board config settings: render exited non-zero"
assert_row "$frame_tr" "^ PR source +board: the board's own GitHub fetch \\(config\\) +\$" "Settings: a board source the file set reads (config)"
# The help names the sixth pane and its key (falsify: change the 1 - 6 lines in HELP_LINES).
frame_tr=$(render to-review.json --keys "?") || fail "to-review help: render exited non-zero"
assert_contains "$frame_tr" "1 - 6        show or hide a pane; each pane title carries its key: [1] Captain's Call" "help overlay documents 1-6"
assert_contains "$frame_tr" "[4] Teammates' PRs" "help overlay lists the Teammates' PRs badge"
assert_row "$frame_tr" '^ j/k move  tab pane  enter open/focus/view  f search  a accept  x hide  H hidden  1-6 panes ' "the footer reads 1-6 panes"

# The fetch's pure pieces, straight from lib/sources.mjs, copy fm-bearings-snapshot.sh's rules: the
# repository slug, the check mapping (gh's statusCheckRollup list and the GraphQL contexts alike),
# the fm/<task> branch rule with the script's defaults, the projection of the title, base branch,
# draft flag, state, merge and close times and, from a GraphQL node, the author, the labels and the
# identity's own review, the 12-hour keep rule on fetched PRs (open always; merged or closed only
# while the finish time is less than twelve hours before now, a missing stamp dropped, a future one
# kept), the candidate rule (PR URLs of every task including a secondmate's, then the origin remote
# of live non-secondmate worktrees only, capped at ten), the Teammates' PRs scope (candidates first, the
# config file's repositories after, deduped), the four search strings (repo: qualifiers only while
# the whole scope fits GitHub's 256 characters) and the aliased lookup. Two scratch git repositories
# stand in for worktrees (falsify: change any branch of checksState, drop the .git strip in
# repoSlug, the kind check in candidateRepos, a field from GH_PR_FIELDS, the length guard in
# searchQueries, or compare with <= in keepFetchedPr).
WT_DIR="$SCRATCH/wt"
WT_SM_DIR="$SCRATCH/wt-secondmate"
git init -q "$WT_DIR" && git -C "$WT_DIR" remote add origin git@github.com:acme/wt.git
git init -q "$WT_SM_DIR" && git -C "$WT_SM_DIR" remote add origin https://github.com/acme/mate-only.git
unit_out=$(node --input-type=module -e "
  import { checksState, projectPr, repoSlug, candidateRepos, keepFetchedPr, GH_PR_FIELDS, myReview, searchQueries, reviewScope, inScope, lookupGraphql, closedSince, SEARCH_QUERY_MAX } from '$ROOT/bin/firstmate-tui/lib/sources.mjs';
  const out = [];
  out.push(['none', checksState([])], ['none-null', checksState(null)]);
  out.push(['passing', checksState([{ status: 'COMPLETED', conclusion: 'SUCCESS' }])]);
  out.push(['passing-state', checksState([{ state: 'SUCCESS' }])]);
  out.push(['pending', checksState([{ status: 'IN_PROGRESS' }, { status: 'COMPLETED', conclusion: 'SUCCESS' }])]);
  out.push(['failing', checksState([{ status: 'COMPLETED', conclusion: 'FAILURE' }, { status: 'IN_PROGRESS' }])]);
  out.push(['failing-state', checksState([{ state: 'ERROR' }])]);
  // Runs of one check: only the newest counts. example-corp/portal#6148's real rollup (six runs of
  // one check, the cancelled one listed first and superseded 23 seconds later), a check whose only
  // run was cancelled, a cancelled re-run after a success, a re-run still in progress, a check in
  // progress beside a completed check of another name, the same job name in two workflows, a
  // StatusContext updated from PENDING to SUCCESS, gh's --json list shape (name, times and
  // workflowName, no app), nameless contexts judged one by one as before, and two runs without
  // times, where the later position wins (falsify: rank by completedAt alone or drop the position
  // from runRank, group by name alone, or judge every run).
  const run = (name, conclusion, startedAt, completedAt, workflow = 'CI', status = 'COMPLETED') => ({ __typename: 'CheckRun', name, status, conclusion, startedAt, completedAt, checkSuite: { app: { name: 'GitHub Actions' }, workflowRun: { workflow: { name: workflow } } } });
  const hive = 'check graphql schema (hive)';
  const schema = 'GraphQL Schema Check';
  out.push(['superseded', checksState([run(hive, 'CANCELLED', '2026-09-18T19:38:34Z', '2026-09-18T19:38:39Z', schema), run('merge check', 'SUCCESS', '2026-09-18T19:32:55Z', '2026-09-18T19:33:00Z'), run(hive, 'SUCCESS', '2026-09-18T19:33:17Z', '2026-09-18T19:33:31Z', schema), run(hive, 'SUCCESS', '2026-09-18T19:36:52Z', '2026-09-18T19:36:58Z', schema), run(hive, 'SUCCESS', '2026-09-18T19:38:57Z', '2026-09-18T19:39:05Z', schema), run(hive, 'SUCCESS', '2026-09-18T19:41:33Z', '2026-09-18T19:41:39Z', schema), run(hive, 'SUCCESS', '2026-09-18T19:42:10Z', '2026-09-18T19:42:16Z', schema)])]);
  out.push(['cancelled-only', checksState([run('build', 'CANCELLED', '2026-09-18T10:00:00Z', '2026-09-18T10:01:00Z')])]);
  out.push(['cancelled-newest', checksState([run('build', 'SUCCESS', '2026-09-18T10:00:00Z', '2026-09-18T10:05:00Z'), run('build', 'CANCELLED', '2026-09-18T10:10:00Z', '2026-09-18T10:11:00Z')])]);
  out.push(['rerun-running', checksState([run('build', 'SUCCESS', '2026-09-18T10:00:00Z', '2026-09-18T10:05:00Z'), run('build', null, '2026-09-18T10:10:00Z', null, 'CI', 'IN_PROGRESS')])]);
  out.push(['other-running', checksState([run('lint', 'SUCCESS', '2026-09-18T10:00:00Z', '2026-09-18T10:05:00Z'), run('build', null, '2026-09-18T10:00:00Z', null, 'CI', 'IN_PROGRESS')])]);
  out.push(['two-workflows', checksState([run('build', 'FAILURE', '2026-09-18T10:00:00Z', '2026-09-18T10:05:00Z', 'CI'), run('build', 'SUCCESS', '2026-09-18T10:10:00Z', '2026-09-18T10:15:00Z', 'Release')])]);
  out.push(['status-context-updated', checksState([{ __typename: 'StatusContext', context: 'ci/circle', state: 'PENDING', createdAt: '2026-09-18T10:00:00Z' }, { __typename: 'StatusContext', context: 'ci/circle', state: 'SUCCESS', createdAt: '2026-09-18T10:05:00Z' }])]);
  out.push(['gh-json-superseded', checksState([{ __typename: 'CheckRun', name: hive, status: 'COMPLETED', conclusion: 'CANCELLED', startedAt: '2026-09-18T19:38:34Z', completedAt: '2026-09-18T19:38:39Z', workflowName: schema }, { __typename: 'CheckRun', name: hive, status: 'COMPLETED', conclusion: 'SUCCESS', startedAt: '2026-09-18T19:38:57Z', completedAt: '2026-09-18T19:39:05Z', workflowName: schema }])]);
  out.push(['gh-json-two-workflows', checksState([{ name: 'build', status: 'COMPLETED', conclusion: 'FAILURE', startedAt: '2026-09-18T10:00:00Z', completedAt: '2026-09-18T10:05:00Z', workflowName: 'CI' }, { name: 'build', status: 'COMPLETED', conclusion: 'SUCCESS', startedAt: '2026-09-18T10:10:00Z', completedAt: '2026-09-18T10:15:00Z', workflowName: 'Release' }])]);
  out.push(['nameless-mixed', checksState([{ status: 'COMPLETED', conclusion: 'CANCELLED' }, { status: 'COMPLETED', conclusion: 'SUCCESS' }])]);
  out.push(['position-only', checksState([run('build', 'SUCCESS', null, null), run('build', 'CANCELLED', null, null)])]);
  out.push(['slug-pull', repoSlug('https://github.com/acme/widgets/pull/41')]);
  out.push(['slug-ssh', repoSlug('git@github.com:acme/widgets.git')]);
  out.push(['slug-other', String(repoSlug('https://gitlab.com/acme/widgets'))]);
  const p = projectPr({ number: 41, title: 'Add the widget cache', url: 'https://github.com/acme/widgets/pull/41', headRefName: 'fm/ship-alpha', baseRefName: 'main', reviewDecision: 'REVIEW_REQUIRED', mergeable: 'MERGEABLE', statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'SUCCESS' }], createdAt: '2026-09-16T09:00:00Z', isDraft: true, state: 'OPEN', mergedAt: null, closedAt: null }, 'acme/widgets');
  out.push(['project', [p.num, p.repo, p.task, p.review, p.mergeable, p.checks, p.created_at, p.title, p.base, p.draft, p.state, String(p.merged_at), String(p.closed_at)].join(' ')]);
  out.push(['project-extra', [String(p.author), p.labels.length, p.requested, String(p.my_review), p.pane].join(' ')]);
  const q = projectPr({ number: 8, url: 'u', headRefName: 'retry-429' }, 'acme/api');
  out.push(['project-defaults', [q.task, q.review, q.mergeable, q.checks, String(q.created_at), String(q.title), String(q.base), q.draft, String(q.state), String(q.merged_at)].join(' ')]);
  const m = projectPr({ number: 9, url: 'u', headRefName: 'x', state: 'merged', mergedAt: '2026-09-16T11:30:00Z', closedAt: '2026-09-16T11:30:00Z' }, 'acme/api');
  out.push(['project-merged', [m.state, m.merged_at, m.closed_at].join(' ')]);
  // A GraphQL node: the repository from nameWithOwner, the checks from the head commit's contexts,
  // the author, the labels and the identity's review.
  const node = { number: 120, title: 'Portal: index', url: 'https://github.com/example-corp/portal/pull/120', headRefName: 'parcel-index', baseRefName: 'main', reviewDecision: 'REVIEW_REQUIRED', mergeable: 'MERGEABLE', isDraft: false, state: 'OPEN', createdAt: '2026-09-16T09:00:00Z', mergedAt: null, closedAt: null, author: { login: 'teammate' }, repository: { nameWithOwner: 'example-corp/portal' }, labels: { nodes: [{ name: 'ready-to-merge' }, { name: 'backend' }] }, latestReviews: { nodes: [{ state: 'COMMENTED', author: { login: 'someone' } }, { state: 'APPROVED', author: { login: 'captain' } }] }, commits: { nodes: [{ commit: { statusCheckRollup: { contexts: { nodes: [{ __typename: 'CheckRun', status: 'COMPLETED', conclusion: 'FAILURE' }, { __typename: 'StatusContext', state: 'SUCCESS' }] } } } }] } };
  const n = projectPr(node, null);
  out.push(['project-node', [n.repo, n.num, n.task, n.author, n.labels.join('+'), n.checks, n.title].join(' ')]);
  out.push(['project-node-nochecks', projectPr({ ...node, commits: { nodes: [{ commit: { statusCheckRollup: null } }] } }, null).checks]);
  out.push(['my-review', String(myReview(node, 'captain'))]);
  out.push(['my-review-comment', String(myReview(node, 'someone'))]);
  out.push(['my-review-none', String(myReview(node, 'nobody'))]);
  out.push(['my-review-changes', String(myReview({ latestReviews: { nodes: [{ state: 'CHANGES_REQUESTED', author: { login: 'captain' } }] } }, 'captain'))]);
  const now = 1789560000; // 2026-09-16T12:00:00Z
  out.push(['keep-open', keepFetchedPr({ state: 'OPEN' }, now)]);
  out.push(['keep-no-state', keepFetchedPr({}, now)]);
  out.push(['keep-merged-inside', keepFetchedPr({ state: 'MERGED', merged_at: '2026-09-16T00:01:00Z' }, now)]);
  out.push(['keep-merged-outside', keepFetchedPr({ state: 'MERGED', merged_at: '2026-09-15T23:59:00Z' }, now)]);
  out.push(['keep-merged-exact', keepFetchedPr({ state: 'MERGED', merged_at: '2026-09-16T00:00:00Z' }, now)]);
  out.push(['keep-merged-closed-only', keepFetchedPr({ state: 'MERGED', closed_at: '2026-09-16T11:00:00Z' }, now)]);
  out.push(['keep-closed-inside', keepFetchedPr({ state: 'CLOSED', closed_at: '2026-09-16T11:00:00Z' }, now)]);
  out.push(['keep-closed-nostamp', keepFetchedPr({ state: 'CLOSED' }, now)]);
  out.push(['keep-merged-future', keepFetchedPr({ state: 'MERGED', merged_at: '2026-09-16T13:00:00Z' }, now)]);
  const need = ['number', 'title', 'url', 'headRefName', 'baseRefName', 'reviewDecision', 'mergeable', 'isDraft', 'state', 'createdAt', 'mergedAt', 'closedAt', 'author { login }', 'repository { nameWithOwner }', 'labels(first: 30)', 'latestReviews(first: 30)', 'commits(last: 1)', 'statusCheckRollup', '... on CheckRun { name status conclusion startedAt completedAt checkSuite { app { name } workflowRun { workflow { name } } } }', '... on StatusContext { context state createdAt }'];
  out.push(['fields', need.filter((f) => !GH_PR_FIELDS.includes(f)).join(',') || 'complete']);
  const tasks = [
    { kind: 'ship', pr: { url: 'https://github.com/acme/widgets/pull/41' }, paths: { worktree: { path: '$WT_DIR' } } },
    { kind: 'secondmate', pr: { url: 'https://github.com/acme/etl/pull/12' }, paths: { worktree: { path: '$WT_SM_DIR' } } },
    { kind: 'ship', pr: { url: 'https://github.com/acme/widgets/pull/30' }, paths: { worktree: { path: '/nonexistent/worktree' } } },
  ];
  const repos = await candidateRepos({ tasks }, { timeoutMs: 10000 });
  out.push(['repos', repos.join(' ')]);
  const many = { tasks: Array.from({ length: 12 }, (_, i) => ({ kind: 'ship', pr: { url: 'https://github.com/acme/r' + i + '/pull/1' } })) };
  out.push(['cap', (await candidateRepos(many, { timeoutMs: 10000 })).join(' ')]);
  const config = { review: { default_labels: [], repos: { 'example-corp/portal': { labels: ['ready-to-merge'] }, 'acme/etl': { labels: [] } } } };
  out.push(['scope', reviewScope(repos, config).join(' ')]);
  out.push(['scope-case', reviewScope(['Acme/Widgets', 'acme/widgets'], { review: { repos: { 'ACME/widgets': {} } } }).join(' ')]);
  out.push(['in-scope', [inScope(['example-corp/portal'], 'Example-Corp/Portal'), inScope(['acme/api'], 'acme/etl')].join(' ')]);
  out.push(['since', closedSince(now)]);
  const s = searchQueries('captain', { now, scope: ['acme/widgets', 'example-corp/portal'] });
  out.push(['q-mine-open', s.mine.open]);
  out.push(['q-mine-tail', s.mine.tail]);
  out.push(['q-review-open', s.toreview.open]);
  out.push(['q-review-tail', s.toreview.tail]);
  const wide = searchQueries('captain', { now, scope: Array.from({ length: 12 }, (_, i) => 'organisation-name/repository-' + i) });
  out.push(['q-review-wide', wide.toreview.open.includes('repo:') ? 'repo terms' : 'no repo terms']);
  out.push(['q-review-wide-len', String(wide.toreview.open.length <= SEARCH_QUERY_MAX)]);
  const lookup = lookupGraphql([{ owner: 'acme', name: 'api', number: 7 }, { owner: 'acme', name: 'widgets', number: 30 }]);
  out.push(['lookup', [lookup.includes('r0: repository(owner: \"acme\", name: \"api\") { pullRequest(number: 7)'), lookup.includes('r1: repository(owner: \"acme\", name: \"widgets\") { pullRequest(number: 30)'), lookup.includes('latestReviews')].join(' ')]);
  process.stdout.write(out.map(([k, v]) => k + '=' + v).join('\n'));
") || fail "sources unit checks: node exited non-zero: $unit_out"
for expected in "none=none" "none-null=none" "passing=passing" "passing-state=passing" "pending=pending" "failing=failing" "failing-state=failing" \
  "superseded=passing" "cancelled-only=failing" "cancelled-newest=failing" "rerun-running=pending" "other-running=pending" \
  "two-workflows=failing" "status-context-updated=passing" "gh-json-superseded=passing" "gh-json-two-workflows=failing" \
  "nameless-mixed=failing" "position-only=failing" \
  "slug-pull=acme/widgets" "slug-ssh=acme/widgets" "slug-other=null" \
  "project=41 acme/widgets ship-alpha REVIEW_REQUIRED MERGEABLE passing 2026-09-16T09:00:00Z Add the widget cache main true OPEN null null" \
  "project-extra=null 0 false null mine" \
  "project-defaults=- none UNKNOWN none null null null false null null" \
  "project-merged=MERGED 2026-09-16T11:30:00Z 2026-09-16T11:30:00Z" \
  "project-node=example-corp/portal 120 - teammate ready-to-merge+backend failing Portal: index" \
  "project-node-nochecks=none" \
  "my-review=APPROVED" "my-review-comment=null" "my-review-none=null" "my-review-changes=CHANGES_REQUESTED" \
  "keep-open=true" "keep-no-state=true" "keep-merged-inside=true" "keep-merged-outside=false" "keep-merged-exact=false" \
  "keep-merged-closed-only=true" "keep-closed-inside=true" "keep-closed-nostamp=false" "keep-merged-future=true" \
  "fields=complete" \
  "repos=acme/widgets acme/etl acme/wt" \
  "cap=acme/r0 acme/r1 acme/r2 acme/r3 acme/r4 acme/r5 acme/r6 acme/r7 acme/r8 acme/r9" \
  "scope=acme/widgets acme/etl acme/wt example-corp/portal" "scope-case=Acme/Widgets" "in-scope=true false" \
  "since=2026-09-16T00:00:00+00:00" \
  "q-mine-open=is:pr is:open author:captain sort:updated-desc" \
  "q-mine-tail=is:pr author:captain closed:>=2026-09-16T00:00:00+00:00 sort:updated-desc" \
  "q-review-open=is:pr is:open review-requested:captain -author:captain repo:acme/widgets repo:example-corp/portal sort:updated-desc" \
  "q-review-tail=is:pr review-requested:captain -author:captain closed:>=2026-09-16T00:00:00+00:00 repo:acme/widgets repo:example-corp/portal sort:updated-desc" \
  "q-review-wide=no repo terms" "q-review-wide-len=true" \
  "lookup=true true true"; do
  if printf '%s\n' "$unit_out" | grep -Fxq -- "$expected"; then pass; else fail "sources: expected line '$expected' in: $unit_out"; fi
done

# fm-bearings-snapshot.sh's rows through the board's own projection (lib/sources.mjs projectScriptPr,
# what runBearingsPrs maps every candidate_prs row through): a row carrying only the script's checks
# word keeps it, since the board has nothing else to judge; a row carrying the contexts themselves
# (gh's statusCheckRollup list, or contexts bare or as { nodes }) is judged by checksState's
# newest-run rule and the word is ignored, so a cancelled run a re-run superseded reads passing there
# and a cancelled run that is the newest reads failing; an unknown or missing word reads none; the
# script's fields come through with title, base and creation time null, so the row falls back to the
# recorded title and the status-log age as the fallback rows always have; and the pane is always mine
# (falsify: spread the row as it is in runBearingsPrs, read the word when a list is there, or judge
# every run of the list).
script_out=$(node --input-type=module -e "
  import { projectScriptPr } from '$ROOT/bin/firstmate-tui/lib/sources.mjs';
  const out = [];
  const run = (name, wf, conclusion, s, c) => ({ __typename: 'CheckRun', name, workflowName: wf, status: 'COMPLETED', conclusion, startedAt: s, completedAt: c });
  const cancelled = run('hive', 'Schema', 'CANCELLED', '2026-09-18T19:38:34Z', '2026-09-18T19:38:39Z');
  const superseded = [cancelled, run('merge check', 'CI', 'SUCCESS', '2026-09-18T19:32:55Z', '2026-09-18T19:33:00Z'), run('hive', 'Schema', 'SUCCESS', '2026-09-18T19:42:10Z', '2026-09-18T19:42:16Z')];
  const word = projectScriptPr({ num: '41', repo: 'acme/widgets', task: 'ship-alpha', url: 'https://github.com/acme/widgets/pull/41', review: 'REVIEW_REQUIRED', mergeable: 'MERGEABLE', checks: 'failing' });
  out.push(['word', [word.num, word.repo, word.task, word.url, word.review, word.mergeable, word.checks, word.title, word.base, word.created_at, word.state, word.pane].map(String).join(' ')]);
  out.push(['list', projectScriptPr({ num: '6148', repo: 'example-corp/portal', task: '-', url: 'https://github.com/example-corp/portal/pull/6148', review: 'REVIEW_REQUIRED', mergeable: 'MERGEABLE', checks: 'failing', statusCheckRollup: superseded }).checks]);
  out.push(['list-cancelled-newest', projectScriptPr({ num: '1', repo: 'a/b', url: 'https://github.com/a/b/pull/1', checks: 'passing', statusCheckRollup: [superseded[2], { ...cancelled, startedAt: '2026-09-18T19:50:00Z', completedAt: '2026-09-18T19:50:05Z' }] }).checks]);
  out.push(['contexts-bare', projectScriptPr({ num: '2', repo: 'a/b', url: 'https://github.com/a/b/pull/2', checks: 'passing', contexts: [run('x', 'W', 'FAILURE', '2026-01-01T00:00:00Z', '2026-01-01T00:01:00Z')] }).checks]);
  out.push(['contexts-nodes', projectScriptPr({ num: '3', repo: 'a/b', url: 'https://github.com/a/b/pull/3', checks: 'failing', contexts: { nodes: [] } }).checks]);
  out.push(['unknown-word', projectScriptPr({ num: '4', repo: 'a/b', url: 'https://github.com/a/b/pull/4', checks: 'Green' }).checks]);
  out.push(['no-word', projectScriptPr({ num: '5', repo: 'a/b', url: 'https://github.com/a/b/pull/5' }).checks]);
  const empty = projectScriptPr({});
  out.push(['empty', [empty.num, empty.repo, empty.task, empty.url, empty.review, empty.mergeable, empty.checks].join(' ')]);
  out.push(['repo-from-url', projectScriptPr({ num: '6', url: 'https://github.com/acme/api/pull/6', checks: 'pending' }).repo]);
  out.push(['pane', projectScriptPr({ num: '7', repo: 'a/b', url: 'https://github.com/a/b/pull/7', checks: 'pending', pane: 'toreview' }).pane]);
  process.stdout.write(out.map(([k, v]) => k + '=' + v).join('\n'));
") || fail "script projection checks: node exited non-zero: $script_out"
for expected in "word=41 acme/widgets ship-alpha https://github.com/acme/widgets/pull/41 REVIEW_REQUIRED MERGEABLE failing null null null null mine" \
  "list=passing" "list-cancelled-newest=failing" "contexts-bare=failing" "contexts-nodes=none" "unknown-word=none" "no-word=none" \
  "empty=- - - - none UNKNOWN none" "repo-from-url=acme/api" "pane=mine"; do
  if printf '%s\n' "$script_out" | grep -Fxq -- "$expected"; then pass; else fail "script projection: expected line '$expected' in: $script_out"; fi
done

# The config file's pure pieces (lib/config.mjs): the example is byte for byte docs/config.example.json,
# a malformed or mistyped file gives the defaults with a reason, unknown keys are ignored, and the
# label rule reads a repository's own entry before the default (an empty own list is unfiltered),
# matching the repository name without case as GitHub does (falsify: change EXAMPLE_CONFIG, accept a
# non-list default_labels, apply default_labels to a repository with its own entry, or compare the
# names with case). prs.source takes "board" or "firstmate" and nothing else: an absent prs, an empty
# one and the example all read board, the example (which spells it out) as configured, the others
# not; a bad value or a prs that is not an object is a malformed field naming the key and the allowed
# values, and gives the defaults as a whole. prSourceInEffect is the one rule for which source a
# fetch uses: firstmate in the file wins whatever PATH holds, board is the board's own fetch with gh
# and the script without, the reason then naming gh (falsify: accept a third value, read a
# configured flag for an absent key, or let a missing gh override a configured firstmate's reason).
config_out=$(node --input-type=module -e "
  import { exampleConfigText, parseConfig, labelsFor, passesLabelRule, configuredRepos, resolveConfigPath, defaultConfigPath, defaultConfig, prSource, prSourceInEffect } from '$ROOT/bin/firstmate-tui/lib/config.mjs';
  import { readFileSync } from 'node:fs';
  const out = [];
  out.push(['example', exampleConfigText() === readFileSync('$ROOT/docs/config.example.json', 'utf8')]);
  const ex = parseConfig(exampleConfigText());
  out.push(['example-parse', [String(ex.error), String(ex.config.identity.github_login), ex.config.review.default_labels.length, configuredRepos(ex.config).join(','), labelsFor(ex.config, 'example-corp/portal').join(',')].join(' ')]);
  const prs = (text) => { const p = parseConfig(text); return [String(p.error), p.config.prs.source, p.config.prs.configured, prSource(p.config)].join(' '); };
  out.push(['prs-example', prs(exampleConfigText())]);
  out.push(['prs-absent', prs('{\"schema\":\"firstmate-tui-config.v1\"}')]);
  out.push(['prs-empty', prs('{\"prs\":{}}')]);
  out.push(['prs-board', prs('{\"prs\":{\"source\":\"board\"}}')]);
  out.push(['prs-firstmate', prs('{\"prs\":{\"source\":\"firstmate\"}}')]);
  out.push(['prs-bad', prs('{\"identity\":{\"github_login\":\"kept\"},\"prs\":{\"source\":\"github\"}}')]);
  out.push(['prs-bad-login', String(parseConfig('{\"identity\":{\"github_login\":\"kept\"},\"prs\":{\"source\":\"github\"}}').config.identity.github_login)]);
  out.push(['prs-null', prs('{\"prs\":{\"source\":null}}')]);
  out.push(['prs-not-object', prs('{\"prs\":\"firstmate\"}')]);
  out.push(['prs-default', [defaultConfig().prs.source, defaultConfig().prs.configured, prSource(null)].join(' ')]);
  const effect = (text, gh) => { const e = prSourceInEffect(parseConfig(text).config, gh); return e.kind + ' ' + e.reason; };
  out.push(['effect-absent-gh', effect('{}', true)]);
  out.push(['effect-absent-nogh', effect('{}', false)]);
  out.push(['effect-board-gh', effect('{\"prs\":{\"source\":\"board\"}}', true)]);
  out.push(['effect-board-nogh', effect('{\"prs\":{\"source\":\"board\"}}', false)]);
  out.push(['effect-firstmate-gh', effect('{\"prs\":{\"source\":\"firstmate\"}}', true)]);
  out.push(['effect-firstmate-nogh', effect('{\"prs\":{\"source\":\"firstmate\"}}', false)]);
  out.push(['effect-bad-gh', effect('{\"prs\":{\"source\":\"github\"}}', true)]);
  // Node's JSON.parse message differs between versions (20 stops at the position, 26 adds the line
  // and column), so only the board's own prefix is pinned.
  out.push(['bad-json', String(parseConfig('{').error).startsWith('bad JSON (') ? 'bad JSON (...)' : String(parseConfig('{').error)]);
  out.push(['not-object', parseConfig('[1]').error]);
  out.push(['schema', parseConfig('{\"schema\":\"other.v9\"}').error]);
  out.push(['login-type', parseConfig('{\"identity\":{\"github_login\":7}}').error]);
  out.push(['labels-type', parseConfig('{\"review\":{\"default_labels\":\"ready\"}}').error]);
  out.push(['repo-name', parseConfig('{\"review\":{\"repos\":{\"portal\":{}}}}').error]);
  const c = parseConfig('{\"schema\":\"firstmate-tui-config.v1\",\"identity\":{\"github_login\":\" zachsibert \"},\"review\":{\"default_labels\":[\"ready\",\"\"],\"repos\":{\"a/b\":{\"labels\":[\"x\"]},\"c/d\":{},\"e/f\":{\"labels\":[]}}},\"extra\":1}').config;
  out.push(['parsed', [c.identity.github_login, c.review.default_labels.join(','), configuredRepos(c).join(',')].join(' ')]);
  out.push(['labels-own', labelsFor(c, 'a/b').join(',')]);
  out.push(['labels-own-empty', String(labelsFor(c, 'c/d').length) + ' ' + String(labelsFor(c, 'e/f').length)]);
  out.push(['labels-default', labelsFor(c, 'other/repo').join(',')]);
  out.push(['labels-case', labelsFor(c, 'A/B').join(',')]);
  out.push(['rule', [passesLabelRule(c, 'a/b', ['x', 'y']), passesLabelRule(c, 'a/b', ['y']), passesLabelRule(c, 'c/d', []), passesLabelRule(c, 'other/repo', ['ready']), passesLabelRule(c, 'other/repo', [])].join(' ')]);
  const env = { HOME: '/home/cap', XDG_CONFIG_HOME: '/xdg' };
  out.push(['path-xdg', defaultConfigPath(env)]);
  out.push(['path-home', defaultConfigPath({ HOME: '/home/cap' })]);
  out.push(['path-none', String(defaultConfigPath({}))]);
  out.push(['path-explicit', resolveConfigPath({ explicit: '/x/config.json', fmHome: '/fm', env }).path]);
  const refused = resolveConfigPath({ explicit: '/fm/state/config.json', fmHome: '/fm', env });
  out.push(['path-refused', refused.path + ' ' + refused.problem]);
  process.stdout.write(out.map(([k, v]) => k + '=' + v).join('\n'));
") || fail "config unit checks: node exited non-zero: $config_out"
for expected in "example=true" \
  "example-parse=null null 0 example-corp/portal ready-to-merge" \
  "prs-example=null board true board" "prs-absent=null board false board" "prs-empty=null board false board" \
  "prs-board=null board true board" "prs-firstmate=null firstmate true firstmate" \
  'prs-bad=prs.source is not "board" or "firstmate" (got "github") board false board' "prs-bad-login=null" \
  'prs-null=prs.source is not "board" or "firstmate" (got null) board false board' \
  "prs-not-object=prs is not an object board false board" "prs-default=board false board" \
  "effect-absent-gh=board default" "effect-absent-nogh=firstmate gh-missing" \
  "effect-board-gh=board config" "effect-board-nogh=firstmate gh-missing" \
  "effect-firstmate-gh=firstmate config" "effect-firstmate-nogh=firstmate config" "effect-bad-gh=board default" \
  "bad-json=bad JSON (...)" \
  "not-object=not an object" "schema=unexpected schema other.v9" "login-type=identity.github_login is not a string" \
  "labels-type=review.default_labels is not a list" 'repo-name=review.repos: "portal" is not owner/name' \
  "parsed=zachsibert ready a/b,c/d,e/f" "labels-own=x" "labels-own-empty=0 0" "labels-default=ready" "labels-case=x" \
  "rule=true false true true false" \
  "path-xdg=/xdg/fm-board/config.json" "path-home=/home/cap/.config/fm-board/config.json" "path-none=null" \
  "path-explicit=/x/config.json" "path-refused=/xdg/fm-board/config.json refusing --config inside FM_HOME (/fm/state/config.json)"; do
  if printf '%s\n' "$config_out" | grep -Fxq -- "$expected"; then pass; else fail "config: expected line '$expected' in: $config_out"; fi
done

# The identity's pure pieces (lib/identity.mjs): the config login first, then gh, then git, never a
# name or an email; an unknown identity names each rung's failure (falsify: reorder the rungs in
# resolveIdentity, accept an email in validLogin, or drop a rung from the reason).
identity_out=$(node --input-type=module -e "
  import { resolveIdentity, validLogin, describeIdentity } from '$ROOT/bin/firstmate-tui/lib/identity.mjs';
  const out = [];
  const show = (k, r) => out.push([k, [String(r.login), r.source, String(r.reason)].join(' | ')]);
  show('config-first', resolveIdentity({ config: 'zachsibert', gh: { value: 'other', error: null }, git: { value: 'third', error: null } }));
  show('gh-second', resolveIdentity({ config: null, gh: { value: 'ghuser', error: null }, git: { value: 'third', error: null } }));
  show('git-third', resolveIdentity({ config: null, gh: { value: null, error: 'exit 1: not logged in' }, git: { value: 'gituser', error: null } }));
  show('gh-not-asked', resolveIdentity({ config: null, gh: null, git: { value: 'gituser', error: null } }));
  show('none', resolveIdentity({ config: null, gh: { value: null, error: 'exit 1: not logged in' }, git: { value: null, error: 'github.user not set' } }));
  show('junk', resolveIdentity({ config: 'Zach Sibert', gh: { value: 'zach@example.com', error: null }, git: { value: '', error: null } }));
  out.push(['valid', [validLogin('zachsibert'), validLogin('a-b-c'), String(validLogin('-a')), String(validLogin('a--b')), String(validLogin('zach@example.com')), String(validLogin('x'.repeat(40)))].join(' ')]);
  out.push(['describe-known', describeIdentity({ login: 'captain', source: 'gh' }, '/cfg/config.json')]);
  out.push(['describe-unknown', describeIdentity({ login: null, source: 'unknown', reason: 'x' }, '/cfg/config.json')]);
  out.push(['describe-nopath', describeIdentity({ login: null, source: 'unknown', reason: 'x' }, null)]);
  process.stdout.write(out.map(([k, v]) => k + '=' + v).join('\n'));
") || fail "identity unit checks: node exited non-zero: $identity_out"
for expected in "config-first=zachsibert | config | null" "gh-second=ghuser | gh | null" "git-third=gituser | git | null" "gh-not-asked=gituser | git | null" \
  "none=null | unknown | config: identity.github_login not set; gh: exit 1: not logged in; git: github.user not set" \
  'junk=null | unknown | config: "Zach Sibert" is not a GitHub login; gh: "zach@example.com" is not a GitHub login; git: github.user not set' \
  "valid=zachsibert a-b-c null null null null" \
  "describe-known=captain  (from gh api user)" \
  "describe-unknown=identity unknown: set identity.github_login in /cfg/config.json, or run gh auth login" \
  "describe-nopath=identity unknown: set identity.github_login in the config file, or run gh auth login"; do
  if printf '%s\n' "$identity_out" | grep -Fxq -- "$expected"; then pass; else fail "identity: expected line '$expected' in: $identity_out"; fi
done

# --------------------------------------------------------------- r refresh
# r is the same refresh a timer tick runs: the fleet snapshot, then the PR fetch for the resolved
# identity. The board asks GitHub itself through gh api graphql: the start-up render resolves the
# identity once (`gh api user`, since the example config written to XDG_CONFIG_HOME names no login)
# and then runs the four searches, all together, plus one lookup of the recorded PRs the author
# searches did not return (ship-alpha's #41, ship-gamma's #7, then done ship-old's #30); r adds a
# second set of searches and lookups and no second identity call. The Teammates' PRs searches carry
# the scope as repo: qualifiers: the three candidate repositories of the stand-in snapshot and
# example-corp/portal from the config file, which no fleet task touches. The stand-in's
# fm-bearings-snapshot.sh must not run at all, and no `pr list` may be issued, since the fake fails
# on it (falsify: keep runBearingsPrs as the default source, drop a search from runGhPrs, drop the
# configured repositories from reviewScope, resolve the identity on every tick, or drop fetchPrs
# from refreshLive).
q_mine_open='gh api graphql q=is:pr is:open author:captain sort:updated-desc'
q_mine_tail='gh api graphql q=is:pr author:captain closed:>=<since> sort:updated-desc'
q_review_open='gh api graphql q=is:pr is:open review-requested:captain -author:captain repo:acme/widgets repo:acme/api repo:acme/etl repo:example-corp/portal sort:updated-desc'
q_review_tail='gh api graphql q=is:pr review-requested:captain -author:captain closed:>=<since> repo:acme/widgets repo:acme/api repo:acme/etl repo:example-corp/portal sort:updated-desc'
q_lookup='gh api graphql lookup=acme/widgets#41,acme/api#7,acme/widgets#30'
expected_live="snapshot
gh api user --jq .login
$q_mine_open
$q_mine_tail
$q_review_open
$q_review_tail
$q_lookup
snapshot
$q_mine_open
$q_mine_tail
$q_review_open
$q_review_tail
$q_lookup"
frame_r=$(render_live --keys "r" --cols 160 --rows 60) || fail "refresh default: render exited non-zero"
assert_fetch_log "$expected_live" "r by default runs the snapshot, then the four searches and the lookup for the identity gh named, never the firstmate PR script and never pr list (falsify: flip the prs default in parseArgs, or call runBearingsPrs with gh on PATH)"
assert_contains "$frame_r" "refreshed: snapshot and PR checks" "r reports the refresh"
if [ -f "$SCRATCH/xdg/fm-board/config.json" ]; then pass; else fail "the first live render wrote the example config to \$XDG_CONFIG_HOME/fm-board/config.json (falsify: drop writeExampleConfig from loadOrCreateConfig)"; fi
# The rows come from the fake gh's answers (tests/fake-gh.sh names them). My PRs: the identity's own
# open PR in a repository no task touches, its own PR that asked its team for a review, the
# bot-authored PR recorded on ship-alpha (through the lookup), ship-gamma's recorded PR the lookup
# answered null (unlisted, and with no status file on this host no age to fall back to), the PR
# merged at run time inside the window; the PR closed in 2020 is dropped by the fetch; and the
# stand-in for example-corp/portal#6148, whose head commit carries six runs of one check with one
# cancelled and re-run, a BLOCKED merge state and a review required: CHECKS passing and STATUS IN
# REVIEW, the case Zach saw read failing. Teammates' PRs: the labelled portal PR and not the
# unlabelled one, the acme/api PR with no label rule (checks failing), the request through the
# identity's team (the same six-run rollup and BLOCKED state), the PR the identity approved (STATUS
# APPROVED), the PR merged at run time after that approval, and never the identity's own PR (falsify:
# drop the lookup from runGhPrs, the label rule or the author check from the Teammates' PRs filter,
# myReview from ghSearch, or judge every run in checksState).
assert_contains "$frame_r" "My PRs (6)" "live: My PRs counts its six rows"
assert_row "$frame_r" '^│ passing +IN REVIEW +dotfiles#5 +Tidy the zsh prompt +main +[0-9]+d │$' "live: the identity's own PR outside the candidate repositories is in My PRs (the author search, not the repositories, is the scope)"
assert_row "$frame_r" '^│ pending +IN REVIEW +api#12 +Retry budget: ask the API team +main +[0-9]+d │$' "live: the identity's own PR that asked its team is in My PRs"
assert_row "$frame_r" '^│ passing +IN REVIEW +portal#6148 +Hide the Primary Sub Type row behind a feature flag +main +[0-9]+d │$' "live: PR 6148's shape reads CHECKS passing and STATUS IN REVIEW: the cancelled run a re-run superseded does not count, and BLOCKED with a review required is a review to give, not a failure (falsify: judge every run in checksState, or read BLOCKED into prStatus)"
assert_not_contains "$frame_r" "failing   IN REVIEW  portal#6148" "live: the 6148 stand-in never reads failing"
assert_row "$frame_r" '^│ passing +IN REVIEW +ship-alpha +Add the widget cache +main +[0-9]+d │$' "live: the bot-authored PR recorded on ship-alpha is in My PRs through the lookup, under the task id"
assert_row "$frame_r" '^│ unlisted +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: not fetched +- +- │$' "live: a recorded PR the lookup answered null stays unlisted"
assert_row "$frame_r" '^│ passing +MERGED +api#9 +Bump the retry budget +main +[0-9]+d │$' "live: the identity's PR merged just now is listed as MERGED"
assert_no_row "$frame_r" 'api#10|Old spike' "live: a PR closed in 2020 is outside the 12-hour window and dropped by the fetch"
assert_no_row "$frame_r" '^│ (passing|failing|pending|none|unlisted|PR) +[^│]*(Rename the widget table|widgets#30)' "live: ship-old's PR merged in 2020 is dropped by the window although the lookup returned it (its Recently Landed and Underway rows stay)"
assert_before "$frame_r" '^│ pending +IN REVIEW +api#12' '^│ passing +MERGED +api#9' "live: MERGED sorts after the open PRs"
assert_contains "$frame_r" "Teammates' PRs (5)" "live: Teammates' PRs counts its five rows"
assert_row "$frame_r" '^│ passing +IN REVIEW +portal#120 +teammate +Portal: index the parcel table +main +[0-9]+d │$' "live: the portal PR with the ready-to-merge label is in Teammates' PRs (a configured repository searched with no fleet work in it), its author from the GraphQL node under AUTHOR"
assert_no_row "$frame_r" 'portal#121|still cooking' "live: the portal PR without the label is dropped by the label rule"
assert_row "$frame_r" '^│ failing +IN REVIEW +api#8 +teammate +Retry on 429 +main +[0-9]+d │$' "live: a PR in a candidate repository with no label rule is in Teammates' PRs, its FAILURE conclusion mapped to failing"
assert_row "$frame_r" '^│ passing +IN REVIEW +etl#15 +teammate +ETL: nightly loader for the team +main +[0-9]+d │$' "live: a request to the identity's team is in Teammates' PRs, and with PR 6148's rollup and a BLOCKED merge state it reads passing and IN REVIEW there too"
assert_row "$frame_r" '^│ passing +APPROVED +widgets#45 +teammate +Widget: approved by captain +main +[0-9]+d │$' "live: a PR the identity already approved reads APPROVED"
assert_row "$frame_r" '^│ passing +MERGED +etl#14 +teammate +ETL: merged after review +main +[0-9]+d │$' "live: a reviewed PR merged just now is in Teammates' PRs as MERGED"
assert_count "$frame_r" "Retry budget: ask the API team" 1 "live: the identity's own PR that asked its team is in My PRs only, never in Teammates' PRs"
assert_before "$frame_r" "My PRs \(6\)" "Teammates' PRs \(5\)" "live: Teammates' PRs is drawn right below My PRs"
assert_before "$frame_r" "Underway \(" "My PRs \(6\)" "live: Underway leads the two PR panes"
frame_r=$(render_live --keys "r" --prs --rows 60) || fail "refresh --prs: render exited non-zero"
assert_fetch_log "$expected_live" "--prs is a no-op: the same calls (falsify: make --prs disable or double the fetch)"
# --no-prs: no gh call at all, not even for the identity; both panes read the off state (falsify:
# call fetchPrs or ghLogin unconditionally, or drop the toreview off text from prPaneEmpty).
frame_r=$(render_live --keys "r" --no-prs --rows 60) || fail "refresh --no-prs: render exited non-zero"
assert_fetch_log "snapshot
snapshot" "r with --no-prs runs only the snapshot again and logs no gh call"
assert_contains "$frame_r" "PR checks off: start without --no-prs" "r with --no-prs says why the PR panes did not change (falsify: drop the notice)"
assert_not_contains "$frame_r" "fetching" "--no-prs: nothing reads fetching after r"
assert_row "$frame_r" '^│ PR +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: off \(--no-prs\) +- +- │$' "--no-prs: My PRs lists the recorded PRs with the off note"
assert_row "$frame_r" '^│ PR fetch off \(--no-prs\) +│$' "--no-prs: Teammates' PRs reads the off text"
assert_not_contains "$frame_r" "identity unknown" "--no-prs: no identity row, since nothing needs the login"
# Without gh on PATH the firstmate script is the fallback for My PRs and Teammates' PRs says why it has
# nothing. The board runs here as node index.mjs under a PATH holding only node, bash and cat (the
# stand-in scripts need the last two), so the PATH lookup finds no gh (falsify: drop the whichOnPath
# check in fetchPrs, and the gh spawn fails instead of the script running; or drop the note from
# fetchPrs, or the unavailable text from prPaneEmpty).
NOGH_BIN="$SCRATCH/nogh"
mkdir -p "$NOGH_BIN"
ln -s "$(command -v node)" "$NOGH_BIN/node"
ln -s "$(command -v bash)" "$NOGH_BIN/bash"
ln -s "$(command -v cat)" "$NOGH_BIN/cat"
rm -f "${FETCH_LOG:?}"
frame_r=$(FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" PATH="$NOGH_BIN" "$NOGH_BIN/node" "$ROOT/bin/firstmate-tui/index.mjs" --render-once --no-herdr --keys "r" --rows 60) || fail "refresh without gh: render exited non-zero"
assert_fetch_log "prs --json --include-prs
prs --json --include-prs
snapshot
snapshot" "without gh on PATH, r runs the snapshot and fm-bearings-snapshot.sh --include-prs, and no gh (falsify: spawn gh without the PATH check)"
assert_contains "$frame_r" "gh not on PATH: PR data from fm-bearings-snapshot.sh" "without gh the footer names the fallback (falsify: drop the note)"
assert_row "$frame_r" "^│ gh not on PATH: Teammates' PRs needs the GitHub CLI +│\$" "without gh Teammates' PRs says what it needs"
assert_row "$frame_r" '^│ unlisted +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: not fetched +- +- │$' "without gh My PRs still lists the recorded PRs (the script fallback needs no login)"
assert_not_contains "$frame_r" "identity unknown" "without gh no identity row: the fallback lists recorded PRs whoever the captain is"
# The script's rows (tests/fixtures/bearings-prs.json) through the board's projection: a row with only
# the script's checks word keeps it, under the recorded task's title, BASE - and no PR age (no status
# file on this host, so the stand-in age is -); a row carrying the head commit's contexts is judged by
# the board's newest-run rule, so PR 6148's superseded cancelled run reads passing although the
# script's own word says failing (falsify: spread the row as it is in runBearingsPrs, or prefer the
# word over the list in projectScriptPr).
assert_row "$frame_r" '^│ failing +IN REVIEW +ship-alpha +Add the widget cache +- +- │$' "without gh a script row with only its checks word keeps the word, with the recorded title and BASE -"
assert_row "$frame_r" '^│ passing +IN REVIEW +portal#6148 +https://github.com/example-corp/portal/pull/6148 +- +- │$' "without gh a script row carrying its contexts reads passing through the board's rule, not the script's failing"
assert_no_row "$frame_r" '^│ failing +[^│]*portal#6148' "without gh the 6148 row never reads failing"
# The Settings page under the same PATH: the PR source line reads what the fetch used, firstmate
# because gh is missing, although this config (the example) says board, and says both sources fail
# alike without gh (falsify: build the line from the config alone).
frame_r=$(FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" PATH="$NOGH_BIN" "$NOGH_BIN/node" "$ROOT/bin/firstmate-tui/index.mjs" --render-once --no-herdr --install-root "$SCRATCH/nowhere" --keys "." --rows 60 --cols 200) || fail "settings without gh: render exited non-zero"
assert_row "$frame_r" '^ PR source +firstmate: fm-bearings-snapshot.sh \(gh not on PATH; the script needs gh too, so both sources fail the same way\) +$' "Settings: without gh the PR source line reads firstmate for the missing gh, whatever the file says"
# prs.source = firstmate in the config file: the script runs although the fake gh is first on PATH, no
# search is issued, the identity is still resolved once (gh api user, as on the board source), the
# footer names the config as the reason once, Teammates' PRs says it needs the board's own fetch, and
# My PRs lists the script's canned rows with their checks words and the stand-in age. prs.source =
# board spelled out, and a file without the key, make exactly the default's calls; the Settings line
# tells the two apart. --no-prs is off whatever the file says (falsify: test gh on PATH before the
# config in fetchPrs, drop the config reason from SCRIPT_NOTES or SCRIPT_CONFIGURED from prPaneEmpty,
# or build the Settings line without the configured flag).
render_source() { # <xdg dir> [flags]: a live render with the fake gh first on PATH and its own config directory
  rm -f "${FETCH_LOG:?}"
  FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$1" PATH="$FAKE_BIN:$PATH" "$BOARD" --render-once --no-herdr --rows 60 "${@:2}"
}
mkdir -p "$SCRATCH/src-firstmate/fm-board" "$SCRATCH/src-board/fm-board" "$SCRATCH/src-unset/fm-board" "$SCRATCH/src-bad/fm-board"
src_review='"review":{"default_labels":[],"repos":{"example-corp/portal":{"labels":["ready-to-merge"]}}}'
printf '{"schema":"firstmate-tui-config.v1","identity":{"github_login":null},%s,"prs":{"source":"firstmate"}}\n' "$src_review" > "$SCRATCH/src-firstmate/fm-board/config.json"
printf '{"schema":"firstmate-tui-config.v1","identity":{"github_login":null},%s,"prs":{"source":"board"}}\n' "$src_review" > "$SCRATCH/src-board/fm-board/config.json"
printf '{"schema":"firstmate-tui-config.v1","identity":{"github_login":null},%s}\n' "$src_review" > "$SCRATCH/src-unset/fm-board/config.json"
printf '{"schema":"firstmate-tui-config.v1","identity":{"github_login":null},%s,"prs":{"source":"github"}}\n' "$src_review" > "$SCRATCH/src-bad/fm-board/config.json"
frame_r=$(render_source "$SCRATCH/src-firstmate" --keys "r" --cols 260) || fail "source firstmate: render exited non-zero"
assert_fetch_log "snapshot
gh api user --jq .login
prs --json --include-prs
snapshot
prs --json --include-prs" "prs.source firstmate: the start and r each run the snapshot and fm-bearings-snapshot.sh --include-prs, the identity is asked once, and no gh graphql search runs although gh is on PATH"
assert_contains "$frame_r" "PR data from fm-bearings-snapshot.sh (config prs.source = firstmate): open PRs only, without titles, base branches or PR creation times; Teammates' PRs needs the board's own fetch" "prs.source firstmate: the footer names the config as the reason and what the script cannot give"
assert_count "$frame_r" "PR data from fm-bearings-snapshot.sh" 1 "prs.source firstmate: the note is shown once"
assert_not_contains "$frame_r" "gh not on PATH" "prs.source firstmate: with gh on PATH nothing blames a missing gh"
assert_row "$frame_r" "^│ config prs.source = firstmate: Teammates' PRs needs the board's own fetch +│\$" "prs.source firstmate: Teammates' PRs says it needs the board's own fetch"
assert_row "$frame_r" '^│ failing +IN REVIEW +ship-alpha +Add the widget cache +- +- │$' "prs.source firstmate: the script's word-only row keeps its failing word under the recorded title, BASE - and the stand-in age"
assert_row "$frame_r" '^│ passing +APPROVED +etl#77 +https://github.com/acme/etl/pull/77 +- +- │$' "prs.source firstmate: a script row on no task reads repo#number and its URL, APPROVED from the review decision alone"
assert_row "$frame_r" '^│ passing +IN REVIEW +portal#6148 +https://github.com/example-corp/portal/pull/6148 +- +- │$' "prs.source firstmate: the row carrying its contexts reads passing through the board's newest-run rule"
assert_row "$frame_r" '^│ unlisted +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: not fetched +- +- │$' "prs.source firstmate: a recorded PR the script did not list stays unlisted"
assert_contains "$frame_r" "My PRs (4)" "prs.source firstmate: My PRs counts the three script rows and the unlisted recorded PR"
assert_not_contains "$frame_r" "dotfiles#5" "prs.source firstmate: none of the fake gh's search answers is listed, since no search ran"
assert_not_contains "$frame_r" "identity unknown" "prs.source firstmate: no identity row, the script needs no login"
frame_r=$(render_source "$SCRATCH/src-firstmate" --install-root "$SCRATCH/nowhere" --keys ".") || fail "source firstmate settings: render exited non-zero"
assert_row "$frame_r" '^ PR source +firstmate: fm-bearings-snapshot.sh \(config prs.source\) +$' "Settings: prs.source firstmate reads on the PR source line with the config as the reason"
frame_r=$(render_source "$SCRATCH/src-board" --keys "r" --cols 160) || fail "source board: render exited non-zero"
assert_fetch_log "$expected_live" "prs.source board spelled out: the default's calls exactly, the script never runs"
frame_r=$(render_source "$SCRATCH/src-board" --install-root "$SCRATCH/nowhere" --keys ".") || fail "source board settings: render exited non-zero"
assert_row "$frame_r" "^ PR source +board: the board's own GitHub fetch \\(config\\) +\$" "Settings: a board source the file set reads (config)"
frame_r=$(render_source "$SCRATCH/src-unset" --keys "r" --cols 160) || fail "source unset: render exited non-zero"
assert_fetch_log "$expected_live" "a config without prs.source: the board source, the default's calls exactly"
frame_r=$(render_source "$SCRATCH/src-unset" --install-root "$SCRATCH/nowhere" --keys ".") || fail "source unset settings: render exited non-zero"
assert_row "$frame_r" "^ PR source +board: the board's own GitHub fetch \\(default\\) +\$" "Settings: a config without prs.source reads (default)"
frame_r=$(render_source "$SCRATCH/src-firstmate" --no-prs --install-root "$SCRATCH/nowhere" --keys ".") || fail "source off settings: render exited non-zero"
assert_fetch_log "snapshot" "--no-prs with prs.source firstmate: neither the script nor gh runs"
assert_row "$frame_r" '^ PR source +off \(--no-prs\) +$' "Settings: --no-prs reads off on the PR source line whatever the file says"
# A bad prs.source is a malformed file: the defaults, so the board source runs (without the file's
# portal rule), and the footer names the key and the allowed values (falsify: accept the value, or
# keep the rest of the file on a bad prs.source).
frame_r=$(render_source "$SCRATCH/src-bad" --cols 260) || fail "source bad: render exited non-zero"
assert_contains "$frame_r" 'config: '"$SCRATCH"'/src-bad/fm-board/config.json: prs.source is not "board" or "firstmate" (got "github"); running with the defaults' "a bad prs.source is named in the footer with the allowed values"
if grep -q "prs --json" "$FETCH_LOG"; then fail "a bad prs.source still ran the script: $(cat "$FETCH_LOG")"; else pass; fi
if grep -q "api graphql" "$FETCH_LOG"; then pass; else fail "a bad prs.source did not fall back to the board's own fetch: $(cat "$FETCH_LOG")"; fi
frame_r=$(render populated.json --keys "r") || fail "refresh fixture: render exited non-zero"
assert_contains "$frame_r" "refresh is not available with --fixture" "r on a fixture render only reports"
# A fixture render runs no script at all, whatever the prs default: with the stand-in home and the log
# in the environment, nothing is logged (falsify: call factsLive or refreshLive when a fixture is given).
rm -f "$FETCH_LOG"
FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" render populated.json --keys "r" >/dev/null || fail "fixture with FM_HOME: render exited non-zero"
if [ -f "$FETCH_LOG" ]; then fail "a fixture render ran a snapshot script: $(cat "$FETCH_LOG")"; else pass; fi
# The fake refuses the old call, so a board that went back to `gh pr list` could not pass the checks
# above (falsify: answer pr list in tests/fake-gh.sh).
rm -f "$FETCH_LOG"
if FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" bash "$ROOT/tests/fake-gh.sh" pr list --repo acme/api >/dev/null 2>&1; then fail "the fake gh answered pr list"; else pass; fi

# ------------------------------------------------------------------ identity
# The login the two PR panes are built around, resolved live: the config file's identity.github_login
# first (no gh call at all), else `gh api user`, else `git config --get github.user`, else unknown,
# which puts one row in both panes, a warning on the Settings page and a footer notice. Each case runs
# against its own XDG_CONFIG_HOME so the config file is what the case wrote (or the example, written
# on the first run); the fake gh fails its login call under FM_BOARD_TEST_GH_LOGIN_FAIL and a fake
# git on IDENT_BIN answers `config --get github.user` from FM_BOARD_TEST_GIT_LOGIN (nothing set: exit
# 1, the unset-key answer) and hands every other git call to the real one (falsify: reorder the
# rungs in resolveIdentityLive, read user.name from git, or drop identityRow from the two builders).
IDENT_BIN="$SCRATCH/ident-bin"
mkdir -p "$IDENT_BIN"
real_git=$(command -v git)
# shellcheck disable=SC2016 # the fake expands its variables at run time, not here
printf '#!/usr/bin/env bash\nif [ "$1 $2 $3" = "config --get github.user" ]; then [ -n "${FM_BOARD_TEST_GIT_LOGIN:-}" ] || exit 1; printf "%%s\\n" "$FM_BOARD_TEST_GIT_LOGIN"; exit 0; fi\nexec %s "$@"\n' "$real_git" > "$IDENT_BIN/git"
chmod +x "$IDENT_BIN/git"
render_identity() { # <xdg dir> [flags]: a live render with the fake git first on PATH and its own config directory
  rm -f "${FETCH_LOG:?}"
  FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$1" PATH="$IDENT_BIN:$FAKE_BIN:$PATH" "$BOARD" --render-once --no-herdr --rows 60 "${@:2}"
}
# config over gh: the file names the login, gh is never asked and the searches carry it.
mkdir -p "$SCRATCH/ident-config/fm-board"
printf '{"schema":"firstmate-tui-config.v1","identity":{"github_login":"cfg-user"},"review":{"default_labels":[],"repos":{}}}\n' > "$SCRATCH/ident-config/fm-board/config.json"
frame_i=$(FM_BOARD_TEST_GIT_LOGIN=gituser render_identity "$SCRATCH/ident-config") || fail "identity config: render exited non-zero"
if grep -q "api user" "$FETCH_LOG"; then fail "identity from the config file: gh api user was still called: $(cat "$FETCH_LOG")"; else pass; fi
if grep -q "author:cfg-user" "$FETCH_LOG"; then pass; else fail "identity from the config file: the searches carry the file's login: $(cat "$FETCH_LOG")"; fi
frame_i=$(FM_BOARD_TEST_GIT_LOGIN=gituser render_identity "$SCRATCH/ident-config" --install-root "$SCRATCH/nowhere" --keys ".") || fail "identity config settings: render exited non-zero"
assert_row "$frame_i" '^ Identity +cfg-user  \(from config\) +$' "Settings: the identity line names the login and the config source"
# gh over git: the example config names no login, gh answers, git is not asked.
frame_i=$(FM_BOARD_TEST_GIT_LOGIN=gituser render_identity "$SCRATCH/ident-gh") || fail "identity gh: render exited non-zero"
if grep -q "author:captain" "$FETCH_LOG"; then pass; else fail "identity from gh: the searches carry gh's login: $(cat "$FETCH_LOG")"; fi
assert_count "$(cat "$FETCH_LOG")" "gh api user --jq .login" 1 "identity from gh: exactly one gh api user call"
frame_i=$(FM_BOARD_TEST_GIT_LOGIN=gituser render_identity "$SCRATCH/ident-gh" --install-root "$SCRATCH/nowhere" --keys ".") || fail "identity gh settings: render exited non-zero"
assert_row "$frame_i" '^ Identity +captain  \(from gh api user\) +$' "Settings: the identity line names gh api user as the source"
# git alone: gh fails (not logged in), git's github.user answers.
frame_i=$(FM_BOARD_TEST_GH_LOGIN_FAIL=1 FM_BOARD_TEST_GIT_LOGIN=gituser render_identity "$SCRATCH/ident-git") || fail "identity git: render exited non-zero"
if grep -q "author:gituser" "$FETCH_LOG"; then pass; else fail "identity from git: the searches carry git's github.user: $(cat "$FETCH_LOG")"; fi
frame_i=$(FM_BOARD_TEST_GH_LOGIN_FAIL=1 FM_BOARD_TEST_GIT_LOGIN=gituser render_identity "$SCRATCH/ident-git" --install-root "$SCRATCH/nowhere" --keys ".") || fail "identity git settings: render exited non-zero"
assert_row "$frame_i" '^ Identity +gituser  \(from git config github.user\) +$' "Settings: the identity line names git config github.user as the source"
# none: gh fails and github.user is unset; nothing is searched, both panes show the row, the footer
# and the Settings page say what to do, and r asks again (one more gh api user call) while it is
# unknown.
frame_i=$(FM_BOARD_TEST_GH_LOGIN_FAIL=1 render_identity "$SCRATCH/ident-none") || fail "identity none: render exited non-zero"
if grep -q "api graphql" "$FETCH_LOG"; then fail "identity unknown: a search ran anyway: $(cat "$FETCH_LOG")"; else pass; fi
assert_count "$frame_i" "identity unknown: see Settings (.)" 2 "identity unknown: one row in each PR pane (falsify: drop identityRow from mineRows or toReviewRows)"
assert_row "$frame_i" '^│ - +- +- +identity unknown: see Settings \(\.\) +- +- │$' "identity unknown: the row reads across the six columns"
assert_no_row "$frame_i" '^│ (unlisted|PR) +- +ship-gamma' "identity unknown: My PRs lists no recorded PR either, since nothing was fetched (its Captain's Call and Underway rows stay)"
frame_i=$(FM_BOARD_TEST_GH_LOGIN_FAIL=1 render_identity "$SCRATCH/ident-none" --install-root "$SCRATCH/nowhere" --keys "." --cols 260) || fail "identity none settings: render exited non-zero"
assert_row "$frame_i" "^ Identity +identity unknown: set identity.github_login in $SCRATCH/ident-none/fm-board/config.json, or run gh auth login +\$" "Settings: the unknown identity names the config file and the gh login"
assert_contains "$frame_i" "tried: config: identity.github_login not set; gh: exit 1: fake gh: not logged in to github.com; git: github.user not set" "Settings: the unknown identity lists what each rung answered"
frame_i=$(FM_BOARD_TEST_GH_LOGIN_FAIL=1 render_identity "$SCRATCH/ident-none" --keys "r") || fail "identity none r: render exited non-zero"
assert_count "$(cat "$FETCH_LOG")" "gh api user --jq .login" 2 "identity unknown: r asks gh again (falsify: never retry, or retry while known)"
frame_i=$(render_identity "$SCRATCH/ident-gh" --keys "r") || fail "identity known r: render exited non-zero"
assert_count "$(cat "$FETCH_LOG")" "gh api user --jq .login" 1 "identity known: r does not ask gh again"

# A fetch with the identity unknown asks nothing and leaves both panes unfetched (fetchPrs marks them
# skipped, mergePrs keeps a null fetchedAt), so the first-fetch spinner still follows once r resolves
# the login; a later fetch that answers stamps them as usual (falsify: drop `skipped` from fetchPrs'
# unknown branch, or stamp fetchedAt for a skipped pane in mergePrs).
skipped_out=$(node --input-type=module -e "
  import { initialPrs, mergePrs } from '$ROOT/bin/firstmate-tui/lib/model.mjs';
  import { fetchPrs } from '$ROOT/bin/firstmate-tui/lib/sources.mjs';
  const unknown = { login: null, source: 'unknown', reason: 'nothing answered' };
  const known = { login: 'captain', source: 'gh', reason: null };
  const r = await fetchPrs('/nowhere', null, { identity: unknown, config: null, timeoutMs: 1000, env: { PATH: '$FAKE_BIN' } });
  const show = (...parts) => console.log(parts.map(String).join(' '));
  show('fetch', r.mine.skipped === true, r.toreview.skipped === true, r.mine.rows.length, r.mine.error, r.toreview.error);
  const after = mergePrs(initialPrs(true, null), r, 100, unknown);
  show('merged', after.fetchedAt, after.mine.fetchedAt, after.toreview.fetchedAt, after.error, after.candidate_prs.length, JSON.stringify(after.toreview.scope), after.identity.source);
  const landed = mergePrs(after, { mine: { rows: [{ url: 'u', pane: 'mine' }], error: null }, toreview: { rows: [], error: null, scope: ['a/b'] }, note: null }, 200, known);
  show('landed', landed.fetchedAt, landed.mine.fetchedAt, landed.toreview.fetchedAt, landed.candidate_prs.length, landed.identity.login);
") || fail "skipped fetch checks: node exited non-zero: $skipped_out"
for expected in "fetch true true 0 null null" "merged null null null null 0 [] unknown" "landed 200 200 200 1 captain"; do
  if printf '%s\n' "$skipped_out" | grep -Fxq -- "$expected"; then pass; else fail "skipped fetch: expected line '$expected' in: $skipped_out"; fi
done

# -------------------------------------------------------------------- config
# The config file's chain and its one-time write: --config first, else the plugin directory the
# wrapper passes (checked with the wrapper checks below), else $XDG_CONFIG_HOME/fm-board/config.json,
# else ~/.config/fm-board/config.json; a path inside FM_HOME is refused with a notice; a malformed
# file gives the defaults plus a notice and the Settings line; an absent file is written once from
# docs/config.example.json and never rewritten (falsify: drop a rung from resolveConfigPath, write
# the example over an existing file, or drop the notice from driveOnce).
cfg_dir="$SCRATCH/cfg"
mkdir -p "$cfg_dir"
frame_c=$(render populated.json --config "$cfg_dir/mine.json") || fail "config explicit: render exited non-zero"
if cmp -s "$cfg_dir/mine.json" "$ROOT/docs/config.example.json"; then pass; else fail "--config to an absent file writes the example there byte for byte"; fi
printf '{"schema":"firstmate-tui-config.v1","identity":{"github_login":"edited"},"review":{"default_labels":["go"],"repos":{"acme/api":{"labels":[]}}}}\n' > "$cfg_dir/mine.json"
frame_c=$(render populated.json --config "$cfg_dir/mine.json" --install-root "$SCRATCH/nowhere" --keys ".") || fail "config edited: render exited non-zero"
if grep -q '"edited"' "$cfg_dir/mine.json"; then pass; else fail "an existing config file is never rewritten"; fi
assert_row "$frame_c" "^ Config +$cfg_dir/mine.json +\$" "Settings: the Config line names the --config path with no suffix once the file is read"
assert_row "$frame_c" '^ Review labels +default: go +$' "Settings: the default labels line reads the file"
assert_row "$frame_c" '^ +acme/api: unfiltered +$' "Settings: a repository entry with an empty list reads unfiltered"
frame_c=$(render populated.json --config "$cfg_dir/fresh.json" --install-root "$SCRATCH/nowhere" --keys ".") || fail "config created settings: render exited non-zero"
assert_row "$frame_c" "^ Config +$cfg_dir/fresh.json  \\(created from the example\\) +\$" "Settings: a file just written from the example says so"
assert_row "$frame_c" '^ Review labels +default: none +$' "Settings: the example has no default labels"
assert_row "$frame_c" '^ +example-corp/portal: ready-to-merge +$' "Settings: the example's portal rule is listed"
# A fixture render without --config touches no config file (falsify: drop the fixture guard in configFor).
frame_c=$(HOME="$SCRATCH/cfg-home" XDG_CONFIG_HOME='' render populated.json) || fail "config fixture default: render exited non-zero"
if [ -e "$SCRATCH/cfg-home/.config/fm-board/config.json" ]; then fail "a fixture render without --config wrote the default config file"; else pass; fi
# The XDG and HOME rungs, on a live render (falsify: drop defaultConfigPath's XDG or HOME branch).
if [ -f "$SCRATCH/xdg/fm-board/config.json" ]; then pass; else fail "a live render without --config uses \$XDG_CONFIG_HOME/fm-board/config.json"; fi
mkdir -p "$SCRATCH/cfg-home"
rm -f "${FETCH_LOG:?}"
FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" HOME="$SCRATCH/cfg-home" XDG_CONFIG_HOME='' PATH="$FAKE_BIN:$PATH" "$BOARD" --render-once --no-herdr >/dev/null || fail "config HOME rung: render exited non-zero"
if cmp -s "$SCRATCH/cfg-home/.config/fm-board/config.json" "$ROOT/docs/config.example.json"; then pass; else fail "without XDG_CONFIG_HOME a live render writes the example to ~/.config/fm-board/config.json"; fi
# Refused inside FM_HOME: the notice, the fallback path, nothing written inside the home.
frame_c=$(XDG_CONFIG_HOME="$SCRATCH/cfg-xdg" render populated.json --config /fixture/firstmate/state/config.json) || fail "config FM_HOME guard: render exited non-zero"
assert_contains "$frame_c" "refusing --config inside FM_HOME (/fixture/firstmate/state/config.json)" "a config path inside FM_HOME is refused with a notice"
if [ -e /fixture/firstmate/state/config.json ]; then fail "the refused config path was written"; else pass; fi
if [ -f "$SCRATCH/cfg-xdg/fm-board/config.json" ]; then pass; else fail "the refused config path falls back to \$XDG_CONFIG_HOME/fm-board/config.json and the example is written there"; fi
# Malformed: the defaults, a footer notice, the Settings line, and the file left alone.
printf '{"schema":"firstmate-tui-config.v1","review":{"default_labels":"ready"}}\n' > "$cfg_dir/bad.json"
frame_c=$(render populated.json --config "$cfg_dir/bad.json" --cols 260) || fail "config malformed: render exited non-zero"
assert_contains "$frame_c" "config: $cfg_dir/bad.json: review.default_labels is not a list; running with the defaults" "a malformed config is named in the footer once"
frame_c=$(render populated.json --config "$cfg_dir/bad.json" --install-root "$SCRATCH/nowhere" --keys "." --cols 260) || fail "config malformed settings: render exited non-zero"
assert_row "$frame_c" "^ Config +$cfg_dir/bad.json  \\(using defaults: $cfg_dir/bad.json: review.default_labels is not a list\\) +\$" "Settings: the Config line says the defaults are in effect and why"
assert_row "$frame_c" '^ Review labels +default: none +$' "Settings: a malformed file leaves no default labels"
assert_not_contains "$frame_c" "example-corp/portal" "Settings: a malformed file leaves no configured repository (the example is not used in its place)"
if grep -q '"ready"' "$cfg_dir/bad.json"; then pass; else fail "a malformed config file is left as it was"; fi
# A live render with a malformed config searches without label rules (the portal PR without the label
# is listed too) and the configured repository is not in the scope (falsify: fall back to the example
# instead of the defaults).
mkdir -p "$SCRATCH/cfg-bad-xdg/fm-board"
cp "$cfg_dir/bad.json" "$SCRATCH/cfg-bad-xdg/fm-board/config.json"
rm -f "${FETCH_LOG:?}"
frame_c=$(FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/cfg-bad-xdg" PATH="$FAKE_BIN:$PATH" "$BOARD" --render-once --no-herdr --rows 60) || fail "config malformed live: render exited non-zero"
if grep -q "repo:example-corp/portal" "$FETCH_LOG"; then fail "a malformed config still put the example's repository into the scope: $(cat "$FETCH_LOG")"; else pass; fi
assert_not_contains "$frame_c" "portal#120" "a malformed config: portal is out of the scope, so its PRs are not listed"
assert_contains "$frame_c" "Teammates' PRs (4)" "a malformed config: the four Teammates' PRs rows of the candidate repositories remain"

# ------------------------------------------------------------- settings page
# The `.` page. Install identity comes from --install-root: INSTALL is a fake prefix (package.json
# version 0.1.0, an install-record naming acme/fm-board-test, tests/fake-upgrade.sh as its
# bin/firstmate-tui.sh), INSTALL_OLD the same install laid out the 0.2.x way (bin/fm-board.sh beside
# bin/fm-board/), CHECKOUT the same tree with a .git file and no record. Release data comes from
# `--curl-cmd bash tests/fake-curl.sh` over REL (tests/fixtures/releases/api: 0.2.0 is the latest
# stable release, three prereleases out of publish order in the list), REL_CURRENT (the same list
# with 0.1.0 as the latest) or REL_NONE (nothing behind the API). The fake upgrade logs its argv to
# UPGRADE_LOG and exits FM_BOARD_TEST_UPGRADE_EXIT; a real `firstmate-tui upgrade`, install.sh or
# GitHub is never reached.
REL="$FIX/releases"
REL_CURRENT="$SCRATCH/releases-current"
REL_NONE="$SCRATCH/releases-none"
mkdir -p "$REL_CURRENT/api" "$REL_NONE/api"
cp "$REL/api/releases.json" "$REL_CURRENT/api/releases.json"
sed 's/v0\.2\.0/v0.1.0/g; s/2026-09-17T14:02:11Z/2026-09-15T12:01:30Z/' "$REL/api/latest.json" > "$REL_CURRENT/api/latest.json"
INSTALL="$SCRATCH/install"
INSTALL_OLD="$SCRATCH/install-old"
CHECKOUT="$SCRATCH/checkout"
UPGRADE_LOG="$SCRATCH/upgrade.log"
CURL_LOG="$SCRATCH/curl.log"
mkdir -p "$INSTALL/bin/firstmate-tui" "$INSTALL_OLD/bin/fm-board" "$CHECKOUT/bin/firstmate-tui"
printf '{\n  "name": "fm-board",\n  "version": "0.1.0"\n}\n' > "$INSTALL/bin/firstmate-tui/package.json"
cp "$INSTALL/bin/firstmate-tui/package.json" "$CHECKOUT/bin/firstmate-tui/package.json"
printf 'gitdir: /nowhere\n' > "$CHECKOUT/.git"
printf '# written by fm-board install.sh and read by fm-board upgrade; do not edit\nprefix=%s\nbin_dir=%s/bin-dir\nrepo=acme/fm-board-test\nversion=0.1.0\ninstalled_from=release v0.1.0\n' "$INSTALL" "$SCRATCH" > "$INSTALL/install-record"
cp "$ROOT/tests/fake-upgrade.sh" "$INSTALL/bin/firstmate-tui.sh"
cp "$ROOT/tests/fake-upgrade.sh" "$CHECKOUT/bin/firstmate-tui.sh"
chmod +x "$INSTALL/bin/firstmate-tui.sh" "$CHECKOUT/bin/firstmate-tui.sh"
# The 0.2.x layout: the same version, record and fake launcher, at the old names.
cp "$INSTALL/bin/firstmate-tui/package.json" "$INSTALL_OLD/bin/fm-board/package.json"
sed "s#^prefix=.*#prefix=$INSTALL_OLD#" "$INSTALL/install-record" > "$INSTALL_OLD/install-record"
cp "$ROOT/tests/fake-upgrade.sh" "$INSTALL_OLD/bin/fm-board.sh"
chmod +x "$INSTALL_OLD/bin/fm-board.sh"
# A fake curl on PATH that logs and fails, for the check that a render without --curl-cmd never
# reaches for the real one.
# shellcheck disable=SC2016 # the fake expands $FM_BOARD_TEST_CURL_LOG at run time, not here
printf '#!/usr/bin/env bash\necho "curl $*" >> "$FM_BOARD_TEST_CURL_LOG"\nexit 7\n' > "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"
# render_settings <api root> <install root> <keys> [flags]: a render of $SETTINGS_FIXTURE (default
# populated.json) with the fakes wired and both logs reset first
render_settings() {
  local api=$1 root=$2 keys=$3
  shift 3
  rm -f "$UPGRADE_LOG" "$CURL_LOG"
  FAKE_CURL_ROOT="$api" FAKE_CURL_LOG="$CURL_LOG" FM_BOARD_TEST_UPGRADE_LOG="$UPGRADE_LOG" \
    "$BOARD" --render-once --fixture "$FIX/${SETTINGS_FIXTURE:-populated.json}" --no-herdr --install-root "$root" --curl-cmd "bash $ROOT/tests/fake-curl.sh" --keys "$keys" "$@"
}
assert_upgrade_log() { # <expected content> <label>: the fake launcher ran exactly once, with these arguments
  if [ -f "$UPGRADE_LOG" ] && [ "$(cat "$UPGRADE_LOG")" = "$1" ]; then pass; else fail "$2: upgrade log is '$(cat "$UPGRADE_LOG" 2>/dev/null || echo '<absent>')', expected '$1'"; fi
}
assert_no_upgrade() { # <label>
  if [ -e "$UPGRADE_LOG" ]; then fail "$1: the upgrade command ran with '$(cat "$UPGRADE_LOG")'"; else pass; fi
}

# . replaces the grid with the page: identity from the fake prefix, the latest release with its
# date and verdict, the actions, the read-only flags, the page's own footer (falsify: drop the
# settings case from keyAction, the record parse in readInstall, or renderSettings from renderFrame).
frame_s=$(render_settings "$REL" "$INSTALL" ".") || fail "settings: render exited non-zero"
assert_row "$frame_s" '^ Settings +$' "settings: heading"
assert_count "$frame_s" "┌─" 0 "settings: no pane is drawn behind the page"
assert_row "$frame_s" '^ firstmate-tui 0\.1\.0 \(stable release\) +$' "settings: the running version, in the words firstmate-tui version prints"
assert_contains "$frame_s" " installed at $INSTALL (from release v0.1.0) · repository acme/fm-board-test" "settings: prefix, origin and repository come from the install record"
assert_row "$frame_s" '^ latest stable  0\.2\.0 · published 2026-09-17 · upgrade available +$' "settings: the latest stable release, its date and the verdict (falsify: compare suffixes in compareBase)"
assert_row "$frame_s" '^ ▸ Upgrade to 0\.2\.0 +firstmate-tui upgrade --version 0\.2\.0 +$' "settings: the upgrade action leads, highlighted, naming the exact command"
assert_row "$frame_s" '^   Betas +3 prereleases +$' "settings: the Betas entry counts the prereleases and not the stable releases"
assert_row "$frame_s" '^   Refresh release data +GitHub releases of acme/fm-board-test +$' "settings: the refetch entry"
assert_row "$frame_s" '^ refresh cadence +30 s \(--refresh\) +$' "settings: refresh cadence, read-only"
assert_row "$frame_s" '^ PR data +on: live GitHub checks on every tick +$' "settings: PR data, read-only"
assert_row "$frame_s" '^ CHECKS +passing, pending or failing, from the newest run of each check on the PR head commit +$' "settings: the CHECKS line says what the PR panes' column means (falsify: drop the entry from settingsFlags)"
assert_row "$frame_s" '^ herdr overlay +off \(--no-herdr\) +$' "settings: the herdr line reflects --no-herdr"
assert_row "$frame_s" '^ mouse +on: click selects, double-click acts, wheel scrolls, a header boundary drags +$' "settings: the mouse line, on by default (falsify: drop the mouse entry from settingsFlags)"
assert_row "$frame_s" '^ Identity +captain  \(from fixture\) +$' "settings: the identity block names the fixture's login and source (falsify: drop settingsInfo from renderSettings)"
assert_row "$frame_s" '^ Config +none: using defaults \(not read \(fixture render without --config\)\) +$' "settings: a fixture render without --config says no config file was read"
assert_row "$frame_s" "^ PR source +board: the board's own GitHub fetch \\(default\\) +\$" "settings: the PR source line reads the board default on a fixture without a source block (falsify: drop the line from settingsInfo, or ask PATH for gh on a fixture render)"
assert_before "$frame_s" '^ Config ' '^ PR source ' "settings: the PR source line follows Config"
assert_before "$frame_s" '^ PR source ' '^ Review labels ' "settings: the PR source line leads the label rules"
assert_row "$frame_s" '^ Review labels +default: none +$' "settings: the label rules line with the defaults"
assert_before "$frame_s" '^ mouse ' '^ Identity ' "settings: the identity block follows the flags"
assert_row "$frame_s" '^ j/k move  enter choose  r refetch  esc/\. back  \? help +$' "settings: the footer names the page's keys"
assert_row "$frame_s" '^ firstmate-tui · /fixture/firstmate · 3 homes ' "settings: the title line stays and leads with firstmate-tui"
assert_lines "$frame_s" 44 "settings: the frame is 44 lines"
assert_widths "$frame_s" 160 "settings: lines are 160 columns"
# Opening the page fetches once: the latest release and the list, for the record's repository
# (falsify: drop settingsFetch from the settings case in handleKey, or fetch on the refresh tick).
assert_file_contains "$CURL_LOG" "https://api.github.com/repos/acme/fm-board-test/releases/latest" "opening the page asks for the latest release of the record's repository"
assert_file_contains "$CURL_LOG" "https://api.github.com/repos/acme/fm-board-test/releases?per_page=30" "opening the page asks for the release list"
assert_count "$(cat "$CURL_LOG")" "api.github.com" 2 "opening the page makes exactly two API calls"
assert_no_upgrade "opening the page runs no upgrade"
frame_s=$(render_settings "$REL" "$INSTALL" ".,r") || fail "settings r: render exited non-zero"
assert_count "$(cat "$CURL_LOG")" "api.github.com" 4 "r inside the page fetches again (falsify: drop the fetch case from settingsKeyAction)"
frame_s=$(render_settings "$REL" "$INSTALL" "." --no-prs --refresh 45) || fail "settings flags: render exited non-zero"
assert_row "$frame_s" '^ refresh cadence +45 s \(--refresh\) +$' "settings: the cadence line follows --refresh"
assert_row "$frame_s" '^ PR data +off \(--no-prs\) +$' "settings: the PR data line follows --no-prs"
assert_row "$frame_s" '^ PR source +off \(--no-prs\) +$' "settings: the PR source line follows --no-prs"
frame_s=$(render_settings "$REL" "$INSTALL" "." --no-mouse) || fail "settings no-mouse: render exited non-zero"
assert_row "$frame_s" '^ mouse +off \(--no-mouse\) +$' "settings: the mouse line follows --no-mouse"
# Without --curl-cmd a one-shot render fetches nothing, not even through a curl on PATH (falsify:
# default curlCmd to curl in driveOnce's settingsFetch).
rm -f "$CURL_LOG"
frame_s=$(PATH="$FAKE_BIN:$PATH" FM_BOARD_TEST_CURL_LOG="$CURL_LOG" render populated.json --install-root "$INSTALL" --keys ".") || fail "settings no curl: render exited non-zero"
assert_row "$frame_s" '^ latest stable  not fetched \(no --curl-cmd in --render-once\) +$' "without --curl-cmd the latest line says nothing was fetched"
assert_contains "$frame_s" "release data not fetched: no --curl-cmd in --render-once" "without --curl-cmd the footer says why"
if [ -e "$CURL_LOG" ]; then fail "a render without --curl-cmd called curl on PATH: $(cat "$CURL_LOG")"; else pass; fi

# Up to date: the same list with 0.1.0 as the latest stable release offers no upgrade and the cursor
# lands on Betas (falsify: offer the latest version whatever the comparison says).
frame_s=$(render_settings "$REL_CURRENT" "$INSTALL" ".") || fail "settings current: render exited non-zero"
assert_row "$frame_s" '^ latest stable  0\.1\.0 · published 2026-09-15 · up to date +$' "up to date: the latest line says so"
assert_not_contains "$frame_s" "Upgrade to" "up to date: no upgrade action"
assert_row "$frame_s" '^ ▸ Betas ' "up to date: the cursor starts on Betas"

# The API unreachable: the failure text is shown verbatim on the latest line and the Betas entry,
# and nothing is offered (falsify: swallow runJson's error in fetchReleases).
frame_s=$(render_settings "$REL_NONE" "$INSTALL" ".") || fail "settings api down: render exited non-zero"
assert_contains "$frame_s" " latest stable  no stable release found: exit 22: fake-curl: 404 https://api.github.com/repos/acme/fm-board-test/releases/latest" "api down: the latest line carries curl's failure text"
assert_row "$frame_s" '^ ▸ Betas +list unavailable: exit 22: fake-curl: 404 https://api.github.com/repos/acme/fm-board-test/releases\?per_page=30' "api down: the Betas entry carries the list's failure text"
assert_not_contains "$frame_s" "Upgrade to" "api down: no upgrade action"

# The Betas submenu: prereleases newest first by publish time (the fixture lists d8b290e after
# a1b2c3d although it was published later), each with its commit and date, the stable releases left
# out, Back to stable last (falsify: drop the sort or the prerelease filter in parseReleases).
frame_s=$(render_settings "$REL" "$INSTALL" ".,j,enter") || fail "betas: render exited non-zero"
assert_row "$frame_s" '^ Settings · Betas +$' "betas: heading"
assert_row "$frame_s" '^ prereleases of acme/fm-board-test, newest first +$' "betas: the list names its source"
assert_row "$frame_s" '^ ▸ 0\.2\.0-9f8e7d6 +commit 9f8e7d6   2026-09-17 +$' "betas: the newest prerelease leads, highlighted, with commit and date"
assert_row "$frame_s" '^   0\.1\.0-d8b290e +commit d8b290e   2026-09-16 +$' "betas: second prerelease"
assert_row "$frame_s" '^   0\.1\.0-a1b2c3d +commit a1b2c3d   2026-09-16 +$' "betas: oldest prerelease"
assert_before "$frame_s" '0\.2\.0-9f8e7d6' '0\.1\.0-d8b290e' "betas: newest first (1)"
assert_before "$frame_s" '0\.1\.0-d8b290e' '0\.1\.0-a1b2c3d' "betas: sorted by publish time, not by the API's order"
assert_no_row "$frame_s" '^ [▸ ] 0\.2\.0 ' "betas: the stable 0.2.0 is not listed as a beta"
assert_no_row "$frame_s" '^ [▸ ] 0\.1\.0 ' "betas: the stable 0.1.0 is not listed as a beta"
assert_row "$frame_s" '^   Back to stable +0\.2\.0   2026-09-17 +$' "betas: Back to stable names the latest stable release"
assert_before "$frame_s" '0\.1\.0-a1b2c3d' 'Back to stable' "betas: Back to stable comes after the prereleases"
assert_row "$frame_s" '^ j/k move  enter choose  esc back  \. close  r refetch  \? help +$' "betas: the footer says esc goes back and . closes"
assert_no_upgrade "opening the Betas menu runs nothing"
frame_s=$(render_settings "$REL" "$INSTALL" ".,j,enter,escape") || fail "betas esc: render exited non-zero"
assert_row "$frame_s" '^ Settings +$' "esc in Betas returns to the main menu"
assert_not_contains "$frame_s" "Settings · Betas" "esc in Betas leaves the submenu"

# Confirm gating: choosing an install shows one line with the exact version and command, and only y
# starts it; any other key cancels and does nothing else (falsify: run the upgrade from the confirm
# case, or let j move while a confirmation is pending).
frame_s=$(render_settings "$REL" "$INSTALL" ".,enter") || fail "confirm: render exited non-zero"
assert_row "$frame_s" '^ install 0\.2\.0 \(firstmate-tui upgrade --version 0\.2\.0\)\? y to confirm, esc to cancel +$' "confirm: the line names the version and the command"
assert_row "$frame_s" '^ y confirm  esc cancel' "confirm: the footer shows the two keys"
assert_no_upgrade "choosing the upgrade runs nothing before y"
frame_s=$(render_settings "$REL" "$INSTALL" ".,enter,j") || fail "confirm j: render exited non-zero"
assert_contains "$frame_s" "cancelled; nothing was installed" "j while pending cancels"
assert_row "$frame_s" '^ ▸ Upgrade to 0\.2\.0 ' "the cancelling key does nothing else: the cursor has not moved"
assert_not_contains "$frame_s" "y to confirm" "the confirm line is gone after the cancel"
assert_no_upgrade "j while pending runs nothing"
frame_s=$(render_settings "$REL" "$INSTALL" ".,enter,escape") || fail "confirm esc: render exited non-zero"
assert_contains "$frame_s" "cancelled; nothing was installed" "esc while pending cancels"
assert_row "$frame_s" '^ Settings +$' "esc while pending stays on the page"
assert_no_upgrade "esc while pending runs nothing"
frame_s=$(render_settings "$REL" "$INSTALL" ".,enter,Y") || fail "confirm Y: render exited non-zero"
assert_no_upgrade "only a lower-case y confirms"

# y runs the launcher's own upgrade with the exact version, streams its lines into the page and ends
# with the restart line and the relaunch entry (falsify: pass --stable for the upgrade entry, spawn
# install.sh directly, or drop finishUpgrade).
frame_s=$(render_settings "$REL" "$INSTALL" ".,enter,y") || fail "upgrade y: render exited non-zero"
assert_upgrade_log "upgrade --version 0.2.0" "y runs bash <prefix>/bin/firstmate-tui.sh upgrade --version 0.2.0, once"
assert_row "$frame_s" '^ install: downloading firstmate-tui-v0\.2\.0\.tar\.gz from acme/fm-board-test release v0\.2\.0 +$' "upgrade: the download line is on the page"
assert_row "$frame_s" '^ install: checksum verified +$' "upgrade: the verify line is on the page"
assert_row "$frame_s" '^ install: firstmate-tui 0\.2\.0 installed \(replaced 0\.1\.0\) +$' "upgrade: the swap line is on the page"
assert_before "$frame_s" 'install: downloading' 'install: checksum verified' "upgrade: lines keep their order (1)"
assert_before "$frame_s" 'install: checksum verified' 'install: firstmate-tui 0\.2\.0 installed' "upgrade: lines keep their order (2)"
assert_row "$frame_s" '^ restart to use 0\.2\.0 · R quits and relaunches the board +$' "upgrade: success names the installed version and the relaunch key"
assert_row "$frame_s" '^ ▸ Relaunch now +quit and start 0\.2\.0 \(R\) +$' "upgrade: the relaunch entry leads the menu after a success"
assert_not_contains "$frame_s" "Upgrade to 0.2.0" "upgrade: the upgrade entry gives way to the relaunch entry"
assert_contains "$frame_s" "installed 0.2.0; R relaunches the board" "upgrade: the footer notice sums it up"
frame_s=$(render_settings "$REL" "$INSTALL" ".,enter,y,R") || fail "upgrade R: render exited non-zero"
assert_contains "$frame_s" "would relaunch: exit 75 makes bin/firstmate-tui.sh run start the installed copy again; --render-once never exits 75" "R after a success asks for the relaunch, which a one-shot render only reports"
assert_upgrade_log "upgrade --version 0.2.0" "R runs no second upgrade"
frame_s=$(render_settings "$REL" "$INSTALL" ".,R") || fail "R early: render exited non-zero"
assert_not_contains "$frame_s" "would relaunch" "R before any success does nothing (falsify: drop the result check from the R case)"
# The version in "restart to use" is read from the installer's last line, in the current wording and
# in the 0.1.0 installer's, which a 0.1.0 install's own upgrade still prints (falsify: match only one
# name in installedVersionFromOutput).
parsed=$(node --input-type=module -e "
  import { installedVersionFromOutput } from '$ROOT/bin/firstmate-tui/lib/settings.mjs';
  console.log(installedVersionFromOutput(['install: checksum verified', 'install: firstmate-tui 0.2.1 installed (replaced 0.2.0)']));
  console.log(installedVersionFromOutput(['install: fm-board 0.2.1 installed']));
  console.log(installedVersionFromOutput(['install: checksum verified']));
")
if [ "$(printf '%s\n' "$parsed" | grep -c '^0\.2\.1$')" -eq 2 ] && [ "$(printf '%s\n' "$parsed" | tail -n 1)" = null ]; then pass; else fail "installedVersionFromOutput: expected 0.2.1 from both wordings and null without the line, got: $parsed"; fi

# A failing upgrade: the launcher's stderr is on the page verbatim with the exit status, nothing says
# restart, and the page stays usable with the upgrade still offered (falsify: drop stderr from
# runUpgrade, or lock the page after a failure).
frame_s=$(FM_BOARD_TEST_UPGRADE_EXIT=2 render_settings "$REL" "$INSTALL" ".,enter,y") || fail "upgrade fail: render exited non-zero"
assert_upgrade_log "upgrade --version 0.2.0" "the failing upgrade ran once"
assert_row "$frame_s" "^ install: error: checksum mismatch for firstmate-tui-v0\.2\.0\.tar\.gz: expected 'abc', got 'def' +\$" "failure: the installer's error line is shown verbatim"
assert_contains "$frame_s" " upgrade failed (exit 2); the output above says why." "failure: the exit status is named"
assert_not_contains "$frame_s" "restart to use" "failure: nothing says restart"
assert_not_contains "$frame_s" "Relaunch now" "failure: no relaunch entry"
assert_row "$frame_s" '^ ▸ Upgrade to 0\.2\.0 ' "failure: the upgrade is still offered"
assert_contains "$frame_s" "upgrade failed; the page shows the installer output" "failure: the footer notice says so"
frame_s=$(FM_BOARD_TEST_UPGRADE_EXIT=2 render_settings "$REL" "$INSTALL" ".,enter,y,j,enter") || fail "upgrade fail then move: render exited non-zero"
assert_row "$frame_s" '^ Settings · Betas +$' "failure: keys work again afterwards (j, enter opens Betas)"

# A beta and Back to stable go through the same confirm and the same launcher (falsify: give the
# beta entries a different channel, or drop the stable channel from upgradeArgs).
frame_s=$(render_settings "$REL" "$INSTALL" ".,j,enter,j,enter") || fail "beta confirm: render exited non-zero"
assert_row "$frame_s" '^ install 0\.1\.0-d8b290e \(firstmate-tui upgrade --version 0\.1\.0-d8b290e\)\? y to confirm, esc to cancel +$' "beta: the confirm line names the exact beta"
assert_no_upgrade "beta: nothing runs before y"
frame_s=$(render_settings "$REL" "$INSTALL" ".,j,enter,j,enter,y") || fail "beta y: render exited non-zero"
assert_upgrade_log "upgrade --version 0.1.0-d8b290e" "beta: y runs the launcher with --version and the exact beta"
frame_s=$(render_settings "$REL" "$INSTALL" ".,j,enter,j,j,j,enter") || fail "stable confirm: render exited non-zero"
assert_row "$frame_s" '^ back to stable 0\.2\.0 \(firstmate-tui upgrade --stable\)\? y to confirm, esc to cancel +$' "Back to stable: the confirm line names the release and the --stable command"
assert_no_upgrade "Back to stable: nothing runs before y"
frame_s=$(render_settings "$REL" "$INSTALL" ".,j,enter,j,j,j,enter,y") || fail "stable y: render exited non-zero"
assert_upgrade_log "upgrade --stable" "Back to stable: y runs the launcher's --stable path"
assert_row "$frame_s" '^ Settings +$' "a success from the Betas menu returns to the main menu"
assert_row "$frame_s" '^ ▸ Relaunch now ' "a success from the Betas menu offers the relaunch"

# An install root laid out the 0.2.x way (bin/fm-board.sh beside bin/fm-board/, what
# `firstmate-tui upgrade --version 0.2.5` leaves behind) is read the same: the version comes from
# bin/fm-board/package.json and y runs that tree's bin/fm-board.sh, the only launcher it has
# (falsify: fix the package.json and launcher paths in readInstall to bin/firstmate-tui).
frame_s=$(render_settings "$REL" "$INSTALL_OLD" ".") || fail "old layout: render exited non-zero"
assert_row "$frame_s" '^ firstmate-tui 0\.1\.0 \(stable release\) +$' "old layout: the version is read from bin/fm-board/package.json"
assert_contains "$frame_s" " installed at $INSTALL_OLD (from release v0.1.0) · repository acme/fm-board-test" "old layout: the record is read"
assert_row "$frame_s" '^ ▸ Upgrade to 0\.2\.0 ' "old layout: the upgrade is offered"
frame_s=$(render_settings "$REL" "$INSTALL_OLD" ".,enter,y") || fail "old layout y: render exited non-zero"
assert_upgrade_log "upgrade --version 0.2.0" "old layout: y runs bash <prefix>/bin/fm-board.sh upgrade, the launcher that tree has"

# enter and a double-click on the same entry are one path: settingsKeyAction answers the same
# { type: 'activate', cursor, action } object settingsMouseAction answers, so the confirm frame is byte
# for byte the same whichever opened it, on Upgrade, on a beta row and on Back to stable (falsify:
# return entry.action from the enter case instead of the activate object, or give the mouse activate
# a prompt path of its own in applySettingsAction).
assert_same_frame() { # <frame a> <frame b> <label>
  if [ "$1" = "$2" ]; then pass; else fail "$3: the frames differ: $(diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") | head -n 6)"; fi
}
frame_ke=$(render_settings "$REL" "$INSTALL" ".,enter") || fail "enter on Upgrade: render exited non-zero"
frame_dc=$(render_settings "$REL" "$INSTALL" "." --mouse "dblclick:10,7") || fail "double-click on Upgrade: render exited non-zero"
assert_row "$frame_ke" '^ install 0\.2\.0 \(firstmate-tui upgrade --version 0\.2\.0\)\? y to confirm, esc to cancel +$' "enter on Upgrade opens the confirm line with the version and the command"
assert_row "$frame_ke" '^ y confirm  esc cancel' "enter on Upgrade: the footer waits for y or esc"
assert_same_frame "$frame_ke" "$frame_dc" "Upgrade: enter and a double-click open the same frame"
assert_no_upgrade "enter on Upgrade runs nothing before y"
frame_ke=$(render_settings "$REL" "$INSTALL" ".,j,enter,j,enter") || fail "enter on a beta: render exited non-zero"
frame_dc=$(render_settings "$REL" "$INSTALL" ".,j,enter" --mouse "dblclick:10,8") || fail "double-click on a beta: render exited non-zero"
assert_row "$frame_ke" '^ install 0\.1\.0-d8b290e \(firstmate-tui upgrade --version 0\.1\.0-d8b290e\)\? y to confirm, esc to cancel +$' "enter on a beta row opens the confirm line naming exactly that beta"
assert_same_frame "$frame_ke" "$frame_dc" "a beta row: enter and a double-click open the same frame"
assert_no_upgrade "enter on a beta runs nothing before y"
frame_ke=$(render_settings "$REL" "$INSTALL" ".,j,enter,j,j,j,enter") || fail "enter on Back to stable: render exited non-zero"
frame_dc=$(render_settings "$REL" "$INSTALL" ".,j,enter" --mouse "dblclick:10,10") || fail "double-click on Back to stable: render exited non-zero"
assert_row "$frame_ke" '^ back to stable 0\.2\.0 \(firstmate-tui upgrade --stable\)\? y to confirm, esc to cancel +$' "enter on Back to stable opens the confirm line with the release and --stable"
assert_same_frame "$frame_ke" "$frame_dc" "Back to stable: enter and a double-click open the same frame"
assert_no_upgrade "enter on Back to stable runs nothing before y"

# The interactive path. neo-blessed 0.2.0 reports one Enter press as two keypress events, { name:
# 'enter' } and then { name: 'return' } (lib/program.js re-emits every \r keypress under the second
# name), and normalizeKey must keep exactly one of them, or every Enter acts twice: on this page the
# second enter cancelled the confirmation the first had just opened, and the footer read "cancelled;
# nothing was installed" instead of the prompt. --render-once never loads the library, so the adapter's
# mapping is checked directly (falsify: map 'return' to 'enter' again in normalizeKey). The one-shot
# picture of the old double delivery is ".,enter,enter", which does cancel, as any key pressed after the
# prompt opened should.
adapter_keys=$(node --input-type=module -e "
  import { normalizeKey } from '$ROOT/bin/firstmate-tui/lib/tui-blessed.mjs';
  const press = [['\r', { name: 'enter', sequence: '\r' }], ['\r', { name: 'return', sequence: '\r' }]];
  console.log(JSON.stringify(press.map(([ch, key]) => normalizeKey(ch, key)).filter((k) => k !== null)));
  console.log(JSON.stringify(normalizeKey('\n', { name: 'linefeed', sequence: '\n' })));
  console.log(JSON.stringify(normalizeKey('j', { name: 'j', sequence: 'j' })));
")
if [ "$(printf '%s\n' "$adapter_keys" | sed -n 1p)" = '["enter"]' ]; then pass; else fail "normalizeKey: the two events of one Enter press must give exactly one enter key, got $(printf '%s\n' "$adapter_keys" | sed -n 1p)"; fi
if [ "$(printf '%s\n' "$adapter_keys" | sed -n 2p)" != '"enter"' ]; then pass; else fail "normalizeKey: a linefeed (ctrl-j) must not count as enter"; fi
if [ "$(printf '%s\n' "$adapter_keys" | sed -n 3p)" = '"j"' ]; then pass; else fail "normalizeKey: a plain character key is itself, got $(printf '%s\n' "$adapter_keys" | sed -n 3p)"; fi
frame_s=$(render_settings "$REL" "$INSTALL" ".,enter,enter") || fail "enter twice: render exited non-zero"
assert_contains "$frame_s" "cancelled; nothing was installed" "a second enter after the prompt opened cancels it (the old double delivery, through --keys)"
assert_no_upgrade "enter twice runs nothing"

# A checkout (no install record): the page says so with the git command the launcher prints, offers
# no upgrade and no Back to stable, lists the betas read-only and asks the default repository
# (falsify: drop the checkout guard from settingsEntries, or make readInstall default to a record).
# 200 columns: the git line names the checkout path and the package directory, and a long TMPDIR
# (macOS) pushes it past the fixture's 160 and into the ellipsis.
frame_s=$(render_settings "$REL" "$CHECKOUT" "." --cols 200) || fail "checkout: render exited non-zero"
assert_row "$frame_s" '^ firstmate-tui 0\.1\.0 \(stable release\) +$' "checkout: the running version"
assert_contains "$frame_s" " running from a checkout at $CHECKOUT (no install record); update it with git:" "checkout: the page says it is a checkout"
assert_contains "$frame_s" "   git -C $CHECKOUT pull   (then (cd bin/firstmate-tui && npm ci) when the lockfile changed)" "checkout: the git command the launcher prints"
assert_not_contains "$frame_s" "installed at" "checkout: no install line"
assert_row "$frame_s" '^ latest stable  0\.2\.0 · published 2026-09-17 · newer than this checkout; git pull updates it +$' "checkout: the latest line points at git instead of an upgrade"
assert_not_contains "$frame_s" "Upgrade to" "checkout: no upgrade action"
assert_row "$frame_s" '^ ▸ Betas +3 prereleases \(read-only from a checkout\) +$' "checkout: Betas is read-only and first"
assert_file_contains "$CURL_LOG" "https://api.github.com/repos/zachsibert/firstmate-tui/releases/latest" "checkout: without a record the default repository is asked"
frame_s=$(render_settings "$REL" "$CHECKOUT" ".,enter") || fail "checkout betas: render exited non-zero"
assert_row "$frame_s" '^ prereleases of zachsibert/firstmate-tui, newest first \(read-only from a checkout\) +$' "checkout betas: the list says it is read-only"
assert_row "$frame_s" '^   0\.2\.0-9f8e7d6 +commit 9f8e7d6   2026-09-17 +$' "checkout betas: prereleases are listed"
assert_not_contains "$frame_s" "▸" "checkout betas: nothing takes the cursor"
assert_not_contains "$frame_s" "Back to stable" "checkout betas: no Back to stable"
frame_s=$(render_settings "$REL" "$CHECKOUT" ".,enter,enter,y") || fail "checkout enter: render exited non-zero"
assert_no_upgrade "checkout: enter and y in the read-only list run nothing"
assert_contains "$frame_s" "no upgrade from a checkout; update it with git -C $CHECKOUT pull" "checkout: enter in the list says why"
frame_s=$(render_settings "$REL" "$CHECKOUT" ".,y,y") || fail "checkout y: render exited non-zero"
assert_no_upgrade "checkout: y with nothing pending runs nothing"

# Closing: esc, . and q bring the board back with its selection and expanded groups intact (falsify:
# reset view.pane or view.row when the page closes, or drop the close case).
# tab,j selects the second My PRs row, api#8 (the pane sorts by status, newest first, so
# ship-alpha's newer PR 41 comes first), a selection enter would not reach from the default one.
rm -f "$OPENER_LOG"
frame_o=$(FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" render populated.json --install-root "$INSTALL" --keys "tab,tab,j,.,escape,enter" --opener-cmd "$FAKE_OPENER") || fail "settings esc: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/8" "esc closes the page and enter acts on the row selected before it opened"
assert_count "$frame_o" "┌─" 6 "esc: the grid is back"
rm -f "$OPENER_LOG"
frame_o=$(FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" render populated.json --install-root "$INSTALL" --keys "tab,tab,j,.,.,enter" --opener-cmd "$FAKE_OPENER") || fail "settings dot: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/8" ". closes the page with the selection intact"
rm -f "$OPENER_LOG"
frame_o=$(FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" render populated.json --install-root "$INSTALL" --keys "tab,tab,j,.,q,enter" --opener-cmd "$FAKE_OPENER") || fail "settings q: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/8" "q closes the page like the help overlay, and the board is not quit"
frame_k=$(render populated.json --install-root "$INSTALL" --keys "tab,j,j,l,.,escape") || fail "settings expanded: render exited non-zero"
assert_row "$frame_k" '^│ working +1 live +!▾ delegate-a ' "a group expanded before the page opened is still expanded after it closes"
# . works from the landing page too and esc returns there (falsify: drop . from LANDING_KEYS).
frame_s=$(render populated.json --install-root "$INSTALL" --keys "1,2,3,4,5,6,.") || fail "settings landing: render exited non-zero"
assert_row "$frame_s" '^ Settings +$' ". opens the page from the landing page"
frame_s=$(render populated.json --install-root "$INSTALL" --keys "1,2,3,4,5,6,.,escape") || fail "settings landing esc: render exited non-zero"
assert_row "$frame_s" '^ +all panes hidden +$' "esc returns to the landing page"
# Help: the overlay documents . and opens over the page (falsify: drop the . line from HELP_LINES).
frame_k=$(render populated.json --keys "?") || fail "help settings: render exited non-zero"
assert_contains "$frame_k" ".            settings page: installed version, latest release, upgrade or a beta" "help overlay documents ."
assert_contains "$frame_k" "upgrade or a beta (asks y first; . closes)" "help overlay documents the confirm step (folded onto the . line so the help box clears the footer at 44 rows)"
frame_s=$(render populated.json --install-root "$INSTALL" --keys ".,?") || fail "help over settings: render exited non-zero"
assert_contains "$frame_s" "firstmate-tui keys" "? opens the help over the settings page"
# Narrow: the page fits the list-mode frame (falsify: pick the layout mode before the page check).
frame_s=$(SETTINGS_FIXTURE=narrow.json render_settings "$REL" "$INSTALL" ".") || fail "settings narrow: render exited non-zero"
assert_row "$frame_s" '^ Settings +$' "narrow: the page renders"
assert_contains "$frame_s" " latest stable  0.2.0 · published 2026-09-17 · upgrade available" "narrow: the latest line fits"
assert_widths "$frame_s" 70 "narrow settings: lines are 70 columns"
assert_lines "$frame_s" 24 "narrow settings: 24 lines"

# The mouse on the page. At 160x40 with the newer release set the main menu draws Upgrade on line 7,
# Betas on 8 and Refresh release data on 9, the flags on 11-14; the Betas menu draws its three
# prereleases on 7-9 and Back to stable on 10. A click highlights an entry, two clicks within the
# double-click window on one entry are enter on it, the wheel moves the highlight one entry, a click
# while a confirmation is pending cancels it, and no click on the page reaches the board behind it
# (falsify: drop the settings zones from renderSettings, the settings branch from handleMouse, or the
# pending check from settingsMouseAction).
frame_s=$(render_settings "$REL" "$INSTALL" "." --mouse "click:10,8") || fail "settings click: render exited non-zero"
assert_row "$frame_s" '^ ▸ Betas ' "a click on the Betas line highlights it"
assert_no_row "$frame_s" '^ ▸ Upgrade' "a click on the Betas line takes the highlight off Upgrade"
assert_row "$frame_s" '^ Settings +$' "a single click chooses nothing: the main menu stays"
frame_s=$(render_settings "$REL" "$INSTALL" "." --mouse "click:10,8 click:10,8") || fail "settings two clicks: render exited non-zero"
assert_row "$frame_s" '^ Settings +$' "two clicks a second apart on Betas only highlight it"
frame_s=$(render_settings "$REL" "$INSTALL" "." --mouse "dblclick:10,8") || fail "settings dblclick: render exited non-zero"
assert_row "$frame_s" '^ Settings · Betas +$' "a double-click on Betas opens the submenu, as enter does"
frame_s=$(render_settings "$REL" "$INSTALL" "." --mouse "wheel:down:80,20") || fail "settings wheel: render exited non-zero"
assert_row "$frame_s" '^ ▸ Betas ' "wheel down moves the highlight one entry, wherever the pointer is"
frame_s=$(render_settings "$REL" "$INSTALL" "." --mouse "wheel:up:80,20") || fail "settings wheel up: render exited non-zero"
assert_row "$frame_s" '^ ▸ Upgrade to 0\.2\.0 ' "wheel up at the top stays on the first entry"
frame_s=$(render_settings "$REL" "$INSTALL" "." --mouse "click:10,12 click:30,0 click:30,43") || fail "settings chrome click: render exited non-zero"
assert_row "$frame_s" '^ ▸ Upgrade to 0\.2\.0 ' "clicks on a flag line, the title line and the footer change nothing on the page"
frame_s=$(render_settings "$REL" "$INSTALL" "." --mouse "dblclick:10,7") || fail "settings dblclick upgrade: render exited non-zero"
assert_row "$frame_s" '^ install 0\.2\.0 \(firstmate-tui upgrade --version 0\.2\.0\)\? y to confirm, esc to cancel +$' "a double-click on Upgrade asks for confirmation like enter"
assert_no_upgrade "a double-click runs nothing before y"
frame_s=$(render_settings "$REL" "$INSTALL" ".,enter" --mouse "click:10,9") || fail "settings click while pending: render exited non-zero"
assert_contains "$frame_s" "cancelled; nothing was installed" "a click while a confirmation is pending cancels it"
assert_row "$frame_s" '^ ▸ Upgrade to 0\.2\.0 ' "the cancelling click does not move the highlight"
assert_no_upgrade "a click while pending runs nothing"
frame_s=$(render_settings "$REL" "$INSTALL" ".,j,enter" --mouse "dblclick:10,8") || fail "settings betas dblclick: render exited non-zero"
assert_row "$frame_s" '^ install 0\.1\.0-d8b290e \(firstmate-tui upgrade --version 0\.1\.0-d8b290e\)\? y to confirm, esc to cancel +$' "in Betas a double-click on the second prerelease asks to install exactly it"
assert_no_upgrade "in Betas a double-click runs nothing before y"
frame_s=$(render_settings "$REL" "$INSTALL" "." --no-mouse --mouse "click:10,8 dblclick:10,8") || fail "settings no-mouse click: render exited non-zero"
assert_row "$frame_s" '^ ▸ Upgrade to 0\.2\.0 ' "--no-mouse: clicks on the page change nothing"
assert_row "$frame_s" '^ Settings +$' "--no-mouse: a double-click opens no submenu"
# A click on the page lands on the page, never on the board row that would be under the pointer: the
# board's selection from before the page opened is what enter acts on afterwards.
rm -f "$OPENER_LOG"
frame_o=$(FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" render populated.json --install-root "$INSTALL" --keys "tab,tab,j,." --mouse "click:30,33 wheel:down:30,29" --keys "escape,enter" --opener-cmd "$FAKE_OPENER") || fail "settings click through: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/8" "a click and a wheel on the page leave the board's selection where it was"

# ------------------------------------------------------------ refresh schedule
# The two cycles, run with --headless and --refresh 5 (the minimum), the fake gh on PATH, stopped
# with a signal: the fetch log (one line per snapshot start and per gh call, in the order the
# processes started) is the evidence. The local cycle is the snapshot: its timer is due 5 s after
# its start and armed when it lands, so a snapshot slower than the cadence is followed by the next
# one at once and never by two. The GitHub cycle follows each landed snapshot without being awaited,
# one at a time: a landing during a running fetch leaves one follow-up behind it.
#
# A slow snapshot (7 s) with gh answering at once: from launch the snapshot runs 0-7 s; at 7 s its
# fetch (the identity call, four searches and the lookup, all within the second) and, the timer
# being due, the second snapshot (7-14 s); at 14 s the second fetch and the third snapshot, still
# running when the run stops at 19 s. Three snapshot lines, one identity call, ten graphql lines;
# the identity call and the first fetch's five lines come after the first snapshot line and before
# the third, the second fetch's five after the second snapshot line (falsify: arm the timer from
# the landing instead of the start: two snapshots and five gh lines; keep the old fixed interval:
# two snapshots; never clear the refreshing flag: one; re-arm the timer at the start of a cycle as
# well: four; start the fetch with the snapshot instead of after it: gh lines before the first
# snapshot line; resolve the identity per tick: two user calls).
SLOW_HOME="$SCRATCH/firstmate-slow"
mkdir -p "$SLOW_HOME/bin"
# shellcheck disable=SC2016 # the fake expands $FM_BOARD_TEST_FETCH_LOG at run time, not here
printf '#!/usr/bin/env bash\necho snapshot >> "$FM_BOARD_TEST_FETCH_LOG"\nsleep 7\ncat "%s"\n' "$FAKE_HOME/snapshot.json" > "$SLOW_HOME/bin/fm-fleet-snapshot.sh"
cp "$FAKE_HOME/bin/fm-bearings-snapshot.sh" "$SLOW_HOME/bin/fm-bearings-snapshot.sh"
chmod +x "$SLOW_HOME/bin/fm-fleet-snapshot.sh" "$SLOW_HOME/bin/fm-bearings-snapshot.sh"
# log_line <pattern> <n>: the line number in FETCH_LOG of the n-th line matching the pattern, or 0
log_line() {
  local n
  n=$(grep -n -- "$1" "$FETCH_LOG" 2>/dev/null | sed -n "${2}p" | cut -d: -f1)
  printf '%s\n' "${n:-0}"
}
rm -f "${FETCH_LOG:?}"
FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$SLOW_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" PATH="$FAKE_BIN:$PATH" "$BOARD" --headless --refresh 5 --no-herdr > "$SCRATCH/headless.log" 2>&1 &
headless_pid=$!
sleep 19
# The launcher runs node as a child, so a signal to the launcher alone leaves the board running (and
# appending to FETCH_LOG every refresh for the rest of the suite): signal the child first, then the launcher.
pkill -TERM -P "$headless_pid" 2>/dev/null
kill "$headless_pid" 2>/dev/null
wait "$headless_pid" 2>/dev/null
headless_log=$(cat "$FETCH_LOG" 2>/dev/null || echo '<absent>')
if [ "$(grep -c '^snapshot$' "$FETCH_LOG" 2>/dev/null)" = 3 ]; then pass; else fail "headless slow snapshot: expected three snapshot starts in 19 s (0, 7 and 14 s), log is '$headless_log' (board output: $(cat "$SCRATCH/headless.log"))"; fi
if [ "$(grep -c '^gh api graphql ' "$FETCH_LOG" 2>/dev/null)" = 10 ]; then pass; else fail "headless slow snapshot: one fetch per landed snapshot (two landed, four searches and one lookup each); log is '$headless_log' (board output: $(cat "$SCRATCH/headless.log"))"; fi
if [ "$(grep -c '^gh api user ' "$FETCH_LOG" 2>/dev/null)" = 1 ]; then pass; else fail "headless slow snapshot: the identity is resolved once per session, not per tick; log is '$headless_log'"; fi
if [ "$(head -n 1 "$FETCH_LOG" 2>/dev/null)" = snapshot ]; then pass; else fail "headless slow snapshot: the snapshot starts before any gh call; log is '$headless_log'"; fi
if [ "$(log_line '^gh api user ' 1)" -gt 1 ] && [ "$(log_line '^gh api user ' 1)" -lt "$(log_line '^snapshot$' 3)" ] && [ "$(log_line '^gh api graphql ' 5)" -lt "$(log_line '^snapshot$' 3)" ]; then pass; else fail "headless slow snapshot: the identity call and the first fetch follow the first landed snapshot and precede the third snapshot start; log is '$headless_log'"; fi
if [ "$(log_line '^gh api graphql ' 6)" -gt "$(log_line '^snapshot$' 2)" ]; then pass; else fail "headless slow snapshot: the second fetch follows the second landed snapshot; log is '$headless_log'"; fi
if grep -q '^prs ' "$FETCH_LOG" 2>/dev/null; then fail "headless slow snapshot: the firstmate PR script ran although gh is on PATH; log is '$headless_log'"; else pass; fi
if [ -s "$SCRATCH/headless.log" ]; then fail "headless run wrote to the terminal: $(head -c 300 "$SCRATCH/headless.log")"; else pass; fi
# A slow gh (FAKE_GH_SLEEP=7: every graphql answer 7 s late, so one fetch, the four searches
# together and then the lookup, takes 14 s) with the stand-in snapshot answering at once: the
# snapshot at 0 s and its fetch 0-14 s; the snapshots at 5, 10 and 15 s land while it runs and leave
# one follow-up between them; at 14 s the follow-up's four searches start (its lookup would at
# 21 s); stopped at 18 s. Four snapshot lines (the local cadence held through the fetch), one
# identity call and nine graphql lines: the one lookup line has exactly four search lines before it
# and four after, and the follow-up's four come after the third snapshot line (falsify: await the
# fetch in the local cycle again: two snapshot lines, at 0 and 14 s; start a fetch per landed
# snapshot: eight search lines before the lookup; forget the follow-up: five graphql lines in all;
# start the follow-up when it is asked for instead of after the running fetch: search lines before
# the lookup line).
rm -f "${FETCH_LOG:?}"
FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FAKE_GH_SLEEP=7 FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" PATH="$FAKE_BIN:$PATH" "$BOARD" --headless --refresh 5 --no-herdr > "$SCRATCH/headless-gh.log" 2>&1 &
headless_pid=$!
sleep 18
pkill -TERM -P "$headless_pid" 2>/dev/null
kill "$headless_pid" 2>/dev/null
wait "$headless_pid" 2>/dev/null
headless_log=$(cat "$FETCH_LOG" 2>/dev/null || echo '<absent>')
if [ "$(grep -c '^snapshot$' "$FETCH_LOG" 2>/dev/null)" = 4 ]; then pass; else fail "headless slow gh: expected four snapshot starts in 18 s (0, 5, 10 and 15 s) while one fetch ran 14 s, log is '$headless_log' (board output: $(cat "$SCRATCH/headless-gh.log"))"; fi
if [ "$(grep -c '^gh api user ' "$FETCH_LOG" 2>/dev/null)" = 1 ]; then pass; else fail "headless slow gh: the identity is resolved once; log is '$headless_log'"; fi
if [ "$(grep -c '^gh api graphql ' "$FETCH_LOG" 2>/dev/null)" = 9 ]; then pass; else fail "headless slow gh: the first fetch's five graphql calls and the one follow-up's four searches, nothing for the other two landings; log is '$headless_log'"; fi
if [ "$(grep -c '^gh api graphql lookup=' "$FETCH_LOG" 2>/dev/null)" = 1 ] && [ "$(grep '^gh api graphql ' "$FETCH_LOG" 2>/dev/null | grep -n 'lookup=' | cut -d: -f1)" = 5 ]; then pass; else fail "headless slow gh: one lookup, with four searches before it (the first fetch) and four after (the follow-up started when it landed, never while it ran); log is '$headless_log'"; fi
if [ "$(log_line '^gh api graphql ' 6)" -gt "$(log_line '^snapshot$' 3)" ]; then pass; else fail "headless slow gh: the follow-up's searches start after the third snapshot landed; log is '$headless_log'"; fi
if grep -q '^prs ' "$FETCH_LOG" 2>/dev/null; then fail "headless slow gh: the firstmate PR script ran although gh is on PATH; log is '$headless_log'"; else pass; fi
if [ -s "$SCRATCH/headless-gh.log" ]; then fail "headless slow gh run wrote to the terminal: $(head -c 300 "$SCRATCH/headless-gh.log")"; else pass; fi

# ------------------------------------------------- refresh countdown, herdr link
# The title line carries one refresh label, from the fixture's refresh block at the fixture's clock
# (now = 12:00:00Z), and the pane headers carry none of the old ages (falsify: drop refreshLabel from
# buildModel's meta, or the refresh segment from titleLine).
assert_row "$frame" '^ firstmate-tui · /fixture/firstmate · 3 homes +next refresh in 18s $' "countdown: the title line reads next refresh in 18s from {\"next_in\": 18}"
assert_count "$frame" "next refresh" 1 "countdown: the label is on the title line only"
frame_c=$(render "$(variant populated.json due '{"refresh": {"next_in": 0}}')") || fail "countdown due: render exited non-zero"
assert_row "$frame_c" '^ firstmate-tui .* +next refresh in 0s $' "countdown: a due refresh reads 0s"
frame_c=$(render "$(variant populated.json overdue '{"refresh": {"next_in": -5}}')") || fail "countdown overdue: render exited non-zero"
assert_row "$frame_c" '^ firstmate-tui .* +next refresh in 0s $' "countdown: never negative (falsify: drop Math.max from refreshLabel)"
# While a refresh runs the label says so and counts nothing (falsify: drop the refreshing branch).
frame_c=$(render "$(variant populated.json refreshing '{"refresh": {"refreshing": true, "next_in": 18}}')") || fail "refreshing: render exited non-zero"
assert_row "$frame_c" '^ firstmate-tui · /fixture/firstmate · 3 homes +refreshing… $' "refreshing: the title line reads refreshing…"
assert_not_contains "$frame_c" "next refresh" "refreshing: no countdown beside it"
# The GitHub cycle's own flag, {"fetching": true}: over rows it marks the two PR pane titles
# (updating), keeps their rows, spins nothing and leaves the title line on the local countdown; a
# stale marker keeps its place before it; with the identity unknown, or with --no-prs, nothing is
# fetched and no pane carries it (falsify: drop paneUpdating from paneHeader, key it on refreshing,
# read fetching in refreshLabel, or mark a loading pane too).
frame_c=$(render "$(variant populated.json fetching '{"refresh": {"fetching": true, "next_in": 18}}')") || fail "fetching: render exited non-zero"
assert_contains "$frame_c" "┌─ [3] My PRs (3) (updating) ─" "fetching: My PRs keeps its count and is marked updating"
assert_contains "$frame_c" "┌─ [4] Teammates' PRs (0) (updating) ─" "fetching: Teammates' PRs, empty after an earlier fetch, is marked updating too"
assert_count "$frame_c" "(updating)" 2 "fetching: the two PR panes alone carry the marker"
assert_row "$frame_c" '^ firstmate-tui · /fixture/firstmate · 3 homes +next refresh in 18s $' "fetching: the title line keeps the local countdown and never reads refreshing"
assert_row "$frame_c" '^│ passing +IN REVIEW +ship-alpha +Add the widget cache +main +3h │$' "fetching: the PR rows stay under the marker"
assert_count "$frame_c" "loading" 0 "fetching: a pane with rows spins nothing"
frame_c=$(render "$(variant populated.json fetching-stale '{"prs": {"mine": {"error": "My PRs: exit 1"}}, "refresh": {"fetching": true, "next_in": 18}}')") || fail "fetching stale: render exited non-zero"
assert_contains "$frame_c" "┌─ [3] My PRs (3) (stale) (updating) ─" "fetching: the stale marker keeps its place before updating"
frame_c=$(render "$(variant populated.json fetching-unknown '{"prs": {"identity": {"login": null, "source": "unknown", "reason": "fixture"}}, "refresh": {"fetching": true, "next_in": 18}}')") || fail "fetching identity unknown: render exited non-zero"
assert_count "$frame_c" "(updating)" 0 "fetching with the identity unknown: nothing is fetched for nobody, so no marker"
frame_c=$(render "$(variant populated.json fetching '{"refresh": {"fetching": true, "next_in": 18}}')" --no-prs) || fail "fetching --no-prs: render exited non-zero"
assert_count "$frame_c" "(updating)" 0 "fetching --no-prs: the PR panes are off, so no marker"
# With nothing fetched yet the flag draws the fetch spinners in the two PR panes, and the four fleet
# panes, whose cycle is not running, read their empty text; the flag off draws neither marker nor
# spinner (falsify: key the PR spinners on refreshing alone, or the fleet spinners on fetching).
frame_c=$(render "$(variant cold-start.json fetching-cold '{"refresh": {"refreshing": false, "fetching": true}}')") || fail "fetching cold: render exited non-zero"
assert_count "$frame_c" "⠋ loading GitHub checks…" 1 "fetching with nothing fetched: My PRs spins on the fetch"
assert_count "$frame_c" "⠋ loading GitHub review requests…" 1 "fetching with nothing fetched: Teammates' PRs spins on its own fetch"
assert_count "$frame_c" "(updating)" 0 "fetching with nothing fetched: a spinning pane carries no marker"
assert_count "$frame_c" "loading fleet snapshot" 0 "fetching alone: the fleet panes do not spin"
assert_row "$frame_c" '^│ nothing is underway +│$' "fetching alone: Underway reads its empty text"
assert_no_row "$frame_c" '^ firstmate-tui .*refreshing' "fetching alone: the title line does not read refreshing"
frame_c=$(render "$(variant populated.json fetching-off '{"refresh": {"fetching": false, "next_in": 18}}')") || fail "fetching off: render exited non-zero"
assert_count "$frame_c" "(updating)" 0 "fetching false: no marker"
assert_count "$frame_c" "loading" 0 "fetching false: no spinner"
# A failed PR fetch: the title line names the failure's age and the retry in red, the Ready for
# review header alone is marked stale, and the previous PR rows stay (falsify: drop the failedAt
# branch from refreshLabel, the 'title bad' style from titleLine, or the review case from paneStale).
fx_pf=$(variant populated.json pr-failed '{"prs": {"error": "exit 1"}, "refresh": {"failed_ago": 40, "next_in": 20, "failed": "PR fetch: exit 1"}}')
frame_f=$(render "$fx_pf") || fail "PR fetch failed: render exited non-zero"
tags_f=$(render "$fx_pf" --tags) || fail "PR fetch failed --tags: render exited non-zero"
assert_row "$frame_f" '^ firstmate-tui · /fixture/firstmate · 3 homes +refresh failed 40s ago, retrying in 20s $' "PR fetch failed: the title line reads refresh failed 40s ago, retrying in 20s"
assert_contains "$tags_f" "{red-fg}refresh failed 40s ago, retrying in 20s{/red-fg}" "PR fetch failed: the label is red"
assert_contains "$frame_f" "┌─ [3] My PRs (3) (stale) ─" "PR fetch failed: the review header is marked stale"
assert_count "$frame_f" "(stale)" 2 "PR fetch failed: a fixture error with no per-pane block marks both PR panes stale and nothing else"
assert_contains "$frame_f" "┌─ [4] Teammates' PRs (0) (stale) ─" "PR fetch failed: Teammates' PRs is marked stale too"
# A failure of one pane's searches alone: that pane is stale, the other PR pane is not (falsify: read
# the top-level error in paneStale instead of the pane's own).
frame_f=$(render "$(variant populated.json review-failed '{"prs": {"toreview": {"error": "review searches: exit 1"}}, "refresh": {"failed_ago": 40, "next_in": 20, "failed": "PR fetch: review searches: exit 1"}}')") || fail "Teammates' PRs fetch failed: render exited non-zero"
assert_count "$frame_f" "(stale)" 1 "Teammates' PRs fetch failed: one pane is stale"
assert_contains "$frame_f" "┌─ [4] Teammates' PRs (0) (stale) ─" "Teammates' PRs fetch failed: Teammates' PRs is the stale pane"
assert_contains "$frame_f" "┌─ [3] My PRs (3) ─" "Teammates' PRs fetch failed: My PRs, whose searches succeeded, is not stale"
frame_f=$(render "$(variant populated.json mine-failed '{"prs": {"mine": {"error": "My PRs: exit 1"}}, "refresh": {"failed_ago": 40, "next_in": 20, "failed": "PR fetch: My PRs: exit 1"}}')") || fail "My PRs fetch failed: render exited non-zero"
assert_count "$frame_f" "(stale)" 1 "My PRs fetch failed: one pane is stale"
assert_contains "$frame_f" "┌─ [3] My PRs (3) (stale) ─" "My PRs fetch failed: My PRs is the stale pane and keeps its rows"
assert_contains "$frame_f" "┌─ [4] Teammates' PRs (0) ─" "My PRs fetch failed: Teammates' PRs is not stale"
assert_row "$frame_f" '^│ passing +IN REVIEW +ship-alpha +Add the widget cache +main +3h │$' "PR fetch failed: the previous PR rows stay on screen"
# A failed snapshot: the four snapshot panes are marked stale and My PRs is not (falsify:
# swap the pane test in paneStale).
frame_f=$(render "$(variant populated.json snap-failed '{"snapshot_error": "exit 1", "refresh": {"failed_ago": 5, "next_in": 25, "failed": "snapshot: exit 1"}}')") || fail "snapshot failed: render exited non-zero"
assert_row "$frame_f" '^ firstmate-tui · /fixture/firstmate · 3 homes +refresh failed 5s ago, retrying in 25s $' "snapshot failed: the title line names the failure"
assert_count "$frame_f" "(stale)" 4 "snapshot failed: four panes are marked stale"
assert_contains "$frame_f" "┌─ [1] Captain's Call (6) (stale) ─" "snapshot failed: Captain's Call is stale"
assert_contains "$frame_f" "┌─ [2] Underway (6) (stale) ─" "snapshot failed: Underway is stale"
assert_contains "$frame_f" "┌─ [5] Charted Next (1) (stale) ─" "snapshot failed: Charted Next is stale"
assert_contains "$frame_f" "┌─ [6] Recently Landed (5) (stale) ─" "snapshot failed: Recently Landed is stale"
assert_contains "$frame_f" "┌─ [3] My PRs (3) ─" "snapshot failed: My PRs, whose fetch succeeded, is not stale"
assert_contains "$frame_f" "┌─ [4] Teammates' PRs (0) ─" "snapshot failed: Teammates' PRs is not stale either"
# The failure text stays in the facts but the label keeps the spec's words: a failure with no age given
# reads 0s ago (falsify: require failed_ago in refreshFromFixture).
frame_f=$(render "$(variant populated.json failed-noage '{"refresh": {"failed": "snapshot: exit 1", "next_in": 30}}')") || fail "failed no age: render exited non-zero"
assert_row "$frame_f" '^ firstmate-tui .* +refresh failed 0s ago, retrying in 30s $' "failed without an age: reads 0s ago"
# Without a refresh block (lost.json) the title line carries no refresh label at all: a one-shot render
# has no schedule (falsify: invent a label when facts.refresh is null).
assert_no_row "$frame_l" '^ firstmate-tui .*refresh' "no refresh block: no refresh label on the title line"
# Herdr link. Connected: no herdr text anywhere on the frame (falsify: bring herdrLabel back into
# the title or the headers). The populated fixture's block has no state, so under --no-herdr it is the
# offline overlay "fixture", which also shows nothing; an explicit connected state is checked too.
assert_count "$frame" "herdr" 0 "fixture overlay: no herdr text on the frame"
frame_h=$(render "$(variant populated.json connected '{"herdr": {"state": "connected"}}')") || fail "connected: render exited non-zero"
tags_h=$(render "$(variant populated.json connected '{"herdr": {"state": "connected"}}')" --tags) || fail "connected --tags: render exited non-zero"
assert_count "$frame_h" "herdr" 0 "connected: no herdr text on the frame"
assert_not_contains "$tags_h" "herdr disconnected" "connected --tags: no warning"
# Down for any reason: one red warning on the title line naming the reason; the reason is left out
# when the client recorded none (falsify: print empty parentheses, or drop a state from herdrWarning).
frame_h=$(render "$(variant populated.json connecting '{"herdr": {"state": "connecting"}}')") || fail "connecting: render exited non-zero"
assert_row "$frame_h" '^ firstmate-tui .* +next refresh in 18s · herdr disconnected \(connecting\) $' "never connected: the title line warns herdr disconnected (connecting) beside the countdown"
assert_count "$frame_h" "herdr" 1 "never connected: the title warning is the only herdr text"
frame_h=$(render "$(variant populated.json unavailable '{"herdr": {"state": "unavailable", "detail": "cannot run herdr: not found"}}')") || fail "unavailable: render exited non-zero"
assert_contains "$frame_h" "herdr disconnected (cannot run herdr: not found) " "herdr not on PATH: the warning carries the client's reason"
frame_h=$(render "$(variant populated.json dropped '{"herdr": {"state": "disconnected", "detail": "closed"}}')") || fail "dropped: render exited non-zero"
tags_h=$(render "$(variant populated.json dropped '{"herdr": {"state": "disconnected", "detail": "closed"}}')" --tags) || fail "dropped --tags: render exited non-zero"
assert_contains "$frame_h" "next refresh in 18s · herdr disconnected (closed) " "dropped: the warning names the socket's close"
assert_contains "$tags_h" "{red-fg}herdr disconnected (closed){/red-fg}" "dropped --tags: the warning is red"
assert_row "$tags_h" '\{white-bg\}next refresh in 18s\{/white-bg\}' "dropped --tags: the countdown beside it keeps the plain title style"
frame_h=$(render "$(variant populated.json noreason '{"herdr": {"state": "disconnected", "detail": ""}}')") || fail "no reason: render exited non-zero"
assert_row "$frame_h" '^ firstmate-tui .* · herdr disconnected $' "dropped with no recorded reason: the parentheses are left out"
tags_e=$(render empty.json --tags) || fail "empty --tags: render exited non-zero"
assert_contains "$tags_e" "{red-fg}herdr disconnected (--no-herdr){/red-fg}" "--no-herdr --tags: the warning is red"
# Narrow: the left text gives way to the right-hand labels and the line keeps its width (falsify: pad
# the title to cols before the labels, or drop the truncate in titleLine).
frame_h=$(render "$(variant narrow.json narrow-both '{"refresh": {"next_in": 18}, "herdr": {"state": "disconnected", "detail": "ECONNREFUSED"}}')") || fail "narrow both labels: render exited non-zero"
assert_row "$frame_h" '^ firstmate-[^ ]*… next refresh in 18s · herdr disconnected \(ECONNREFUSED\) $' "narrow: both labels fit and the left text is cut (at 70 columns with both labels, the name itself)"
assert_widths "$frame_h" 70 "narrow: the title line is still 70 columns"
# The Settings page keeps the same title line (falsify: give renderSettings its own title).
frame_h=$(render "$(variant populated.json settings-title '{"herdr": {"state": "disconnected", "detail": "closed"}}')" --install-root "$INSTALL" --keys ".") || fail "settings title: render exited non-zero"
assert_row "$frame_h" '^ firstmate-tui · /fixture/firstmate · 3 homes +next refresh in 18s · herdr disconnected \(closed\) $' "settings page: the title line carries the countdown and the warning"
assert_row "$frame_h" '^ Settings +$' "settings page: the page itself is drawn"

# --------------------------------------------------------- loading spinner
# assert_line <frame> <line number from 1> <extended regex> <label>: that one line matches
assert_line() {
  local got
  got=$(printf '%s\n' "$1" | sed -n "${2}p")
  if printf '%s\n' "$got" | grep -Eq -- "$3"; then pass; else fail "$4: line $2 is '$got', expected /$3/"; fi
}
# Cold start (cold-start.json, 120x40): the first refresh is in flight and nothing has landed, so
# each pane body is one spinner line, the first braille frame and the source the pane waits on,
# right under its column header, and no pane draws its empty text (falsify: drop paneLoading from
# buildModel, the loading branch from renderPanes, or name one source for every pane).
frame_ld=$(render cold-start.json) || fail "cold start: render exited non-zero"
tags_ld=$(render cold-start.json --tags) || fail "cold start --tags: render exited non-zero"
assert_row "$frame_ld" '^ firstmate-tui · /fixture/firstmate · 1 home +refreshing… · herdr disconnected \(--no-herdr\) $' "cold start: the title line reads refreshing… (the block that puts the panes into the loading state)"
assert_count "$frame_ld" "⠋ loading fleet snapshot…" 4 "cold start: Captain's Call, Underway, Charted Next and Recently Landed each spin and name the fleet snapshot"
assert_count "$frame_ld" "⠋ loading GitHub checks…" 1 "cold start: My PRs alone names the GitHub checks"
assert_line "$frame_ld" 4 '^│ ⠋ loading fleet snapshot… +│$' "cold start: Captain's Call's first body line, at the top of the frame, is the spinner"
assert_line "$frame_ld" 26 '^│ ⠋ loading GitHub checks… +│$' "cold start: My PRs' first body line is the spinner"
assert_line "$frame_ld" 8 '^│ ⠋ loading fleet snapshot… +│$' "cold start: Underway's first body line is the spinner"
assert_line "$frame_ld" 34 '^│ ⠋ loading fleet snapshot… +│$' "cold start: Charted Next's first body line is the spinner"
assert_line "$frame_ld" 38 '^│ ⠋ loading fleet snapshot… +│$' "cold start: Recently Landed's first body line is the spinner"
assert_count "$frame_ld" "⠋ loading GitHub review requests…" 1 "cold start: Teammates' PRs alone names the GitHub review requests (falsify: name one source for both PR panes)"
assert_line "$frame_ld" 30 '^│ ⠋ loading GitHub review requests… +│$' "cold start: Teammates' PRs' first body line, right under My PRs, is its own spinner"
for empty_text in "no captain decisions, holds or blocked workers" "no pull requests of yours" "no workers in flight" "no scout reports" "nothing landed yet" "no pull requests waiting for your review"; do
  assert_not_contains "$frame_ld" "$empty_text" "cold start: the spinner replaces the empty text (falsify: draw the empty text beside the loading line)"
done
assert_contains "$frame_ld" "┌─ [2] Underway (0) ─" "cold start: the headers count zero rows and carry no stale marker"
assert_count "$frame_ld" "(stale)" 0 "cold start: nothing has failed, so nothing is stale"
assert_widths "$frame_ld" 120 "cold start: every line is still 120 columns"
assert_contains "$tags_ld" "{blue-fg}⠋ loading fleet snapshot…" "cold start --tags: the spinner line is dimmed like the empty text (falsify: give it the row style)"
# The identity not yet resolved on a cold start (cold-start.json with prs.identity null, the app's
# state until its first refresh has asked the rungs, which follows the snapshot): the two PR panes
# spin on the identity, in the exact shape of the other spinner lines, in place of the fetch
# spinners, and the unknown row is nowhere; cold-start.json itself stands for a known login, so it
# keeps showing the fetch spinners above (falsify: read a null identity as unknown in
# identityMissing, give the resolving line its own style, or leave it on a hard-coded glyph).
frame_ld=$(render "$(variant cold-start.json identity-pending '{"prs": {"identity": null}}')") || fail "cold start identity pending: render exited non-zero"
tags_ld=$(render "$(variant cold-start.json identity-pending '{"prs": {"identity": null}}')" --tags) || fail "cold start identity pending --tags: render exited non-zero"
assert_count "$frame_ld" "⠋ resolving GitHub identity…" 2 "cold start identity pending: both PR panes spin on the identity"
assert_line "$frame_ld" 26 '^│ ⠋ resolving GitHub identity… +│$' "cold start identity pending: My PRs' first body line is the resolving spinner"
assert_line "$frame_ld" 30 '^│ ⠋ resolving GitHub identity… +│$' "cold start identity pending: Teammates' PRs' first body line is the resolving spinner"
assert_not_contains "$frame_ld" "identity unknown" "cold start identity pending: the identity row is not drawn before the rungs have answered"
assert_not_contains "$frame_ld" "loading GitHub" "cold start identity pending: the fetch spinners wait for the login"
assert_count "$frame_ld" "⠋ loading fleet snapshot…" 4 "cold start identity pending: the four snapshot panes still spin on the snapshot"
assert_contains "$frame_ld" "┌─ [3] My PRs (0) ─" "cold start identity pending: the header counts zero rows"
assert_contains "$frame_ld" "┌─ [4] Teammates' PRs (0) ─" "cold start identity pending: Teammates' PRs counts zero rows"
assert_widths "$frame_ld" 120 "cold start identity pending: every line is still 120 columns"
assert_contains "$tags_ld" "{blue-fg}⠋ resolving GitHub identity…" "cold start identity pending --tags: the resolving line is dimmed like the other spinner lines"
frame_ld=$(render "$(variant cold-start.json identity-pending-frame3 '{"prs": {"identity": null}, "refresh": {"refreshing": true, "loading_frame": 3}}')") || fail "cold start identity pending frame 3: render exited non-zero"
assert_count "$frame_ld" "⠸ resolving GitHub identity…" 2 "cold start identity pending: loading_frame moves the resolving glyph with the others"
assert_count "$frame_ld" "⠸ loading fleet snapshot…" 4 "cold start identity pending frame 3: the snapshot panes show the same glyph"
frame_ld=$(render "$(variant cold-start.json identity-pending '{"prs": {"identity": null}}')" --no-prs) || fail "cold start identity pending --no-prs: render exited non-zero"
assert_not_contains "$frame_ld" "resolving" "cold start identity pending --no-prs: nothing needs the login, so nothing spins on it"
assert_not_contains "$frame_ld" "identity unknown" "cold start identity pending --no-prs: no identity row"
assert_line "$frame_ld" 26 '^│ no pull requests of yours +│$' "cold start identity pending --no-prs: My PRs reads its empty text"
frame_ld=$(render "$(variant cold-start.json identity-pending-narrow '{"prs": {"identity": null}, "cols": 70, "rows": 24}')") || fail "narrow cold start identity pending: render exited non-zero"
assert_line "$frame_ld" 8 '^ ⠋ resolving GitHub identity… +$' "narrow cold start identity pending: My PRs' line spins on the identity"
assert_line "$frame_ld" 10 '^ ⠋ resolving GitHub identity… +$' "narrow cold start identity pending: Teammates' PRs' line spins on the identity"
assert_widths "$frame_ld" 70 "narrow cold start identity pending: every line is 70 columns"
# The snapshot landed, the PR fetch still running (populated.json with prs null and refreshing):
# only My PRs spins, above the recorded PR rows it already has from the snapshot, and the
# four snapshot panes keep their rows (falsify: key the review pane on the snapshot, or drop the
# rows under the loading line).
frame_ld=$(render "$(variant populated.json snap-landed '{"prs": null, "refresh": {"refreshing": true}}')") || fail "snapshot landed: render exited non-zero"
assert_count "$frame_ld" "loading" 2 "snapshot landed: the two PR panes spin and nothing else"
assert_row "$frame_ld" '^│ ⠋ loading GitHub review requests… +│$' "snapshot landed: Teammates' PRs spins on its own fetch"
assert_line "$frame_ld" 24 '^│ ⠋ loading GitHub checks… +│$' "snapshot landed: My PRs' first body line is the spinner"
assert_row "$frame_ld" '^│ PR +- +ship-alpha +https://github.com/acme/widgets/pull/41 · checks: fetching +- +5m~ │$' "snapshot landed: the recorded PR rows stay under the spinner"
assert_contains "$frame_ld" "┌─ [3] My PRs (2) ─" "snapshot landed: the header counts the recorded rows"
assert_contains "$frame_ld" "┌─ [1] Captain's Call (6) ─" "snapshot landed: Captain's Call has its rows and no spinner"
assert_row "$frame_ld" '^│ working +working +ship-alpha +Add the widget cache · harness busy \(claude-hook\)' "snapshot landed: Underway's rows are drawn"
# --no-prs: My PRs is never loading; it shows the off state, and a cold start's empty
# review pane reads the empty text while the other four spin (falsify: drop the prs.enabled test
# from paneLoadingSource).
frame_ld=$(render "$(variant populated.json snap-landed-noprs '{"prs": null, "refresh": {"refreshing": true}}')" --no-prs) || fail "--no-prs refreshing: render exited non-zero"
assert_count "$frame_ld" "loading" 0 "--no-prs: no spinner while the snapshot data is on screen"
assert_row "$frame_ld" '^│ PR +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: off \(--no-prs\) +- +1m~ │$' "--no-prs: the recorded PR rows read the off state"
frame_ld=$(render cold-start.json --no-prs) || fail "cold start --no-prs: render exited non-zero"
assert_count "$frame_ld" "⠋ loading fleet snapshot…" 4 "cold start --no-prs: the four snapshot panes still spin"
assert_not_contains "$frame_ld" "GitHub checks" "cold start --no-prs: My PRs does not spin"
assert_line "$frame_ld" 26 '^│ no pull requests of yours +│$' "cold start --no-prs: My PRs reads its empty text"
assert_line "$frame_ld" 30 '^│ PR fetch off \(--no-prs\) +│$' "cold start --no-prs: Teammates' PRs reads the off text (falsify: drop PRS_OFF_TEXT from prPaneEmpty)"
# Data on screen: a refresh over landed data spins nothing, so rows are never covered (falsify:
# key the loading state on refreshing alone). The populated frame without a running refresh spins
# nothing either.
frame_ld=$(render "$(variant populated.json data-refreshing '{"refresh": {"refreshing": true}}')") || fail "data refreshing: render exited non-zero"
assert_count "$frame_ld" "loading" 0 "data refreshing: no spinner over existing rows"
assert_row "$frame_ld" '^ firstmate-tui · /fixture/firstmate · 3 homes +refreshing… $' "data refreshing: the title line still says refreshing…"
assert_count "$frame" "loading" 0 "populated: no spinner when no refresh runs"
# The frame counter picks the glyph: loading_frame 3 is the fourth braille frame, 10 wraps to the
# first, the default is the first, and a fraction is refused (falsify: drop the modulo from
# spinnerGlyph, or read the clock instead of the counter).
frame_ld=$(render "$(variant cold-start.json frame3 '{"refresh": {"refreshing": true, "loading_frame": 3}}')") || fail "loading_frame 3: render exited non-zero"
assert_count "$frame_ld" "⠸ loading fleet snapshot…" 4 "loading_frame 3: the fourth braille glyph on the snapshot panes"
assert_contains "$frame_ld" "⠸ loading GitHub checks…" "loading_frame 3: the same glyph on My PRs"
assert_not_contains "$frame_ld" "⠋" "loading_frame 3: the first glyph is gone"
frame_ld=$(render "$(variant cold-start.json frame10 '{"refresh": {"refreshing": true, "loading_frame": 10}}')") || fail "loading_frame 10: render exited non-zero"
assert_count "$frame_ld" "⠋ loading fleet snapshot…" 4 "loading_frame 10: the cycle wraps to the first glyph"
if out=$(render "$(variant cold-start.json frame-bad '{"refresh": {"refreshing": true, "loading_frame": 1.5}}')" 2>&1); then
  fail "loading_frame 1.5 should exit non-zero"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq "refresh.loading_frame is not a whole number: 1.5"; then pass; else fail "loading_frame 1.5 is named in the error: $out"; fi
# Narrow (70x24): the list layout draws the same line right under each section header (falsify:
# drop the loading entry from flattenRows).
frame_ld=$(render "$(variant cold-start.json narrow '{"cols": 70, "rows": 24}')") || fail "cold start narrow: render exited non-zero"
assert_count "$frame_ld" "⠋ loading fleet snapshot…" 4 "narrow cold start: the four snapshot sections spin"
assert_line "$frame_ld" 3 '^── \[1\] Captain.s Call \(0\) ─+$' "narrow cold start: the first section header is Captain's Call"
assert_line "$frame_ld" 4 '^ ⠋ loading fleet snapshot… +$' "narrow cold start: the spinner line follows the section header"
assert_line "$frame_ld" 8 '^ ⠋ loading GitHub checks… +$' "narrow cold start: My PRs' line names the GitHub checks"
assert_line "$frame_ld" 10 '^ ⠋ loading GitHub review requests… +$' "narrow cold start: Teammates' PRs' line names the review requests"
assert_not_contains "$frame_ld" "nothing is underway" "narrow cold start: no empty text beside the spinner"
assert_widths "$frame_ld" 70 "narrow cold start: every line is 70 columns"
# A failed first fetch shows the failure text, not the spinner: a PR fetch that failed before any
# fetch landed leaves the recorded rows reading checks: fetch failed under a stale header, and a
# snapshot that failed before any landed leaves the four panes stale with their empty text while
# My PRs, whose own fetch is still running, spins (falsify: drop the prs.error or the
# snapshotError test from paneLoadingSource).
frame_ld=$(render "$(variant populated.json pr-first-failed '{"prs": {"candidate_prs": null, "error": "exit 1"}, "refresh": {"refreshing": true}}')") || fail "PR first fetch failed: render exited non-zero"
assert_count "$frame_ld" "loading" 0 "PR first fetch failed: no spinner"
assert_contains "$frame_ld" "┌─ [3] My PRs (2) (stale) ─" "PR first fetch failed: the review header is stale"
assert_row "$frame_ld" '^│ PR +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: fetch failed +- +1m~ │$' "PR first fetch failed: the rows read checks: fetch failed"
frame_ld=$(render "$(variant cold-start.json snap-first-failed '{"snapshot_error": "exit 1"}')") || fail "snapshot first fetch failed: render exited non-zero"
assert_count "$frame_ld" "loading fleet snapshot" 0 "snapshot first fetch failed: the snapshot panes do not spin"
assert_count "$frame_ld" "(stale)" 4 "snapshot first fetch failed: the four snapshot panes are stale"
assert_line "$frame_ld" 4 '^│ nothing needs your action right now +│$' "snapshot first fetch failed: Captain's Call reads its empty text"
assert_line "$frame_ld" 26 '^│ ⠋ loading GitHub checks… +│$' "snapshot first fetch failed: My PRs still spins on its own fetch"
# Herdr: once the snapshot has landed, Underway names herdr while the link is still connecting,
# above the rows it already has, and only while a refresh runs; on a cold start the snapshot
# comes first (falsify: drop the herdr branch from paneLoadingSource, or move it above the
# snapshot test).
frame_ld=$(render "$(variant populated.json herdr-connecting '{"herdr": {"state": "connecting"}, "refresh": {"refreshing": true}}')") || fail "herdr connecting: render exited non-zero"
assert_count "$frame_ld" "loading" 1 "herdr connecting: one spinner on the board"
assert_row "$frame_ld" '^│ ⠋ loading herdr… +│$' "herdr connecting: Underway names herdr"
assert_before "$frame_ld" "Underway \(6\)" "⠋ loading herdr…" "herdr connecting: the line is in Underway"
assert_before "$frame_ld" "⠋ loading herdr…" "working +working +ship-alpha" "herdr connecting: the rows follow the spinner line"
assert_contains "$frame_ld" "┌─ [2] Underway (6) ─" "herdr connecting: the header still counts the rows"
frame_ld=$(render "$(variant populated.json herdr-connecting-idle '{"herdr": {"state": "connecting"}}')") || fail "herdr connecting idle: render exited non-zero"
assert_count "$frame_ld" "loading" 0 "herdr connecting with no refresh running: no spinner"
frame_ld=$(render "$(variant cold-start.json cold-connecting '{"herdr": {"state": "connecting", "agents": []}}')") || fail "cold start connecting: render exited non-zero"
assert_count "$frame_ld" "⠋ loading fleet snapshot…" 4 "cold start connecting: Underway names the snapshot first"
assert_not_contains "$frame_ld" "loading herdr" "cold start connecting: herdr is not named before the snapshot lands"

# ------------------------------------------------------- state cache
# The state cache (lib/cache.mjs): with --cache <file> a one-shot render reads it before the frame
# the way the app does at launch and, when none of the rendered facts came from it and nothing
# failed, writes them back as a clean tick of the app does; so the populated render below builds
# the cache with the real serializer and the cold-start renders restore from it. Without the flag
# a render reads and writes no cache (checked further down).
mkdir -p "$SCRATCH/cache"
CACHE="$SCRATCH/cache/state-cache.json"
frame_c=$(render populated.json --cache "$CACHE") || fail "cache build: render exited non-zero"
assert_file_contains "$CACHE" '"schema": "fm-board-state-cache.v1"' "a clean render writes the cache with its schema (falsify: drop the write from finish)"
assert_file_contains "$CACHE" '"fetched_at": "2026-09-16T12:00:00.000Z"' "the cache is stamped with the fixture's clock, when its data landed"
assert_file_contains "$CACHE" '"fm_home": "/fixture/firstmate"' "the cache names the home its data describes"
assert_file_contains "$CACHE" '"login": "captain"' "the cache carries the identity the PR panes were built around"
assert_count "$frame_c" "cached" 0 "the render that wrote the cache draws no cached marker"
# A fresh cache at a cold start: every pane draws its cached rows at once, marked with the age of
# the data, the title line reads refreshing… (the launch refresh runs as ever) and nothing spins
# (falsify: drop restoreFromCache from driveOnce, paneCached from buildModel, or the marker from
# paneHeader).
fx_cc=$(variant cold-start.json cached '{"now": "2026-09-16T12:12:00Z"}')
frame_c=$(render "$fx_cc" --cache "$CACHE") || fail "cache cold start: render exited non-zero"
assert_row "$frame_c" '^ firstmate-tui · /fixture/firstmate · 3 homes +refreshing… · herdr disconnected \(--no-herdr\) $' "cached launch: the title line reads refreshing… over the cached data and counts the cached homes"
assert_count "$frame_c" "(cached 12m ago)" 6 "cached launch: all six pane titles carry the age of the cached data"
assert_contains "$frame_c" "┌─ [1] Captain's Call (6) (cached 12m ago) ─" "cached launch: Captain's Call counts its cached rows and carries the marker"
assert_contains "$frame_c" "┌─ [3] My PRs (3) (cached 12m ago) ─" "cached launch: My PRs draws the cached PR rows"
assert_contains "$frame_c" "┌─ [4] Teammates' PRs (0) (cached 12m ago) ─" "cached launch: an empty cached pane carries the marker too"
assert_count "$frame_c" "loading" 0 "cached launch: no spinner anywhere (falsify: key paneLoadingSource on refreshing alone)"
assert_row "$frame_c" '^│ passing +IN REVIEW +ship-alpha +Add the widget cache +main +3h │$' "cached launch: a cached PR row is on screen with its columns"
assert_row "$frame_c" '^│ blocked +- +scout-beta +blocked: gh auth expired ' "cached launch: a cached Captain's Call row is on screen"
assert_widths "$frame_c" 120 "cached launch: every line is still 120 columns"
# A cached launch while the identity is still being resolved (prs.identity null): the PR panes keep
# the cached rows, drawn around the login the cache was fetched for, and never spin on the identity
# (falsify: restore the cache only over a known identity in restoreFromCache).
frame_c=$(render "$(variant cold-start.json cached-pending '{"prs": {"identity": null}, "now": "2026-09-16T12:12:00Z"}')" --cache "$CACHE") || fail "cache identity pending: render exited non-zero"
assert_contains "$frame_c" "┌─ [3] My PRs (3) (cached 12m ago) ─" "cached launch, identity pending: My PRs draws the cached PR rows"
assert_not_contains "$frame_c" "resolving" "cached launch, identity pending: no resolving line over cached rows"
assert_not_contains "$frame_c" "identity unknown" "cached launch, identity pending: no identity row either"
# The cached rows are live for the cursor: j selects the second Captain's Call row (falsify: draw the
# cached rows as the empty text).
tags_c=$(render "$fx_cc" --cache "$CACHE" --tags --keys "j") || fail "cache select: render exited non-zero"
assert_row "$tags_c" "${SEL}decide +${SEL_END}" "cached launch: j selects the second cached row"
# The marker's age has the AGE column's shape (fmtAge): seconds under a minute, minutes under an
# hour, hours from there (falsify: format the age by hand in paneCached).
frame_c=$(render "$(variant cold-start.json cached-s '{"now": "2026-09-16T12:00:40Z"}')" --cache "$CACHE") || fail "cache 40s: render exited non-zero"
assert_count "$frame_c" "(cached 40s ago)" 6 "cached launch: under a minute the age reads in seconds"
frame_c=$(render "$(variant cold-start.json cached-h '{"now": "2026-09-16T14:00:00Z"}')" --cache "$CACHE" --cache-max-age 86400) || fail "cache 2h: render exited non-zero"
assert_count "$frame_c" "(cached 2h ago)" 6 "cached launch: from an hour on the age reads in hours (a raised --cache-max-age keeps the cache)"
# Stale: data older than --cache-max-age (default 3600 s) is not drawn and the frame is today's
# cold start, spinner by spinner and without a notice; the flag moves the line (falsify: drop the
# maxAge check from parseStateCache, or read the flag as milliseconds).
fx_st=$(variant cold-start.json stale '{"now": "2026-09-16T13:00:01Z"}')
frame_c=$(render "$fx_st" --cache "$CACHE") || fail "cache stale: render exited non-zero"
assert_count "$frame_c" "⠋ loading fleet snapshot…" 4 "stale cache: the four snapshot panes spin as on a cold start"
assert_count "$frame_c" "⠋ loading GitHub checks…" 1 "stale cache: My PRs spins on its own fetch"
assert_count "$frame_c" "cached" 0 "stale cache: no cached marker and no notice"
assert_line "$frame_c" 4 '^│ ⠋ loading fleet snapshot… +│$' "stale cache: Captain's Call's first body line is the spinner"
frame_c=$(render "$fx_st" --cache "$CACHE" --cache-max-age 3602) || fail "cache max-age: render exited non-zero"
assert_count "$frame_c" "(cached 1h ago)" 6 "--cache-max-age 3602 keeps the same cache"
# --no-cache: a fresh cache is not read (falsify: drop the opts.cache check in driveOnce).
frame_c=$(render "$fx_cc" --cache "$CACHE" --no-cache) || fail "cache --no-cache: render exited non-zero"
assert_count "$frame_c" "⠋ loading fleet snapshot…" 4 "--no-cache: the cold start spins although the cache is fresh"
assert_count "$frame_c" "cached" 0 "--no-cache: no cached marker"
# A damaged cache (bad JSON), one that is not an object, one with another schema and one written
# for another home are each ignored with a footer notice, never an error; the board cold-starts
# (falsify: let parseStateCache throw, or drop the notice from driveOnce). 200 columns so the path
# in the notice is not cut.
printf '{"schema": "fm-board-state-cache.v1", "fetched_at": ' > "$SCRATCH/cache/bad.json"
frame_c=$(render "$fx_cc" --cache "$SCRATCH/cache/bad.json" --cols 200) || fail "cache corrupt: render exited non-zero"
assert_contains "$frame_c" "state cache ignored: $SCRATCH/cache/bad.json: bad JSON" "a corrupt cache is named in the footer"
assert_count "$frame_c" "⠋ loading fleet snapshot…" 4 "a corrupt cache leaves the cold start spinning"
printf '[1, 2]\n' > "$SCRATCH/cache/array.json"
frame_c=$(render "$fx_cc" --cache "$SCRATCH/cache/array.json" --cols 200) || fail "cache array: render exited non-zero"
assert_contains "$frame_c" "state cache ignored: $SCRATCH/cache/array.json: not an object" "a cache that is not an object is named in the footer"
printf '{"schema": "fm-board-state-cache.v2", "fetched_at": "2026-09-16T12:00:00Z", "snapshot": {}}\n' > "$SCRATCH/cache/schema.json"
frame_c=$(render "$fx_cc" --cache "$SCRATCH/cache/schema.json" --cols 200) || fail "cache schema: render exited non-zero"
assert_contains "$frame_c" "state cache ignored: $SCRATCH/cache/schema.json: unexpected schema \"fm-board-state-cache.v2\"" "another schema is named in the footer"
assert_count "$frame_c" "cached" 0 "another schema: nothing is drawn from it"
sed 's#"fm_home": "/fixture/firstmate"#"fm_home": "/elsewhere/firstmate"#' "$CACHE" > "$SCRATCH/cache/other-home.json"
frame_c=$(render "$fx_cc" --cache "$SCRATCH/cache/other-home.json" --cols 200) || fail "cache other home: render exited non-zero"
assert_contains "$frame_c" "state cache ignored: $SCRATCH/cache/other-home.json: written for another home (/elsewhere/firstmate)" "a cache written for another home is ignored and says so"
assert_count "$frame_c" "⠋ loading fleet snapshot…" 4 "another home's cache leaves the cold start spinning"
# Pane by pane: with the snapshot landed (the fixture has one) and the PR fetch still out, the
# cached PR rows fill the two PR panes and only their titles carry the marker; the other way
# round, a landed PR fetch clears the two and leaves the four (falsify: mark every pane from one
# flag in paneCached, or clear the snapshot flag with the PR fetch).
frame_c=$(render "$(variant populated.json snap-live '{"prs": null, "refresh": {"refreshing": true}, "now": "2026-09-16T12:05:00Z"}')" --cache "$CACHE") || fail "cache pane by pane: render exited non-zero"
assert_count "$frame_c" "(cached 5m ago)" 2 "snapshot landed: two panes still carry the marker"
assert_contains "$frame_c" "┌─ [3] My PRs (3) (cached 5m ago) ─" "snapshot landed: My PRs is cached and draws the cached rows"
assert_contains "$frame_c" "┌─ [4] Teammates' PRs (0) (cached 5m ago) ─" "snapshot landed: Teammates' PRs is cached"
assert_contains "$frame_c" "┌─ [1] Captain's Call (6) ─" "snapshot landed: Captain's Call draws live data and carries no marker"
assert_count "$frame_c" "loading" 0 "snapshot landed: the PR panes draw the cache instead of spinning"
frame_c=$(render "$(variant cold-start.json prs-live '{"prs": {"candidate_prs": []}, "now": "2026-09-16T12:05:00Z"}')" --cache "$CACHE") || fail "cache prs live: render exited non-zero"
assert_count "$frame_c" "(cached 5m ago)" 4 "PR fetch landed: the four snapshot panes still carry the marker"
assert_contains "$frame_c" "┌─ [3] My PRs (2) ─" "PR fetch landed: My PRs draws the live (empty) fetch over the cached snapshot's recorded PRs, no marker"
assert_contains "$frame_c" "┌─ [2] Underway (6) (cached 5m ago) ─" "PR fetch landed: Underway is still cached"
# The GitHub cycle in flight over a cached launch, the snapshot landed: the PR panes keep the cached
# rows under both markers, cached first, then updating, and never spin; the fleet panes, live
# already, carry neither (falsify: put updating before cached in paneHeader, or treat cached rows
# as loading).
frame_c=$(render "$(variant populated.json cached-fetching '{"prs": null, "refresh": {"refreshing": false, "fetching": true}, "now": "2026-09-16T12:05:00Z"}')" --cache "$CACHE") || fail "cache fetching: render exited non-zero"
assert_contains "$frame_c" "┌─ [3] My PRs (3) (cached 5m ago) (updating) ─" "cached and fetching: My PRs carries the cached marker, then updating"
assert_contains "$frame_c" "┌─ [4] Teammates' PRs (0) (cached 5m ago) (updating) ─" "cached and fetching: Teammates' PRs too"
assert_count "$frame_c" "(updating)" 2 "cached and fetching: the two PR panes alone"
assert_count "$frame_c" "loading" 0 "cached and fetching: the cached rows never give way to a spinner"
assert_contains "$frame_c" "┌─ [1] Captain's Call (6) ─" "cached and fetching: Captain's Call is live and carries no marker"
# The launch refresh failed over a cached board: the rows stay, each pane is stale and cached at
# once, and the title line names the failure (falsify: drop the cached snapshot when
# snapshot_error is set, or the fixture's errors, in restoreFromCache).
frame_c=$(render "$(variant cold-start.json cached-failed '{"snapshot_error": "exit 1", "prs": {"error": "exit 1"}, "refresh": {"refreshing": false, "failed_ago": 3, "next_in": 27, "failed": "snapshot: exit 1"}, "now": "2026-09-16T12:05:00Z"}')" --cache "$CACHE") || fail "cache failed refresh: render exited non-zero"
assert_count "$frame_c" "(stale) (cached 5m ago)" 6 "failed launch refresh: every pane is stale and cached at once"
assert_row "$frame_c" '^ firstmate-tui .* +refresh failed 3s ago, retrying in 27s · herdr disconnected \(--no-herdr\) $' "failed launch refresh: the title line names the failure"
assert_row "$frame_c" '^│ passing +IN REVIEW +ship-alpha ' "failed launch refresh: the cached PR row stays"
# enter on a cached PR row: the footer names the age of the data the row was read from and the PR
# opens through the opener as usual, with no prompt and no delay; the same row over live PR data
# carries no age, and a Captain's Call review row read from the cached snapshot carries it (falsify:
# drop the cached suffix from ctx.open, wait for a confirmation, or read one flag for every pane).
rm -f "${OPENER_LOG:?}"
frame_c=$(FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" render "$fx_cc" --cache "$CACHE" --keys "tab,tab,enter" --opener-cmd "$FAKE_OPENER") || fail "cache open: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "enter on a cached My PRs row opens the PR through the opener"
assert_contains "$frame_c" "opened https://github.com/acme/widgets/pull/41 (ship-alpha) · data cached 12m ago" "the footer names the age of the cached data the row came from"
rm -f "${OPENER_LOG:?}"
frame_c=$(FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" render "$(variant cold-start.json prs-live-41 '{"prs": {"candidate_prs": [{"num": "41", "repo": "acme/widgets", "task": "ship-alpha", "url": "https://github.com/acme/widgets/pull/41", "review": "REVIEW_REQUIRED", "mergeable": "MERGEABLE", "checks": "passing"}]}, "now": "2026-09-16T12:12:00Z"}')" --cache "$CACHE" --keys "tab,tab,enter" --opener-cmd "$FAKE_OPENER") || fail "cache open live: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "enter on the live PR row opens it"
assert_contains "$frame_c" "opened https://github.com/acme/widgets/pull/41 (ship-alpha) " "a live PR row opens with the plain notice"
assert_not_contains "$frame_c" "data cached" "a live PR row names no cached age although the snapshot panes are still cached"
rm -f "${OPENER_LOG:?}"
frame_c=$(FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" render "$fx_cc" --cache "$CACHE" --keys "j,j,j,j,j,enter" --opener-cmd "$FAKE_OPENER") || fail "cache open review: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/7" "enter on a cached Captain's Call review row opens its PR"
assert_contains "$frame_c" "opened https://github.com/acme/api/pull/7 (ship-gamma) · data cached 12m ago" "a Captain's Call row from the cached snapshot names the age too"
# Without --cache a render reads and writes no cache: a fresh one beside the --view-state file is
# not drawn and is not rewritten (falsify: resolve the default location in cacheFor without the
# flag).
mkdir -p "$SCRATCH/cache-default"
vs_c="$SCRATCH/cache-default/view-state.json"
cp "$CACHE" "$SCRATCH/cache-default/state-cache.json"
frame_c=$(render "$fx_cc" --view-state "$vs_c") || fail "cache default: render exited non-zero"
assert_count "$frame_c" "cached" 0 "without --cache a fresh cache beside the view-state file is not read"
assert_count "$frame_c" "⠋ loading fleet snapshot…" 4 "without --cache the cold start spins"
frame_c=$(render populated.json --view-state "$vs_c") || fail "cache default write: render exited non-zero"
if cmp -s "$CACHE" "$SCRATCH/cache-default/state-cache.json"; then pass; else fail "without --cache a render rewrote the cache beside the view-state file"; fi
if [ -e "$fake_home_dir/.config/fm-board/state-cache.json" ]; then fail "a fixture render without --cache wrote the default cache file"; else pass; fi
# A --cache path inside FM_HOME is refused with a notice and the cache beside the view-state file
# is read instead; nothing is written at the refused path (falsify: drop insideHome from
# resolveCachePath).
frame_c=$(render "$fx_cc" --view-state "$vs_c" --cache /fixture/firstmate/state/state-cache.json --cols 200) || fail "cache FM_HOME: render exited non-zero"
assert_contains "$frame_c" "refusing --cache inside FM_HOME (/fixture/firstmate/state/state-cache.json)" "a cache path inside FM_HOME is refused with a notice"
assert_count "$frame_c" "(cached 12m ago)" 6 "the refused path falls back to the cache beside the view-state file"
if [ -e /fixture/firstmate/state/state-cache.json ]; then fail "the refused cache path was written"; else pass; fi
# The launcher passes the three flags through (falsify: drop --cache or --cache-max-age from its
# value-taking list, which would swallow the value as a flag).
frame_c=$("$BOARD" open --render-once --fixture "$fx_cc" --no-herdr --cache "$CACHE" --cache-max-age 7200 --no-cache) || fail "launcher cache flags: render exited non-zero"
assert_count "$frame_c" "⠋ loading fleet snapshot…" 4 "the launcher passes --cache, --cache-max-age and --no-cache through to the board"
if "$BOARD" --render-once --fixture "$fx_cc" --no-herdr --cache-max-age -1 >/dev/null 2>&1; then fail "--cache-max-age -1 should be refused"; else pass; fi
if "$BOARD" --help | grep -q -- '--cache-max-age <s>'; then pass; else fail "--help names --cache-max-age"; fi

# ------------------------------------------------------------ view restore
# The selection comes back from the view-state file: the focused pane, the row by its hide key
# (its index when the key is gone, clamped to the pane), the expanded Underway groups and the
# scroll offsets. A one-shot render restores them and never records them (its keys are scripted
# from a known start), so the files here are written by hand in the shape lib/viewstate.mjs
# saves; the app's own save is checked in the headless section below (falsify: drop focus,
# expanded or scroll from loadViewState, or focusFromSaved from driveOnce).
vs_f="$SCRATCH/view-restore.json"
write_vs() { printf '{"schema":"fm-board-view-state.v1","hidden":[],"hidden_panes":[],"columns":{},%s}\n' "$1" > "$vs_f"; }
write_vs '"focus":{"pane":"mine","row":"mine:main:api#8","index":0},"expanded":[],"scroll":{}'
tags_v=$(render populated.json --view-state "$vs_f" --tags) || fail "view restore: render exited non-zero"
assert_row "$tags_v" "${SEL}failing ${SEL_END}.*${SEL}api#8" "the saved row is selected by its hide key, whatever its saved index says (falsify: read the index first)"
assert_count "$tags_v" "$SEL_TAG" 1 "one row is selected"
tags_v=$(render populated.json --view-state "$vs_f" --tags --keys "j") || fail "view restore j: render exited non-zero"
assert_row "$tags_v" "${SEL}unlisted${SEL_END}.*${SEL}ship-gamma" "keys move on from the restored row"
# The row is gone: the saved index, clamped to the pane (falsify: fall back to row 0).
fx_gone=$(variant populated.json api8-gone '{"prs": {"candidate_prs": []}}')
write_vs '"focus":{"pane":"mine","row":"mine:main:api#8","index":1},"expanded":[],"scroll":{}'
tags_v=$(render "$fx_gone" --view-state "$vs_f" --tags) || fail "view restore index: render exited non-zero"
assert_row "$tags_v" "${SEL}unlisted${SEL_END}.*${SEL}ship-alpha" "with the row gone the saved index picks the pane's second row"
write_vs '"focus":{"pane":"mine","row":"mine:main:api#8","index":9},"expanded":[],"scroll":{}'
tags_v=$(render "$fx_gone" --view-state "$vs_f" --tags) || fail "view restore clamp: render exited non-zero"
assert_row "$tags_v" "${SEL}unlisted${SEL_END}.*${SEL}ship-alpha" "an index past the pane's rows is clamped to its last row"
# The focused pane alone (no row: the pane was empty when saved) focuses that pane; a pane the
# board does not know, or one hidden in the same file, leaves the default selection in force
# (falsify: drop the PANE_IDS check from sanitizeFocus, or the clamp after focusFromSaved).
write_vs '"focus":{"pane":"landed","row":null,"index":0},"expanded":[],"scroll":{}'
tags_v=$(render populated.json --view-state "$vs_f" --tags) || fail "view restore pane: render exited non-zero"
assert_row "$tags_v" "${SEL}report +${SEL_END}.*${SEL}scout-beta" "a saved pane with no row selects its first row"
write_vs '"focus":{"pane":"nope","row":"x","index":0},"expanded":[],"scroll":{}'
tags_v=$(render populated.json --view-state "$vs_f" --tags) || fail "view restore unknown pane: render exited non-zero"
assert_row "$tags_v" "${SEL}blocked *${SEL_END}.*${SEL}scout-beta" "an unknown pane id leaves the selection on the first pane, Captain's Call"
write_vs '"focus":{"pane":"mine","row":"mine:main:api#8","index":1},"expanded":[],"scroll":{}'
frame_v=$(render populated.json --view-state "$vs_f" --keys "3") || fail "view restore hidden pane: render exited non-zero"
assert_contains "$frame_v" "pane hidden: My PRs" "hiding the restored pane moves the selection on without an error"
# A pre-0.4.0 file naming the pane review restores onto My PRs (falsify: skip paneIdOf in sanitizeFocus).
write_vs '"focus":{"pane":"review","row":"review:main:api#8","index":0},"expanded":[],"scroll":{}'
tags_v=$(render populated.json --view-state "$vs_f" --tags) || fail "view restore old id: render exited non-zero"
assert_row "$tags_v" "${SEL}failing ${SEL_END}.*${SEL}api#8" "an old file's review pane and row key restore onto My PRs"
# Expanded groups and scroll: the delegate-a group comes back open with the cursor on it, and the
# Underway pane, two rows tall in the 30-row frame, starts one row down as saved, so the group row,
# the third, is its last shown row (falsify: drop expanded from the view init in driveOnce, or
# scrollFromSaved).
write_vs '"focus":{"pane":"inflight","row":"inflight:delegate-a:home","index":2},"expanded":["home:/fixture/homes/delegate-a"],"scroll":{"inflight":1}'
frame_v=$(render populated.json --view-state "$vs_f") || fail "view restore expanded: render exited non-zero"
assert_contains "$frame_v" "!▾ delegate-a" "the saved Underway group is expanded"
assert_row "$frame_v" '^│ working +working +↳ child-one ' "the expanded group lists its children"
frame_v=$(render populated.json --view-state "$vs_f" --rows 30) || fail "view restore scroll: render exited non-zero"
assert_row "$frame_v" '1 above, \+[0-9]+ more ──┘$' "the saved scroll offset starts the two-row Underway pane one row down, the cursor on its last shown row"
tags_v=$(render populated.json --view-state "$vs_f" --rows 30 --tags) || fail "view restore expanded --tags: render exited non-zero"
assert_row "$tags_v" "${SEL}working +${SEL_END}.*${SEL}!▾ delegate-a" "the cursor is on the group row"
# The restore waits for the rows: on a cold start the saved pane is loading and the default
# selection stands; over a fresh cache the same file puts the cursor on the cached row (falsify:
# apply focusFromSaved to a loading pane).
write_vs '"focus":{"pane":"mine","row":"mine:main:api#8","index":1},"expanded":[],"scroll":{}'
frame_v=$(render cold-start.json --view-state "$vs_f") || fail "view restore cold: render exited non-zero"
assert_count "$frame_v" "⠋ loading fleet snapshot…" 4 "a saved selection on a loading pane leaves the cold start as it is"
tags_v=$(render "$fx_cc" --view-state "$vs_f" --cache "$CACHE" --tags) || fail "view restore cached: render exited non-zero"
assert_row "$tags_v" "${SEL}failing ${SEL_END}.*${SEL}api#8" "over a fresh cache the saved row is selected among the cached rows"
# A one-shot render writes the selection back as it read it: x hides a row, and the file keeps
# the hand-written focus rather than the scripted cursor (falsify: save savedFocus from
# the driver's persist).
frame_v=$(render populated.json --view-state "$vs_f" --keys "tab,tab,tab,tab,x") || fail "view restore persist: render exited non-zero"
assert_contains "$frame_v" "hidden " "x hid a row"
assert_file_contains "$vs_f" '"row": "mine:main:api#8"' "the hide left the saved selection as it was"
assert_file_contains "$vs_f" '"hidden": [' "the hide itself is saved"

# ------------------------------------------------- state cache, headless app
# The app itself, --headless against the stand-in home (its snapshot answers at once; the fake gh on
# PATH sleeps 3 s before each graphql answer, so the GitHub cycle lands about 6 s after the local
# one) with --view-state and --cache in a scratch directory, run as node index.mjs so the signal
# reaches the board (a launcher killed by the suite leaves node running). The cache is written
# twice per launch: by the local cycle, the snapshot and the ledgers with the PR block as it was
# (empty here, the identity not asked yet), and by the GitHub cycle with the rows and the login gh
# named; SIGTERM quits the board, which saves the selection (Underway, its first row) and writes
# the cache again with the fetch's fetched_at and a later saved_at. A second run over the same files
# with gh failing every graphql call (FAKE_GH_GRAPHQL_FAIL) writes the cache once, at the local
# landing, the previous run's PR rows still in it, and never again: not at the failed fetch and not
# at the quit after it. A third run against a home whose snapshot fails leaves the cache byte for
# byte as it was and keeps the saved selection (a board that never had data records no empty one)
# (falsify: write the cache before the failure check in landed, or on quit with a failure standing:
# the failing runs move it; stamp it with the write time; await the fetch before the first write:
# the 1.5 s cache carries the login; save savedFocus without a snapshot).
HL="$SCRATCH/headless-cache"
mkdir -p "$HL"
vs_h="$HL/view-state.json"
cache_h="$HL/state-cache.json"
rm -f "${FETCH_LOG:?}"
FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FAKE_GH_SLEEP=3 FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" PATH="$FAKE_BIN:$PATH" node "$ROOT/bin/firstmate-tui/index.mjs" --headless --refresh 30 --no-herdr --view-state "$vs_h" --cache "$cache_h" > "$HL/out.log" 2>&1 &
hl_pid=$!
sleep 1.5
if [ -f "$cache_h" ]; then pass; else fail "headless: the cache is written when the snapshot lands, before the fetch"; fi
local_cache=$(cat "$cache_h" 2>/dev/null)
assert_file_contains "$cache_h" '"id": "ship-alpha"' "headless local landing: the cache carries the snapshot's tasks"
assert_file_not_contains "$cache_h" '"login": "captain"' "headless local landing: the identity is not in it yet, the GitHub cycle has not landed"
assert_file_not_contains "$cache_h" 'acme/api/pull/9' "headless local landing: no fetched PR row yet"
sleep 7
tick_cache=$(cat "$cache_h" 2>/dev/null)
if [ -n "$tick_cache" ] && [ "$tick_cache" != "$local_cache" ]; then pass; else fail "headless: the cache is written again when the fetch lands"; fi
kill -TERM "$hl_pid" 2>/dev/null
wait "$hl_pid" 2>/dev/null
assert_file_contains "$cache_h" '"schema": "fm-board-state-cache.v1"' "headless: the cache names its schema"
assert_file_contains "$cache_h" "\"fm_home\": \"$FAKE_HOME\"" "headless: the cache names the stand-in home"
assert_file_contains "$cache_h" '"login": "captain"' "headless fetch landing: the cache carries the identity gh named"
assert_file_contains "$cache_h" 'acme/api/pull/9' "headless fetch landing: the cache carries the fetched PR rows"
assert_file_contains "$cache_h" '"id": "ship-alpha"' "headless: the cache carries the snapshot's tasks"
tick_fetched=$(printf '%s\n' "$tick_cache" | grep -o '"fetched_at": "[^"]*"')
quit_fetched=$(grep -o '"fetched_at": "[^"]*"' "$cache_h")
tick_saved=$(printf '%s\n' "$tick_cache" | grep -o '"saved_at": "[^"]*"')
quit_saved=$(grep -o '"saved_at": "[^"]*"' "$cache_h")
if [ -n "$tick_fetched" ] && [ "$tick_fetched" = "$quit_fetched" ]; then pass; else fail "headless quit: fetched_at stays the fetch landing's ($tick_fetched, then $quit_fetched)"; fi
if [ -n "$quit_saved" ] && [ "$tick_saved" != "$quit_saved" ]; then pass; else fail "headless quit: the cache is written again on quit, saved_at moving on ($tick_saved, then $quit_saved)"; fi
assert_file_contains "$vs_h" '"pane": "needs"' "headless quit: the focused pane, Captain's Call where the board starts, is saved"
assert_file_contains "$vs_h" '"row": "needs:main:scout-beta"' "headless quit: the selected row is saved by its hide key"
if [ -s "$HL/out.log" ]; then fail "headless cache run wrote to the terminal: $(head -c 300 "$HL/out.log")"; else pass; fi
cp "$cache_h" "$HL/before-ghfail.json"
rm -f "${FETCH_LOG:?}"
FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FAKE_GH_SLEEP=1 FAKE_GH_GRAPHQL_FAIL=1 FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" PATH="$FAKE_BIN:$PATH" node "$ROOT/bin/firstmate-tui/index.mjs" --headless --refresh 30 --no-herdr --view-state "$vs_h" --cache "$cache_h" > "$HL/out-ghfail.log" 2>&1 &
hl_pid=$!
sleep 0.8
local_cache=$(cat "$cache_h" 2>/dev/null)
if [ -n "$local_cache" ] && [ "$local_cache" != "$(cat "$HL/before-ghfail.json")" ]; then pass; else fail "headless failing fetch: the local landing wrote the cache (a clean snapshot over the previous run's clean PR data)"; fi
assert_file_contains "$cache_h" 'acme/api/pull/9' "headless failing fetch: the previous run's PR rows are still in the cache the local landing wrote"
sleep 3.2
if [ "$(cat "$cache_h" 2>/dev/null)" = "$local_cache" ]; then pass; else fail "headless failing fetch: the failed fetch left the cache as the local landing wrote it"; fi
kill -TERM "$hl_pid" 2>/dev/null
wait "$hl_pid" 2>/dev/null
if [ "$(cat "$cache_h" 2>/dev/null)" = "$local_cache" ]; then pass; else fail "headless failing fetch: the quit after a failed fetch wrote nothing"; fi
if [ "$(grep -c '^gh api graphql ' "$FETCH_LOG" 2>/dev/null)" -ge 4 ]; then pass; else fail "headless failing fetch: the searches ran and failed ($(cat "$FETCH_LOG" 2>/dev/null))"; fi
if [ -s "$HL/out-ghfail.log" ]; then fail "headless failing fetch run wrote to the terminal: $(head -c 300 "$HL/out-ghfail.log")"; else pass; fi
FAIL_HOME="$SCRATCH/firstmate-fail"
mkdir -p "$FAIL_HOME/bin"
# shellcheck disable=SC2016 # the fake expands $FM_BOARD_TEST_FETCH_LOG at run time, not here
printf '#!/usr/bin/env bash\necho snapshot-fail >> "$FM_BOARD_TEST_FETCH_LOG"\necho broken >&2\nexit 1\n' > "$FAIL_HOME/bin/fm-fleet-snapshot.sh"
cp "$FAKE_HOME/bin/fm-bearings-snapshot.sh" "$FAIL_HOME/bin/fm-bearings-snapshot.sh"
chmod +x "$FAIL_HOME/bin/fm-fleet-snapshot.sh" "$FAIL_HOME/bin/fm-bearings-snapshot.sh"
cp "$cache_h" "$HL/before-fail.json"
rm -f "${FETCH_LOG:?}"
FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAIL_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" PATH="$FAKE_BIN:$PATH" node "$ROOT/bin/firstmate-tui/index.mjs" --headless --refresh 5 --no-herdr --view-state "$vs_h" --cache "$cache_h" > "$HL/out-fail.log" 2>&1 &
hl_pid=$!
sleep 3
kill -TERM "$hl_pid" 2>/dev/null
wait "$hl_pid" 2>/dev/null
if grep -q '^snapshot-fail$' "$FETCH_LOG" 2>/dev/null; then pass; else fail "headless failing home: the failing snapshot ran ($(cat "$FETCH_LOG" 2>/dev/null))"; fi
if cmp -s "$HL/before-fail.json" "$cache_h"; then pass; else fail "headless failing home: a failed snapshot (and the quit after it) left the cache untouched"; fi
assert_file_contains "$vs_h" '"row": "needs:main:scout-beta"' "headless failing home: the saved selection survives a run that never had data"
if [ -s "$HL/out-fail.log" ]; then fail "headless failing run wrote to the terminal: $(head -c 300 "$HL/out-fail.log")"; else pass; fi

# ------------------------------------------------------------------- mouse
# Cells are column,line from 0 at the top-left. In populated.json at 160x44 the lines are: 0 title,
# 1 Captain's Call title, 2 its column header, 3-8 its rows (scout-beta, ship-alpha, delegate-a's
# etl-window, decide-vendor, etl-cutover, ship-gamma), 10 Underway title, 11 its column header, 12-17
# its rows (ship-alpha, tmux-task, delegate-a group, remote-child, scout-beta, ship-gamma), 21 My PRs
# title, 23-25 its rows (ship-alpha #41, api#8, ship-gamma #7), 27 Teammates' PRs title, 28 its column
# header, 29 its empty text, 31 Charted Next title, 33 its row (later-hold), 35 Recently Landed title,
# 37-41 its rows (scout-beta, etl-index, ship-old, mobile-fix, old-scout), 43 footer. The board starts
# focused on Captain's Call's first row.
#
# A left click selects: the pane gets the amber focus border and the row the inverse cursor bar, the
# same as tab/j/k would leave them, and the pane that lost the focus is back to plain blue (falsify:
# drop the 'select' case from applyAction, or the row zones from renderPanes).
tags_m=$(render populated.json --mouse "click:30,40" --tags) || fail "mouse click: render exited non-zero"
assert_row "$tags_m" "${SEL}reported *${SEL_END}.*mobile-fix" "click on the fourth Recently Landed row selects it"
assert_row "$tags_m" '\{bold\}\{214-fg\}┌─ .*\[6\].*Recently Landed \(5\)' "click on a Recently Landed row focuses the Recently Landed pane"
assert_no_row "$tags_m" '\{214-fg\}┌─ .*\[1\]' "click: Captain's Call lost the focus border"
assert_row "$tags_m" '\{blue-fg\}┌─ \{/blue-fg\}\{grey-fg\}\[1\]\{/grey-fg\}\{blue-fg\} Captain.s Call' "click: Captain's Call's border is plain blue again"
assert_not_contains "$tags_m" "{cyan-fg}" "click: no cyan anywhere in the frame"
assert_no_row "$tags_m" "${SEL}blocked" "click: the old selection is no longer on the bar"
# The selection a click leaves is what the keys then act on (falsify: set view.row without view.pane in 'select').
frame_m=$(render populated.json --mouse "click:30,40" --keys "x") || fail "mouse click then x: render exited non-zero"
assert_contains "$frame_m" "Recently Landed (4, 1 hidden)" "x after a click hides the clicked row"
assert_contains "$frame_m" "hidden mobile-fix" "x after a click names the clicked row"
# A click on a pane title focuses the pane, cursor on its first row (falsify: drop the title zone, or return
# 'none' for a non-row hit in mouseAction).
tags_m=$(render populated.json --mouse "click:5,35" --tags) || fail "mouse title click: render exited non-zero"
assert_row "$tags_m" '\{bold\}\{214-fg\}┌─ .*\[6\].*Recently Landed \(5\)' "click on the Recently Landed title focuses Recently Landed"
assert_row "$tags_m" "${SEL}report +${SEL_END}.*scout-beta" "click on the Recently Landed title puts the cursor on its first row"
frame_m=$(render populated.json --mouse "click:5,35" --keys "enter") || fail "mouse title click then enter: render exited non-zero"
assert_contains "$frame_m" "would view /fixture/firstmate/data/scout-beta/report.md" "enter after a title click acts on that pane's first row"
# A click on a pane's empty space (its column header) focuses the pane too (falsify: drop the pane zone).
tags_m=$(render populated.json --mouse "click:30,11" --tags) || fail "mouse empty click: render exited non-zero"
assert_row "$tags_m" '\{bold\}\{214-fg\}┌─ .*\[2\].*Underway \(6\)' "click on Underway's column header focuses Underway"
# A click on the title line or the footer changes nothing (falsify: give those lines a zone).
frame_m=$(render populated.json --mouse "click:30,0 click:30,43") || fail "mouse chrome click: render exited non-zero"
if [ "$frame_m" = "$frame" ]; then pass; else fail "a click on the title line or footer changed the frame: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_m") | head -n 5)"; fi
# The narrow list has zones too (falsify: drop the zones from renderList).
tags_m=$(render narrow.json --mouse "click:10,14" --tags) || fail "mouse narrow click: render exited non-zero"
assert_row "$tags_m" "${SEL}merged +${SEL_END}.*ship-old" "list mode: a click on the Recently Landed row selects it"
assert_row "$tags_m" '\{bold\}\{214-fg\}── .*\[6\].*Recently Landed \(1\)' "list mode: the Recently Landed section header takes the focus style"
tags_m=$(render narrow.json --mouse "click:10,2" --tags) || fail "mouse narrow title click: render exited non-zero"
assert_row "$tags_m" '\{bold\}\{214-fg\}── .*\[1\].*Captain.s Call \(1\)' "list mode: a click on a section header focuses that section"

# A double-click is enter on that row: two left clicks on one row within 400 ms, recognized in
# lib/controller.mjs, not by the terminal library (falsify: drop the lastClick check from mouseAction, or
# stamp the two dblclick events with different times in driveOnce).
frame_m=$(render_mouse populated.json "dblclick:30,23") || fail "mouse dblclick review: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "double-click on the first My PRs row opens its PR, as enter does"
assert_contains "$frame_m" "opened https://github.com/acme/widgets/pull/41 (ship-alpha)" "double-click: the footer names the opened PR"
frame_m=$(render_mouse populated.json "click:30,24 click:30,24") || fail "mouse two clicks: render exited non-zero"
assert_not_opened "two single clicks a second apart on one row open nothing"
frame_m=$(render_mouse populated.json "click:30,23 click:30,24 click:30,24 click:30,23") || fail "mouse clicks on different rows: render exited non-zero"
assert_not_opened "clicks alternating between rows never make a double-click"
frame_m=$(render_mouse populated.json "dblclick:30,14") || fail "mouse dblclick group: render exited non-zero"
assert_row "$frame_m" '^│ working +1 live +!▾ delegate-a ' "double-click on the delegate-a group row expands it"
assert_contains "$frame_m" "Underway (8)" "double-click on a group: only that group's rows are added"
assert_not_opened "double-click on a group row opens no PR"
frame_m=$(render_mouse populated.json "dblclick:30,14 dblclick:30,14") || fail "mouse dblclick group twice: render exited non-zero"
assert_row "$frame_m" '^│ working +1 live +!▸ delegate-a ' "a second double-click on the group row collapses it again"
frame_m=$(render_mouse populated.json "dblclick:60,37") || fail "mouse dblclick report: render exited non-zero"
assert_viewed "/fixture/firstmate/data/scout-beta/report.md" "double-click on a Recently Landed report row views its report through --viewer-cmd"
frame_m=$(render_mouse populated.json "dblclick:30,12") || fail "mouse dblclick worker: render exited non-zero"
assert_contains "$frame_m" "herdr is off (--no-herdr); cannot focus" "double-click on an Underway worker means herdr focus, refused here as enter is"
assert_not_opened "double-click on a worker opens no PR"
assert_not_viewed "double-click on a worker views no report"
frame_m=$(render_mouse populated.json "dblclick:60,41") || fail "mouse dblclick landed no url: render exited non-zero"
assert_not_opened "double-click on a Recently Landed row without a PR opens nothing"
assert_viewed "/fixture/firstmate/data/old-scout/report.md" "double-click on a Recently Landed row without a PR views its report, as enter does (falsify: give the double-click its own action instead of keyAction enter)"

# One gesture, one open. The second press of a double-click acts, and every further press on that row
# inside the same 400 ms window only selects, so a triple-click, or a release or drag report a host
# delivers shaped as a press, opens the PR once and the opener log has exactly one line; assert_opened
# compares the whole log (falsify: drop the lastActivate check from mouseAction, or stop applyAction
# recording lastActivate on activate).
frame_m=$(render_mouse populated.json "dblclick:30,23") || fail "mouse dblclick once: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "a double-click opens the PR exactly once: one opener line"
frame_m=$(render_mouse populated.json "tripleclick:30,23") || fail "mouse tripleclick: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "a third press inside the window opens nothing more: one opener line"
assert_contains "$frame_m" "opened https://github.com/acme/widgets/pull/41 (ship-alpha)" "triple-click: the footer names the one open"
# The guard covers one window only: a click a second later is a fresh single click, a double-click a
# second later opens again (falsify: make the guard ignore the time, or never clear it).
frame_m=$(render_mouse populated.json "dblclick:30,23 click:30,23") || fail "mouse dblclick then click: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "a click a second after a double-click only selects: still one opener line"
frame_m=$(render_mouse populated.json "dblclick:30,23 dblclick:30,23") || fail "mouse dblclick twice: render exited non-zero"
assert_opened "$(printf 'https://github.com/acme/widgets/pull/41\nhttps://github.com/acme/widgets/pull/41')" "a second double-click a second later opens again"
# enter is never guarded: one press opens once (checked above with tab,tab,enter) and it still opens right
# after a double-click on the row (falsify: apply the lastActivate guard in keyAction).
frame_m=$(render_mouse populated.json "dblclick:30,23" --keys enter) || fail "mouse dblclick then enter: render exited non-zero"
assert_opened "$(printf 'https://github.com/acme/widgets/pull/41\nhttps://github.com/acme/widgets/pull/41')" "enter after a double-click opens the row again: two opener lines, one each"

# What the terminal library hands the adapter for the mouse, checked without a terminal
# (lib/tui-blessed.mjs loads neo-blessed only inside createScreen). neo-blessed 0.2.0 labels a drag
# report with the left button held (button code 32 + 32 in X10 and urxvt, 32 in SGR: the pointer
# crossed a cell with the button down, terminal mode 1002) as 'mousedown left', seen on a pty, which
# made the controller count a click whose pointer slipped a cell as two presses. The adapter turns
# every report whose code carries the motion flag and a held button into a drag event (the column
# resize reads them; a press never comes out of one) while presses, releases and the wheel pass
# (falsify: drop motionCode, or return null for a drag). A chunk carrying two reports is split so the
# second click of a fast double-click is not lost to the library's one-report parse; a single report
# is left alone (falsify: return the match for one report too).
adapter=$(node --input-type=module -e "
  import { normalizeMouse, splitMouseReports } from '$ROOT/bin/firstmate-tui/lib/tui-blessed.mjs';
  const show = (label, v) => console.log(label + ' ' + JSON.stringify(v === undefined ? null : v));
  const ev = (action, raw, type, button = 'left') => normalizeMouse({ action, button, x: 30, y: 10, raw: [raw, 63, 43, ''], type });
  show('x10-press', ev('mousedown', 32, 'X10'));
  show('x10-drag', ev('mousedown', 64, 'X10'));
  show('x10-release', ev('mouseup', 35, 'X10'));
  show('x10-wheel', ev('wheelup', 96, 'X10', 'middle'));
  show('urxvt-drag', ev('mousedown', 64, 'urxvt'));
  show('sgr-press', ev('mousedown', 0, 'sgr'));
  show('sgr-drag', ev('mousedown', 32, 'sgr'));
  show('sgr-motion', normalizeMouse({ action: 'mousemove', x: 30, y: 10, raw: [35, 63, 43, ''], type: 'sgr' }));
  show('x10-motion', normalizeMouse({ action: 'mousemove', x: 30, y: 10, raw: [67, 63, 43, ''], type: 'X10' }));
  show('sgr-release', ev('mouseup', 0, 'sgr'));
  show('split-two', splitMouseReports('\x1b[M#?+\x1b[M ?+'));
  show('split-one', splitMouseReports('\x1b[M ?+'));
  show('split-mixed', splitMouseReports('\x1b[<0;31;11m\x1b[M ?+'));
")
assert_row "$adapter" '^x10-press \{"type":"down","button":"left","x":30,"y":10\}$' "adapter: an X10 left press is a down event"
assert_row "$adapter" '^x10-drag \{"type":"drag","button":"left","x":30,"y":10\}$' "adapter: an X10 drag report (code 64) is a drag event, never a press, although the library calls it mousedown"
assert_row "$adapter" '^x10-release \{"type":"up","button":"left","x":30,"y":10\}$' "adapter: an X10 release is an up event"
assert_row "$adapter" '^x10-wheel \{"type":"wheel","dir":"up","x":30,"y":10\}$' "adapter: the wheel (code 96) is not mistaken for motion"
assert_row "$adapter" '^urxvt-drag \{"type":"drag","button":"left","x":30,"y":10\}$' "adapter: a urxvt drag report is a drag event"
assert_row "$adapter" '^sgr-press \{"type":"down","button":"left","x":30,"y":10\}$' "adapter: an SGR left press is a down event"
assert_row "$adapter" '^sgr-drag \{"type":"drag","button":"left","x":30,"y":10\}$' "adapter: an SGR drag report (code 32) is a drag event"
assert_row "$adapter" '^sgr-motion null$' "adapter: SGR motion with no button held (code 35) is dropped"
assert_row "$adapter" '^x10-motion null$' "adapter: X10 motion with no button held (code 67) is dropped"
assert_row "$adapter" '^sgr-release \{"type":"up","button":"left","x":30,"y":10\}$' "adapter: an SGR release is an up event"
assert_row "$adapter" '^split-two \["\\u001b\[M#\?\+","\\u001b\[M \?\+"\]$' "adapter: a chunk with a release and the next press splits into two reports"
assert_row "$adapter" '^split-one null$' "adapter: a chunk with one report is left to the library"
assert_row "$adapter" '^split-mixed \["\\u001b\[<0;31;11m","\\u001b\[M \?\+"\]$' "adapter: SGR and X10 reports in one chunk both split out"

# Only the left button acts. Herdr keeps the right button for its own pane menu, so the board binds
# nothing to it: the harness refuses an rclick token, and a right- or middle-button event reaching the
# controller is a no-op while the same left-button event selects (falsify: give another button a branch
# in mouseAction, or accept rclick in parseMouseToken).
if out=$("$BOARD" --render-once --fixture "$FIX/empty.json" --no-herdr --mouse "rclick:30,11" 2>&1); then
  fail "--mouse rclick should be refused"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq -- '--mouse: bad event "rclick:30,11"'; then pass; else fail "--mouse names rclick as an unsupported event: $out"; fi
buttons=$(node --input-type=module -e "
  import { mouseAction } from '$ROOT/bin/firstmate-tui/lib/controller.mjs';
  const zones = Array.from({ length: 40 }, (_, y) => (y === 5 ? { kind: 'row', pane: 0, row: 2 } : null));
  const model = { panes: [{ id: 'needs', hidden: false, hiddenCount: 0, rows: [{ name: 'a' }, { name: 'b' }, { name: 'c' }] }], meta: {} };
  const view = { pane: 0, row: 0, frame: { cols: 160, rows: 40, zones }, lastClick: null, showHidden: false };
  for (const button of ['right', 'middle', 'left']) console.log(button + ' ' + mouseAction(model, view, { type: 'down', button, x: 30, y: 5, time: 0 }).type);
")
assert_row "$buttons" '^right none$' "a right-button press on a row is a no-op in the controller"
assert_row "$buttons" '^middle none$' "a middle-button press on a row is a no-op in the controller"
assert_row "$buttons" '^left select$' "the same left-button press selects the row"

# The wheel moves the selection three rows in the focused pane (Captain's Call, where the board
# starts, the pointer over Recently Landed), whichever pane the pointer is over, and clamps at the
# ends: six rows, so two wheel downs land on the sixth, the review row (falsify: change WHEEL_ROWS, or
# hit-test the wheel's pointer).
frame_m=$(render_mouse populated.json "wheel:down:30,39 wheel:down:30,39" --keys "enter") || fail "mouse wheel: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/7" "two wheel downs over Recently Landed move the focused Captain's Call selection to its last row, the review row, which enter opens"
tags_m=$(render populated.json --mouse "wheel:down:30,39" --tags) || fail "mouse wheel --tags: render exited non-zero"
assert_row "$tags_m" "${SEL}hold +${SEL_END}.*${SEL}decide-vendor" "wheel down: the fourth Captain's Call row is selected"
assert_no_row "$tags_m" '\{214-fg\}┌─ .*\[6\]' "wheel: the pane under the pointer is not focused"
tags_m=$(render populated.json --mouse "wheel:up:30,39 wheel:down:30,39 wheel:down:30,39 wheel:down:30,39" --tags) || fail "mouse wheel clamp: render exited non-zero"
assert_row "$tags_m" "${SEL}review " "wheel up at the top stays, three wheel downs clamp at the last row"
tags_m=$(render populated.json --mouse "wheel:down:30,39 wheel:up:30,39" --tags) || fail "mouse wheel back: render exited non-zero"
assert_row "$tags_m" "${SEL}blocked *${SEL_END}" "wheel down then up is back on the first row"
# A wheel move breaks a double-click: click, wheel, click on the same row is two singles (falsify: keep
# lastClick across a wheel action).
frame_m=$(render_mouse populated.json "click:30,24 wheel:down:30,24 wheel:up:30,24 click:30,24") || fail "mouse click wheel click: render exited non-zero"
assert_not_opened "click, wheel and click on one row are two single clicks"

# --no-mouse: every gesture is ignored and the frame is the plain one (falsify: drop the opts.mouse guard
# in driveOnce, or make --no-mouse set anything but opts.mouse).
frame_m=$(render populated.json --no-mouse --mouse "click:30,40 dblclick:30,23 wheel:down:30,39") || fail "--no-mouse: render exited non-zero"
if [ "$frame_m" = "$frame" ]; then pass; else fail "--no-mouse changed the frame: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_m") | head -n 5)"; fi
frame_m=$(render_mouse populated.json "dblclick:30,23" --no-mouse) || fail "--no-mouse dblclick: render exited non-zero"
assert_not_opened "--no-mouse: a double-click opens nothing"
frame_m=$(render populated.json --no-mouse --mouse "click:30,40 x") || fail "--no-mouse keys in list: render exited non-zero"
assert_contains "$frame_m" "Captain's Call (5, 1 hidden)" "--no-mouse: the key tokens of the list still apply (x hid the row the keyboard selection was on)"
assert_contains "$frame_m" "hidden scout-beta" "--no-mouse: the click was ignored, so x acted on the first Captain's Call row, not the clicked Recently Landed row"
# The landing page has no mouse targets (falsify: give renderLanding zones).
frame_l=$(render populated.json --keys "1,2,3,4,5,6")
frame_m=$(render populated.json --keys "1,2,3,4,5,6" --mouse "click:30,20 dblclick:30,24 wheel:down:30,20") || fail "mouse on landing: render exited non-zero"
if [ "$frame_m" = "$frame_l" ]; then pass; else fail "mouse events changed the landing page: $(diff <(printf '%s\n' "$frame_l") <(printf '%s\n' "$frame_m") | head -n 5)"; fi
# A click while the help is up closes it (falsify: ignore mouse events under view.help).
frame_m=$(render populated.json --keys "?" --mouse "click:30,40") || fail "mouse click on help: render exited non-zero"
assert_not_contains "$frame_m" "firstmate-tui keys" "a click closes the help overlay"

# The help lists the gestures and binds nothing to the right button (falsify: drop the mouse block from
# HELP_LINES, or bring a right-click line back).
frame_m=$(render populated.json --keys "?") || fail "mouse help: render exited non-zero"
assert_contains "$frame_m" "mouse (off with --no-mouse" "help overlay has a mouse section naming --no-mouse"
assert_contains "$frame_m" "click        select that row and focus its pane; a pane title focuses the pane" "help overlay documents click"
assert_contains "$frame_m" "double-click the same as enter on that row" "help overlay documents double-click"
assert_contains "$frame_m" "wheel        move the selection three rows in the focused pane" "help overlay documents the wheel"
assert_not_contains "$frame_m" "right-click" "help overlay offers no right-click gesture"
assert_not_contains "$frame" "menu" "the frame offers no menu"

# --mouse parsing (falsify: loosen parseMouseToken, or drop --mouse from the wrapper's value-taking list).
if out=$("$BOARD" --render-once --fixture "$FIX/empty.json" --no-herdr --mouse "click:12" 2>&1); then
  fail "--mouse with a bad event should exit non-zero"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq -- '--mouse: bad event "click:12"'; then pass; else fail "--mouse names the bad event: $out"; fi
if out=$("$BOARD" --render-once --fixture "$FIX/empty.json" --no-herdr --mouse 2>&1); then
  fail "--mouse without a value should exit non-zero"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq -- "--mouse needs a value"; then pass; else fail "--mouse without a value is named in the error: $out"; fi
frame_m=$(render populated.json --mouse "click:30,40,x") || fail "mouse comma list: render exited non-zero"
assert_contains "$frame_m" "hidden mobile-fix" "a comma-separated list keeps the comma inside X,Y and reads the rest as keys"
if "$BOARD" --help 2>/dev/null | grep -Fq -- "--no-mouse"; then pass; else fail "wrapper --help lists --no-mouse"; fi
if "$BOARD" --help 2>/dev/null | grep -Fq -- "--mouse <list>"; then pass; else fail "wrapper --help lists --mouse"; fi

# ----------------------------------------------------------- column widths
# Every fixed column is as wide as the widest value it shows in its pane (at least its label, at most
# the 24-cell cap), two blank cells separate neighbours, and the one flexible column (WHAT, TITLE,
# REPORT) takes the rest. column-widths.json is the shape of the captain's 2026-09-17 screenshot, where
# BASE (always main), REPO and HOME took the room TITLE needed (falsify: give base, repo or home a fixed
# width again in lib/layout.mjs columnSpec).
frame_cw=$(render column-widths.json) || fail "column-widths: render exited non-zero"
assert_row "$frame_cw" '^│ CHECKS   STATUS     ID {16}TITLE {104}BASE  AGE │$' "column widths: CHECKS is as wide as passing, ID as wide as firstmate-tui#17, BASE four cells for main, AGE three, and TITLE has the 107 cells left"
assert_row "$frame_cw" '^│ passing  DRAFT      entity-ai#279     refactor\(helm\): read credentials from entity-secrets instead of the chart values +main  22d │$' "column widths: the 79-character title shows in full in the room BASE gave back (the id is five cells short of the ID column, which firstmate-tui#17 sizes)"
assert_row "$frame_cw" '^│ hold   by 09-15  uuidv7-rfc-rewrite +Rewrite RFC-017 as thought leadership for the platform team +example-corp/portal  main  37d │$' "column widths: a 19-character repository name is not cut and HOME hugs main"
assert_row "$frame_cw" '^│ hold   by 09-09  review-rfc-discussion-t…  Review RFC · Captain asked on 2026-09-02' "column widths: an id longer than the 24-cell cap truncates with an ellipsis (falsify: raise COLUMN_CAP)"
assert_row "$frame_cw" '^│ STATE  KEY       ID {24}WHAT ' "column widths: STATE stays as wide as its label when every value is shorter, KEY is as wide as by 09-15"
assert_widths "$frame_cw" 160 "column widths: lines are 160 columns"
assert_lines "$frame_cw" 40 "column widths: 40 lines"

# Dragging a boundary. populated.json at 160x44: Captain's Call's column header is line 2 and its
# columns start at x=2 STATE (7 wide), 11 KEY (10, as wide as etl-window), 23 ID (13), 38 WHAT (89),
# 129 REPO (12), 143 HOME (10), 155 AGE (3), two blank cells between neighbours, so the ID/WHAT gutter
# is cells 36-37 and a left press on cells 35 to 38 takes that boundary. My PRs' header is line 22
# with CHECKS (8), STATUS (9), ID (10) and its ID/TITLE gutter at 33-34. In the header line a column
# W cells wide reads as its label followed by W blank cells (its padding plus the gutter) before the
# next label.
# A drag from 36 to 46 widens ID by ten cells and WHAT gives up exactly those ten: the columns right of
# WHAT keep their place and the line is still 160 cells (falsify: drop drag-move from applyAction, or
# size the flexible column before the overrides are applied).
assert_row "$frame" '^│ STATE    KEY         ID {13}WHAT {87}REPO' "before any drag ID is 13 wide, as wide as decide-vendor, and WHAT 89"
frame_d=$(render populated.json --mouse "drag:36,2->46") || fail "drag ID/WHAT: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {23}WHAT {77}REPO +HOME +AGE │$' "drag: ID is 23 wide, WHAT 79, and REPO, HOME and AGE are where they were"
assert_row "$frame_d" '^│ decide   db-choice   ship-alpha {15}Postgres or SQLite for the cache\? +acme/widgets  main +5m │$' "drag: the rows follow the header's widths"
assert_widths "$frame_d" 160 "drag: lines are still 160 columns"
assert_contains "$frame_d" "ID 23 wide · double-click the boundary resets it, = resets every column" "drag: the footer names the new width and both resets"
# The boundary is taken from one cell either side of its gutter and nowhere else (falsify: change
# BOUNDARY_REACH); only the header line has boundaries, a drag started on a row is a click on that row
# (falsify: put header geometry on row zones).
frame_d=$(render populated.json --mouse "drag:35,2->45") || fail "drag from ID's last cell: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {23}WHAT ' "a press on the last cell of ID, one cell before the gutter, drags the same boundary"
frame_d=$(render populated.json --mouse "drag:38,2->48") || fail "drag from WHAT's first cell: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {23}WHAT ' "a press on the first cell of WHAT, one cell after the gutter, drags the same boundary"
frame_d=$(render populated.json --mouse "drag:34,2->44") || fail "drag from two cells before the gutter: render exited non-zero"
frame_c=$(render populated.json --mouse "click:34,2") || fail "click two cells before the gutter: render exited non-zero"
if [ "$frame_d" = "$frame_c" ]; then pass; else fail "a press two cells before the gutter is a plain header click (the frame a click there leaves) and resizes nothing: $(diff <(printf '%s\n' "$frame_c") <(printf '%s\n' "$frame_d") | head -n 5)"; fi
assert_row "$frame_d" '^│ STATE    KEY         ID {13}WHAT ' "and ID keeps its automatic width"
frame_d=$(render populated.json --mouse "drag:36,3->46") || fail "drag on a row: render exited non-zero"
frame_c=$(render populated.json --mouse "click:36,3") || fail "click on a row: render exited non-zero"
if [ "$frame_d" = "$frame_c" ]; then pass; else fail "a drag started on a row line selects the row and resizes nothing: $(diff <(printf '%s\n' "$frame_c") <(printf '%s\n' "$frame_d") | head -n 5)"; fi
# Clamps: a column never goes under its label width plus one, and never takes more than the flexible
# column can spare (falsify: drop min or max from boundaryAt, or the clamp from drag-move).
frame_d=$(render populated.json --mouse "drag:36,2->21") || fail "drag left past the minimum: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {3}WHAT ' "dragged 15 cells left, ID stops at 3, its label width plus one"
assert_row "$frame_d" '^│ blocked  -           sc…  blocked: gh auth expired' "the rows truncate to the three-cell ID"
assert_contains "$frame_d" "ID 3 wide" "the footer names the clamped width"
frame_d=$(render populated.json --mouse "drag:36,2->158") || fail "drag right past the maximum: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {97}WHAT   REPO' "dragged to the frame's edge, ID stops at 97 and WHAT keeps its five-cell minimum"
assert_row "$frame_d" '^│ hold     - +decide-vendor +Pick…  acme/api +main +3d │$' "the flexible column at its minimum shows four characters and the ellipsis"
assert_widths "$frame_d" 160 "clamped drag: lines are still 160 columns"
# The boundary beside the flexible column moves the fixed column on its other side, so the boundary
# still follows the pointer: WHAT/REPO dragged right narrows REPO (falsify: return null in boundaries()
# for a boundary whose left column is flexible, or drop sign).
frame_d=$(render populated.json --mouse "drag:127,2->137") || fail "drag WHAT/REPO: render exited non-zero"
assert_row "$frame_d" '^│ blocked  - +scout-beta +blocked: gh auth expired +acme…  main +2h │$' "dragging the WHAT/REPO boundary ten cells right narrows REPO to its five-cell minimum"
assert_contains "$frame_d" "REPO 5 wide" "the footer names REPO, the column that moved"
# Mid-drag, before the release, the boundary's first gutter cell draws a bar on the header and on
# every row of that pane, bold yellow with --tags, and nowhere else (falsify: drop the drag branch
# from gutterSegments, or the drag style from STYLE_TAGS).
frame_d=$(render populated.json --mouse "click:36,2 move:41,2") || fail "mid-drag: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {16}│ WHAT ' "mid-drag: the bar stands in the header's gutter at the pointer, ID 18 wide"
assert_row "$frame_d" '^│ blocked  -           scout-beta {8}│ blocked: gh auth expired' "mid-drag: the rows draw the bar in the same cell"
tags_d=$(render populated.json --mouse "click:36,2 move:41,2" --tags) || fail "mid-drag --tags: render exited non-zero"
assert_count "$tags_d" '{bold}{yellow-fg}│{/yellow-fg}{/bold}' 7 "mid-drag --tags: the bar is bold yellow on the header and the six rows of Captain's Call only"
frame_d=$(render populated.json --mouse "click:36,2 move:41,2 release:41,2") || fail "drag then release: render exited non-zero"
assert_not_contains "$frame_d" "│ WHAT" "after the release the bar is gone"
assert_row "$frame_d" '^│ STATE    KEY         ID {18}WHAT ' "after the release ID keeps its 18 cells"
frame_d=$(render populated.json --mouse "click:36,2 move:41,2" --keys "j") || fail "key mid-drag: render exited non-zero"
assert_not_contains "$frame_d" "│ WHAT" "a key pressed mid-drag ends the drag"
assert_row "$frame_d" '^│ STATE    KEY         ID {18}WHAT ' "a key pressed mid-drag keeps the width reached"
# A drag that comes back to where it started leaves no custom width behind (falsify: persist on every
# drag-end).
frame_d=$(render populated.json --mouse "click:36,2 move:46,2 move:36,2 release:36,2") || fail "drag back: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {13}WHAT ' "dragged out and back, ID is automatic again"
assert_not_contains "$frame_d" "wide" "dragged out and back, no width is announced"

# Persistence: the width goes to the view-state file on the release and a restart reads it back; the
# saved width pins the column when the data changes (falsify: drop columns from serializeViewState or
# loadViewState, or from persist in index.mjs).
vs_cols="$SCRATCH/view-state-columns.json"
rm -f "${vs_cols:?}"
frame_d=$(render populated.json --view-state "$vs_cols" --mouse "drag:36,2->46") || fail "drag with view state: render exited non-zero"
assert_file_contains "$vs_cols" '"needs": {' "the view-state file records the pane"
assert_file_contains "$vs_cols" '"id": 23' "the view-state file records the column and its width"
assert_file_contains "$vs_cols" '"hidden_panes": []' "the other view state is written beside it"
frame_d=$(render populated.json --view-state "$vs_cols") || fail "drag reload: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {23}WHAT ' "a restart reads the width back from the file"
frame_d=$(render column-widths.json --view-state "$vs_cols") || fail "drag reload other data: render exited non-zero"
assert_row "$frame_d" '^│ STATE  KEY       ID {23}WHAT ' "the saved width pins ID at 23 where the data alone would size it 24"
# A double-click on the boundary resets that column and drops it from the file (falsify: drop
# reset-column from mouseAction, or the persist from its case).
frame_d=$(render populated.json --view-state "$vs_cols" --mouse "dblclick:46,2") || fail "dblclick boundary: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {13}WHAT ' "a double-click on the moved boundary puts ID back to its automatic width"
assert_contains "$frame_d" "ID back to its automatic width" "the footer says so"
assert_file_not_contains "$vs_cols" '"id"' "the reset column is gone from the file"
frame_d=$(render populated.json --mouse "dblclick:36,2") || fail "dblclick automatic boundary: render exited non-zero"
assert_contains "$frame_d" "ID already has its automatic width" "a double-click on an automatic column says there is nothing to reset"
assert_row "$frame_d" '^│ STATE    KEY         ID {13}WHAT ' "and changes nothing"
# = resets every pane, from the board and from the Settings page, and says how many widths it
# dropped; the review pane's own column set resizes and resets the same way (falsify: drop the = case
# from keyAction, the reset-columns entry from settingsEntries, or the review pane's header geometry).
frame_d=$(render populated.json --view-state "$vs_cols" --mouse "drag:36,2->46 drag:33,22->43") || fail "two drags: render exited non-zero"
assert_row "$frame_d" '^│ CHECKS    STATUS     ID {20}TITLE ' "My PRs' ID/TITLE boundary drags its ID to 20"
assert_file_contains "$vs_cols" '"mine": {' "the review pane's width is saved under its own id"
frame_d=$(render populated.json --view-state "$vs_cols" --keys "=") || fail "reset all: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {13}WHAT ' "= resets Captain's Call's ID"
assert_row "$frame_d" '^│ CHECKS    STATUS     ID {10}TITLE ' "= resets My PRs' ID"
assert_contains "$frame_d" "column widths reset: 2 custom widths dropped" "= counts the widths it dropped"
assert_file_not_contains "$vs_cols" '"id"' "= empties the saved widths"
frame_d=$(render populated.json --keys "=") || fail "reset none: render exited non-zero"
assert_contains "$frame_d" "no custom column widths to reset" "= with nothing to reset says so"
frame_d=$(render populated.json --view-state "$vs_cols" --mouse "drag:36,2->46" --keys ".,pagedown,enter,escape") || fail "settings reset: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {13}WHAT ' "the Settings page's last entry, Reset column widths, resets the board's columns"
assert_contains "$frame_d" "column widths reset: 1 custom width dropped" "the Settings entry reports through the same notice"
frame_s=$(render populated.json --keys ".") || fail "settings entry: render exited non-zero"
assert_row "$frame_s" '^   Reset column widths +every pane back to its automatic widths \(= on the board\) +$' "the Settings page lists the entry"
# A saved file naming a pane or column the board does not know, or a width that is not a positive
# integer, loses only that entry (falsify: drop sanitizeColumns from loadViewState).
printf '{"schema":"fm-board-view-state.v1","hidden":[],"hidden_panes":[],"columns":{"needs":{"id":30,"bogus":9},"nope":{"id":5},"mine":{"id":"wide"}}}\n' > "$vs_cols"
frame_d=$(render populated.json --view-state "$vs_cols" --keys "tab,tab,tab,tab,x") || fail "hand-written columns: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY         ID {30}WHAT ' "a saved width for a known pane and column applies"
assert_row "$frame_d" '^│ CHECKS    STATUS     ID {10}TITLE ' "a width that is not a number is ignored"
assert_file_contains "$vs_cols" '"id": 30' "the known width survives the next save"
assert_file_not_contains "$vs_cols" 'bogus' "an unknown column key is dropped on the next save"
assert_file_not_contains "$vs_cols" 'nope' "an unknown pane id is dropped on the next save"
assert_file_not_contains "$vs_cols" 'wide' "a width that is not a number is dropped on the next save"
# The narrow list shares one header over every pane and ignores the saved widths, and nothing on
# that header is a boundary (falsify: pass overrides to columns() in renderList, or give the list
# header a zone with geometry).
printf '{"schema":"fm-board-view-state.v1","hidden":[],"hidden_panes":[],"columns":{"needs":{"id":30},"inflight":{"id":30}}}\n' > "$vs_cols"
frame_d=$(render narrow.json --view-state "$vs_cols") || fail "narrow with columns: render exited non-zero"
if [ "$frame_d" = "$frame_narrow" ]; then pass; else fail "narrow: the saved widths changed the shared list: $(diff <(printf '%s\n' "$frame_narrow") <(printf '%s\n' "$frame_d") | head -n 5)"; fi
frame_d=$(render narrow.json --mouse "drag:20,1->30 drag:9,1->15") || fail "narrow drag: render exited non-zero"
if [ "$frame_d" = "$frame_narrow" ]; then pass; else fail "narrow: a drag on the shared header changed the frame: $(diff <(printf '%s\n' "$frame_narrow") <(printf '%s\n' "$frame_d") | head -n 5)"; fi
# --no-mouse leaves a drag unread like every other gesture (falsify: skip only click tokens under
# --no-mouse in driveOnce).
frame_d=$(render populated.json --no-mouse --mouse "drag:36,2->46 dblclick:36,2 move:41,2 release:41,2") || fail "--no-mouse drag: render exited non-zero"
if [ "$frame_d" = "$frame" ]; then pass; else fail "--no-mouse: a drag changed the frame: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_d") | head -n 5)"; fi
# The help names the key and the gesture (falsify: drop the = or drag lines from HELP_LINES).
frame_d=$(render populated.json --keys "?") || fail "help columns: render exited non-zero"
assert_contains "$frame_d" "=            reset every column width to its automatic size" "help overlay documents ="
assert_contains "$frame_d" "drag         a column boundary in a pane's header row resizes that column" "help overlay documents the drag"
# --mouse parsing of the drag tokens (falsify: loosen the drag regex in parseMouseToken).
if out=$("$BOARD" --render-once --fixture "$FIX/empty.json" --no-herdr --mouse "drag:35,2" 2>&1); then
  fail "--mouse drag without ->X2 should be refused"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq -- '--mouse: bad event "drag:35,2"'; then pass; else fail "--mouse names the bad drag token whole: $out"; fi
if out=$("$BOARD" --render-once --fixture "$FIX/empty.json" --no-herdr --mouse "move:12" 2>&1); then
  fail "--mouse move without Y should be refused"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq -- '--mouse: bad event "move:12"'; then pass; else fail "--mouse names the bad move token: $out"; fi
frame_d=$(render populated.json --mouse "drag:36,2->46,x") || fail "drag comma list: render exited non-zero"
assert_row "$frame_d" '^│ STATE +KEY +ID {23}WHAT ' "a comma-separated list keeps the drag token whole"
assert_contains "$frame_d" "hidden scout-beta" "and reads the rest as keys: x hid the Captain's Call row the keyboard selection was on"

# ----------------------------------------------------------- wrapper checks
# The fake herdr on HERDR_BIN_PATH and PATH (fake_herdr_env, defined with the other fakes at the
# top) guards the checks below.
# Without FM_HOME the wrapper stops with two lines, each carrying a command to copy (falsify: fold
# die_no_home back into one die(), or drop the plugin fm-home line). From a directory with no
# firstmate home above it and without herdr, the plugin line uses the $(herdr plugin config-dir) form.
mkdir -p "$SCRATCH/nohome"
if out=$(cd "$SCRATCH/nohome" && env -u FM_HOME -u HERDR_PLUGIN_CONFIG_DIR "$BOARD" --render-once --no-herdr 2>&1); then
  fail "wrapper without FM_HOME should exit non-zero"
else
  pass
fi
assert_contains "$out" "FM_HOME is not set" "wrapper names FM_HOME in its error"
assert_lines "$out" 2 "the FM_HOME error is exactly two lines"
assert_row "$out" '^firstmate-tui: FM_HOME is not set\. In a terminal:  export FM_HOME=/path/to/firstmate   \(the directory holding bin/fm-fleet-snapshot\.sh\), then run this again\.$' "line 1 carries the export command"
assert_row "$out" '^firstmate-tui: for a herdr plugin action, which carries no FM_HOME:  mkdir -p "\$\(herdr plugin config-dir firstmate\.board\)" && echo /path/to/firstmate > "\$\(herdr plugin config-dir firstmate\.board\)/fm-home"$' "line 2 carries the fm-home command in its herdr-less form"
assert_not_contains "$out" "Found a firstmate home" "no firstmate home above the scratch directory: nothing is suggested"
# With herdr answering, the plugin line prints the resolved directory instead (falsify: drop the
# plugin_config_dir call from die_no_home).
if out=$(cd "$SCRATCH/nohome" && fake_herdr_env env -u FM_HOME -u HERDR_PLUGIN_CONFIG_DIR "$BOARD" --render-once 2>&1); then
  fail "wrapper without FM_HOME (herdr reachable) should exit non-zero"
else
  pass
fi
assert_lines "$out" 2 "the FM_HOME error with herdr is still two lines"
assert_contains "$out" "mkdir -p $PLUGIN_DIR && echo /path/to/firstmate > $PLUGIN_DIR/fm-home" "line 2 names the directory herdr plugin config-dir printed"
assert_file_contains "$HERDR_LOG" "herdr plugin config-dir firstmate.board" "the directory came from herdr plugin config-dir"
# A firstmate home above the current directory is suggested by absolute path and never adopted
# (falsify: make resolve_fm_home fall back to suggest_fm_home; the render would then succeed).
mkdir -p "$FAKE_HOME/projects/deep"
fake_home_real=$(cd "$FAKE_HOME" && pwd -P)
if out=$(cd "$FAKE_HOME/projects/deep" && env -u FM_HOME -u HERDR_PLUGIN_CONFIG_DIR "$BOARD" --render-once --no-herdr 2>&1); then
  fail "no FM_HOME inside a firstmate home: must still exit non-zero, discovery only suggests"
else
  pass
fi
assert_lines "$out" 2 "the suggested-home error is two lines"
assert_contains "$out" "Found a firstmate home above the current directory" "line 1 says a home was found"
assert_contains "$out" "export FM_HOME=$fake_home_real   then run this again." "the export command names the found home by absolute path"
assert_contains "$out" "echo $fake_home_real > " "the plugin line echoes the found home"
if "$BOARD" --help 2>/dev/null | grep -Fq -- "--render-once"; then pass; else fail "wrapper --help lists --render-once"; fi
if "$BOARD" --help 2>/dev/null | grep -Fq -- "--keys"; then pass; else fail "wrapper --help lists --keys"; fi
if "$BOARD" --help 2>/dev/null | grep -Fq -- "--viewer-cmd"; then pass; else fail "wrapper --help lists --viewer-cmd"; fi
if "$BOARD" --help 2>/dev/null | grep -Fq -- "--view-state"; then pass; else fail "wrapper --help lists --view-state"; fi
if "$BOARD" --help 2>/dev/null | grep -Fq -- "--config <path>"; then pass; else fail "wrapper --help lists --config"; fi
if "$BOARD" --help 2>/dev/null | grep -Fq -- "-firstmate"; then fail "wrapper --help still lists a firstmate pane subcommand"; else pass; fi
# Bare, `open` and `run` are one command: with the same flags all three print the same
# frame, and it is the frame the suite checked above (falsify: drop the open -> run mapping
# after the argument loop, route plain open to open_detached, or drop `run` from the
# subcommand case so it falls into the unknown-subcommand branch).
frame_bare=$("$BOARD" --render-once --fixture "$FIX/populated.json" --no-herdr) || fail "wrapper bare: render exited non-zero"
frame_run=$("$BOARD" run --render-once --fixture "$FIX/populated.json" --no-herdr) || fail "wrapper run: render exited non-zero"
frame_open=$("$BOARD" open --render-once --fixture "$FIX/populated.json" --no-herdr) || fail "wrapper open: render exited non-zero"
if [ -n "$frame_open" ] && [ "$frame_open" = "$frame_run" ]; then pass; else fail "open printed a different frame from run: $(diff <(printf '%s\n' "$frame_run") <(printf '%s\n' "$frame_open") | head -n 5)"; fi
if [ -n "$frame_bare" ] && [ "$frame_bare" = "$frame_open" ]; then pass; else fail "bare printed a different frame from open: $(diff <(printf '%s\n' "$frame_open") <(printf '%s\n' "$frame_bare") | head -n 5)"; fi
if [ "$frame_bare" = "$frame" ]; then pass; else fail "the bare frame differs from the populated frame rendered through render() at the top of the suite"; fi
# `help` is the usage page with exit 0, the same page as --help and -h; an unknown
# subcommand prints it to stderr and exits 2 with nothing on stdout (falsify: drop the help
# case or the catch-all from the subcommand case, or print the page to stdout there).
if help_page=$("$BOARD" help 2>/dev/null); then pass; else fail "help should exit 0"; fi
if [ "$help_page" = "$("$BOARD" --help 2>/dev/null)" ] && [ "$help_page" = "$("$BOARD" -h 2>/dev/null)" ]; then pass; else fail "help, --help and -h should print the same page"; fi
bogus_stdout=$("$BOARD" bogus 2>"$SCRATCH/bogus.err")
bogus_status=$?
if [ "$bogus_status" -eq 2 ]; then pass; else fail "an unknown subcommand should exit 2, got $bogus_status"; fi
if [ -z "$bogus_stdout" ]; then pass; else fail "an unknown subcommand printed to stdout: $bogus_stdout"; fi
assert_file_contains "$SCRATCH/bogus.err" "unknown subcommand bogus" "the unknown subcommand is named on stderr"
assert_file_contains "$SCRATCH/bogus.err" "usage: firstmate-tui [open] [flags]" "the usage page follows on stderr"
# --help after open works like --help alone (falsify: handle -h/--help only before the
# subcommand case).
if "$BOARD" open --help >/dev/null 2>&1; then pass; else fail "open --help should exit 0"; fi
# open --detached is the only route that places a pane, and it needs herdr; with --no-herdr the
# wrapper refuses before any herdr call, which the fake's empty log proves (falsify: drop the
# want_herdr guard from open_detached, or the --detached case from the argument loop).
if out=$(FM_HOME="$FAKE_HOME" fake_herdr_env "$BOARD" open --detached --no-herdr 2>&1); then
  fail "open --detached --no-herdr should exit non-zero"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq -- "open --detached needs herdr"; then pass; else fail "open --detached --no-herdr says the detached route needs herdr: $out"; fi
if [ -e "$HERDR_LOG" ]; then fail "open --detached --no-herdr called herdr: $(cat "$HERDR_LOG")"; else pass; fi
# --detached belongs to open alone (falsify: drop the command != open check).
if out=$("$BOARD" run --detached --render-once --fixture "$FIX/empty.json" --no-herdr 2>&1); then
  fail "run --detached should exit non-zero"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq -- "--detached applies to 'open' only"; then pass; else fail "run --detached names open in its error: $out"; fi
# --help documents the in-place default and the detached flag (falsify: restore the old open
# line in the header comment of bin/firstmate-tui.sh).
help=$("$BOARD" --help 2>/dev/null)
if printf '%s\n' "$help" | grep -Fq -- "open --detached"; then pass; else fail "wrapper --help lists open --detached"; fi
# The usage page leads with the bare command and `open` as one thing, running in this
# terminal, and does not list `run`, which stays a hidden synonym (falsify: put [run] back
# in the usage line, or dump the header comment again).
if printf '%s\n' "$help" | grep -Eq -- '^usage: firstmate-tui \[open\] \[flags\] +run the board in this terminal'; then pass; else fail "wrapper --help leads with firstmate-tui [open] [flags] running in this terminal"; fi
if printf '%s\n' "$help" | grep -Fq -- "[run]"; then fail "wrapper --help still lists run as the primary command"; else pass; fi
if printf '%s\n' "$help" | grep -Eq -- '^ *firstmate-tui open \[flags\] .*herdr pane'; then fail "wrapper --help still describes plain open as opening its own pane"; else pass; fi
if printf '%s\n' "$help" | grep -Fq -- "launcher for firstmate-tui"; then fail "wrapper --help dumps the header comment instead of a usage page"; else pass; fi
for sub in "firstmate-tui focus" "firstmate-tui upgrade" "firstmate-tui version" "firstmate-tui help"; do
  if printf '%s\n' "$help" | grep -Fq -- "$sub"; then pass; else fail "wrapper --help lists $sub"; fi
done
for flag in --refresh --no-prs --home --no-herdr; do
  if printf '%s\n' "$help" | grep -Fq -- "$flag"; then pass; else fail "wrapper --help lists the common flag $flag"; fi
done
if printf '%s\n' "$help" | grep -Fq -- "Press ? inside the"; then pass; else fail "wrapper --help points at ? for the keys"; fi
if printf '%s\n' "$help" | grep -Fq -- "running from a checkout at $ROOT"; then pass; else fail "wrapper --help from a checkout names the checkout (falsify: read the install record without testing for it)"; fi
# The manifest's palette action has no terminal to run in, so it carries --detached; the pane
# entry keeps running the board in place (falsify: edit either command in herdr-plugin.toml).
if grep -Fq -- '"open", "--detached"]' "$ROOT/bin/firstmate-tui/herdr-plugin.toml"; then pass; else fail "herdr-plugin.toml open action carries --detached"; fi
if grep -Fq -- '"../firstmate-tui.sh", "open"]' "$ROOT/bin/firstmate-tui/herdr-plugin.toml"; then pass; else fail "herdr-plugin.toml pane entry runs the board in place with the public subcommand"; fi
if out=$("$BOARD" --render-once --fixture "$FIX/empty.json" --no-herdr --config 2>&1); then
  fail "--config without a value should exit non-zero"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq -- "--config needs a value"; then pass; else fail "--config without a value is named in the error: $out"; fi
if out=$("$BOARD" --render-once --fixture "$FIX/empty.json" --no-herdr --view-state 2>&1); then
  fail "--view-state without a value should exit non-zero"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq -- "--view-state needs a value"; then pass; else fail "--view-state without a value is named in the error: $out"; fi
if out=$("$BOARD" --render-once --fixture "$FIX/empty.json" --no-herdr --keys 2>&1); then
  fail "--keys without a value should exit non-zero"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq -- "--keys needs a value"; then pass; else fail "--keys without a value is named in the error: $out"; fi
if out=$("$BOARD" --render-once --fixture "$FIX/empty.json" --no-herdr --bogus 2>&1); then
  fail "unknown flag should exit non-zero"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq "unknown option --bogus"; then pass; else fail "unknown flag is named in the error: $out"; fi
if "$BOARD" --help 2>/dev/null | grep -Fq -- "--curl-cmd"; then pass; else fail "wrapper --help lists --curl-cmd"; fi
if "$BOARD" --help 2>/dev/null | grep -Fq -- "--install-root"; then pass; else fail "wrapper --help lists --install-root"; fi
# run answers the board's exit 75 (the relaunch key on the Settings page) by starting itself again
# with the flags as typed, once; every other status passes through and runs the board once (falsify:
# exec node in run_board, or re-run on every status). tests/fake-node.sh on PATH answers the version
# probe, logs each board start and exits 75 (or FM_BOARD_TEST_NODE_FIRST_EXIT) the first time, 0 after.
FAKE_NODE="$SCRATCH/fake-node"
mkdir -p "$FAKE_NODE"
cp "$ROOT/tests/fake-node.sh" "$FAKE_NODE/node"
chmod +x "$FAKE_NODE/node"
NODE_LOG="$SCRATCH/node.log"
rm -f "$NODE_LOG"
PATH="$FAKE_NODE:$PATH" FM_BOARD_TEST_NODE_LOG="$NODE_LOG" "$BOARD" --render-once --fixture "$FIX/empty.json" --no-herdr --keys "tab,j" >/dev/null 2>&1
status=$?
if [ "$status" -eq 0 ]; then pass; else fail "relaunch: the wrapper should exit 0 after the relaunched board exits 0, got $status"; fi
assert_count "$(cat "$NODE_LOG" 2>/dev/null)" "index.mjs --render-once --fixture $FIX/empty.json --no-herdr --keys tab,j" 2 "exit 75 starts the board a second time with the same arguments"
assert_lines "$(cat "$NODE_LOG" 2>/dev/null)" 2 "exit 75 relaunches exactly once"
rm -f "$NODE_LOG"
PATH="$FAKE_NODE:$PATH" FM_BOARD_TEST_NODE_LOG="$NODE_LOG" FM_BOARD_TEST_NODE_FIRST_EXIT=3 "$BOARD" open --render-once --fixture "$FIX/empty.json" --no-herdr >/dev/null 2>&1
status=$?
if [ "$status" -eq 3 ]; then pass; else fail "relaunch: exit 3 should pass through, got $status"; fi
assert_lines "$(cat "$NODE_LOG" 2>/dev/null)" 1 "exit 3 runs the board once and relaunches nothing"
# A live run with herdr answering gets both files in herdr's plugin config directory, view-state.json
# and config.json, unless the flag was given; the fake node logs the argv the launcher built (falsify:
# drop the --config line from the plugin-directory block in bin/firstmate-tui.sh).
rm -f "$NODE_LOG"
FM_HOME="$FAKE_HOME" fake_herdr_env env PATH="$FAKE_NODE:$FAKE_BIN:$PATH" FM_BOARD_TEST_NODE_LOG="$NODE_LOG" FM_BOARD_TEST_NODE_FIRST_EXIT=0 "$BOARD" open --no-prs >/dev/null 2>&1
assert_contains "$(cat "$NODE_LOG" 2>/dev/null)" "--view-state $PLUGIN_DIR/view-state.json" "a live run passes the plugin directory's view-state.json"
assert_contains "$(cat "$NODE_LOG" 2>/dev/null)" "--config $PLUGIN_DIR/config.json" "a live run passes the plugin directory's config.json the same way"
assert_file_contains "$HERDR_LOG" "herdr plugin config-dir firstmate.board" "the directory came from herdr plugin config-dir"
rm -f "$NODE_LOG"
FM_HOME="$FAKE_HOME" fake_herdr_env env PATH="$FAKE_NODE:$FAKE_BIN:$PATH" FM_BOARD_TEST_NODE_LOG="$NODE_LOG" FM_BOARD_TEST_NODE_FIRST_EXIT=0 "$BOARD" open --no-prs --config /tmp/own.json >/dev/null 2>&1
assert_contains "$(cat "$NODE_LOG" 2>/dev/null)" "--config /tmp/own.json" "an explicit --config is passed through"
assert_count "$(cat "$NODE_LOG" 2>/dev/null)" "--config" 1 "an explicit --config is not doubled by the plugin directory's"
assert_contains "$(cat "$NODE_LOG" 2>/dev/null)" "--view-state $PLUGIN_DIR/view-state.json" "an explicit --config still gets the plugin directory's view-state.json"

# ---------------------------------------------------- real terminal input
# The one section that runs the interactive board itself, on a pseudo-terminal through tests/pty-keys.py,
# typing raw bytes: the terminal library's own input path, which --render-once never loads. neo-blessed
# 0.2.0 reports one carriage return (0x0d) as two keypress events, 'enter' and then 'return', and the
# adapter must hand the controller one key, or every Enter acts twice: a PR row opened twice (two opener
# calls from the same board pid) and on the Settings page the second enter cancelled the confirmation the
# first had opened, so y did nothing (falsify: map 'return' to 'enter' again in normalizeKey; with the
# adapter before the fix the opener log below has two lines and the upgrade log stays absent). Each
# gesture runs under TERM=xterm-256color, screen and tmux-256color, whichever terminfo the host has,
# because the board runs inside herdr. The driver waits for the PR row's URL, not the pane header, since
# the header is drawn over the loading spinner before the snapshot lands. Each run gets its own
# view-state file (and so its own state cache beside it): the app saves the selection on quit and
# restores it at launch, so runs sharing one file would start where the last one left off. Needs
# python3 and the board's node_modules (npm ci in bin/firstmate-tui); without them the section is
# skipped with a note, not failed.
PTY="$ROOT/tests/pty-keys.py"
PTY_URL=https://github.com/acme/widgets/pull/41
PTY_TRACE="$SCRATCH/pty-opener-trace.log"
if command -v python3 >/dev/null 2>&1 && [ -d "$ROOT/bin/firstmate-tui/node_modules/neo-blessed" ]; then
  run_pty() { # <term> <name> <actions...>: the interactive board on a pty against the stand-in home, with every fake wired
    local term=$1 name=$2
    shift 2
    rm -f "${OPENER_LOG:?}" "${PTY_TRACE:?}" "${UPGRADE_LOG:?}" "${CURL_LOG:?}" "${HOLD_LOG:?}"
    mkdir -p "$SCRATCH/pty-$name"
    FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" PATH="$FAKE_BIN:$PATH" \
      FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" FM_BOARD_TEST_OPENER_TRACE="$PTY_TRACE" FM_BOARD_TEST_UPGRADE_LOG="$UPGRADE_LOG" FM_BOARD_TEST_HOLD_LOG="$HOLD_LOG" \
      FAKE_CURL_ROOT="$REL" FAKE_CURL_LOG="$CURL_LOG" \
      python3 "$PTY" --term "$term" --timeout 20 --capture "$SCRATCH/pty-$name.bin" "$@" -- \
      "$BOARD" run --no-herdr --no-prs --opener-cmd "$FAKE_OPENER" --install-root "$INSTALL" --curl-cmd "bash $ROOT/tests/fake-curl.sh" --view-state "$SCRATCH/pty-$name/view-state.json" \
      > "$SCRATCH/pty-$name.out" 2>&1
  }
  pty_ok() { # <name> <label>: the driver saw every marker it waited for and the board exited on q
    if grep -q "not seen\|must not be\|killed\|still running" "$SCRATCH/pty-$1.out"; then fail "$2: $(tr '\n' ';' < "$SCRATCH/pty-$1.out")"; else pass; fi
  }
  pty_terms=""
  for t in xterm-256color screen tmux-256color; do
    if infocmp "$t" >/dev/null 2>&1; then pty_terms="$pty_terms $t"; fi
  done
  [ -n "$pty_terms" ] || pty_terms=xterm-256color
  for t in $pty_terms; do
    # One 0x0d on the first My PRs row (two tabs move there from Underway once the row is drawn):
    # exactly one opener call, made by the board (the trace names one pid and the URL as the only
    # argument).
    run_pty "$t" "cr-$t" "wait:$PTY_URL" "send:\t" "sleep:0.3" "send:\t" "sleep:0.6" "send:\r" "wait:opened$PTY_URL" "sleep:0.4" "send:q" exit
    pty_ok "cr-$t" "pty $t: one Enter on a PR row reaches the opened notice and q quits"
    assert_opened "$PTY_URL" "pty $t: one carriage return on a PR row calls the opener exactly once (falsify: map 'return' to 'enter' in normalizeKey)"
    assert_lines "$(cat "$PTY_TRACE" 2>/dev/null)" 1 "pty $t: the opener trace holds one invocation (pid, ppid, argv)"
    assert_contains "$(cat "$PTY_TRACE" 2>/dev/null)" "argv=$PTY_URL" "pty $t: that invocation carries the URL as its only argument"
    # One 0x0d on the Settings Upgrade entry: the confirm line is drawn and still pending, so y runs the
    # launcher once. The old double delivery cancelled it and y did nothing.
    run_pty "$t" "settings-$t" "wait:$PTY_URL" "send:." "wait:Upgradeto0.2.0" "send:\r" "wait:ytoconfirm" "sleep:0.4" "send:y" "wait:0.2.0installed" "sleep:0.4" "send:q" "sleep:0.4" "send:q" exit
    pty_ok "settings-$t" "pty $t: one Enter on Upgrade shows the confirm line and y runs the installer"
    assert_upgrade_log "upgrade --version 0.2.0" "pty $t: one carriage return opens the prompt and y then runs the launcher exactly once"
    assert_not_opened "pty $t: nothing on the Settings page opens a PR"
  done
  # The colour bytes, from the same captures. The selected row is the terminal's inverse video (SGR 7)
  # whatever TERM says. The focused pane's border is lib/tui-blessed.mjs accentStyle: bold palette 214
  # (38;5;214) when the terminal reports 256 colours, bold yellow (1;33) below that, so the library
  # never reduces 214 to red; the amber background 0.6.1 drew the bar with (48;5;214) appears nowhere.
  # The colour count that picks the expectation is the one neo-blessed's own terminfo reader gives for
  # that TERM, not the TERM's name and not tput's answer: the terminfo entry for tmux-256color exists
  # on the GitHub Ubuntu runner (infocmp admits it to pty_terms above) yet neo-blessed 0.2.0 reads it
  # as 8 colours there, so the board rightly draws the fallback on that host; the note line names both
  # counts so a CI log shows which case ran (falsify: put the amber background back in
  # STYLE_TAGS.selected, a hex tag or cyan in STYLE_TAGS['border-focus'], or drop accentStyle from
  # createScreen). The library joins a cell's codes into one SGR sequence (ESC [ codes m) with bold
  # first, so bold yellow is `1;33` and a code may sit between others; a cursor move such as
  # ESC [ 7 ; 1 H is not one. Bold yellow is otherwise only the column drag bar, which nothing here drags.
  tput_colors() { # <TERM>: the colour count neo-blessed reads for it, 0 when it cannot
    node -e 'const b = require(process.argv[1] + "/node_modules/neo-blessed"); let c = 0; try { c = new b.Tput({ terminal: process.argv[2] }).colors || 0; } catch (e) { c = 0; } process.stdout.write(String(c));' "$ROOT/bin/firstmate-tui" "$1"
  }
  for t in $pty_terms; do
    colors=$(tput_colors "$t")
    printf 'note: pty %s: neo-blessed reads %s colours (tput -T %s colors says %s)\n' "$t" "${colors:-0}" "$t" "$(tput -T "$t" colors 2>/dev/null || echo '?')"
    if LC_ALL=C grep -aEq $'\e\\[([0-9]+;)*7(;[0-9]+)*m' "$SCRATCH/pty-cr-$t.bin"; then pass; else fail "pty $t: the selected row is not drawn inverse (SGR 7)"; fi
    if LC_ALL=C grep -aEq $'\e\\[([0-9]+;)*48;5;214(;[0-9]+)*m' "$SCRATCH/pty-cr-$t.bin"; then fail "pty $t: something is drawn on the amber background 48;5;214 of the 0.6.1 bar"; else pass; fi
    if [ "${colors:-0}" -ge 256 ] 2>/dev/null; then
      if LC_ALL=C grep -aEq $'\e\\[([0-9]+;)*38;5;214(;[0-9]+)*m' "$SCRATCH/pty-cr-$t.bin"; then pass; else fail "pty $t ($colors colours): the focused border is not drawn in the 256-colour amber 38;5;214"; fi
      if LC_ALL=C grep -aEq $'\e\\[([0-9]+;)*1;33(;[0-9]+)*m' "$SCRATCH/pty-cr-$t.bin"; then fail "pty $t ($colors colours): a 256-colour TERM got the bold yellow fallback"; else pass; fi
    else
      if LC_ALL=C grep -aEq $'\e\\[([0-9]+;)*1;33(;[0-9]+)*m' "$SCRATCH/pty-cr-$t.bin"; then pass; else fail "pty $t ($colors colours): below 256 colours the focused border is not drawn bold yellow 1;33"; fi
      if LC_ALL=C grep -aEq $'\e\\[([0-9]+;)*38;5;214(;[0-9]+)*m' "$SCRATCH/pty-cr-$t.bin"; then fail "pty $t ($colors colours): a TERM below 256 colours got a 256-colour foreground"; else pass; fi
    fi
  done
  # 0x0d 0x0a (a terminal in newline mode) opens once: the linefeed is a separate key the board does not
  # bind. 0x0a alone opens nothing (falsify: bind linefeed to enter, which would double a CR LF).
  run_pty xterm-256color crlf "wait:$PTY_URL" "send:\t" "sleep:0.3" "send:\t" "sleep:0.6" "send:\r\n" "wait:opened$PTY_URL" "sleep:0.4" "send:q" exit
  pty_ok crlf "pty: CR LF reaches the opened notice"
  assert_opened "$PTY_URL" "pty: CR LF on a PR row calls the opener exactly once"
  run_pty xterm-256color lf "wait:$PTY_URL" "send:\t" "sleep:0.3" "send:\t" "sleep:0.6" "send:\n" "sleep:1.2" "send:q" exit
  pty_ok lf "pty: LF alone leaves the board running until q"
  assert_not_opened "pty: LF alone (ctrl-j) opens nothing"
  # The D prompt on a real terminal: j, j, j selects decide-vendor, the stand-in's live captain hold and
  # Captain's Call's fourth row (after the blocked scout, the main decision and the delegate's relayed
  # decision); D opens the footer prompt; ten 0x7f bytes (the Backspace key, which the library names 'backspace'
  # and hands over as the DEL character) clear the default date, and typed digits and dashes fill it
  # through the library's keypress path, which --keys never exercises; the carriage return runs the
  # stand-in home's fake fm-captain-hold.sh exactly once with the typed date and the record's reason
  # (falsify: drop the prompt branch from handleKey, or let normalizeKey return DEL for the Backspace
  # key: the backspaces then do nothing, the full value refuses every digit and enter defers to the
  # default date). Only the prompt's `(YYYY-MM-DD):` is waited for on screen: its cells all differ
  # from the hint they replace, while the letters of a notice drawn over an earlier one of the same
  # length can reach the driver missing; the log, not the screen, proves the rest. After the carriage
  # return the deferred row leaves Captain's Call at once: the delegate's hold below it, etl-cutover,
  # moves up onto its line, and every cell of that row differs from the hold row it replaces, so the
  # driver sees the id repainted (falsify: drop dismissRow from holdDefer in lib/app.mjs, and the rows
  # stay where they were until the refresh lands, which the unchanged stand-in snapshot never moves them).
  run_pty xterm-256color hold-prompt "wait:$PTY_URL" "send:j" "sleep:0.3" "send:j" "sleep:0.3" "send:j" "sleep:0.3" "send:D" "wait:(YYYY-MM-DD):" "send:\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f" "sleep:0.4" "send:2027-01-15" "sleep:0.6" "send:\r" "wait:etl-cutover" "sleep:1.0" "send:q" exit
  pty_ok hold-prompt "pty: the D prompt opens on a real terminal, the deferred row leaves at once and the board exits on q"
  if [ -f "$HOLD_LOG" ]; then pass; else fail "pty: the D prompt's enter ran no hold command; the driver reported: $(tr '\n' ';' < "$SCRATCH/pty-hold-prompt.out")"; fi
  assert_hold_log "FM_HOME=$FAKE_HOME
cwd=$FAKE_HOME_REAL
argv=hold decide-vendor --reason Two quotes in the report --until 2027-01-15" "pty: the typed date reaches the stand-in home's fm-captain-hold.sh once, with the record's full reason (backspaces and digits both arrived)"
  assert_not_opened "pty: the D prompt opens no PR"
  # The a prompt on a real terminal: j, j, j selects decide-vendor as above; a replaces the grid with the
  # card (the heading lands where the Captain's Call border was, every cell different); the typed line with
  # its space bar reaches the answer through the library's keypress path; the carriage return runs the
  # stand-in's fake fm-captain-hold.sh once with --release (decide-vendor's record is kind task, a work
  # item) and the typed line, and the footer's notice lands on cells the prompt left blank. The decision
  # line names whatever login this host resolves, so it is matched apart (falsify: drop the accept branch
  # from promptKeyAction, and the letters go to the board's own keys).
  run_pty xterm-256color accept-prompt "wait:$PTY_URL" "send:j" "sleep:0.3" "send:j" "sleep:0.3" "send:j" "sleep:0.3" "send:a" "wait:Acceptdecide-vendor:" "sleep:0.4" "send:go ahead" "sleep:0.6" "send:\r" "wait:answerrecorded;firstmatedispatches" "sleep:1.0" "send:q" exit
  pty_ok accept-prompt "pty: the a prompt opens on a real terminal, the typed answer is recorded and the board exits on q"
  if [ "$(grep -v '^decision=' "$HOLD_LOG" 2>/dev/null)" = "FM_HOME=$FAKE_HOME
cwd=$FAKE_HOME_REAL
argv=answer decide-vendor --decision-file $(decision_file) --release" ]; then pass; else fail "pty: the a prompt's enter did not run answer --release once; the log is '$(tr '\n' '|' < "$HOLD_LOG" 2>/dev/null || echo '<absent>')', the driver reported: $(tr '\n' ';' < "$SCRATCH/pty-accept-prompt.out")"; fi
  assert_row "$(cat "$HOLD_LOG" 2>/dev/null)" "^decision=Accepted by [^ ]+ from firstmate-tui on $TODAY: go ahead$" "pty: the typed line, space included, is the decision"
  assert_not_opened "pty: the a prompt opens no PR"
  # The search prompt on a real terminal: f opens it, the typed query with its space bar reaches
  # the prompt through the library's keypress path (one keypress event per character of the chunk,
  # each redrawing the frame), and the carriage return jumps to the one match, the stand-in's tmux
  # task, whose notice lands on the footer's blank right end; then f again and one 0x1b (the Escape
  # key alone, which the library names 'escape') close the prompt so q quits the board (falsify:
  # drop the search branch from promptKeyAction: the letters then go to the board's own keys, enter
  # jumps to the first row of the empty query, ship-alpha, and the notice never names tmux-task;
  # drop the search-cancel case: q types into the query and the board never exits). The waits name
  # text on cells the previous frame left blank, since the library repaints changed cells only: the
  # header's `Search:` replaces the Captain's Call border, the notice the footer's spaces.
  run_pty xterm-256color search "wait:$PTY_URL" "send:f" "wait:Search:" "sleep:0.3" "send:tmux task" "sleep:0.6" "send:\r" "wait:tmux-taskin${T_INFLIGHT// /}" "sleep:0.4" "send:f" "wait:Search:" "sleep:0.3" "send:\x1b" "sleep:0.6" "send:q" exit
  pty_ok search "pty: f opens the search, the typed query finds the tmux task, enter jumps to it, esc closes a second search and q quits"
  assert_not_opened "pty: the search opens no PR"
  # A live start with the PR fetch on, against a stand-in whose snapshot sleeps 2 s and a gh that
  # sleeps 2 s before answering, so each state stays on screen long enough to be told apart. With
  # nothing to name the login (gh not logged in, github.user unset, the example config): both PR
  # panes spin on the identity, the identity row appears only once the rungs have answered, and r
  # spins again before the row returns. With gh logged in: the resolving line, then the fetch
  # spinner, then the rows. The library repaints changed cells only, so a phrase drawn over other
  # text can reach the driver with letters missing: the resolving line is waited for as a whole
  # once the snapshot's redraw has laid the panes out afresh (2 s in, the rungs still 2 s away),
  # the later lines are ones whose every cell differs from what they replace, and the last row
  # waited for lands on a blank line, with 60 rows so every row fits. `absent` checks the row was
  # not drawn before the spinner (falsify: fire identityRow on !identityKnown, and the row is drawn
  # first, so the resolving wait times out; drop the draw after the identity resolves, and the fetch
  # spinner is never seen; stamp fetchedAt for a skipped fetch, and r's second resolving line is
  # followed by the empty text, not the row).
  IDENT_HOME="$SCRATCH/firstmate-ident"
  mkdir -p "$IDENT_HOME/bin" "$SCRATCH/slow-gh-bin"
  # shellcheck disable=SC2016 # the fake expands $FM_BOARD_TEST_FETCH_LOG at run time, not here
  printf '#!/usr/bin/env bash\necho snapshot >> "$FM_BOARD_TEST_FETCH_LOG"\nsleep 2\ncat "%s"\n' "$FAKE_HOME/snapshot.json" > "$IDENT_HOME/bin/fm-fleet-snapshot.sh"
  cp "$FAKE_HOME/bin/fm-bearings-snapshot.sh" "$IDENT_HOME/bin/fm-bearings-snapshot.sh"
  chmod +x "$IDENT_HOME/bin/fm-fleet-snapshot.sh" "$IDENT_HOME/bin/fm-bearings-snapshot.sh"
  # shellcheck disable=SC2016 # the wrapper passes its own arguments on at run time
  printf '#!/usr/bin/env bash\nsleep 2\nexec "%s/gh" "$@"\n' "$FAKE_BIN" > "$SCRATCH/slow-gh-bin/gh"
  chmod +x "$SCRATCH/slow-gh-bin/gh"
  run_pty_identity() { # <name> <gh login failure: 1 or empty> <actions...>: the interactive board with the PR fetch on, against the slow stand-in, the slowed fake gh and the fake git, in its own config directory
    local name=$1 ghfail=$2
    shift 2
    rm -f "${FETCH_LOG:?}"
    FM_HOME="$IDENT_HOME" XDG_CONFIG_HOME="${PTY_XDG:-$SCRATCH/ident-pty-$name}" FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_BOARD_TEST_GH_LOGIN_FAIL="$ghfail" PATH="$SCRATCH/slow-gh-bin:$IDENT_BIN:$FAKE_BIN:$PATH" \
      FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" \
      python3 "$PTY" --term xterm-256color --rows 60 --timeout 20 --capture "$SCRATCH/pty-$name.bin" "$@" -- \
      "$BOARD" run --no-herdr --opener-cmd "$FAKE_OPENER" \
      > "$SCRATCH/pty-$name.out" 2>&1
  }
  run_pty_identity ident-none 1 "wait:resolvingGitHubidentity" "absent:identityunknown" "wait:identityunknown:seeSettings(.)" "send:r" "wait:resolvingGitHub" "wait:identityunknown" "sleep:0.4" "send:q" exit
  pty_ok ident-none "pty identity unknown: the resolving line first, the row once the rungs have answered, and r repeats both"
  assert_count "$(cat "$FETCH_LOG")" "gh api user --jq .login" 2 "pty identity unknown: the start and r each asked gh once"
  if grep -q "api graphql" "$FETCH_LOG"; then fail "pty identity unknown: a search ran with no login: $(cat "$FETCH_LOG")"; else pass; fi
  run_pty_identity ident-gh "" "wait:resolvingGitHubidentity" "absent:identityunknown" "wait:loadingGitHubchecks" "wait:Bumptheretrybudget" "sleep:0.4" "send:q" exit
  pty_ok ident-gh "pty identity known: the resolving line, then loading GitHub checks, then the rows gh answered"
  assert_count "$(cat "$FETCH_LOG")" "gh api user --jq .login" 1 "pty identity known: one gh api user call"
  assert_count "$(cat "$FETCH_LOG")" "gh api graphql " 5 "pty identity known: the four searches and the lookup ran once the login was known"
  # A warm launch: the previous run wrote the state cache on quit, so the next launch in the same
  # config directory draws the cached PR rows around the login they were fetched for, marked cached,
  # and never spins on the identity while the launch refresh resolves it again (falsify: set
  # prs.identity to null for every first resolution in lib/app.mjs, and the cached rows give way
  # to the resolving line).
  PTY_XDG="$SCRATCH/ident-pty-ident-gh" run_pty_identity ident-gh-warm "" "wait:cached" "sleep:4.5" "absent:resolvingGitHub" "absent:identityunknown" "wait:Bumptheretrybudget" "sleep:0.4" "send:q" exit
  pty_ok ident-gh-warm "pty warm launch: the cached rows stay on screen through the identity resolution"
  assert_count "$(cat "$FETCH_LOG")" "gh api user --jq .login" 1 "pty warm launch: the identity is still resolved once"
  # The two cycles on a real terminal, against a stand-in whose snapshot answers at once and gains a
  # task, latecomer, from its second run on, with the fake gh sleeping 4 s before each graphql answer
  # (one fetch, the four searches and then the lookup, takes 8 s) and --refresh 5. Cold: Underway's
  # rows are drawn at once while the PR panes spin; at 5 s the second local cycle lands and
  # latecomer, a failed task that sorts last onto a blank line (every cell new, so the driver sees
  # the whole id), is drawn while the fetch has 3 s to run and no PR row is on screen yet; the rows
  # follow when the fetch lands (falsify: await the fetch in the local cycle: latecomer is drawn
  # with the PR rows at 8 s, and the absent check after it fails). Warm, over the state cache the
  # cold run wrote on quit: the cached PR rows are on screen from the first frame, their titles gain
  # (updating), drawn over border cells, when the fetch starts and never give way to the fetch
  # spinner, and the capped-search note (FM_BOARD_TEST_GH_CAPPED) names the landing (falsify: drop
  # paneUpdating from paneHeader, or spin a pane that has cached rows).
  LATE_HOME="$SCRATCH/firstmate-late"
  mkdir -p "$LATE_HOME/bin"
  node -e '
    const fs = require("fs");
    const [src, dst] = process.argv.slice(1);
    const snap = JSON.parse(fs.readFileSync(src, "utf8"));
    const t = JSON.parse(JSON.stringify(snap.tasks.find((x) => x.id === "tmux-task")));
    t.id = "latecomer";
    t.project = "/fixture/firstmate/projects/late";
    t.current_state = { state: "failed", source: "pane", detail: "exit 1", observed_at: "2026-09-16T11:59:48Z", freshness: "fresh" };
    t.endpoint = { target: "0:fm-latecomer", exists: true, agent_alive: "not_checked", status: "unknown" };
    t.hints.last_event_text = "failed: exit 1";
    t.paths.status_log.path = "/fixture/firstmate/state/latecomer.status";
    t.backlog = { state: "in_flight", title: "Arrives with the second snapshot", repo: "acme/late" };
    snap.tasks.push(t);
    fs.writeFileSync(dst, JSON.stringify(snap));
  ' "$FAKE_HOME/snapshot.json" "$LATE_HOME/snapshot-late.json"
  # shellcheck disable=SC2016 # the fake expands $FM_BOARD_TEST_FETCH_LOG at run time, not here
  printf '#!/usr/bin/env bash\necho snapshot >> "$FM_BOARD_TEST_FETCH_LOG"\nif [ -e "%s/ran" ]; then cat "%s"; else touch "%s/ran"; cat "%s"; fi\n' "$LATE_HOME" "$LATE_HOME/snapshot-late.json" "$LATE_HOME" "$FAKE_HOME/snapshot.json" > "$LATE_HOME/bin/fm-fleet-snapshot.sh"
  cp "$FAKE_HOME/bin/fm-bearings-snapshot.sh" "$LATE_HOME/bin/fm-bearings-snapshot.sh"
  chmod +x "$LATE_HOME/bin/fm-fleet-snapshot.sh" "$LATE_HOME/bin/fm-bearings-snapshot.sh"
  run_pty_cycles() { # <name> <state dir> <actions...>: the interactive board with the PR fetch on against the late stand-in and the slowed fake gh, its view state and state cache in <state dir>
    local name=$1 dir=$2
    shift 2
    mkdir -p "$dir"
    rm -f "${FETCH_LOG:?}"
    FM_HOME="$LATE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FAKE_GH_SLEEP=4 PATH="$FAKE_BIN:$PATH" \
      FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" \
      python3 "$PTY" --term xterm-256color --rows 60 --timeout 20 --capture "$SCRATCH/pty-$name.bin" "$@" -- \
      "$BOARD" run --no-herdr --refresh 5 --opener-cmd "$FAKE_OPENER" --view-state "$dir/view-state.json" \
      > "$SCRATCH/pty-$name.out" 2>&1
  }
  rm -f "${LATE_HOME:?}/ran"
  run_pty_cycles cycles-cold "$SCRATCH/pty-cycles" "wait:ship-alpha" "absent:Bumptheretrybudget" "wait:latecomer" "absent:Bumptheretrybudget" "absent:(updating)" "wait:Bumptheretrybudget" "sleep:0.4" "send:q" exit
  pty_ok cycles-cold "pty two cycles: Underway lands first, the second snapshot repaints it while the fetch runs, and the PR rows follow"
  assert_count "$(cat "$FETCH_LOG")" "gh api user --jq .login" 1 "pty two cycles: the identity is resolved once"
  if [ "$(grep -c '^snapshot$' "$FETCH_LOG")" -ge 2 ]; then pass; else fail "pty two cycles: the second snapshot ran while the fetch was out ($(cat "$FETCH_LOG"))"; fi
  FM_BOARD_TEST_GH_CAPPED=1 run_pty_cycles cycles-warm "$SCRATCH/pty-cycles" "wait:cached" "wait:(updating)" "absent:loadingGitHub" "wait:searchcappedatthe50" "sleep:0.4" "send:q" exit
  pty_ok cycles-warm "pty two cycles warm: the cached PR rows stay under (updating) until the fetch lands with its note"
else
  echo "note: the pseudo-terminal section was skipped; it needs python3 on PATH and bin/firstmate-tui/node_modules (npm ci in bin/firstmate-tui)"
fi

printf '%s checks, %s failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
