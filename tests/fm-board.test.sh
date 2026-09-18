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
# `--view-state <temp file>`. The r key is checked against a stand-in firstmate
# home whose bin/fm-fleet-snapshot.sh and bin/fm-bearings-snapshot.sh only log
# that they ran and print canned JSON, with tests/fake-gh.sh first on PATH as
# `gh` (it logs its argv and answers canned PR lists in every state, with the
# fields the board asks for), so a
# live --render-once with --keys r shows exactly which fetches a refresh
# triggers without GitHub or a real home; a run under a PATH holding no gh
# proves the fallback to the firstmate script. Every live render must put the
# fake gh first on PATH, or the board's own fetch reaches the real GitHub CLI.
# The refresh schedule itself (one tick runs the snapshot and then the gh
# calls; a tick during a running refresh is skipped) is checked by running the
# app with --headless against a second stand-in whose snapshot sleeps, then
# stopping it with a signal; --headless draws nothing, reads no key and never
# loads neo-blessed.
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
#   populated.json  160x40, every pane has rows: a blocked worker, a keyed
#                   decision, a live captain hold, a secondmate hold and a
#                   secondmate-relayed decision, a green-unmerged PR, a done
#                   task with a merged PR, recorded PRs (one live candidate
#                   with a creation time), herdr statuses, a tmux task, a
#                   remote cached home, reports and landed rows, and a refresh
#                   block ({"next_in": 18}) standing in for the app's schedule;
#                   the refreshing, failed and herdr-state variants are derived
#                   from it at run time (variant)
#   pr-ages.json    160x40, Ready for review AGE sources: candidates with a
#                   creation time, without one, with a future and a malformed
#                   one, the camel-case alias, no-task candidates and a
#                   recorded PR missing from the live list
#   pr-status.json  160x40, Ready for review STATUS: one PR per status (DRAFT,
#                   IN REVIEW, APPROVED, CLOSED, MERGED), a merged PR 11h59m and
#                   one 12h01m before now, an open PR of a done task, a closed PR
#                   with no time stamp, a closed draft and an unlisted recorded PR
#   column-widths.json  160x40, the column-spacing screenshot's shape: three
#                   captain holds with a long organisation/repo name and HOME
#                   main, seven live PRs with long titles and BASE main, three
#                   workers on one repository, Findings and Landed empty
#   grouped.json    160x44, In flight grouping: two secondmate homes, one with
#                   four children (a keyed decision, a blocked child with a hold
#                   reason) plus live and dated captain holds, one quiet
#   empty.json      120x40, every pane empty, no herdr block
#   narrow.json     70x24, list mode with section headers, a cached local home
#   lost.json       160x40, a main worker and a secondmate child whose panes
#                   are absent from the herdr block (pane lost), a live one, a
#                   main scout report and a secondmate landed report
#   lost-disconnected.json  160x30, the same lost pane with herdr disconnected
#   cold-start.json 120x40, the first refresh in flight with nothing landed:
#                   no snapshot, no prs block, no herdr block, so every pane
#                   shows its loading spinner; the landed, failed, frame and
#                   narrow variants are derived from it at run time
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
# Fake on PATH: `gh` (the board's own PR fetch), logging its argv to FM_BOARD_TEST_FETCH_LOG and
# answering canned open-PR lists. Every live render below puts FAKE_BIN first on PATH so that no
# fetch reaches GitHub.
cp "$ROOT/tests/fake-gh.sh" "$FAKE_BIN/gh"
chmod +x "$FAKE_BIN/gh"
# A stand-in firstmate home for the live-refresh checks: both snapshot scripts
# append one line to FM_BOARD_TEST_FETCH_LOG and print canned JSON (the
# populated fixture's snapshot; an empty PR list). Nothing reaches GitHub.
FAKE_HOME="$SCRATCH/firstmate"
mkdir -p "$FAKE_HOME/bin"
node -e 'process.stdout.write(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).snapshot))' "$FIX/populated.json" > "$FAKE_HOME/snapshot.json"
# shellcheck disable=SC2016 # the fakes expand $FM_BOARD_TEST_FETCH_LOG at run time, not here
printf '#!/usr/bin/env bash\necho snapshot >> "$FM_BOARD_TEST_FETCH_LOG"\ncat "%s"\n' "$FAKE_HOME/snapshot.json" > "$FAKE_HOME/bin/fm-fleet-snapshot.sh"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "prs $*" >> "$FM_BOARD_TEST_FETCH_LOG"\necho "{\\"candidate_prs\\":[]}"\n' > "$FAKE_HOME/bin/fm-bearings-snapshot.sh"
chmod +x "$FAKE_HOME/bin/fm-fleet-snapshot.sh" "$FAKE_HOME/bin/fm-bearings-snapshot.sh"

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
# assert_fetch_log <expected lines, sorted> <label>: the gh calls of one refresh start together, so
# their log lines land in any order; the log is compared sorted.
assert_fetch_log() {
  if [ -f "$FETCH_LOG" ] && [ "$(sort "$FETCH_LOG")" = "$1" ]; then pass; else fail "$2: fetch log is '$(cat "$FETCH_LOG" 2>/dev/null || echo '<absent>')', expected (sorted) '$1'"; fi
}

# ------------------------------------------------------------- populated
frame=$(render populated.json) || fail "populated: render exited non-zero"

# Pane order and counts (falsify: reorder PANES in lib/layout.mjs, or delete a row source in the fixture).
assert_contains "$frame" "Needs you (4)" "populated needs-you count (main home only)"
assert_contains "$frame" "Ready for review (3)" "populated review count (two recorded PRs plus the live candidate; live PR data is the default)"
assert_contains "$frame" "In flight (7)" "populated in-flight count (five main rows, two home groups)"
assert_contains "$frame" "Findings (3)" "populated findings count"
assert_contains "$frame" "Landed (4)" "populated landed count"
assert_before "$frame" "Needs you \(4\)" "Ready for review \(3\)" "pane order 1"
assert_before "$frame" "Ready for review \(3\)" "In flight \(7\)" "pane order 2"
assert_before "$frame" "In flight \(7\)" "Findings \(3\)" "pane order 3"
assert_before "$frame" "Findings \(3\)" "Landed \(4\)" "pane order 4"

# Every pane title leads with its toggle key, btop-style (falsify: drop the badge segment from the
# top border in renderPanes, or change paneBadge).
assert_contains "$frame" "┌─ [1] Needs you (4) ─" "badge on Needs you"
assert_contains "$frame" "┌─ [2] Ready for review (3) ─" "badge on Ready for review"
assert_contains "$frame" "┌─ [3] In flight (7) ─" "badge on In flight"
assert_contains "$frame" "┌─ [4] Findings (3) ─" "badge on Findings"
assert_contains "$frame" "┌─ [5] Landed (4) ─" "badge on Landed"
assert_count "$frame" "┌─ [" 5 "exactly five badges, one per pane"
# With --tags the badge is its own grey segment between the border segments (falsify: give the badge the
# border style, or drop `badge` from STYLE_TAGS).
tags=$(render populated.json --tags) || fail "populated --tags: render exited non-zero"
assert_row "$tags" '\{blue-fg\}┌─ \{/blue-fg\}\{grey-fg\}\[2\]\{/grey-fg\}\{blue-fg\} Ready for review \(3\)' "--tags: the badge is grey and the title keeps the border color"
assert_count "$tags" "{grey-fg}[" 5 "--tags: five grey badges"

# Pane headers are `[n] Name (count)` and nothing else: the snapshot and checks ages, and the herdr
# state, are gone from them (falsify: put snapshotLabel or herdrLabel back into paneHeader in
# lib/model.mjs). The countdown and the herdr warning have their own section below.
assert_no_row "$frame" '^┌─ \[[1-5]\] [^─]*(ago|snapshot|herdr|checks)' "no pane header carries an age, a snapshot, herdr or checks word"
assert_count "$frame" " ago" 0 "nothing on the populated frame says N ago: no header age, and the title counts down instead"
assert_row "$frame" '^ firstmate-tui · /fixture/firstmate · 3 homes ' "the title line leads with firstmate-tui and counts the main home plus two secondmate homes (falsify: put fm-board back in titleLine)"

# Needs you rows (falsify: remove scout-beta's blocked_event, ship-alpha's open_decisions entry,
# decide-vendor's hold_bucket=live, or ship-gamma's pr.url).
assert_row "$frame" '^│ blocked +- +scout-beta +blocked: gh auth expired +acme/api +main +2h │$' "blocked worker row with repo, home and age"
assert_row "$frame" '^│ decide +db-choice +ship-alpha +Postgres or SQLite for the cache\? +acme/widgets +main +5m │$' "keyed decision row shows key, task, summary"
assert_row "$frame" '^│ hold +- +decide-vendor +Pick the vendor for the address API · Two quotes in the report +acme/api +main +3d │$' "live captain hold row with title and reason"
assert_row "$frame" '^│ merge\? +#7 +ship-gamma +PR ready: https://github.com/acme/api/pull/7 +acme/api +main +1m │$' "green-unmerged PR row"
assert_not_contains "$frame" "later-hold" "dated hold is not actionable and stays out of Needs you"
assert_before "$frame" '^│ blocked +- +scout-beta' '^│ decide +db-choice' "blocked sorts before decide"
assert_before "$frame" '^│ decide +db-choice' '^│ hold +- +decide-vendor' "decide sorts before hold"
assert_before "$frame" '^│ hold +- +decide-vendor' '^│ merge\?' "hold sorts before merge?"
# Secondmate decisions stay out of Needs you by default and flag their In flight group instead
# (falsify: drop the opts.allHomesNeeds guard in needsRows, or the flag in ledgerGroup).
assert_not_contains "$frame" "etl-cutover" "secondmate captain hold is not in Needs you by default (and hyperion is collapsed)"
assert_not_contains "$frame" "etl-window" "a decision the secondmate record relays into the main home is not in Needs you by default"
assert_row "$frame" '^│ decide +1 live +!▸ hyperion ' "the home holding those decisions is flagged with ! in In flight and reads decide"
frame_all=$(render populated.json --all-homes-needs) || fail "populated --all-homes-needs: render exited non-zero"
assert_contains "$frame_all" "Needs you (6)" "--all-homes-needs adds the secondmate ledger decision and the relayed one"
assert_row "$frame_all" '^│ hold +- +etl-cutover +Cut over the nightly ETL on Friday\? +acme/etl +hyperion +1d │$' "--all-homes-needs: secondmate captain hold row labelled with its home"
assert_row "$frame_all" '^│ decide +etl-window +hyperion +Which maintenance window for the ETL cutover\? +acme/etl +main +- │$' "--all-homes-needs: the relayed keyed decision on the secondmate record (the KEY column grows to fit the key; falsify: cap extra below 10 in columnSpec)"
assert_before "$frame_all" '^│ hold +- +etl-cutover' '^│ merge\?' "--all-homes-needs: hold sorts before merge?"

# Ready for review with --no-prs: the recorded PRs only, tagged PR and marked off (falsify: drop the
# --no-prs case in parseArgs, or the !prs.enabled branch in unlistedChecks).
frame_noprs=$(render populated.json --no-prs) || fail "populated --no-prs: render exited non-zero"
assert_contains "$frame_noprs" "Ready for review (2)" "--no-prs lists the two recorded PRs only"
assert_contains "$frame_noprs" "┌─ [2] Ready for review (2) ─" "--no-prs: the review header is bare; the rows say checks: off (falsify: put checksLabel back into paneHeader)"
assert_row "$frame_noprs" '^│ PR +- +ship-alpha +https://github.com/acme/widgets/pull/41 · checks: off[^│]* - +5m~ │$' "recorded PR 41 row: with the fetch off STATUS and BASE are unknown (-) and the AGE is the status-log age marked ~ (falsify: keep the PR age without the fetch)"
assert_row "$frame_noprs" '^│ PR +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: off \(--no-prs\) +- +1m~ │$' "recorded PR 7 row names the flag"
assert_not_contains "$frame_noprs" "passing" "no live check state with --no-prs"
assert_not_contains "$frame_noprs" "fetching" "--no-prs never says fetching"
# Finished work stays out (falsify: drop the taskBacklogState or the secondmate check in recordedPrs).
assert_no_row "$frame_noprs" '^│ PR +- +ship-old ' "a task whose backlog row is done does not list its PR without a fetched record"
assert_no_row "$frame_noprs" '^│ PR +- +hyperion ' "a PR mentioned on a secondmate record is not ready for review"

# In flight rows: state, herdr join, tmux (falsify: remove the herdr agents block, or change
# tmux-task's endpoint target).
assert_row "$frame" '^│ STATE +HERDR +ID +WHAT +REPO +HOME +AGE │$' "in-flight column headers"
assert_row "$frame" '^│ working +working +ship-alpha +harness busy \(claude-hook\) +acme/widgets +main +5m │$' "task with herdr working and status-log age"
assert_row "$frame" '^│ blocked +blocked +scout-beta +\(scout\) gh auth expired +acme/api +main +2h │$' "task with herdr blocked"
assert_row "$frame" '^│ awaiting merge +done +ship-gamma +PR https://github.com/acme/api/pull/7 checks green +acme/api +main +1m │$' "worker said done with an unmerged PR: STATE reads awaiting merge (falsify: drop awaitingMerge from mainTaskRow)"
assert_row "$frame" '^│ done +pane lost +ship-old +PR https://github.com/acme/widgets/pull/30 merged +acme/widgets +main +2d │$' "done task whose backlog row is done stays done; its closed pane reads pane lost"
assert_row "$frame" '^│ working +tmux +tmux-task +running the migration +acme/legacy +main +- │$' "tmux-backed task shows tmux in HERDR"
assert_row "$frame" '^│ STATE {11}HERDR ' "In flight's STATE column widens to fit awaiting merge, then the two-cell gutter (falsify: cap tag below 14 in columnSpec, or change GUTTER)"
assert_row "$frame" '^│ STATE {4}KEY ' "Needs you's STATE column is only as wide as its own widest word, blocked: fixed columns size per pane (falsify: size tag over the whole board again)"
assert_row "$frame" '^│ CHECKS +STATUS +ID +TITLE +BASE  AGE │$' "Ready for review: BASE hugs its widest value, main, and AGE its ages, so TITLE gets the rest (falsify: give base or age a fixed width)"
assert_before "$frame" '^│ working +working +ship-alpha' '^│ blocked +blocked +scout-beta' "in flight: working sorts before blocked"
assert_before "$frame" '^│ blocked +blocked +scout-beta' '^│ awaiting merge +done +ship-gamma' "in flight: blocked sorts before awaiting merge"
assert_before "$frame" '^│ awaiting merge +done +ship-gamma' '^│ done +pane lost +ship-old' "in flight: awaiting merge keeps the done slot, before plain done"

# In flight groups, collapsed: one row per secondmate home with worst state, live count, child ids,
# shared repo and newest child age; the mate's own agent row is folded into its group (falsify:
# remove child-one from hyperion's active_children, w2A:p2 from the herdr block, or the mateTaskFor
# fold in inflightRows).
assert_row "$frame" '^│ decide +1 live +!▸ hyperion +child-one, child-failed +acme/etl +hyperion +1h │$' "hyperion group: the relayed decision is the worst state, one live worker, flagged, newest age 1h"
assert_row "$frame" '^│ working +1 live +▸ remote-sm +remote-child +acme/mobile +remote-sm \(remote\) +- │$' "remote home group row, not flagged"
assert_no_row "$frame" '^│ working +idle +hyperion ' "the secondmate agent row is folded into its group when collapsed"
assert_not_contains "$frame" "child-one  " "children are hidden while collapsed (id appears only in the group text)"
assert_not_contains "$frame" "↳" "no child rows while collapsed"
assert_before "$frame" '^│ working +1 live +▸ remote-sm' '^│ blocked +blocked +scout-beta' "a working group sorts with the working rows, before blocked"
assert_before "$frame" '^│ blocked +blocked +scout-beta' '^│ decide +1 live +!▸ hyperion' "a group with a pending decision sorts with the blocked/decide rows"

# In flight groups, expanded with --expand all (falsify: drop the children list in ledgerGroup, or
# the etl-cutover decision from hyperion's decisions_open).
frame_x=$(render populated.json --expand all --rows 48) || fail "populated --expand all: render exited non-zero"
assert_contains "$frame_x" "In flight (13)" "expanding both groups adds the mate rows, children, home decisions and the relayed decision"
assert_row "$frame_x" '^│ decide +1 live +!▾ hyperion +child-one, child-failed +acme/etl +hyperion +1h │$' "expanded group row shows ▾"
assert_row "$frame_x" '^│ working +idle +↳ hyperion +\(secondmate\) supervising two children +acme/etl +main +- │$' "expanded: the secondmate agent row is the first child"
assert_row "$frame_x" '^│ decide +etl-window +↳ hyperion +Which maintenance window for the ETL cutover\? +acme/etl +main +- │$' "expanded: the relayed keyed decision lists under the group (falsify: drop relayed from ledgerGroup)"
assert_row "$frame_x" '^│ working +working +↳ child-one +writing the loader +acme/etl +hyperion +3d │$' "expanded: active child with age from its home state file"
assert_row "$frame_x" '^│ failed +pane lost +↳ child-failed +endpoint default:w2B:p2 \(run-step\) +- +hyperion +1h │$' "expanded: failed endpoint child whose pane is gone reads pane lost"
assert_row "$frame_x" '^│ hold +- +↳ etl-cutover +Cut over the nightly ETL on Friday\? +acme/etl +hyperion +1d │$' "expanded: the home's live captain hold lists under the group"
assert_row "$frame_x" '^│ working +remote +↳ remote-child +porting the login screen +acme/mobile +remote-sm \(remote\) +- │$' "expanded: remote home child row reads remote in HERDR, never pane lost (falsify: drop the remote branch in herdrColumn)"
assert_before "$frame_x" '!▾ hyperion' '↳ child-one' "children follow their group row"
assert_before "$frame_x" '↳ remote-child' '^│ blocked +blocked +scout-beta' "the next top-level row starts after the previous group's children"
assert_before "$frame_x" '↳ etl-cutover' '↳ hyperion +Which maintenance' "the ledger's home decisions come before the relayed ones"
assert_before "$frame_x" '↳ hyperion +Which maintenance' '^│ awaiting merge' "the group's rows end before the next top-level row"
assert_before "$frame_x" '↳ child-one' '↳ child-failed' "children sort working before failed"

# Findings (falsify: remove scout_reports[0], the mobile-fix report_path, or the report mtimes).
assert_row "$frame" '^│ scout +- +scout-beta +data/scout-beta/report.md +acme/api +main +10m │$' "scout report with age from the report mtime"
assert_row "$frame" '^│ report +reported +mobile-fix +data/mobile-fix/report.md +- +remote-sm \(remote\) +4d │$' "remote home report in findings"
assert_row "$frame" '^│ scout +reported +old-scout +data/old-scout/report.md +acme/legacy +main +10d │$' "older scout report with backlog verb"
assert_before "$frame" 'data/scout-beta/report.md' 'data/mobile-fix/report.md' "findings newest first (1)"
assert_before "$frame" 'data/mobile-fix/report.md' 'data/old-scout/report.md' "findings newest first (2)"

# Landed (falsify: change ship-old's state from done, or etl-index's completion date).
assert_row "$frame" '^│ merged +09-14 +ship-old +Rename the widget table · https://github.com/acme/widgets/pu' "landed merged row with PR (text truncated to the flex column at 160 cols)"
assert_row "$frame" '^│ merged +09-14 +ship-old .* acme/widgets +main +2d │$' "landed merged row keeps repo, home and age"
assert_row "$frame" '^│ merged +09-15 +etl-index +Add the ETL index · https://github.com/acme/etl/pull/12 +acme/etl +hyperion +1d │$' "secondmate landed row"
assert_row "$frame" '^│ reported +09-06 +old-scout +Scout: legacy import path +acme/legacy +main +10d │$' "reported row in landed"
assert_before "$frame" '^│ merged +09-15 +etl-index' '^│ merged +09-14 +ship-old' "landed newest first"

# Frame geometry (falsify: change the fixture cols/rows, or break padding in render.mjs).
assert_lines "$frame" 40 "populated frame is 40 lines"
assert_widths "$frame" 160 "populated frame lines are 160 columns"
assert_row "$frame" '^│ STATE +KEY +ID +WHAT +REPO +HOME +AGE │$' "wide layout keeps REPO and AGE"
assert_row "$frame" '^ j/k move  tab pane  enter open/focus/view  l/h expand  x hide  H hidden  1-5 panes  r refresh  \. settings  \? help  q quit +$' "footer keys (falsify: drop . settings from FOOTER_KEYS)"

# Keys through --render-once --keys (falsify: change keyAction in lib/controller.mjs).
frame_k=$(render populated.json --keys "tab,tab,j,j,j,j,l") || fail "keys l: render exited non-zero"
assert_row "$frame_k" '^│ decide +1 live +!▾ hyperion ' "l on the fifth In flight row expands the hyperion group"
assert_contains "$frame_k" "↳ child-one" "expanded by key: child rows appear"
assert_contains "$frame_k" "In flight (12)" "expanded by key: only hyperion's rows are added"
assert_not_contains "$frame_k" "▾ remote-sm" "expanded by key: the other group stays collapsed"
frame_k=$(render populated.json --keys "tab,tab,j,j,j,j,l,j,h") || fail "keys h: render exited non-zero"
assert_not_contains "$frame_k" "▾" "h from a child row collapses its group"
assert_contains "$frame_k" "In flight (7)" "collapsed again by key"
frame_k=$(render populated.json --keys "tab,tab,j,j,j,j,enter") || fail "keys enter group: render exited non-zero"
assert_row "$frame_k" '^│ decide +1 live +!▾ hyperion ' "enter on a group row expands it"
frame_k=$(render populated.json --keys "tab,tab,enter") || fail "keys enter worker: render exited non-zero"
assert_contains "$frame_k" "herdr is off (--no-herdr); cannot focus" "enter on an In flight worker still means herdr focus"
frame_k=$(render populated.json --keys "?") || fail "keys ?: render exited non-zero"
assert_contains "$frame_k" "enter        Ready for review, Landed or a Needs-you PR row: open the PR in the browser" "help overlay documents enter on Landed"
assert_not_contains "$frame_k" "open the PR of the selected row" "help overlay no longer documents o"
assert_contains "$frame_k" "l / right    expand the selected In flight group" "help overlay documents l/right"
# The help lists the pane keys the way the badges show them (falsify: change the 1 - 5 lines in HELP_LINES).
assert_contains "$frame_k" "each pane title carries its key: [1] Needs you" "help overlay ties the 1-5 keys to the title badges"
assert_contains "$frame_k" "[2] Ready for review  [3] In flight  [4] Findings  [5] Landed" "help overlay lists every badge"
assert_contains "$frame_k" "0            show every pane (with all five hidden the board lists these keys)" "help overlay documents 0 and the landing page"

# Opening a PR: enter in Ready for review, on a Needs-you PR row and on a Landed row with a PR,
# through the injected opener only (falsify: drop the url field from reviewRows, the merge? row or
# landedRows, drop 'landed' from OPEN_PANES, or drop the 'open' case in keyAction). The opener
# receives the exact URL as its only argument.
frame_o=$(render_open populated.json "tab,enter") || fail "open review: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "enter on the first Ready for review row (the newest IN REVIEW PR, joined to its task) opens its PR"
assert_contains "$frame_o" "opened https://github.com/acme/widgets/pull/41 (ship-alpha)" "footer notice names the task, not the candidate"
frame_o=$(render_open populated.json "tab,j,enter") || fail "open review second row: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/8" "enter on the second Ready for review row (the failing live candidate nobody recorded) opens its PR"
assert_contains "$frame_o" "opened https://github.com/acme/api/pull/8 (api#8)" "footer notice names the opened URL"
frame_o=$(render_open populated.json "j,j,j,enter") || fail "open needs enter: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/7" "enter on the Needs-you merge? row opens its PR"
frame_o=$(render_open populated.json "tab,tab,tab,tab,enter") || fail "open landed enter: render exited non-zero"
assert_opened "https://github.com/acme/etl/pull/12" "enter on the first Landed row opens its PR"
assert_contains "$frame_o" "opened https://github.com/acme/etl/pull/12 (etl-index)" "footer notice names the Landed URL"
frame_o=$(render_open populated.json "tab,tab,tab,tab,j,j,j,enter") || fail "open landed no url: render exited non-zero"
assert_not_opened "enter on a Landed row without a PR URL calls no opener"
assert_contains "$frame_o" "old-scout: no PR URL on this row" "enter on a Landed row without a URL says so"
frame_o=$(render_open populated.json "tab,tab,enter") || fail "enter inflight: render exited non-zero"
assert_not_opened "enter on an In flight worker calls no opener"
rm -f "$OPENER_LOG"
frame_o=$(render populated.json --keys "tab,enter") || fail "open without opener: render exited non-zero"
assert_contains "$frame_o" "would open https://github.com/acme/widgets/pull/41" "without --opener-cmd, --render-once only reports the open"
assert_not_opened "without --opener-cmd nothing is launched"

# Live PR data (falsify: remove candidate_prs from the fixture or the enabled branch in reviewRows).
# --prs is accepted and changes nothing, since it is the default (falsify: give --prs an effect in
# parseArgs, or flip the default).
frame_prs=$(render populated.json --prs) || fail "populated --prs: render exited non-zero"
if [ "$frame_prs" = "$frame" ]; then pass; else fail "--prs renders a different frame from the default: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_prs") | head -n 5)"; fi
assert_contains "$frame_prs" "Ready for review (3)" "live PR data adds the unrecorded candidate"
assert_row "$frame_prs" '^│ CHECKS +STATUS +ID +TITLE +BASE +AGE │$' "Ready for review draws its own six columns (falsify: drop the review branch from columns in lib/layout.mjs)"
assert_no_row "$frame_prs" '^│ CHECKS [^│]*(REPO|HOME|WHAT|REVIEW)' "the review pane draws no REPO, HOME, WHAT or REVIEW column"
assert_row "$frame_prs" '^│ failing +IN REVIEW +api#8 +Retry on 429 +main +- │$' "failing candidate nobody recorded: changes requested reads IN REVIEW, the title and base branch come from the fetch, no age without a creation time (falsify: map CHANGES_REQUESTED to its own word in prStatus)"
assert_row "$frame_prs" '^│ passing +IN REVIEW +ship-alpha +Add the widget cache +main +3h │$' "passing candidate joined to its task, AGE from its created_at (falsify: drop prCreatedAt from reviewRows)"
assert_row "$frame_prs" '^│ unlisted +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: not fetched +- +1m~ │$' "recorded PR missing from the live list: STATUS -, the URL and note in TITLE, BASE -, AGE from the status log marked ~"
assert_no_row "$frame_prs" '^│ (passing|failing|pending|none|unlisted|PR) +[^│]* ship-old ' "a candidate GitHub reports MERGED with no merge time cannot be placed in the 12-hour window and is dropped (falsify: return true from insideWindow when the stamp is missing)"
assert_no_row "$frame_prs" '^│ (passing|failing|pending|none|unlisted|PR) +[^│]*Rename the widget table' "the merged PR's title appears nowhere in Ready for review"
assert_before "$frame_prs" '^│ passing +IN REVIEW +ship-alpha' '^│ failing +IN REVIEW +api#8' "inside IN REVIEW the PR with a creation time sorts before the one without (newest first, no age last; falsify: sort by the CHECKS word)"

# Medium width: REPO and AGE drop below 100 columns (falsify: change WIDE_BREAKPOINT in lib/layout.mjs).
frame_med=$(render populated.json --cols 90 --rows 30) || fail "medium: render exited non-zero"
assert_contains "$frame_med" "Needs you (4)" "medium keeps five panes"
assert_row "$frame_med" '^│ STATE +HERDR +ID +WHAT +HOME +│$' "medium keeps the HERDR column and drops REPO and AGE"
assert_no_row "$frame_med" ' REPO +HOME' "medium drops REPO"
assert_no_row "$frame_med" ' HOME +AGE' "medium drops AGE"
assert_row "$frame_med" '^│ CHECKS +STATUS +ID +TITLE +AGE │$' "medium: Ready for review drops BASE and keeps AGE (falsify: drop AGE with BASE in the review branch of columns)"
assert_no_row "$frame_med" ' TITLE +BASE' "medium: no BASE column"
assert_widths "$frame_med" 90 "medium frame lines are 90 columns"
assert_lines "$frame_med" 30 "medium frame is 30 lines"
assert_row "$frame_med" '^ j/k  tab  enter  l/h  x hide  H  1-5 panes  r  \. settings  \? help  q quit +$' "medium width uses the short footer"

# Minimum height (falsify: change MIN_ROWS in lib/layout.mjs).
frame_tiny=$(render populated.json --rows 10) || fail "tiny: render exited non-zero"
assert_lines "$frame_tiny" 20 "frame never shrinks below 20 rows"
assert_row "$frame_tiny" '\+[0-9]+ more ──┘$' "tiny frame marks hidden rows on the pane border"

# ----------------------------------------------------------------- empty
frame_empty=$(render empty.json) || fail "empty: render exited non-zero"
assert_contains "$frame_empty" "Needs you (0)" "empty needs-you count"
assert_row "$frame_empty" '^│ no captain decisions, holds or blocked workers +│$' "empty needs-you message"
assert_row "$frame_empty" '^│ no recorded pull requests +│$' "empty review message"
assert_row "$frame_empty" '^│ no workers in flight +│$' "empty in-flight message"
assert_row "$frame_empty" '^│ no scout reports +│$' "empty findings message"
assert_row "$frame_empty" '^│ nothing landed yet +│$' "empty landed message"
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
assert_row "$frame_narrow" '^── \[1\] Needs you \(1\) ─+$' "narrow: section header with its badge and count only, padded with dashes"
assert_contains "$frame_narrow" "── [2] Ready for review (0)" "narrow: review section badge"
assert_contains "$frame_narrow" "── [3] In flight (2)" "narrow: in-flight section badge"
assert_contains "$frame_narrow" "── [4] Findings (0)" "narrow: findings section badge"
assert_contains "$frame_narrow" "── [5] Landed (1)" "narrow: landed section badge"
assert_count "$frame_narrow" "── [" 5 "narrow: five badges, one per section"
assert_not_contains "$frame_narrow" "┌" "narrow: no pane borders"
assert_row "$frame_narrow" '^ STATE +ID +WHAT +HOME +$' "narrow: single shared column header without REPO, AGE or HERDR"
assert_row "$frame_narrow" '^ hold +decide-vendor +Pick the vendor for the addr… +main +$' "narrow: hold row in list mode, text truncated to the flex column (which is what the fixed columns leave after sizing to their values)"
assert_row "$frame_narrow" '^ working +ship-alpha +harness busy \(claude-hook\) +main +$' "narrow: in-flight row"
assert_row "$frame_narrow" '^ working +▸ notes +notes-child +notes \(cached\) *$' "narrow: cached home group row in list mode"
frame_narrow_x=$(render narrow.json --expand all) || fail "narrow --expand all: render exited non-zero"
assert_row "$frame_narrow_x" '^ working +↳ notes-child +summarizing Monday +notes \(cached\) *$' "narrow expanded: cached home label on a ledger child"
assert_contains "$frame_narrow" "firstmate-tui · firstmate · 2 homes" "narrow: title uses the home basename"
assert_widths "$frame_narrow" 70 "narrow frame lines are 70 columns"
assert_lines "$frame_narrow" 24 "narrow frame is 24 lines"

# --------------------------------------------------------------- grouped
frame_g=$(render grouped.json) || fail "grouped: render exited non-zero"

# No prs block in the fixture is the state before the first fetch of a session lands: the recorded
# PR row says fetching, never "not fetched", and the header stays bare (falsify: drop the fetching
# branch in unlistedChecks).
assert_contains "$frame_g" "┌─ [2] Ready for review (1) ─" "grouped: the review header is bare before the first fetch"
assert_row "$frame_g" '^│ PR +- +ship-alpha +https://github.com/acme/widgets/pull/41 · checks: fetching +- +5m~ │$' "grouped: recorded PR row says checks fetching before the first fetch, STATUS unknown, AGE marked as the fallback"
assert_not_contains "$frame_g" "not fetched" "grouped: nothing reads not fetched before the first fetch"

# Needs you is main-home only (falsify: remove the opts.allHomesNeeds guard in needsRows).
assert_contains "$frame_g" "Needs you (0)" "grouped: no main-home needs"
assert_row "$frame_g" '^│ no captain decisions, holds or blocked workers +│$' "grouped: Needs you empty although hyperion has two live decisions"
assert_not_contains "$frame_g" "cutover-day" "grouped: the keyed child decision is not in Needs you"
assert_not_contains "$frame_g" "etl-vendor" "grouped: the secondmate captain hold is not in Needs you"

# Collapsed groups (falsify: remove etl-backfill from hyperion's endpoints (state), the decisions_open
# entries, or the notes ledger).
assert_contains "$frame_g" "In flight (3)" "grouped: one main worker plus two home groups"
assert_row "$frame_g" '^│ STATE {4}HERDR ' "STATE column stays 8 wide when no longer state word is on the board"
assert_row "$frame_g" '^│ working +working +ship-alpha +harness busy \(claude-hook\) +acme/widgets +main +5m │$' "grouped: main-home worker stays one row"
assert_row "$frame_g" '^│ blocked +4 live +!▸ hyperion +etl-loader, etl-schema, etl-cutover-runbook, etl-backfill +acme/etl +hyperion +5m │$' "hyperion group: blocked is the worst child state, four live, flagged, newest child 5m"
assert_row "$frame_g" '^│ working +2 live +▸ notes +brag-week-37, notes-monday +acme/brag +notes +40m │$' "notes group: working, two live, no flag"
assert_before "$frame_g" '^│ working +2 live +▸ notes' '^│ blocked +4 live +!▸ hyperion' "grouped: working group sorts before blocked group"
assert_not_contains "$frame_g" "↳" "grouped: collapsed by default"

# Expanded (falsify: drop the decision text lookup or the hold text lookup in ledgerChildRows, or
# the dated-hold filter in liveDecisions).
frame_gx=$(render grouped.json --expand all) || fail "grouped --expand all: render exited non-zero"
assert_contains "$frame_gx" "In flight (12)" "grouped expanded: 3 top rows + 6 under hyperion + 3 under notes"
assert_row "$frame_gx" '^│ working +idle +↳ hyperion +\(secondmate\) supervising four children +hyperion +main +- │$' "expanded: mate agent row first"
assert_row "$frame_gx" '^│ working +working +↳ etl-loader +writing the loader +acme/etl +hyperion +3h │$' "expanded: working child with doing"
assert_row "$frame_gx" '^│ working +working +↳ etl-schema +adding the schema migration +acme/etl +hyperion +20m │$' "expanded: second working child"
assert_row "$frame_gx" '^│ decide +idle +↳ etl-cutover-runbook +Cut over Friday or Monday\? +acme/etl +hyperion +5m │$' "expanded: child with a keyed decision shows the decision text and tag decide"
assert_row "$frame_gx" '^│ blocked +blocked +↳ etl-backfill +Backfill the ETL history · waiting on the prod snapshot +- +hyperion +1h │$' "expanded: blocked child shows its hold title and reason"
assert_row "$frame_gx" '^│ hold +- +↳ etl-vendor +Pick the ETL vendor · Two quotes in the report +acme/etl +hyperion +2d │$' "expanded: the home's live captain hold lists last"
assert_not_contains "$frame_gx" "etl-later" "expanded: a dated hold is not live and stays out"
assert_row "$frame_gx" '^│ working +working +↳ brag-week-37 +drafting week 37 +acme/brag +notes +2h │$' "expanded: notes child"
assert_before "$frame_gx" '↳ etl-loader' '↳ etl-cutover-runbook' "children: working before decide"
assert_before "$frame_gx" '↳ etl-cutover-runbook' '↳ etl-backfill' "children: decide before blocked (ledger order within a rank)"
assert_before "$frame_gx" '↳ etl-backfill' '↳ etl-vendor' "home decisions come after the workers"
frame_gh=$(render grouped.json --expand hyperion) || fail "grouped --expand hyperion: render exited non-zero"
assert_contains "$frame_gh" "!▾ hyperion" "--expand by id expands that home"
assert_contains "$frame_gh" "▸ notes" "--expand by id leaves the other home collapsed"
assert_not_contains "$frame_gh" "↳ brag-week-37" "--expand by id: no children of the collapsed home"

# --all-homes-needs restores the secondmate decisions (falsify: drop the flag in lib/args.mjs).
frame_ga=$(render grouped.json --all-homes-needs) || fail "grouped --all-homes-needs: render exited non-zero"
assert_contains "$frame_ga" "Needs you (2)" "--all-homes-needs: both live secondmate decisions"
assert_row "$frame_ga" '^│ decide +cutover-day +etl-cutover-runbook +Cut over Friday or Monday\? +- +hyperion +- │$' "--all-homes-needs: keyed child decision"
assert_row "$frame_ga" '^│ hold +- +etl-vendor +Pick the ETL vendor · Two quotes in the report +acme/etl +hyperion +2d │$' "--all-homes-needs: captain hold with repo from queued"
assert_not_contains "$frame_ga" "etl-later" "--all-homes-needs: dated hold still out"

# Geometry (falsify: change the fixture cols/rows).
assert_widths "$frame_g" 160 "grouped frame lines are 160 columns"
assert_lines "$frame_g" 44 "grouped frame is 44 lines"
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

# Enter in Findings without --viewer-cmd only reports the viewer the chain resolved to, naming the fake glow
# shadowing PATH; nothing runs (falsify: run the viewer without --viewer-cmd in driveOnce, or drop whichOnPath).
rm -f "$VIEWER_LOG"
frame_v=$(FM_BOARD_TEST_VIEWER_LOG="$VIEWER_LOG" PATH="$FAKE_BIN:$PATH" render lost.json --keys "tab,tab,enter") || fail "viewer report-only: render exited non-zero"
assert_contains "$frame_v" "would view /fixture/firstmate/data/scout-beta/report.md with $FAKE_BIN/glow -p (glow)" "fake glow on PATH is the resolved viewer, reported with its path and -p"
assert_not_viewed "without --viewer-cmd the resolved viewer is never spawned"
# With --viewer-cmd the report path is the only appended argument (falsify: drop reportPath from findingsRows).
frame_v=$(render_view lost.json "tab,tab,enter") || fail "viewer main: render exited non-zero"
assert_viewed "/fixture/firstmate/data/scout-beta/report.md" "enter on a main-home scout report hands its absolute path to the viewer"
assert_contains "$frame_v" "viewed /fixture/firstmate/data/scout-beta/report.md (viewer-cmd)" "footer names the viewed report"
frame_v=$(render_view lost.json "tab,tab,j,enter") || fail "viewer secondmate: render exited non-zero"
assert_viewed "/fixture/homes/hyperion/data/etl-report/report.md" "a secondmate report resolves against its own home, not FM_HOME (falsify: use fmHome for ledger reports)"
frame_v=$(render_view lost.json "tab,tab,enter" "$FAKE_VIEWER -p") || fail "viewer flags: render exited non-zero"
assert_viewed "-p
/fixture/firstmate/data/scout-beta/report.md" "viewer flags stay separate argv elements, the path last (falsify: join argv into one string)"
frame_v=$(render_view populated.json "tab,tab,tab,j,enter") || fail "viewer remote: render exited non-zero"
assert_not_viewed "a remote home's report is never opened"
assert_contains "$frame_v" "mobile-fix: report lives on another host (remote-sm (remote)); not reachable from here" "remote report: red notice instead (falsify: drop reportRemote)"
frame_v=$(render_view lost.json "enter") || fail "viewer wrong pane: render exited non-zero"
assert_not_viewed "enter outside Findings never runs the viewer"
frame_v=$(render lost.json --keys "?") || fail "help: render exited non-zero"
assert_contains "$frame_v" "Findings row: open the report in the viewer (glow, \$EDITOR, vim, less)" "help overlay documents the viewer"
assert_contains "$frame_v" "x            hide the selected row from view" "help overlay documents x"
assert_contains "$frame_v" "1 - 5        show or hide a pane" "help overlay documents 1-5"
assert_contains "$frame_v" "r            refresh now: the fleet snapshot and the PR checks (unless --no-prs)" "help overlay documents r"
# The board never moves the firstmate pane; the captain splits panes himself (falsify: add an f line to HELP_LINES).
assert_not_contains "$frame_v" "firstmate pane" "help overlay does not mention the firstmate pane"
assert_not_contains "$frame_v" "  f  " "help overlay has no f key"

# ------------------------------------------------------------- lost panes
frame_l=$(render lost.json --expand all) || fail "lost: render exited non-zero"
tags_l=$(render lost.json --expand all --tags) || fail "lost --tags: render exited non-zero"
# A recorded pane absent from the herdr overlay reads "pane lost" (falsify: drop the lost branch in herdrColumn).
assert_row "$frame_l" '^│ working +pane lost +ship-lost +adding the retry loop +acme/api +main +10m │$' "main worker whose pane is gone: HERDR reads pane lost"
assert_row "$frame_l" '^│ working +pane lost +↳ child-lost +indexing the warehouse +acme/etl +hyperion +1h │$' "secondmate child whose pane is gone: HERDR reads pane lost"
assert_row "$frame_l" '^│ working +working +ship-alpha ' "a worker whose pane is present keeps its agent status"
assert_count "$tags_l" "{red-fg}pane lost{/red-fg}" 2 "--tags: both lost HERDR cells carry the red tag (falsify: drop the lost style in rowSegments)"
# Needs you has no HERDR column, so the whole lost row is red; the live decision row is not (falsify: drop
# the `row.lost && !herdrCell` term from bad in rowSegments).
assert_row "$tags_l" '\{red-fg\}decide.*\{red-fg\}ship-lost' "Needs you row of the lost worker is red"
assert_no_row "$tags_l" '\{red-fg\}decide.*ship-alpha' "Needs you row of the live worker is not red"
# Enter on a lost row: a footer notice, never a focus (falsify: drop the lost check in focusProblem).
frame_k=$(render lost.json --keys "tab,j,enter") || fail "lost enter inflight: render exited non-zero"
assert_contains "$frame_k" "ship-lost: pane w1L:p1 is gone from herdr (pane lost); nothing to focus" "enter on the lost In flight row says pane lost"
frame_k=$(render lost.json --keys "j,enter") || fail "lost enter needs: render exited non-zero"
assert_contains "$frame_k" "ship-lost: pane w1L:p1 is gone from herdr (pane lost); nothing to focus" "enter on the lost Needs you row says pane lost"
# Disconnected herdr: absence is unproved, so the cell reads unknown in grey and nothing is red (falsify: drop
# the unknown branch in herdrColumn, or the grey style in rowSegments).
frame_d=$(render lost-disconnected.json) || fail "disconnected: render exited non-zero"
tags_d=$(render lost-disconnected.json --tags) || fail "disconnected --tags: render exited non-zero"
assert_row "$frame_d" '^ firstmate-tui · /fixture/firstmate · 1 home +herdr disconnected \(ECONNREFUSED\) $' "disconnected fixture: the title line warns with the socket error as the reason"
assert_row "$frame_d" '^│ working +unknown +ship-lost +adding the retry loop ' "disconnected: the missing pane reads unknown, not pane lost"
assert_row "$tags_d" '\{grey-fg\}unknown *\{/grey-fg\}' "disconnected: the unknown cell is grey"
assert_count "$tags_d" "{red-fg}" 1 "disconnected: the title warning is the only red text; no row is red"
assert_contains "$tags_d" "{red-fg}herdr disconnected (ECONNREFUSED){/red-fg}" "disconnected: the warning carries the red tag the lost cell uses (falsify: give the warning the title style only)"
assert_widths "$frame_l" 160 "lost frame lines are 160 columns"

# -------------------------------------------------------------------- hide
vs="$SCRATCH/view-state.json"
rm -f "$vs"
# x hides the selected row and persists its key (falsify: drop the filter in applyHidden, or the date from the
# Landed hideKey).
frame_h=$(render populated.json --view-state "$vs" --keys "tab,tab,tab,tab,x") || fail "hide: render exited non-zero"
assert_contains "$frame_h" "Landed (3, 1 hidden)" "x on the first Landed row: header counts it hidden"
assert_no_row "$frame_h" '^│ merged +09-15 +etl-index ' "the hidden row is out of view"
assert_contains "$frame_h" "hidden etl-index · H shows hidden rows, X unhides this pane" "x leaves a notice"
assert_file_contains "$vs" '"landed:hyperion:etl-index:2026-09-15"' "the key is pane:home:id:completion date, so a re-landed item reappears"
assert_file_contains "$vs" '"schema": "fm-board-view-state.v1"' "the file names its schema"
# Restart: the file is loaded again (falsify: drop loadViewState from driveOnce).
frame_h=$(render populated.json --view-state "$vs") || fail "hide reload: render exited non-zero"
assert_contains "$frame_h" "Landed (3, 1 hidden)" "after a restart the row stays hidden"
assert_no_row "$frame_h" '^│ merged +09-15 +etl-index ' "after a restart the row is still out of view"
# H shows hidden rows greyed with a marker (falsify: drop showHidden from applyHidden, or the grey style).
frame_h=$(render populated.json --view-state "$vs" --keys "H") || fail "hide H: render exited non-zero"
tags_h=$(render populated.json --view-state "$vs" --keys "H" --tags) || fail "hide H --tags: render exited non-zero"
assert_contains "$frame_h" "Landed (4, 1 hidden shown)" "H: header says the hidden row is shown"
assert_row "$frame_h" '^│ merged +09-15 +etl-index +\(hidden\) Add the ETL index ' "H: the hidden row is listed with a (hidden) marker"
assert_row "$tags_h" '\{grey-fg\}\(hidden\) Add the ETL index' "H: the hidden row is grey"
assert_contains "$frame_h" "showing hidden rows (greyed); H hides them again" "H leaves a notice"
# x on a shown hidden row unhides it (falsify: drop the unhide action in keyAction).
frame_h=$(render populated.json --view-state "$vs" --keys "H,tab,tab,tab,tab,x") || fail "hide toggle: render exited non-zero"
assert_contains "$frame_h" "unhidden etl-index" "x on the shown hidden row unhides it"
assert_contains "$frame_h" "Landed (4)" "after unhiding the header shows the plain count"
assert_file_not_contains "$vs" "etl-index" "unhiding removes the key from the file"
# X clears the pane (falsify: drop the prefix filter in unhide-pane).
frame_h=$(render populated.json --view-state "$vs" --keys "tab,tab,tab,tab,x,j,x,X") || fail "hide X: render exited non-zero"
assert_contains "$frame_h" "unhidden 2 rows in Landed" "X unhides every hidden row of the pane"
assert_contains "$frame_h" "Landed (4)" "X: all four Landed rows are back"
assert_file_contains "$vs" '"hidden": []' "X empties the hidden list in the file"
# A hidden group takes its children with it (falsify: drop the parent lookup in applyHidden).
frame_h=$(render populated.json --rows 48 --keys "tab,tab,j,j,j,j,l,x") || fail "hide group: render exited non-zero"
assert_contains "$frame_h" "In flight (6, 6 hidden)" "hiding the expanded hyperion group hides its five children too"
assert_not_contains "$frame_h" "↳ child-one" "hidden group: children are out of view"
# A fixture render without --view-state loads and saves nothing (falsify: drop the fixture guard in viewStateFor).
fake_home_dir="$SCRATCH/home"
mkdir -p "$fake_home_dir"
frame_h=$(HOME="$fake_home_dir" XDG_CONFIG_HOME='' render populated.json --keys "tab,tab,tab,tab,x") || fail "hide no file: render exited non-zero"
assert_contains "$frame_h" "Landed (3, 1 hidden)" "without --view-state hiding still works for the frame"
if [ -e "$fake_home_dir/.config/fm-board/view-state.json" ]; then fail "a fixture render without --view-state wrote the default view-state file"; else pass; fi
# A view-state path inside FM_HOME is refused (falsify: drop insideHome from resolveViewStatePath).
frame_h=$(XDG_CONFIG_HOME="$SCRATCH/xdg" render populated.json --view-state /fixture/firstmate/state/view-state.json) || fail "hide FM_HOME guard: render exited non-zero"
assert_contains "$frame_h" "refusing --view-state inside FM_HOME (/fixture/firstmate/state/view-state.json)" "a view-state path inside FM_HOME is refused with a notice"
frame_h=$(XDG_CONFIG_HOME="$SCRATCH/xdg" render populated.json --view-state /fixture/firstmate/state/view-state.json --keys "tab,tab,tab,tab,x") || fail "hide FM_HOME fallback: render exited non-zero"
if [ -f "$SCRATCH/xdg/fm-board/view-state.json" ]; then pass; else fail "the refused path falls back to \$XDG_CONFIG_HOME/fm-board/view-state.json"; fi
if [ -e /fixture/firstmate/state/view-state.json ]; then fail "the refused path was written"; else pass; fi

# ------------------------------------------------------------ pane toggles
rm -f "$vs"
# 5 hides Landed; its rows go to the other panes; the title lists it (falsify: drop the visible list from
# paneHeights, or the hidden skip in renderPanes).
frame_p=$(render populated.json --view-state "$vs" --keys "5") || fail "panes 5: render exited non-zero"
assert_contains "$frame_p" "· panes hidden: 5" "title lists the hidden pane number"
assert_not_contains "$frame_p" "Landed (" "the hidden pane draws nothing"
assert_count "$frame_p" "┌─" 4 "four pane frames remain"
assert_lines "$frame_p" 40 "one pane hidden: the frame is still 40 lines"
assert_widths "$frame_p" 160 "one pane hidden: lines are 160 columns"
assert_contains "$frame_p" "pane hidden: Landed · 5 or 0 shows it again" "5 leaves a notice"
assert_file_contains "$vs" '"landed"' "the hidden pane is persisted"
frame_p=$(render populated.json --view-state "$vs") || fail "panes reload: render exited non-zero"
assert_count "$frame_p" "┌─" 4 "after a restart the pane stays hidden (falsify: drop hidden_panes from loadViewState)"
frame_p=$(render populated.json --view-state "$vs" --keys "1,2,4") || fail "panes 1,2,4: render exited non-zero"
assert_contains "$frame_p" "· panes hidden: 1,2,4,5" "four panes hidden: the title lists all four"
assert_count "$frame_p" "┌─" 1 "four panes hidden: one frame"
assert_contains "$frame_p" "In flight (7)" "four panes hidden: In flight remains"
assert_lines "$frame_p" 40 "four panes hidden: still 40 lines"
assert_widths "$frame_p" 160 "four panes hidden: lines are 160 columns"
assert_row "$frame_p" '^│ decide +1 live +!▸ hyperion ' "four panes hidden: In flight rows render in the freed space"
# The last pane goes too: with every pane hidden the grid gives way to the landing page, a centered key
# list between the title line and the footer (falsify: bring back a shown <= 1 guard in toggle-pane, or
# drop the landing branch from renderFrame).
frame_p=$(render populated.json --view-state "$vs" --keys "3") || fail "panes last: render exited non-zero"
assert_count "$frame_p" "┌─" 0 "all panes hidden: no pane frame is drawn"
assert_not_contains "$frame_p" "Needs you (" "all panes hidden: no pane header"
assert_not_contains "$frame_p" "In flight (" "all panes hidden: no pane header for the last one hidden"
assert_row "$frame_p" '^ +all panes hidden +$' "landing page heading"
assert_row "$frame_p" '^ firstmate-tui · /fixture/firstmate · 3 homes · all panes hidden ' "landing page: the title line leads with firstmate-tui (falsify: put fm-board back in titleLine)"
assert_row "$frame_p" '^ +1  Needs you +$' "landing page: 1 brings Needs you back"
assert_row "$frame_p" '^ +2  Ready for review +$' "landing page: 2 brings Ready for review back"
assert_row "$frame_p" '^ +3  In flight +$' "landing page: 3 brings In flight back"
assert_row "$frame_p" '^ +4  Findings +$' "landing page: 4 brings Findings back"
assert_row "$frame_p" '^ +5  Landed +$' "landing page: 5 brings Landed back"
assert_row "$frame_p" '^ +0  show all +$' "landing page: 0 shows all"
assert_row "$frame_p" '^ +r  refresh +$' "landing page: r"
assert_row "$frame_p" '^ +\?  help +$' "landing page: ?"
assert_row "$frame_p" '^ +q  quit +$' "landing page: q"
assert_before "$frame_p" '^ +all panes hidden +$' '^ +1  Needs you +$' "landing page: heading first"
assert_before "$frame_p" '^ +5  Landed +$' '^ +0  show all +$' "landing page: 0 after the five panes"
assert_before "$frame_p" '^ +0  show all +$' '^ +r  refresh +$' "landing page: r after 0"
assert_contains "$frame_p" "3 homes · all panes hidden " "all panes hidden: the title says so instead of listing five numbers (falsify: drop allHidden from titleLine)"
assert_not_contains "$frame_p" "panes hidden: 1,2,3,4,5" "all panes hidden: the title does not list the five numbers"
assert_contains "$frame_p" "pane hidden: In flight · every pane hidden; 1-5 or 0 shows them" "hiding the last pane leaves a notice naming the way back"
assert_row "$frame_p" '^ j/k .* q quit +pane hidden' "the footer stays on the landing page"
assert_lines "$frame_p" 40 "landing page: the frame is still 40 lines"
assert_widths "$frame_p" 160 "landing page: lines are 160 columns"
for id in needs review inflight findings landed; do
  assert_file_contains "$vs" "\"$id\"" "all five pane ids are persisted ($id)"
done
# A restart with an all-hidden file lands on the page again (falsify: drop hidden_panes from loadViewState,
# or make the landing depend on view.notice).
frame_p=$(render populated.json --view-state "$vs") || fail "panes landing reload: render exited non-zero"
assert_row "$frame_p" '^ +all panes hidden +$' "after a restart the landing page is shown"
assert_count "$frame_p" "┌─" 0 "after a restart no pane is drawn"
assert_not_contains "$frame_p" "pane hidden:" "after a restart there is no toggle notice"
# Keys on the landing page: 1-5 and 0 act as always; a key that would move or act on a row nobody can see
# only repeats the reminder and runs nothing; an unbound key such as o stays silent (falsify: drop
# LANDING_KEYS or ROW_KEYS from keyAction, or the !pane.hidden term on the row lookup).
frame_o=$(render_open populated.json "1,2,3,4,5,enter") || fail "landing enter: render exited non-zero"
assert_not_opened "enter on the landing page opens nothing"
assert_contains "$frame_o" "all panes hidden · 1-5 shows a pane, 0 shows all" "enter on the landing page only reminds"
frame_o=$(render_open populated.json "1,2,3,4,5,j,tab,enter") || fail "landing move+enter: render exited non-zero"
assert_not_opened "moving on the landing page then enter opens nothing"
frame_p=$(render populated.json --keys "1,2,3,4,5,o") || fail "landing o: render exited non-zero"
assert_not_contains "$frame_p" "all panes hidden · 1-5 shows a pane" "o on the landing page is the same silent no-op as elsewhere"
assert_row "$frame_p" '^ +all panes hidden +$' "o on the landing page leaves the page in place"
frame_p=$(render populated.json --view-state "$vs" --keys "x") || fail "landing x: render exited non-zero"
assert_contains "$frame_p" "all panes hidden · 1-5 shows a pane, 0 shows all" "x on the landing page only reminds"
assert_file_contains "$vs" '"hidden": []' "x on the landing page hides no row"
frame_p=$(render populated.json --view-state "$vs" --keys "?") || fail "landing ?: render exited non-zero"
assert_contains "$frame_p" "firstmate-tui keys" "? opens the help over the landing page"
frame_p=$(render populated.json --view-state "$vs" --keys "3") || fail "landing 3: render exited non-zero"
assert_count "$frame_p" "┌─" 1 "3 on the landing page brings In flight back alone"
assert_contains "$frame_p" "┌─ [3] In flight (7)" "the returned pane carries its badge"
assert_contains "$frame_p" "pane shown: In flight" "3 on the landing page leaves the usual notice"
assert_contains "$frame_p" "· panes hidden: 1,2,4,5" "one pane back: the title lists the four still hidden"
assert_file_contains "$vs" '"hidden_panes": [' "the returned pane is persisted"
frame_p=$(render populated.json --view-state "$vs" --keys "0") || fail "panes 0: render exited non-zero"
assert_count "$frame_p" "┌─" 5 "0 shows every pane again"
assert_contains "$frame_p" "all panes shown" "0 leaves a notice"
assert_not_contains "$frame_p" "panes hidden" "0 clears the title note"
assert_file_contains "$vs" '"hidden_panes": []' "0 empties the persisted list"
# The same in one sitting and without a file: 1,2,3,4,5 lands, 0 restores (falsify: make the landing
# depend on the view-state file).
frame_p=$(render populated.json --keys "1,2,3,4,5") || fail "panes 1-5: render exited non-zero"
assert_row "$frame_p" '^ +all panes hidden +$' "1,2,3,4,5 in one sitting lands on the page"
assert_count "$frame_p" "┌─" 0 "1,2,3,4,5: nothing else is drawn"
frame_p=$(render populated.json --keys "1,2,3,4,5,0") || fail "panes 1-5,0: render exited non-zero"
assert_count "$frame_p" "┌─" 5 "0 after 1,2,3,4,5 restores all five"
assert_not_contains "$frame_p" "all panes hidden" "0 after 1,2,3,4,5 leaves the landing page"
# A hand-written all-hidden file is enough to land (falsify: require the ids in a particular order, or
# only honor a file the board wrote itself).
vs_all="$SCRATCH/view-state-all.json"
printf '{"schema":"fm-board-view-state.v1","hidden":[],"hidden_panes":["landed","findings","inflight","review","needs"]}\n' > "$vs_all"
frame_p=$(render populated.json --view-state "$vs_all") || fail "panes hand-written all-hidden: render exited non-zero"
assert_row "$frame_p" '^ +all panes hidden +$' "a hand-written all-hidden view-state file renders the landing page"
assert_count "$frame_p" "┌─" 0 "hand-written all-hidden file: no pane drawn"
# The landing page replaces the narrow list too (falsify: pick the layout mode before the all-hidden check).
frame_p=$(render narrow.json --keys "1,2,3,4,5") || fail "panes narrow landing: render exited non-zero"
assert_row "$frame_p" '^ +all panes hidden +$' "narrow: the landing page replaces the list"
assert_not_contains "$frame_p" "── [" "narrow: no section header on the landing page"
assert_not_contains "$frame_p" " STATE " "narrow: no column header on the landing page"
assert_widths "$frame_p" 70 "narrow landing page: lines are 70 columns"
assert_lines "$frame_p" 24 "narrow landing page: 24 lines"
# Hiding the selected pane moves the selection to the next shown pane (falsify: drop the shown() clamp in
# moveSelection): 1 hides Needs you, then enter opens the first Ready for review PR.
frame_o=$(render_open populated.json "1,enter") || fail "panes selection: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "after hiding the selected pane, enter acts on the next shown pane"
frame_p=$(render narrow.json --keys "5") || fail "panes narrow: render exited non-zero"
assert_not_contains "$frame_p" "── Landed" "list mode: the hidden pane's section is gone (falsify: drop the hidden skip in flattenRows)"
assert_contains "$frame_p" "panes hidden: 5" "list mode: the title lists the hidden pane"
assert_widths "$frame_p" 70 "list mode with a hidden pane: lines are 70 columns"

# ---------------------------------------------------------- o and f are no-ops
# o used to open the selected row's PR in any pane; enter does that now, so
# the key does nothing, not even a notice (falsify: give 'o' a case in keyAction).
frame_o=$(render_open populated.json "tab,o") || fail "keys o: render exited non-zero"
assert_not_opened "o on a Ready for review row calls no opener"
frame_o=$(render populated.json --keys "o") || fail "keys o plain: render exited non-zero"
if [ "$frame_o" = "$frame" ]; then pass; else fail "o changed the frame: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_o") | head -n 5)"; fi
assert_not_contains "$frame_o" "no PR URL" "o leaves no PR notice"
assert_no_row "$frame" '^ j/k move .* o open' "footer offers no o key"
# f used to move the firstmate pane beside the board; the captain splits panes
# himself now, so the key does nothing (falsify: give 'f' a case in keyAction).
frame_f=$(render populated.json --keys "f") || fail "keys f: render exited non-zero"
if [ "$frame_f" = "$frame" ]; then pass; else fail "f changed the frame: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_f") | head -n 5)"; fi
assert_not_contains "$frame_f" "firstmate pane" "f leaves no firstmate-pane notice"
assert_not_contains "$frame" " f " "footer offers no f key"
if grep -Fq -- "-firstmate" "$ROOT/bin/firstmate-tui/herdr-plugin.toml"; then fail "herdr-plugin.toml still declares a firstmate pane action"; else pass; fi

# ------------------------------------------------------------------ PR ages
# Ready for review's AGE is the time since the PR was opened when the live fetch carries created_at,
# else the task's status-log age with a trailing ~ (falsify: drop prCreatedAt or the ageFallback
# marker in lib/model.mjs; the rows below then read 2d for 2d~, or 3h~ for 3h). These candidates
# carry no title or base branch, as the script fallback's do not: TITLE falls back to the recorded
# task's backlog title (the URL for a PR no task recorded) and BASE reads - (falsify: drop the
# rec.title fallback from reviewRows).
frame_age=$(render pr-ages.json) || fail "pr-ages: render exited non-zero"
assert_contains "$frame_age" "Ready for review (8)" "pr-ages: seven live candidates plus one unlisted recorded PR"
assert_row "$frame_age" '^│ passing +IN REVIEW +pr-fresh +Paginate the address API +- +3h │$' "created_at 3h before now: AGE 3h with no marker, the backlog title in TITLE (falsify: read the status-log age first)"
assert_row "$frame_age" '^│ passing +IN REVIEW +pr-nodate +Cache the geocoder +- +2d~ │$' "no creation time: the status-log age with ~ (falsify: drop ageFallback from reviewAge)"
assert_row "$frame_age" '^│ passing +IN REVIEW +pr-future +Rate-limit headers +- +4h~ │$' "a future created_at counts as absent (falsify: drop the created > now check in prCreatedAt)"
assert_row "$frame_age" '^│ passing +IN REVIEW +pr-bad +Retry budget +- +30m~ │$' "a malformed created_at counts as absent (falsify: return 0 instead of null from parseTime)"
assert_row "$frame_age" '^│ passing +APPROVED +pr-camel +Bulk lookup endpoint +- +5d │$' "the camel-case createdAt is read too, and an APPROVED review decision reads APPROVED (falsify: drop the alias in prCreatedAt)"
assert_row "$frame_age" '^│ passing +IN REVIEW +api#107 +https://github.com/acme/api/pull/107 +- +2h │$' "a candidate with no task and no title shows its URL and its PR age"
assert_row "$frame_age" '^│ passing +IN REVIEW +api#108 +https://github.com/acme/api/pull/108 +- +- │$' "no creation time and no task: - with no marker (falsify: append ~ to a null age)"
assert_row "$frame_age" '^│ unlisted +- +pr-unlisted +https://github.com/acme/api/pull/106 · checks: not fetched +- +45m~ │$' "a recorded PR missing from the live list falls back with ~"
assert_count "$frame_age" "~ │" 4 "exactly the four fallback rows carry the marker (falsify: mark every review row)"
# Only the display text carries the marker: the In flight row of the same task shows the plain
# file-time age (falsify: put the marker into ageSeconds or fmtAge).
assert_row "$frame_age" '^│ working +- +pr-nodate +fixing the flaky test +acme/api +main +2d │$' "In flight shows the same status-log age unmarked"
# --no-prs: every recorded row falls back (falsify: skip the marker when prs.enabled is false).
frame_age_np=$(render pr-ages.json --no-prs) || fail "pr-ages --no-prs: render exited non-zero"
assert_contains "$frame_age_np" "Ready for review (6)" "--no-prs: the six recorded PRs"
assert_row "$frame_age_np" '^│ PR +- +pr-fresh +https://github.com/acme/api/pull/101 · checks: off \(--no-prs\) +- +10m~ │$' "--no-prs: the PR that had a live creation time shows its status-log age with ~ instead"
assert_count "$frame_age_np" "~ │" 6 "--no-prs: every Ready for review row carries the marker"
assert_no_row "$frame_age_np" '^│ PR .* (3h|5d|2h) │$' "--no-prs: no PR age survives without the fetch"
# The marker fits the AGE column at every breakpoint: at the wide breakpoint (100 columns) the column
# still holds 30m~ whole with BASE beside it; below it Ready for review drops BASE and keeps AGE, so
# the marker still shows there while the other panes lose their AGE; in the narrow list AGE is gone
# everywhere (falsify: narrow the AGE column in lib/layout.mjs, render the age into another column,
# or drop AGE with BASE in the review branch of columns).
frame_age_100=$(render pr-ages.json --cols 100 --rows 30) || fail "pr-ages 100: render exited non-zero"
assert_row "$frame_age_100" '^│ passing +IN REVIEW +pr-bad +[^│]* - +30m~ │$' "100 columns: the widest fallback age fits the AGE column beside BASE"
assert_row "$frame_age_100" '^│ passing +IN REVIEW +pr-fresh +[^│]* - +3h │$' "100 columns: the PR age fits"
assert_widths "$frame_age_100" 100 "100-column frame lines are 100 columns"
frame_age_90=$(render pr-ages.json --cols 90 --rows 30) || fail "pr-ages 90: render exited non-zero"
assert_row "$frame_age_90" '^│ passing +IN REVIEW +pr-bad +[^│]* 30m~ │$' "medium width: Ready for review keeps AGE, so the marker still shows"
assert_no_row "$frame_age_90" ' BASE ' "medium width: BASE is dropped"
assert_no_row "$frame_age_90" '^│ working [^│]*~ │$' "medium width: the other panes have no AGE column, so no marker outside Ready for review"
assert_widths "$frame_age_90" 90 "medium PR-ages frame lines are 90 columns"
frame_age_70=$(render pr-ages.json --cols 70 --rows 30) || fail "pr-ages 70: render exited non-zero"
assert_not_contains "$frame_age_70" "~" "narrow width: no marker in list mode"
assert_widths "$frame_age_70" 70 "narrow PR-ages frame lines are 70 columns"

# ------------------------------------------------------------------ PR status
# Ready for review's STATUS column, its 12-hour window on finished PRs and its sort, from
# tests/fixtures/pr-status.json: one PR per status, a PR merged 11h59m and one 12h01m before now, an
# open PR of a done task, a closed PR with no time stamp, a closed draft and an unlisted recorded PR.
frame_st=$(render pr-status.json) || fail "pr-status: render exited non-zero"
# The six columns, in order, and nothing else; the other panes keep theirs (falsify: drop the review
# branch from columns in lib/layout.mjs, reorder its pushes, or apply it to every pane).
assert_row "$frame_st" '^│ CHECKS +STATUS +ID +TITLE +BASE +AGE │$' "pr-status: the header reads CHECKS, STATUS, ID, TITLE, BASE, AGE"
assert_no_row "$frame_st" '^│ CHECKS [^│]*(REPO|HOME|WHAT|REVIEW)' "pr-status: the review pane draws no REPO, HOME, WHAT or REVIEW column"
assert_row "$frame_st" '^│ STATE +HERDR +ID +WHAT +REPO +HOME +AGE │$' "pr-status: the other panes keep the shared columns"
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
assert_no_row "$frame_st" '^│ (passing|failing|pending|none|unlisted|PR) +[^│]* st-old ' "the done task of the PR outside the window has no review row (its In flight row stays)"
assert_not_contains "$frame_st" "Rename the widget table" "an open PR of a done task is not listed: a done task's PR shows only once terminal (falsify: drop the rec.done check in reviewRows)"
assert_not_contains "$frame_st" "Abandoned spike" "a closed PR with no close time cannot be placed in the window and is dropped"
assert_contains "$frame_st" "Ready for review (9)" "the pane count is the rows shown after the window filter (falsify: count candidate_prs instead of rows)"
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
frame_o=$(render_open pr-status.json "tab,enter") || fail "pr-status open first: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/201" "enter on the DRAFT row opens its PR"
frame_o=$(render_open pr-status.json "tab,j,j,j,j,j,j,j,enter") || fail "pr-status open merged: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/206" "enter on a MERGED row still opens its PR"
assert_contains "$frame_o" "opened https://github.com/acme/api/pull/206 (st-merged)" "the notice names the task of the merged PR"
# --no-prs: the recorded PRs of unfinished tasks only, STATUS unknown, as before (falsify: list a done
# task's PR without a fetched record).
frame_st_np=$(render pr-status.json --no-prs) || fail "pr-status --no-prs: render exited non-zero"
assert_contains "$frame_st_np" "Ready for review (5)" "--no-prs: the five recorded PRs of unfinished tasks"
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
assert_row "$frame_st_70" '^ pending +st-draft +Rework the geocoder cache with a… +main *$' "70 columns: a review row in the shared list (HOME is 4 wide for main and ends the line)"
assert_not_contains "$frame_st_70" "DRAFT" "70 columns: the list has no STATUS column"
assert_widths "$frame_st_70" 70 "70-column pr-status frame lines are 70 columns"

# The fetch's pure pieces, straight from lib/sources.mjs, copy fm-bearings-snapshot.sh's rules: the
# repository slug, the statusCheckRollup mapping, the fm/<task> branch rule with the script's
# defaults, the projection of the title, base branch, draft flag, state and merge and close times, the
# field list, the 12-hour keep rule on fetched PRs (open always; merged or closed only while the
# finish time is less than twelve hours before now, a missing stamp dropped, a future one kept) and
# the candidate rule (PR URLs of every task including a secondmate's, then the origin remote of live
# non-secondmate worktrees only, capped at ten). Two scratch git repositories stand in for worktrees
# (falsify: change any branch of checksState, drop the .git strip in repoSlug, the kind check in
# candidateRepos, a field from GH_PR_FIELDS, or compare with <= in keepFetchedPr).
WT_DIR="$SCRATCH/wt"
WT_SM_DIR="$SCRATCH/wt-secondmate"
git init -q "$WT_DIR" && git -C "$WT_DIR" remote add origin git@github.com:acme/wt.git
git init -q "$WT_SM_DIR" && git -C "$WT_SM_DIR" remote add origin https://github.com/acme/mate-only.git
unit_out=$(node --input-type=module -e "
  import { checksState, projectPr, repoSlug, candidateRepos, keepFetchedPr, GH_PR_FIELDS } from '$ROOT/bin/firstmate-tui/lib/sources.mjs';
  const out = [];
  out.push(['none', checksState([])], ['none-null', checksState(null)]);
  out.push(['passing', checksState([{ status: 'COMPLETED', conclusion: 'SUCCESS' }])]);
  out.push(['passing-state', checksState([{ state: 'SUCCESS' }])]);
  out.push(['pending', checksState([{ status: 'IN_PROGRESS' }, { status: 'COMPLETED', conclusion: 'SUCCESS' }])]);
  out.push(['failing', checksState([{ status: 'COMPLETED', conclusion: 'FAILURE' }, { status: 'IN_PROGRESS' }])]);
  out.push(['failing-state', checksState([{ state: 'ERROR' }])]);
  out.push(['slug-pull', repoSlug('https://github.com/acme/widgets/pull/41')]);
  out.push(['slug-ssh', repoSlug('git@github.com:acme/widgets.git')]);
  out.push(['slug-other', String(repoSlug('https://gitlab.com/acme/widgets'))]);
  const p = projectPr({ number: 41, title: 'Add the widget cache', url: 'https://github.com/acme/widgets/pull/41', headRefName: 'fm/ship-alpha', baseRefName: 'main', reviewDecision: 'REVIEW_REQUIRED', mergeable: 'MERGEABLE', statusCheckRollup: [{ status: 'COMPLETED', conclusion: 'SUCCESS' }], createdAt: '2026-09-16T09:00:00Z', isDraft: true, state: 'OPEN', mergedAt: null, closedAt: null }, 'acme/widgets');
  out.push(['project', [p.num, p.repo, p.task, p.review, p.mergeable, p.checks, p.created_at, p.title, p.base, p.draft, p.state, String(p.merged_at), String(p.closed_at)].join(' ')]);
  const q = projectPr({ number: 8, url: 'u', headRefName: 'retry-429' }, 'acme/api');
  out.push(['project-defaults', [q.task, q.review, q.mergeable, q.checks, String(q.created_at), String(q.title), String(q.base), q.draft, String(q.state), String(q.merged_at)].join(' ')]);
  const m = projectPr({ number: 9, url: 'u', headRefName: 'x', state: 'merged', mergedAt: '2026-09-16T11:30:00Z', closedAt: '2026-09-16T11:30:00Z' }, 'acme/api');
  out.push(['project-merged', [m.state, m.merged_at, m.closed_at].join(' ')]);
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
  out.push(['fields', GH_PR_FIELDS.join(',')]);
  const tasks = [
    { kind: 'ship', pr: { url: 'https://github.com/acme/widgets/pull/41' }, paths: { worktree: { path: '$WT_DIR' } } },
    { kind: 'secondmate', pr: { url: 'https://github.com/acme/etl/pull/12' }, paths: { worktree: { path: '$WT_SM_DIR' } } },
    { kind: 'ship', pr: { url: 'https://github.com/acme/widgets/pull/30' }, paths: { worktree: { path: '/nonexistent/worktree' } } },
  ];
  out.push(['repos', (await candidateRepos({ tasks }, { timeoutMs: 10000 })).join(' ')]);
  const many = { tasks: Array.from({ length: 12 }, (_, i) => ({ kind: 'ship', pr: { url: 'https://github.com/acme/r' + i + '/pull/1' } })) };
  out.push(['cap', (await candidateRepos(many, { timeoutMs: 10000 })).join(' ')]);
  process.stdout.write(out.map(([k, v]) => k + '=' + v).join('\n'));
") || fail "sources unit checks: node exited non-zero: $unit_out"
for expected in "none=none" "none-null=none" "passing=passing" "passing-state=passing" "pending=pending" "failing=failing" "failing-state=failing" \
  "slug-pull=acme/widgets" "slug-ssh=acme/widgets" "slug-other=null" \
  "project=41 acme/widgets ship-alpha REVIEW_REQUIRED MERGEABLE passing 2026-09-16T09:00:00Z Add the widget cache main true OPEN null null" \
  "project-defaults=- none UNKNOWN none null null null false null null" \
  "project-merged=MERGED 2026-09-16T11:30:00Z 2026-09-16T11:30:00Z" \
  "keep-open=true" "keep-no-state=true" "keep-merged-inside=true" "keep-merged-outside=false" "keep-merged-exact=false" \
  "keep-merged-closed-only=true" "keep-closed-inside=true" "keep-closed-nostamp=false" "keep-merged-future=true" \
  "fields=number,title,url,headRefName,baseRefName,reviewDecision,mergeable,statusCheckRollup,createdAt,isDraft,state,mergedAt,closedAt" \
  "repos=acme/widgets acme/etl acme/wt" \
  "cap=acme/r0 acme/r1 acme/r2 acme/r3 acme/r4 acme/r5 acme/r6 acme/r7 acme/r8 acme/r9"; do
  if printf '%s\n' "$unit_out" | grep -Fxq -- "$expected"; then pass; else fail "sources: expected line '$expected' in: $unit_out"; fi
done

# --------------------------------------------------------------- r refresh
# r is the same refresh a timer tick runs: the fleet snapshot, then the PR fetch against the
# repositories that snapshot names. The board asks GitHub itself, so the fake gh on PATH logs one
# call per candidate repository (acme/widgets, acme/api and acme/etl carry PR URLs in the stand-in
# snapshot), every state, newest-updated first, one over the 50 cap, the full field list; the start-up
# read is one set and r adds the second. The stand-in's fm-bearings-snapshot.sh must not run at all
# (falsify: keep runBearingsPrs as the default source, keep --state open or drop a field in ghPrList,
# or drop fetchPrs from refreshLive).
gh_line() { printf 'gh pr list --repo %s --state all --search sort:updated-desc --limit 51 --json number,title,url,headRefName,baseRefName,reviewDecision,mergeable,statusCheckRollup,createdAt,isDraft,state,mergedAt,closedAt' "$1"; }
expected_live="$(gh_line acme/api)
$(gh_line acme/api)
$(gh_line acme/etl)
$(gh_line acme/etl)
$(gh_line acme/widgets)
$(gh_line acme/widgets)
snapshot
snapshot"
frame_r=$(render_live --keys "r" --cols 160 --rows 40) || fail "refresh default: render exited non-zero"
assert_fetch_log "$expected_live" "r by default runs the snapshot and then one gh pr list per candidate repository, never the firstmate PR script (falsify: flip the prs default in parseArgs, or call runBearingsPrs with gh on PATH)"
assert_contains "$frame_r" "refreshed: snapshot and PR checks" "r reports the refresh"
# The rows come from the fake gh's answers: ship-alpha's PR, opened in 2020, shows a day count with no
# marker and its title and base branch; the failing PR nobody recorded shows the mapped checks state;
# ship-gamma's recorded PR 7 is not in the fake's list and, with no status file on this host, has no
# age to fall back to; api#9, merged at run time, is listed as MERGED inside the window, and api#10,
# closed in 2020, is dropped by the fetch before the model sees it (falsify: drop created_at, title or
# base from projectPr, the FAILURE branch of checksState, the MERGED branch of prStatus, or
# keepFetchedPr from ghPrList).
assert_row "$frame_r" '^│ passing +IN REVIEW +ship-alpha +Add the widget cache +main +[0-9]+d │$' "live: STATUS, title and base branch come from gh, the PR age from its createdAt"
assert_row "$frame_r" '^│ failing +IN REVIEW +api#8 +Retry on 429 +main +[0-9]+d │$' "live: a FAILURE conclusion maps to failing"
assert_row "$frame_r" '^│ unlisted +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: not fetched +- +- │$' "live: a recorded PR the fetch did not list stays unlisted"
assert_row "$frame_r" '^│ passing +MERGED +api#9 +Bump the retry budget +main +[0-9]+d │$' "live: a PR gh reports merged just now is listed as MERGED"
assert_no_row "$frame_r" 'api#10|Old spike' "live: a PR closed in 2020 is outside the 12-hour window and dropped by the fetch"
assert_contains "$frame_r" "Ready for review (4)" "live: the pane counts the rows shown after the window filter"
assert_before "$frame_r" '^│ failing +IN REVIEW +api#8' '^│ passing +MERGED +api#9' "live: MERGED sorts after the open PRs"
frame_r=$(render_live --keys "r" --prs) || fail "refresh --prs: render exited non-zero"
assert_fetch_log "$expected_live" "--prs is a no-op: the same calls (falsify: make --prs disable or double the fetch)"
frame_r=$(render_live --keys "r" --no-prs) || fail "refresh --no-prs: render exited non-zero"
assert_fetch_log "snapshot
snapshot" "r with --no-prs runs only the snapshot again (falsify: call fetchPrs unconditionally)"
assert_contains "$frame_r" "PR checks off: start without --no-prs" "r with --no-prs says why the PR pane did not change (falsify: drop the notice)"
assert_not_contains "$frame_r" "fetching" "--no-prs: nothing reads fetching after r"
# Without gh on PATH the firstmate script is the fallback and the footer says so. The board runs here
# as node index.mjs under a PATH holding only node, bash and cat (the stand-in scripts need the last
# two), so the PATH lookup finds no gh (falsify: drop the whichOnPath check in fetchPrs, and the gh
# spawn fails instead of the script running; or drop the note from fetchPrs).
NOGH_BIN="$SCRATCH/nogh"
mkdir -p "$NOGH_BIN"
ln -s "$(command -v node)" "$NOGH_BIN/node"
ln -s "$(command -v bash)" "$NOGH_BIN/bash"
ln -s "$(command -v cat)" "$NOGH_BIN/cat"
rm -f "${FETCH_LOG:?}"
frame_r=$(FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" PATH="$NOGH_BIN" "$NOGH_BIN/node" "$ROOT/bin/firstmate-tui/index.mjs" --render-once --no-herdr --keys "r") || fail "refresh without gh: render exited non-zero"
assert_fetch_log "prs --json --include-prs
prs --json --include-prs
snapshot
snapshot" "without gh on PATH, r runs the snapshot and fm-bearings-snapshot.sh --include-prs, and no gh (falsify: spawn gh without the PATH check)"
assert_contains "$frame_r" "gh not on PATH: PR data from fm-bearings-snapshot.sh" "without gh the footer names the fallback (falsify: drop the note)"
frame_r=$(render populated.json --keys "r") || fail "refresh fixture: render exited non-zero"
assert_contains "$frame_r" "refresh is not available with --fixture" "r on a fixture render only reports"
# A fixture render runs no script at all, whatever the prs default: with the stand-in home and the log
# in the environment, nothing is logged (falsify: call factsLive or refreshLive when a fixture is given).
rm -f "$FETCH_LOG"
FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" render populated.json --keys "r" >/dev/null || fail "fixture with FM_HOME: render exited non-zero"
if [ -f "$FETCH_LOG" ]; then fail "a fixture render ran a snapshot script: $(cat "$FETCH_LOG")"; else pass; fi

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
assert_row "$frame_s" '^ herdr overlay +off \(--no-herdr\) +$' "settings: the herdr line reflects --no-herdr"
assert_row "$frame_s" '^ mouse +on: click selects, double-click acts, wheel scrolls, a header boundary drags +$' "settings: the mouse line, on by default (falsify: drop the mouse entry from settingsFlags)"
assert_row "$frame_s" '^ j/k move  enter choose  r refetch  esc/\. back  \? help +$' "settings: the footer names the page's keys"
assert_row "$frame_s" '^ firstmate-tui · /fixture/firstmate · 3 homes ' "settings: the title line stays and leads with firstmate-tui"
assert_lines "$frame_s" 40 "settings: the frame is 40 lines"
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
# tab,j selects the second Ready for review row, api#8 (the pane sorts by status, newest first, so
# ship-alpha's newer PR 41 comes first), a selection enter would not reach from the default one.
rm -f "$OPENER_LOG"
frame_o=$(FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" render populated.json --install-root "$INSTALL" --keys "tab,j,.,escape,enter" --opener-cmd "$FAKE_OPENER") || fail "settings esc: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/8" "esc closes the page and enter acts on the row selected before it opened"
assert_count "$frame_o" "┌─" 5 "esc: the grid is back"
rm -f "$OPENER_LOG"
frame_o=$(FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" render populated.json --install-root "$INSTALL" --keys "tab,j,.,.,enter" --opener-cmd "$FAKE_OPENER") || fail "settings dot: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/8" ". closes the page with the selection intact"
rm -f "$OPENER_LOG"
frame_o=$(FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" render populated.json --install-root "$INSTALL" --keys "tab,j,.,q,enter" --opener-cmd "$FAKE_OPENER") || fail "settings q: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/8" "q closes the page like the help overlay, and the board is not quit"
frame_k=$(render populated.json --install-root "$INSTALL" --keys "tab,tab,j,j,j,j,l,.,escape") || fail "settings expanded: render exited non-zero"
assert_row "$frame_k" '^│ decide +1 live +!▾ hyperion ' "a group expanded before the page opened is still expanded after it closes"
# . works from the landing page too and esc returns there (falsify: drop . from LANDING_KEYS).
frame_s=$(render populated.json --install-root "$INSTALL" --keys "1,2,3,4,5,.") || fail "settings landing: render exited non-zero"
assert_row "$frame_s" '^ Settings +$' ". opens the page from the landing page"
frame_s=$(render populated.json --install-root "$INSTALL" --keys "1,2,3,4,5,.,escape") || fail "settings landing esc: render exited non-zero"
assert_row "$frame_s" '^ +all panes hidden +$' "esc returns to the landing page"
# Help: the overlay documents . and opens over the page (falsify: drop the . line from HELP_LINES).
frame_k=$(render populated.json --keys "?") || fail "help settings: render exited non-zero"
assert_contains "$frame_k" ".            settings page: installed version, latest release, upgrade or a beta" "help overlay documents ."
assert_contains "$frame_k" "(each install asks y first; . or esc brings the board back)" "help overlay documents the confirm step"
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
frame_s=$(render_settings "$REL" "$INSTALL" "." --mouse "click:10,12 click:30,0 click:30,39") || fail "settings chrome click: render exited non-zero"
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
frame_o=$(FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" render populated.json --install-root "$INSTALL" --keys "tab,j,." --mouse "click:30,29 wheel:down:30,29" --keys "escape,enter" --opener-cmd "$FAKE_OPENER") || fail "settings click through: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/8" "a click and a wheel on the page leave the board's selection where it was"

# ------------------------------------------------------------ refresh schedule
# The interactive schedule, run with --headless against a stand-in whose snapshot sleeps 7 s, with
# --refresh 5 (the minimum) and the fake gh on PATH. The next refresh is due 5 s after the last
# one started, armed when it completes, so a refresh slower than the cadence is followed by the
# next one at once and never by two. From launch: the start refresh runs the snapshot (0-7 s) and
# then the three gh calls; its timer is already due, so the second refresh runs the snapshot
# (7-14 s) and the gh calls; the third starts its snapshot at 14 s and is still in it at 19 s.
# Stopped at 19 s, the log holds three snapshot lines, the first two each followed by their three
# gh lines, and no script fallback (falsify: arm the timer from the completion instead of the
# start, two snapshots and three gh lines; keep the old fixed interval, two snapshots; never
# clear the refreshing flag, one; re-arm the timer at the start of a refresh as well, four; start
# the fetch with the snapshot instead of after it, and gh lines land before the snapshot line).
SLOW_HOME="$SCRATCH/firstmate-slow"
mkdir -p "$SLOW_HOME/bin"
# shellcheck disable=SC2016 # the fake expands $FM_BOARD_TEST_FETCH_LOG at run time, not here
printf '#!/usr/bin/env bash\necho snapshot >> "$FM_BOARD_TEST_FETCH_LOG"\nsleep 7\ncat "%s"\n' "$FAKE_HOME/snapshot.json" > "$SLOW_HOME/bin/fm-fleet-snapshot.sh"
cp "$FAKE_HOME/bin/fm-bearings-snapshot.sh" "$SLOW_HOME/bin/fm-bearings-snapshot.sh"
chmod +x "$SLOW_HOME/bin/fm-fleet-snapshot.sh" "$SLOW_HOME/bin/fm-bearings-snapshot.sh"
rm -f "${FETCH_LOG:?}"
FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$SLOW_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" PATH="$FAKE_BIN:$PATH" "$BOARD" --headless --refresh 5 --no-herdr > "$SCRATCH/headless.log" 2>&1 &
headless_pid=$!
sleep 19
kill "$headless_pid" 2>/dev/null
wait "$headless_pid" 2>/dev/null
headless_log=$(cat "$FETCH_LOG" 2>/dev/null || echo '<absent>')
if [ "$(grep -c '^snapshot$' "$FETCH_LOG" 2>/dev/null)" = 3 ]; then pass; else fail "headless schedule: expected three snapshot starts in 19 s (0, 7 and 14 s), log is '$headless_log' (board output: $(cat "$SCRATCH/headless.log"))"; fi
if [ "$(grep -c '^gh pr list ' "$FETCH_LOG" 2>/dev/null)" = 6 ]; then pass; else fail "headless schedule: no second PR fetch during a running refresh, and one per completed refresh (two completed, three repositories each); log is '$headless_log' (board output: $(cat "$SCRATCH/headless.log"))"; fi
if [ "$(sed -n '1p;5p;9p' "$FETCH_LOG" 2>/dev/null)" = "snapshot
snapshot
snapshot" ]; then pass; else fail "headless schedule: each refresh runs the snapshot before its gh calls, and the third starts only after the second's gh calls; log is '$headless_log'"; fi
if grep -q '^prs ' "$FETCH_LOG" 2>/dev/null; then fail "headless schedule: the firstmate PR script ran although gh is on PATH; log is '$headless_log'"; else pass; fi
if [ -s "$SCRATCH/headless.log" ]; then fail "headless run wrote to the terminal: $(head -c 300 "$SCRATCH/headless.log")"; else pass; fi

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
# A failed PR fetch: the title line names the failure's age and the retry in red, the Ready for
# review header alone is marked stale, and the previous PR rows stay (falsify: drop the failedAt
# branch from refreshLabel, the 'title bad' style from titleLine, or the review case from paneStale).
fx_pf=$(variant populated.json pr-failed '{"prs": {"error": "exit 1"}, "refresh": {"failed_ago": 40, "next_in": 20, "failed": "PR fetch: exit 1"}}')
frame_f=$(render "$fx_pf") || fail "PR fetch failed: render exited non-zero"
tags_f=$(render "$fx_pf" --tags) || fail "PR fetch failed --tags: render exited non-zero"
assert_row "$frame_f" '^ firstmate-tui · /fixture/firstmate · 3 homes +refresh failed 40s ago, retrying in 20s $' "PR fetch failed: the title line reads refresh failed 40s ago, retrying in 20s"
assert_contains "$tags_f" "{red-fg}refresh failed 40s ago, retrying in 20s{/red-fg}" "PR fetch failed: the label is red"
assert_contains "$frame_f" "┌─ [2] Ready for review (3) (stale) ─" "PR fetch failed: the review header is marked stale"
assert_count "$frame_f" "(stale)" 1 "PR fetch failed: no other pane is marked stale"
assert_row "$frame_f" '^│ passing +IN REVIEW +ship-alpha +Add the widget cache +main +3h │$' "PR fetch failed: the previous PR rows stay on screen"
# A failed snapshot: the four snapshot panes are marked stale and Ready for review is not (falsify:
# swap the pane test in paneStale).
frame_f=$(render "$(variant populated.json snap-failed '{"snapshot_error": "exit 1", "refresh": {"failed_ago": 5, "next_in": 25, "failed": "snapshot: exit 1"}}')") || fail "snapshot failed: render exited non-zero"
assert_row "$frame_f" '^ firstmate-tui · /fixture/firstmate · 3 homes +refresh failed 5s ago, retrying in 25s $' "snapshot failed: the title line names the failure"
assert_count "$frame_f" "(stale)" 4 "snapshot failed: four panes are marked stale"
assert_contains "$frame_f" "┌─ [1] Needs you (4) (stale) ─" "snapshot failed: Needs you is stale"
assert_contains "$frame_f" "┌─ [3] In flight (7) (stale) ─" "snapshot failed: In flight is stale"
assert_contains "$frame_f" "┌─ [4] Findings (3) (stale) ─" "snapshot failed: Findings is stale"
assert_contains "$frame_f" "┌─ [5] Landed (4) (stale) ─" "snapshot failed: Landed is stale"
assert_contains "$frame_f" "┌─ [2] Ready for review (3) ─" "snapshot failed: Ready for review, whose fetch succeeded, is not stale"
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
assert_count "$frame_ld" "⠋ loading fleet snapshot…" 4 "cold start: Needs you, In flight, Findings and Landed each spin and name the fleet snapshot"
assert_count "$frame_ld" "⠋ loading GitHub checks…" 1 "cold start: Ready for review alone names the GitHub checks"
assert_line "$frame_ld" 4 '^│ ⠋ loading fleet snapshot… +│$' "cold start: Needs you's first body line is the spinner"
assert_line "$frame_ld" 8 '^│ ⠋ loading GitHub checks… +│$' "cold start: Ready for review's first body line is the spinner"
assert_line "$frame_ld" 12 '^│ ⠋ loading fleet snapshot… +│$' "cold start: In flight's first body line is the spinner"
assert_line "$frame_ld" 34 '^│ ⠋ loading fleet snapshot… +│$' "cold start: Findings' first body line is the spinner"
assert_line "$frame_ld" 38 '^│ ⠋ loading fleet snapshot… +│$' "cold start: Landed's first body line is the spinner"
for empty_text in "no captain decisions, holds or blocked workers" "no recorded pull requests" "no workers in flight" "no scout reports" "nothing landed yet"; do
  assert_not_contains "$frame_ld" "$empty_text" "cold start: the spinner replaces the empty text (falsify: draw the empty text beside the loading line)"
done
assert_contains "$frame_ld" "┌─ [3] In flight (0) ─" "cold start: the headers count zero rows and carry no stale marker"
assert_count "$frame_ld" "(stale)" 0 "cold start: nothing has failed, so nothing is stale"
assert_widths "$frame_ld" 120 "cold start: every line is still 120 columns"
assert_contains "$tags_ld" "{blue-fg}⠋ loading fleet snapshot…" "cold start --tags: the spinner line is dimmed like the empty text (falsify: give it the row style)"
# The snapshot landed, the PR fetch still running (populated.json with prs null and refreshing):
# only Ready for review spins, above the recorded PR rows it already has from the snapshot, and the
# four snapshot panes keep their rows (falsify: key the review pane on the snapshot, or drop the
# rows under the loading line).
frame_ld=$(render "$(variant populated.json snap-landed '{"prs": null, "refresh": {"refreshing": true}}')") || fail "snapshot landed: render exited non-zero"
assert_count "$frame_ld" "loading" 1 "snapshot landed: one spinner on the board"
assert_line "$frame_ld" 11 '^│ ⠋ loading GitHub checks… +│$' "snapshot landed: Ready for review's first body line is the spinner"
assert_row "$frame_ld" '^│ PR +- +ship-alpha +https://github.com/acme/widgets/pull/41 · checks: fetching +- +5m~ │$' "snapshot landed: the recorded PR rows stay under the spinner"
assert_contains "$frame_ld" "┌─ [2] Ready for review (2) ─" "snapshot landed: the header counts the recorded rows"
assert_contains "$frame_ld" "┌─ [1] Needs you (4) ─" "snapshot landed: Needs you has its rows and no spinner"
assert_row "$frame_ld" '^│ working +working +ship-alpha +harness busy \(claude-hook\)' "snapshot landed: In flight's rows are drawn"
# --no-prs: Ready for review is never loading; it shows the off state, and a cold start's empty
# review pane reads the empty text while the other four spin (falsify: drop the prs.enabled test
# from paneLoadingSource).
frame_ld=$(render "$(variant populated.json snap-landed-noprs '{"prs": null, "refresh": {"refreshing": true}}')" --no-prs) || fail "--no-prs refreshing: render exited non-zero"
assert_count "$frame_ld" "loading" 0 "--no-prs: no spinner while the snapshot data is on screen"
assert_row "$frame_ld" '^│ PR +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: off \(--no-prs\) +- +1m~ │$' "--no-prs: the recorded PR rows read the off state"
frame_ld=$(render cold-start.json --no-prs) || fail "cold start --no-prs: render exited non-zero"
assert_count "$frame_ld" "⠋ loading fleet snapshot…" 4 "cold start --no-prs: the four snapshot panes still spin"
assert_not_contains "$frame_ld" "GitHub checks" "cold start --no-prs: Ready for review does not spin"
assert_line "$frame_ld" 8 '^│ no recorded pull requests +│$' "cold start --no-prs: Ready for review reads its empty text"
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
assert_contains "$frame_ld" "⠸ loading GitHub checks…" "loading_frame 3: the same glyph on Ready for review"
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
assert_line "$frame_ld" 3 '^── \[1\] Needs you \(0\) ─+$' "narrow cold start: the first section header"
assert_line "$frame_ld" 4 '^ ⠋ loading fleet snapshot… +$' "narrow cold start: the spinner line follows the section header"
assert_line "$frame_ld" 6 '^ ⠋ loading GitHub checks… +$' "narrow cold start: Ready for review's line names the GitHub checks"
assert_not_contains "$frame_ld" "no workers in flight" "narrow cold start: no empty text beside the spinner"
assert_widths "$frame_ld" 70 "narrow cold start: every line is 70 columns"
# A failed first fetch shows the failure text, not the spinner: a PR fetch that failed before any
# fetch landed leaves the recorded rows reading checks: fetch failed under a stale header, and a
# snapshot that failed before any landed leaves the four panes stale with their empty text while
# Ready for review, whose own fetch is still running, spins (falsify: drop the prs.error or the
# snapshotError test from paneLoadingSource).
frame_ld=$(render "$(variant populated.json pr-first-failed '{"prs": {"candidate_prs": null, "error": "exit 1"}, "refresh": {"refreshing": true}}')") || fail "PR first fetch failed: render exited non-zero"
assert_count "$frame_ld" "loading" 0 "PR first fetch failed: no spinner"
assert_contains "$frame_ld" "┌─ [2] Ready for review (2) (stale) ─" "PR first fetch failed: the review header is stale"
assert_row "$frame_ld" '^│ PR +- +ship-gamma +https://github.com/acme/api/pull/7 · checks: fetch failed +- +1m~ │$' "PR first fetch failed: the rows read checks: fetch failed"
frame_ld=$(render "$(variant cold-start.json snap-first-failed '{"snapshot_error": "exit 1"}')") || fail "snapshot first fetch failed: render exited non-zero"
assert_count "$frame_ld" "loading fleet snapshot" 0 "snapshot first fetch failed: the snapshot panes do not spin"
assert_count "$frame_ld" "(stale)" 4 "snapshot first fetch failed: the four snapshot panes are stale"
assert_line "$frame_ld" 4 '^│ no captain decisions, holds or blocked workers +│$' "snapshot first fetch failed: Needs you reads its empty text"
assert_line "$frame_ld" 8 '^│ ⠋ loading GitHub checks… +│$' "snapshot first fetch failed: Ready for review still spins on its own fetch"
# Herdr: once the snapshot has landed, In flight names herdr while the link is still connecting,
# above the rows it already has, and only while a refresh runs; on a cold start the snapshot
# comes first (falsify: drop the herdr branch from paneLoadingSource, or move it above the
# snapshot test).
frame_ld=$(render "$(variant populated.json herdr-connecting '{"herdr": {"state": "connecting"}, "refresh": {"refreshing": true}}')") || fail "herdr connecting: render exited non-zero"
assert_count "$frame_ld" "loading" 1 "herdr connecting: one spinner on the board"
assert_row "$frame_ld" '^│ ⠋ loading herdr… +│$' "herdr connecting: In flight names herdr"
assert_before "$frame_ld" "In flight \(7\)" "⠋ loading herdr…" "herdr connecting: the line is in In flight"
assert_before "$frame_ld" "⠋ loading herdr…" "working +working +ship-alpha" "herdr connecting: the rows follow the spinner line"
assert_contains "$frame_ld" "┌─ [3] In flight (7) ─" "herdr connecting: the header still counts the rows"
frame_ld=$(render "$(variant populated.json herdr-connecting-idle '{"herdr": {"state": "connecting"}}')") || fail "herdr connecting idle: render exited non-zero"
assert_count "$frame_ld" "loading" 0 "herdr connecting with no refresh running: no spinner"
frame_ld=$(render "$(variant cold-start.json cold-connecting '{"herdr": {"state": "connecting", "agents": []}}')") || fail "cold start connecting: render exited non-zero"
assert_count "$frame_ld" "⠋ loading fleet snapshot…" 4 "cold start connecting: In flight names the snapshot first"
assert_not_contains "$frame_ld" "loading herdr" "cold start connecting: herdr is not named before the snapshot lands"

# ------------------------------------------------------------------- mouse
# Cells are column,line from 0 at the top-left. In populated.json at 160x40 the lines are: 0 title,
# 1 Needs you title, 3-6 its rows (scout-beta, ship-alpha, decide-vendor, ship-gamma), 8 Ready for
# review title, 10-12 its rows (ship-alpha #41, api#8, ship-gamma #7), 14 In flight title, 15 its
# column header, 16-22 its rows (ship-alpha, tmux-task, remote-sm group, scout-beta, hyperion group,
# ship-gamma, ship-old), 26 Findings title, 28-30 its rows (scout-beta, mobile-fix, old-scout),
# 32 Landed title, 34-37 its rows (etl-index, ship-old, mobile-fix, old-scout), 39 footer.
#
# A left click selects: the pane gets the focus border and the row the inverse style, the same as
# tab/j/k would leave them (falsify: drop the 'select' case from applyAction, or the row zones from
# renderPanes).
tags_m=$(render populated.json --mouse "click:30,29" --tags) || fail "mouse click: render exited non-zero"
assert_row "$tags_m" '\{inverse\}report *\{/inverse\}.*mobile-fix' "click on the second Findings row selects it"
assert_row "$tags_m" '\{bold\}\{cyan-fg\}┌─ .*\[4\].*Findings \(3\)' "click on a Findings row focuses the Findings pane"
assert_no_row "$tags_m" '\{cyan-fg\}┌─ .*\[1\]' "click: Needs you lost the focus border"
assert_no_row "$tags_m" '\{inverse\}blocked' "click: the old selection is no longer inverse"
# The selection a click leaves is what the keys then act on (falsify: set view.row without view.pane in 'select').
frame_m=$(render populated.json --mouse "click:30,29" --keys "x") || fail "mouse click then x: render exited non-zero"
assert_contains "$frame_m" "Findings (2, 1 hidden)" "x after a click hides the clicked row"
assert_contains "$frame_m" "hidden mobile-fix" "x after a click names the clicked row"
# A click on a pane title focuses the pane, cursor on its first row (falsify: drop the title zone, or return
# 'none' for a non-row hit in mouseAction).
tags_m=$(render populated.json --mouse "click:5,26" --tags) || fail "mouse title click: render exited non-zero"
assert_row "$tags_m" '\{bold\}\{cyan-fg\}┌─ .*\[4\].*Findings \(3\)' "click on the Findings title focuses Findings"
assert_row "$tags_m" '\{inverse\}scout +\{/inverse\}.*scout-beta' "click on the Findings title puts the cursor on its first row"
frame_m=$(render populated.json --mouse "click:5,26" --keys "enter") || fail "mouse title click then enter: render exited non-zero"
assert_contains "$frame_m" "would view /fixture/firstmate/data/scout-beta/report.md" "enter after a title click acts on that pane's first row"
# A click on a pane's empty space (its column header) focuses the pane too (falsify: drop the pane zone).
tags_m=$(render populated.json --mouse "click:30,15" --tags) || fail "mouse empty click: render exited non-zero"
assert_row "$tags_m" '\{bold\}\{cyan-fg\}┌─ .*\[3\].*In flight \(7\)' "click on In flight's column header focuses In flight"
# A click on the title line or the footer changes nothing (falsify: give those lines a zone).
frame_m=$(render populated.json --mouse "click:30,0 click:30,39") || fail "mouse chrome click: render exited non-zero"
if [ "$frame_m" = "$frame" ]; then pass; else fail "a click on the title line or footer changed the frame: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_m") | head -n 5)"; fi
# The narrow list has zones too (falsify: drop the zones from renderList).
tags_m=$(render narrow.json --mouse "click:10,12" --tags) || fail "mouse narrow click: render exited non-zero"
assert_row "$tags_m" '\{inverse\}merged +\{/inverse\}.*ship-old' "list mode: a click on the Landed row selects it"
assert_row "$tags_m" '\{bold\}\{cyan-fg\}── .*\[5\].*Landed \(1\)' "list mode: the Landed section header takes the focus style"
tags_m=$(render narrow.json --mouse "click:10,2" --tags) || fail "mouse narrow title click: render exited non-zero"
assert_row "$tags_m" '\{bold\}\{cyan-fg\}── .*\[1\].*Needs you \(1\)' "list mode: a click on a section header focuses that section"

# A double-click is enter on that row: two left clicks on one row within 400 ms, recognized in
# lib/controller.mjs, not by the terminal library (falsify: drop the lastClick check from mouseAction, or
# stamp the two dblclick events with different times in driveOnce).
frame_m=$(render_mouse populated.json "dblclick:30,10") || fail "mouse dblclick review: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "double-click on the first Ready for review row opens its PR, as enter does"
assert_contains "$frame_m" "opened https://github.com/acme/widgets/pull/41 (ship-alpha)" "double-click: the footer names the opened PR"
frame_m=$(render_mouse populated.json "click:30,11 click:30,11") || fail "mouse two clicks: render exited non-zero"
assert_not_opened "two single clicks a second apart on one row open nothing"
frame_m=$(render_mouse populated.json "click:30,10 click:30,11 click:30,11 click:30,10") || fail "mouse clicks on different rows: render exited non-zero"
assert_not_opened "clicks alternating between rows never make a double-click"
frame_m=$(render_mouse populated.json "dblclick:30,20") || fail "mouse dblclick group: render exited non-zero"
assert_row "$frame_m" '^│ decide +1 live +!▾ hyperion ' "double-click on the hyperion group row expands it"
assert_contains "$frame_m" "In flight (12)" "double-click on a group: only that group's rows are added"
assert_not_opened "double-click on a group row opens no PR"
frame_m=$(render_mouse populated.json "dblclick:30,20 dblclick:30,20") || fail "mouse dblclick group twice: render exited non-zero"
assert_row "$frame_m" '^│ decide +1 live +!▸ hyperion ' "a second double-click on the group row collapses it again"
frame_m=$(render_mouse populated.json "dblclick:60,28") || fail "mouse dblclick findings: render exited non-zero"
assert_viewed "/fixture/firstmate/data/scout-beta/report.md" "double-click on a Findings row views its report through --viewer-cmd"
frame_m=$(render_mouse populated.json "dblclick:30,16") || fail "mouse dblclick worker: render exited non-zero"
assert_contains "$frame_m" "herdr is off (--no-herdr); cannot focus" "double-click on an In flight worker means herdr focus, refused here as enter is"
assert_not_opened "double-click on a worker opens no PR"
assert_not_viewed "double-click on a worker views no report"
frame_m=$(render_mouse populated.json "dblclick:60,37") || fail "mouse dblclick landed no url: render exited non-zero"
assert_not_opened "double-click on a Landed row without a PR opens nothing"
assert_contains "$frame_m" "old-scout: no PR URL on this row" "double-click on a Landed row without a PR says so, as enter does"

# One gesture, one open. The second press of a double-click acts, and every further press on that row
# inside the same 400 ms window only selects, so a triple-click, or a release or drag report a host
# delivers shaped as a press, opens the PR once and the opener log has exactly one line; assert_opened
# compares the whole log (falsify: drop the lastActivate check from mouseAction, or stop applyAction
# recording lastActivate on activate).
frame_m=$(render_mouse populated.json "dblclick:30,10") || fail "mouse dblclick once: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "a double-click opens the PR exactly once: one opener line"
frame_m=$(render_mouse populated.json "tripleclick:30,10") || fail "mouse tripleclick: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "a third press inside the window opens nothing more: one opener line"
assert_contains "$frame_m" "opened https://github.com/acme/widgets/pull/41 (ship-alpha)" "triple-click: the footer names the one open"
# The guard covers one window only: a click a second later is a fresh single click, a double-click a
# second later opens again (falsify: make the guard ignore the time, or never clear it).
frame_m=$(render_mouse populated.json "dblclick:30,10 click:30,10") || fail "mouse dblclick then click: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "a click a second after a double-click only selects: still one opener line"
frame_m=$(render_mouse populated.json "dblclick:30,10 dblclick:30,10") || fail "mouse dblclick twice: render exited non-zero"
assert_opened "$(printf 'https://github.com/acme/widgets/pull/41\nhttps://github.com/acme/widgets/pull/41')" "a second double-click a second later opens again"
# enter is never guarded: one press opens once (checked above with tab,enter) and it still opens right
# after a double-click on the row (falsify: apply the lastActivate guard in keyAction).
frame_m=$(render_mouse populated.json "dblclick:30,10" --keys enter) || fail "mouse dblclick then enter: render exited non-zero"
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

# The wheel moves the selection three rows in the focused pane, whichever pane the pointer is over, and
# clamps at the ends (falsify: change WHEEL_ROWS, or hit-test the wheel's pointer).
frame_m=$(render_mouse populated.json "wheel:down:30,35" --keys "enter") || fail "mouse wheel: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/7" "wheel down over Landed moves the focused Needs you selection three rows to merge?, which enter opens"
tags_m=$(render populated.json --mouse "wheel:down:30,35" --tags) || fail "mouse wheel --tags: render exited non-zero"
assert_row "$tags_m" '\{inverse\}merge\? ' "wheel down: the fourth Needs you row is selected"
assert_no_row "$tags_m" '\{cyan-fg\}┌─ .*\[5\]' "wheel: the pane under the pointer is not focused"
tags_m=$(render populated.json --mouse "wheel:up:30,35 wheel:down:30,35 wheel:down:30,35" --tags) || fail "mouse wheel clamp: render exited non-zero"
assert_row "$tags_m" '\{inverse\}merge\? ' "wheel up at the top stays, two wheel downs clamp at the last row"
tags_m=$(render populated.json --mouse "wheel:down:30,35 wheel:up:30,35" --tags) || fail "mouse wheel back: render exited non-zero"
assert_row "$tags_m" '\{inverse\}blocked\{/inverse\}' "wheel down then up is back on the first row"
# A wheel move breaks a double-click: click, wheel, click on the same row is two singles (falsify: keep
# lastClick across a wheel action).
frame_m=$(render_mouse populated.json "click:30,11 wheel:down:30,11 wheel:up:30,11 click:30,11") || fail "mouse click wheel click: render exited non-zero"
assert_not_opened "click, wheel and click on one row are two single clicks"

# --no-mouse: every gesture is ignored and the frame is the plain one (falsify: drop the opts.mouse guard
# in driveOnce, or make --no-mouse set anything but opts.mouse).
frame_m=$(render populated.json --no-mouse --mouse "click:30,29 dblclick:30,11 wheel:down:30,35") || fail "--no-mouse: render exited non-zero"
if [ "$frame_m" = "$frame" ]; then pass; else fail "--no-mouse changed the frame: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_m") | head -n 5)"; fi
frame_m=$(render_mouse populated.json "dblclick:30,11" --no-mouse) || fail "--no-mouse dblclick: render exited non-zero"
assert_not_opened "--no-mouse: a double-click opens nothing"
frame_m=$(render populated.json --no-mouse --mouse "click:30,29 x") || fail "--no-mouse keys in list: render exited non-zero"
assert_contains "$frame_m" "Needs you (3, 1 hidden)" "--no-mouse: the key tokens of the list still apply (x hid the row the keyboard selection was on)"
assert_contains "$frame_m" "hidden scout-beta" "--no-mouse: the click was ignored, so x acted on the first Needs you row, not the clicked Findings row"
# The landing page has no mouse targets (falsify: give renderLanding zones).
frame_l=$(render populated.json --keys "1,2,3,4,5")
frame_m=$(render populated.json --keys "1,2,3,4,5" --mouse "click:30,20 dblclick:30,20 wheel:down:30,20") || fail "mouse on landing: render exited non-zero"
if [ "$frame_m" = "$frame_l" ]; then pass; else fail "mouse events changed the landing page: $(diff <(printf '%s\n' "$frame_l") <(printf '%s\n' "$frame_m") | head -n 5)"; fi
# A click while the help is up closes it (falsify: ignore mouse events under view.help).
frame_m=$(render populated.json --keys "?" --mouse "click:30,29") || fail "mouse click on help: render exited non-zero"
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
frame_m=$(render populated.json --mouse "click:30,29,x") || fail "mouse comma list: render exited non-zero"
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
assert_row "$frame_cw" '^│ passing  DRAFT      hyperion-ai#279   refactor\(helm\): read credentials from hyperion-secrets instead of the chart values +main  22d │$' "column widths: the 81-character title shows in full in the room BASE gave back"
assert_row "$frame_cw" '^│ hold   by 09-15  uuidv7-rfc-rewrite +Rewrite RFC-017 as thought leadership for the platform team +MatthewsREIS/gemini  main  37d │$' "column widths: a 19-character repository name is not cut and HOME hugs main"
assert_row "$frame_cw" '^│ hold   by 09-09  review-rfc-discussion-t…  Review RFC · Captain asked on 2026-09-02' "column widths: an id longer than the 24-cell cap truncates with an ellipsis (falsify: raise COLUMN_CAP)"
assert_row "$frame_cw" '^│ STATE  KEY       ID {24}WHAT ' "column widths: STATE stays as wide as its label when every value is shorter, KEY is as wide as by 09-15"
assert_widths "$frame_cw" 160 "column widths: lines are 160 columns"
assert_lines "$frame_cw" 40 "column widths: 40 lines"

# Dragging a boundary. populated.json at 160x40: Needs you's column header is line 2 and its columns
# start at x=2 STATE (7 wide), 11 KEY (9), 22 ID (13), 37 WHAT (96), 135 REPO (12), 149 HOME (4),
# 155 AGE (3), two blank cells between neighbours, so the ID/WHAT gutter is cells 35-36 and a left press
# on cells 34 to 37 takes that boundary. Ready for review's header is line 9 with CHECKS (8), STATUS
# (9), ID (10) and its ID/TITLE gutter at 33-34. In the header line a column W cells wide reads as its
# label followed by W blank cells (its padding plus the gutter) before the next label.
# A drag from 35 to 45 widens ID by ten cells and WHAT gives up exactly those ten: the columns right of
# WHAT keep their place and the line is still 160 cells (falsify: drop drag-move from applyAction, or
# size the flexible column before the overrides are applied).
assert_row "$frame" '^│ STATE    KEY        ID {13}WHAT {94}REPO' "before any drag ID is 13 wide, as wide as decide-vendor, and WHAT 96"
frame_d=$(render populated.json --mouse "drag:35,2->45") || fail "drag ID/WHAT: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {23}WHAT {84}REPO +HOME  AGE │$' "drag: ID is 23 wide, WHAT 86, and REPO, HOME and AGE are where they were"
assert_row "$frame_d" '^│ decide   db-choice  ship-alpha {15}Postgres or SQLite for the cache\? +acme/widgets  main   5m │$' "drag: the rows follow the header's widths"
assert_widths "$frame_d" 160 "drag: lines are still 160 columns"
assert_contains "$frame_d" "ID 23 wide · double-click the boundary resets it, = resets every column" "drag: the footer names the new width and both resets"
# The boundary is taken from one cell either side of its gutter and nowhere else (falsify: change
# BOUNDARY_REACH); only the header line has boundaries, a drag started on a row is a click on that row
# (falsify: put header geometry on row zones).
frame_d=$(render populated.json --mouse "drag:34,2->44") || fail "drag from ID's last cell: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {23}WHAT ' "a press on the last cell of ID, one cell before the gutter, drags the same boundary"
frame_d=$(render populated.json --mouse "drag:37,2->47") || fail "drag from WHAT's first cell: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {23}WHAT ' "a press on the first cell of WHAT, one cell after the gutter, drags the same boundary"
frame_d=$(render populated.json --mouse "drag:33,2->43") || fail "drag from two cells before the gutter: render exited non-zero"
if [ "$frame_d" = "$frame" ]; then pass; else fail "a press two cells before the gutter is a plain header click and resizes nothing: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_d") | head -n 5)"; fi
frame_d=$(render populated.json --mouse "drag:35,3->45") || fail "drag on a row: render exited non-zero"
frame_c=$(render populated.json --mouse "click:35,3") || fail "click on a row: render exited non-zero"
if [ "$frame_d" = "$frame_c" ]; then pass; else fail "a drag started on a row line selects the row and resizes nothing: $(diff <(printf '%s\n' "$frame_c") <(printf '%s\n' "$frame_d") | head -n 5)"; fi
# Clamps: a column never goes under its label width plus one, and never takes more than the flexible
# column can spare (falsify: drop min or max from boundaryAt, or the clamp from drag-move).
frame_d=$(render populated.json --mouse "drag:35,2->20") || fail "drag left past the minimum: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {3}WHAT ' "dragged 15 cells left, ID stops at 3, its label width plus one"
assert_row "$frame_d" '^│ blocked  -          sc…  blocked: gh auth expired' "the rows truncate to the three-cell ID"
assert_contains "$frame_d" "ID 3 wide" "the footer names the clamped width"
frame_d=$(render populated.json --mouse "drag:35,2->158") || fail "drag right past the maximum: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {104}WHAT   REPO' "dragged to the frame's edge, ID stops at 104 and WHAT keeps its five-cell minimum"
assert_row "$frame_d" '^│ hold     - +decide-vendor +Pick…  acme/api +main +3d │$' "the flexible column at its minimum shows four characters and the ellipsis"
assert_widths "$frame_d" 160 "clamped drag: lines are still 160 columns"
# The boundary beside the flexible column moves the fixed column on its other side, so the boundary
# still follows the pointer: WHAT/REPO dragged right narrows REPO (falsify: return null in boundaries()
# for a boundary whose left column is flexible, or drop sign).
frame_d=$(render populated.json --mouse "drag:133,2->143") || fail "drag WHAT/REPO: render exited non-zero"
assert_row "$frame_d" '^│ blocked  - +scout-beta +blocked: gh auth expired +acme…  main   2h │$' "dragging the WHAT/REPO boundary ten cells right narrows REPO to its five-cell minimum"
assert_contains "$frame_d" "REPO 5 wide" "the footer names REPO, the column that moved"
# Mid-drag, before the release, the boundary's first gutter cell draws a bar on the header and on
# every row of that pane, bold yellow with --tags, and nowhere else (falsify: drop the drag branch
# from gutterSegments, or the drag style from STYLE_TAGS).
frame_d=$(render populated.json --mouse "click:35,2 move:40,2") || fail "mid-drag: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {16}│ WHAT ' "mid-drag: the bar stands in the header's gutter at the pointer, ID 18 wide"
assert_row "$frame_d" '^│ blocked  -          scout-beta {8}│ blocked: gh auth expired' "mid-drag: the rows draw the bar in the same cell"
tags_d=$(render populated.json --mouse "click:35,2 move:40,2" --tags) || fail "mid-drag --tags: render exited non-zero"
assert_count "$tags_d" '{bold}{yellow-fg}│{/yellow-fg}{/bold}' 5 "mid-drag --tags: the bar is bold yellow on the header and the four rows of Needs you only"
frame_d=$(render populated.json --mouse "click:35,2 move:40,2 release:40,2") || fail "drag then release: render exited non-zero"
assert_not_contains "$frame_d" "│ WHAT" "after the release the bar is gone"
assert_row "$frame_d" '^│ STATE    KEY        ID {18}WHAT ' "after the release ID keeps its 18 cells"
frame_d=$(render populated.json --mouse "click:35,2 move:40,2" --keys "j") || fail "key mid-drag: render exited non-zero"
assert_not_contains "$frame_d" "│ WHAT" "a key pressed mid-drag ends the drag"
assert_row "$frame_d" '^│ STATE    KEY        ID {18}WHAT ' "a key pressed mid-drag keeps the width reached"
# A drag that comes back to where it started leaves no custom width behind (falsify: persist on every
# drag-end).
frame_d=$(render populated.json --mouse "click:35,2 move:45,2 move:35,2 release:35,2") || fail "drag back: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {13}WHAT ' "dragged out and back, ID is automatic again"
assert_not_contains "$frame_d" "wide" "dragged out and back, no width is announced"

# Persistence: the width goes to the view-state file on the release and a restart reads it back; the
# saved width pins the column when the data changes (falsify: drop columns from serializeViewState or
# loadViewState, or from persist in index.mjs).
vs_cols="$SCRATCH/view-state-columns.json"
rm -f "${vs_cols:?}"
frame_d=$(render populated.json --view-state "$vs_cols" --mouse "drag:35,2->45") || fail "drag with view state: render exited non-zero"
assert_file_contains "$vs_cols" '"needs": {' "the view-state file records the pane"
assert_file_contains "$vs_cols" '"id": 23' "the view-state file records the column and its width"
assert_file_contains "$vs_cols" '"hidden_panes": []' "the other view state is written beside it"
frame_d=$(render populated.json --view-state "$vs_cols") || fail "drag reload: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {23}WHAT ' "a restart reads the width back from the file"
frame_d=$(render column-widths.json --view-state "$vs_cols") || fail "drag reload other data: render exited non-zero"
assert_row "$frame_d" '^│ STATE  KEY       ID {23}WHAT ' "the saved width pins ID at 23 where the data alone would size it 24"
# A double-click on the boundary resets that column and drops it from the file (falsify: drop
# reset-column from mouseAction, or the persist from its case).
frame_d=$(render populated.json --view-state "$vs_cols" --mouse "dblclick:45,2") || fail "dblclick boundary: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {13}WHAT ' "a double-click on the moved boundary puts ID back to its automatic width"
assert_contains "$frame_d" "ID back to its automatic width" "the footer says so"
assert_file_not_contains "$vs_cols" '"id"' "the reset column is gone from the file"
frame_d=$(render populated.json --mouse "dblclick:35,2") || fail "dblclick automatic boundary: render exited non-zero"
assert_contains "$frame_d" "ID already has its automatic width" "a double-click on an automatic column says there is nothing to reset"
assert_row "$frame_d" '^│ STATE    KEY        ID {13}WHAT ' "and changes nothing"
# = resets every pane, from the board and from the Settings page, and says how many widths it
# dropped; the review pane's own column set resizes and resets the same way (falsify: drop the = case
# from keyAction, the reset-columns entry from settingsEntries, or the review pane's header geometry).
frame_d=$(render populated.json --view-state "$vs_cols" --mouse "drag:35,2->45 drag:33,9->43") || fail "two drags: render exited non-zero"
assert_row "$frame_d" '^│ CHECKS    STATUS     ID {20}TITLE ' "Ready for review's ID/TITLE boundary drags its ID to 20"
assert_file_contains "$vs_cols" '"review": {' "the review pane's width is saved under its own id"
frame_d=$(render populated.json --view-state "$vs_cols" --keys "=") || fail "reset all: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {13}WHAT ' "= resets Needs you's ID"
assert_row "$frame_d" '^│ CHECKS    STATUS     ID {10}TITLE ' "= resets Ready for review's ID"
assert_contains "$frame_d" "column widths reset: 2 custom widths dropped" "= counts the widths it dropped"
assert_file_not_contains "$vs_cols" '"id"' "= empties the saved widths"
frame_d=$(render populated.json --keys "=") || fail "reset none: render exited non-zero"
assert_contains "$frame_d" "no custom column widths to reset" "= with nothing to reset says so"
frame_d=$(render populated.json --view-state "$vs_cols" --mouse "drag:35,2->45" --keys ".,pagedown,enter,escape") || fail "settings reset: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {13}WHAT ' "the Settings page's last entry, Reset column widths, resets the board's columns"
assert_contains "$frame_d" "column widths reset: 1 custom width dropped" "the Settings entry reports through the same notice"
frame_s=$(render populated.json --keys ".") || fail "settings entry: render exited non-zero"
assert_row "$frame_s" '^   Reset column widths +every pane back to its automatic widths \(= on the board\) +$' "the Settings page lists the entry"
# A saved file naming a pane or column the board does not know, or a width that is not a positive
# integer, loses only that entry (falsify: drop sanitizeColumns from loadViewState).
printf '{"schema":"fm-board-view-state.v1","hidden":[],"hidden_panes":[],"columns":{"needs":{"id":30,"bogus":9},"nope":{"id":5},"review":{"id":"wide"}}}\n' > "$vs_cols"
frame_d=$(render populated.json --view-state "$vs_cols" --keys "tab,tab,tab,tab,x") || fail "hand-written columns: render exited non-zero"
assert_row "$frame_d" '^│ STATE    KEY        ID {30}WHAT ' "a saved width for a known pane and column applies"
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
frame_d=$(render populated.json --no-mouse --mouse "drag:35,2->45 dblclick:35,2 move:40,2 release:40,2") || fail "--no-mouse drag: render exited non-zero"
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
frame_d=$(render populated.json --mouse "drag:35,2->45,x") || fail "drag comma list: render exited non-zero"
assert_row "$frame_d" '^│ STATE +KEY +ID {23}WHAT ' "a comma-separated list keeps the drag token whole (STATE is narrower here: x hid the blocked row, so the widest state word is decide)"
assert_contains "$frame_d" "hidden scout-beta" "and reads the rest as keys"

# ----------------------------------------------------------- wrapper checks
# A fake herdr for the checks below, on HERDR_BIN_PATH and PATH: it logs every call to
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
# the header is drawn over the loading spinner before the snapshot lands. Needs python3 and the board's
# node_modules (npm ci in bin/firstmate-tui); without them the section is skipped with a note, not failed.
PTY="$ROOT/tests/pty-keys.py"
PTY_URL=https://github.com/acme/widgets/pull/41
PTY_TRACE="$SCRATCH/pty-opener-trace.log"
if command -v python3 >/dev/null 2>&1 && [ -d "$ROOT/bin/firstmate-tui/node_modules/neo-blessed" ]; then
  run_pty() { # <term> <name> <actions...>: the interactive board on a pty against the stand-in home, with every fake wired
    local term=$1 name=$2
    shift 2
    rm -f "${OPENER_LOG:?}" "${PTY_TRACE:?}" "${UPGRADE_LOG:?}" "${CURL_LOG:?}"
    FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" PATH="$FAKE_BIN:$PATH" \
      FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" FM_BOARD_TEST_OPENER_TRACE="$PTY_TRACE" FM_BOARD_TEST_UPGRADE_LOG="$UPGRADE_LOG" \
      FAKE_CURL_ROOT="$REL" FAKE_CURL_LOG="$CURL_LOG" \
      python3 "$PTY" --term "$term" --timeout 20 --capture "$SCRATCH/pty-$name.bin" "$@" -- \
      "$BOARD" run --no-herdr --no-prs --opener-cmd "$FAKE_OPENER" --install-root "$INSTALL" --curl-cmd "bash $ROOT/tests/fake-curl.sh" \
      > "$SCRATCH/pty-$name.out" 2>&1
  }
  pty_ok() { # <name> <label>: the driver saw every marker it waited for and the board exited on q
    if grep -q "not seen\|killed\|still running" "$SCRATCH/pty-$1.out"; then fail "$2: $(tr '\n' ';' < "$SCRATCH/pty-$1.out")"; else pass; fi
  }
  pty_terms=""
  for t in xterm-256color screen tmux-256color; do
    if infocmp "$t" >/dev/null 2>&1; then pty_terms="$pty_terms $t"; fi
  done
  [ -n "$pty_terms" ] || pty_terms=xterm-256color
  for t in $pty_terms; do
    # One 0x0d on the first Ready for review row (tab moves there once the row is drawn): exactly one opener
    # call, made by the board (the trace names one pid and the URL as the only argument).
    run_pty "$t" "cr-$t" "wait:$PTY_URL" "send:\t" "sleep:0.6" "send:\r" "wait:opened$PTY_URL" "sleep:0.4" "send:q" exit
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
  # 0x0d 0x0a (a terminal in newline mode) opens once: the linefeed is a separate key the board does not
  # bind. 0x0a alone opens nothing (falsify: bind linefeed to enter, which would double a CR LF).
  run_pty xterm-256color crlf "wait:$PTY_URL" "send:\t" "sleep:0.6" "send:\r\n" "wait:opened$PTY_URL" "sleep:0.4" "send:q" exit
  pty_ok crlf "pty: CR LF reaches the opened notice"
  assert_opened "$PTY_URL" "pty: CR LF on a PR row calls the opener exactly once"
  run_pty xterm-256color lf "wait:$PTY_URL" "send:\t" "sleep:0.6" "send:\n" "sleep:1.2" "send:q" exit
  pty_ok lf "pty: LF alone leaves the board running until q"
  assert_not_opened "pty: LF alone (ctrl-j) opens nothing"
else
  echo "note: the pseudo-terminal section was skipped; it needs python3 on PATH and bin/firstmate-tui/node_modules (npm ci in bin/firstmate-tui)"
fi

printf '%s checks, %s failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
