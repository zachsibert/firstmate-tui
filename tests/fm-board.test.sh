#!/usr/bin/env bash
# tests/fm-board.test.sh - behavior tests for fm-board through its executable
# interface: `bin/fm-board.sh --render-once --fixture <json> --no-herdr` prints
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
# `--mouse <list>` (click:X,Y, dblclick:X,Y, rclick:X,Y, wheel:up:X,Y,
# wheel:down:X,Y and key names, in order with --keys; X the column and Y the
# line, from 0 at the top-left cell), which feeds lib/controller.mjs
# handleMouse the same event objects the terminal adapter would, measured
# against the frame the app would have drawn, so no terminal library and no
# pointer is involved. Hidden rows and panes go to
# `--view-state <temp file>`. The r key is checked against a stand-in firstmate
# home whose bin/fm-fleet-snapshot.sh and bin/fm-bearings-snapshot.sh only log
# that they ran and print canned JSON, so a live --render-once with --keys r
# shows exactly which fetches a refresh triggers without GitHub or a real home.
# The refresh schedule itself (one tick runs both scripts; a tick during a
# running refresh is skipped) is checked by running the app with --headless
# against a second stand-in whose snapshot sleeps, then stopping it with a
# signal; --headless draws nothing, reads no key and never loads neo-blessed.
# The wrapper checks that touch the detached routes run with a fake `herdr` on
# HERDR_BIN_PATH and PATH (herdr sets HERDR_BIN_PATH inside its panes, so PATH
# alone would still reach the captain's live server); the fake logs its argv
# and fails, and the suite asserts it was never called.
#
# Fixtures (tests/fixtures/):
#   populated.json  160x40, every pane has rows: a blocked worker, a keyed
#                   decision, a live captain hold, a secondmate hold and a
#                   secondmate-relayed decision, a green-unmerged PR, a done
#                   task with a merged PR, recorded PRs, herdr statuses, a
#                   tmux task, a remote cached home, reports and landed rows
#   grouped.json    160x44, In flight grouping: two secondmate homes, one with
#                   four children (a keyed decision, a blocked child with a hold
#                   reason) plus live and dated captain holds, one quiet
#   empty.json      120x40, every pane empty, no herdr block
#   narrow.json     70x24, list mode with section headers, a cached local home
#   lost.json       160x40, a main worker and a secondmate child whose panes
#                   are absent from the herdr block (pane lost), a live one, a
#                   main scout report and a secondmate landed report
#   lost-disconnected.json  160x30, the same lost pane with herdr disconnected
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BOARD="$ROOT/bin/fm-board.sh"
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
    import { width } from '$ROOT/bin/fm-board/lib/text.mjs';
    let src = '';
    process.stdin.on('data', (d) => (src += d));
    process.stdin.on('end', () => {
      const lines = src.replace(/\n\$/, '').split('\n');
      const bad = lines.map((l, i) => [i + 1, width(l)]).filter(([, w]) => w !== $2);
      process.stdout.write(bad.map(([i, w]) => i + ':' + w).join(' '));
    });")
  if [ -z "$bad" ]; then pass; else fail "$3: lines with width != $2 -> $bad"; fi
}

render() { # <fixture> [extra flags...]
  local fixture=$1
  shift
  "$BOARD" --render-once --fixture "$FIX/$fixture" --no-herdr "$@"
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
# menu_items <frame>: how many right-click menu item lines the frame shows (a marker or space, a key,
# a label, the box edge); pane rows never match because their first cell is a state word, not a key
menu_items() {
  printf '%s\n' "$1" | grep -Ec '│[▸ ] (enter|l|h|x|X|H) +[a-zA-Z ]*[a-zA-Z] +│'
}
# render_mouse <fixture> <mouse list> [extra flags...]: render with --mouse, the fake opener and the
# fake viewer both recording (their logs reset first), so a gesture can never reach a browser or editor
render_mouse() {
  local fixture=$1 mouse=$2
  shift 2
  rm -f "${OPENER_LOG:?}" "${VIEWER_LOG:?}"
  FM_BOARD_TEST_OPENER_LOG="$OPENER_LOG" FM_BOARD_TEST_VIEWER_LOG="$VIEWER_LOG" "$BOARD" --render-once --fixture "$FIX/$fixture" --no-herdr --mouse "$mouse" --opener-cmd "$FAKE_OPENER" --viewer-cmd "$FAKE_VIEWER" "$@"
}
# render_live [flags]: a one-shot render of the stand-in home (no fixture), fetch log reset first
render_live() {
  rm -f "$FETCH_LOG"
  FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" "$BOARD" --render-once --no-herdr "$@"
}
# assert_fetch_log <expected lines, sorted> <label>: the snapshot and the PR fetch of one refresh start
# together, so their two log lines land in either order; the log is compared sorted.
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
assert_contains "$frame" "┌─ [1] Needs you (4) · snapshot 12s ago" "badge on Needs you"
assert_contains "$frame" "┌─ [2] Ready for review (3) · snapshot 12s ago" "badge on Ready for review"
assert_contains "$frame" "┌─ [3] In flight (7) · snapshot 12s ago" "badge on In flight"
assert_contains "$frame" "┌─ [4] Findings (3) · snapshot 12s ago" "badge on Findings"
assert_contains "$frame" "┌─ [5] Landed (4) · snapshot 12s ago" "badge on Landed"
assert_count "$frame" "┌─ [" 5 "exactly five badges, one per pane"
# With --tags the badge is its own grey segment between the border segments (falsify: give the badge the
# border style, or drop `badge` from STYLE_TAGS).
tags=$(render populated.json --tags) || fail "populated --tags: render exited non-zero"
assert_row "$tags" '\{blue-fg\}┌─ \{/blue-fg\}\{grey-fg\}\[2\]\{/grey-fg\}\{blue-fg\} Ready for review \(3\)' "--tags: the badge is grey and the title keeps the border color"
assert_count "$tags" "{grey-fg}[" 5 "--tags: five grey badges"

# Freshness header on every pane (falsify: drop herdrLabel() from paneHeader in lib/model.mjs).
assert_count "$frame" "snapshot 12s ago · herdr fixture" 6 "title plus five pane headers carry snapshot age and herdr state"
assert_contains "$frame" "checks 30s ago" "review header carries the PR data age by default (falsify: flip the prs default in parseArgs)"
assert_contains "$frame" "fm-board · /fixture/firstmate · 3 homes" "title counts the main home plus two secondmate homes"

# Needs you rows (falsify: remove scout-beta's blocked_event, ship-alpha's open_decisions entry,
# decide-vendor's hold_bucket=live, or ship-gamma's pr.url).
assert_row "$frame" '^│ blocked +- +scout-beta +blocked: gh auth expired +acme/api +main +2h │$' "blocked worker row with repo, home and age"
assert_row "$frame" '^│ decide +db-choice ship-alpha +Postgres or SQLite for the cache\? +acme/widgets +main +5m │$' "keyed decision row shows key, task, summary"
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
assert_row "$frame_all" '^│ decide +etl-wind… +hyperion +Which maintenance window for the ETL cutover\? +acme/etl +main +- │$' "--all-homes-needs: the relayed keyed decision on the secondmate record"
assert_before "$frame_all" '^│ hold +- +etl-cutover' '^│ merge\?' "--all-homes-needs: hold sorts before merge?"

# Ready for review with --no-prs: the recorded PRs only, tagged PR and marked off (falsify: drop the
# --no-prs case in parseArgs, or the !prs.enabled branch in unlistedChecks).
frame_noprs=$(render populated.json --no-prs) || fail "populated --no-prs: render exited non-zero"
assert_contains "$frame_noprs" "Ready for review (2)" "--no-prs lists the two recorded PRs only"
assert_contains "$frame_noprs" "· checks off" "--no-prs: the review header says checks off"
assert_row "$frame_noprs" '^│ PR +#41 +ship-alpha +https://github.com/acme/widgets/pull/41 · checks: off' "recorded PR 41 row"
assert_row "$frame_noprs" '^│ PR +#7 +ship-gamma +https://github.com/acme/api/pull/7 · checks: off \(--no-prs\) +acme/api +main +- │$' "recorded PR 7 row names the flag"
assert_not_contains "$frame_noprs" "passing" "no live check state with --no-prs"
assert_not_contains "$frame_noprs" "fetching" "--no-prs never says fetching"
# Finished work stays out (falsify: drop the taskBacklogState or the secondmate check in recordedPrs).
assert_no_row "$frame_noprs" '^│ PR +#30 ' "a task whose backlog row is done does not list its PR"
assert_no_row "$frame_noprs" '^│ PR +#12 ' "a PR mentioned on a secondmate record is not ready for review"

# In flight rows: state, herdr join, tmux (falsify: remove the herdr agents block, or change
# tmux-task's endpoint target).
assert_row "$frame" '^│ STATE +HERDR +ID +WHAT +REPO +HOME +AGE │$' "in-flight column headers"
assert_row "$frame" '^│ working +working +ship-alpha +harness busy \(claude-hook\) +acme/widgets +main +5m │$' "task with herdr working and status-log age"
assert_row "$frame" '^│ blocked +blocked +scout-beta +\(scout\) gh auth expired +acme/api +main +2h │$' "task with herdr blocked"
assert_row "$frame" '^│ awaiting merge +done +ship-gamma +PR https://github.com/acme/api/pull/7 checks green +acme/api +main +1m │$' "worker said done with an unmerged PR: STATE reads awaiting merge (falsify: drop awaitingMerge from mainTaskRow)"
assert_row "$frame" '^│ done +pane lost +ship-old +PR https://github.com/acme/widgets/pull/30 merged +acme/widgets +main +2d │$' "done task whose backlog row is done stays done; its closed pane reads pane lost"
assert_row "$frame" '^│ working +tmux +tmux-task +running the migration +acme/legacy +main +- │$' "tmux-backed task shows tmux in HERDR"
assert_row "$frame" '^│ STATE {10}KEY ' "STATE column widens to fit awaiting merge (falsify: fix the width in tagColumnWidth)"
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
assert_row "$frame_x" '^│ decide +etl-wind… +↳ hyperion +Which maintenance window for the ETL cutover\? +acme/etl +main +- │$' "expanded: the relayed keyed decision lists under the group (falsify: drop relayed from ledgerGroup)"
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
assert_row "$frame" '^ j/k move  tab pane  enter open/focus/view  l/h expand  x hide  H hidden  1-5 panes  r refresh  \? help  q quit +$' "footer keys"

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
assert_opened "https://github.com/acme/api/pull/8" "enter on the first Ready for review row (the failing live candidate) opens its PR"
assert_contains "$frame_o" "opened https://github.com/acme/api/pull/8 (api#8)" "footer notice names the opened URL"
frame_o=$(render_open populated.json "tab,j,enter") || fail "open review second row: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "enter on the second Ready for review row opens the recorded PR joined to its task"
assert_contains "$frame_o" "opened https://github.com/acme/widgets/pull/41 (ship-alpha)" "footer notice names the task, not the candidate"
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
assert_contains "$frame_o" "would open https://github.com/acme/api/pull/8" "without --opener-cmd, --render-once only reports the open"
assert_not_opened "without --opener-cmd nothing is launched"

# Live PR data (falsify: remove candidate_prs from the fixture or the enabled branch in reviewRows).
# --prs is accepted and changes nothing, since it is the default (falsify: give --prs an effect in
# parseArgs, or flip the default).
frame_prs=$(render populated.json --prs) || fail "populated --prs: render exited non-zero"
if [ "$frame_prs" = "$frame" ]; then pass; else fail "--prs renders a different frame from the default: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_prs") | head -n 5)"; fi
assert_contains "$frame_prs" "Ready for review (3)" "live PR data adds the unrecorded candidate"
assert_contains "$frame_prs" "checks 30s ago" "review header shows the checks age"
assert_row "$frame_prs" '^│ failing +changes +api#8 +https://github.com/acme/api/pull/8 · conflicting +acme/api +main +- │$' "failing candidate with review and mergeable"
assert_row "$frame_prs" '^│ passing +review +ship-alpha +https://github.com/acme/widgets/pull/41 +acme/widgets +main +- │$' "passing candidate joined to its task"
assert_row "$frame_prs" '^│ unlisted +#7 +ship-gamma +https://github.com/acme/api/pull/7 · checks: not fetched' "recorded PR missing from the live list"
assert_no_row "$frame_prs" '^│ (passing|failing|pending|none|unlisted|PR) +[^ ]+ +ship-old ' "a candidate GitHub reports MERGED is dropped (falsify: drop prClosed from reviewRows)"
assert_no_row "$frame_prs" '^│ (passing|failing|pending|none|unlisted|PR) +[^ ]+ +[^ ]+ +https://github.com/acme/widgets/pull/30' "the merged PR appears nowhere in Ready for review"
assert_before "$frame_prs" '^│ failing +changes' '^│ passing +review' "failing sorts before passing"

# Medium width: REPO and AGE drop below 100 columns (falsify: change WIDE_BREAKPOINT in lib/layout.mjs).
frame_med=$(render populated.json --cols 90 --rows 30) || fail "medium: render exited non-zero"
assert_contains "$frame_med" "Needs you (4)" "medium keeps five panes"
assert_row "$frame_med" '^│ STATE +HERDR +ID +WHAT +HOME +│$' "medium keeps the HERDR column and drops REPO and AGE"
assert_no_row "$frame_med" ' REPO +HOME' "medium drops REPO"
assert_no_row "$frame_med" ' HOME +AGE' "medium drops AGE"
assert_widths "$frame_med" 90 "medium frame lines are 90 columns"
assert_lines "$frame_med" 30 "medium frame is 30 lines"
assert_row "$frame_med" '^ j/k  tab  enter  l/h  x hide  H  1-5 panes  r  \? help  q quit +$' "medium width uses the short footer"

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
assert_count "$frame_empty" "herdr off" 6 "herdr off in the title and every pane header without a herdr block"
assert_contains "$frame_empty" "· 1 home " "empty board counts one home"
assert_widths "$frame_empty" 120 "empty frame lines are 120 columns"
assert_lines "$frame_empty" 40 "empty frame is 40 lines"

# ---------------------------------------------------------------- narrow
frame_narrow=$(render narrow.json) || fail "narrow: render exited non-zero"
# Section headers carry the same key badge as the pane titles (falsify: drop `badge` from the section
# entry in flattenRows, or the badge segment in renderList).
assert_row "$frame_narrow" '^── \[1\] Needs you \(1\) · snapshot 12s ago · herdr fixture ─+$' "narrow: section header with its badge, padded with dashes"
assert_contains "$frame_narrow" "── [2] Ready for review (0)" "narrow: review section badge"
assert_contains "$frame_narrow" "── [3] In flight (2)" "narrow: in-flight section badge"
assert_contains "$frame_narrow" "── [4] Findings (0)" "narrow: findings section badge"
assert_contains "$frame_narrow" "── [5] Landed (1)" "narrow: landed section badge"
assert_count "$frame_narrow" "── [" 5 "narrow: five badges, one per section"
assert_not_contains "$frame_narrow" "┌" "narrow: no pane borders"
assert_row "$frame_narrow" '^ STATE +ID +WHAT +HOME +$' "narrow: single shared column header without REPO, AGE or HERDR"
assert_row "$frame_narrow" '^ hold +decide-vendor +Pick the vendor for t… main +$' "narrow: hold row in list mode, text truncated to the flex column"
assert_row "$frame_narrow" '^ working +ship-alpha +harness busy \(claude-… main +$' "narrow: in-flight row"
assert_row "$frame_narrow" '^ working +▸ notes +notes-child +notes \(cached\) *$' "narrow: cached home group row in list mode"
frame_narrow_x=$(render narrow.json --expand all) || fail "narrow --expand all: render exited non-zero"
assert_row "$frame_narrow_x" '^ working +↳ notes-child +summarizing Monday +notes \(cached\) *$' "narrow expanded: cached home label on a ledger child"
assert_contains "$frame_narrow" "fm-board · firstmate · 2 homes" "narrow: title uses the home basename"
assert_widths "$frame_narrow" 70 "narrow frame lines are 70 columns"
assert_lines "$frame_narrow" 24 "narrow frame is 24 lines"

# --------------------------------------------------------------- grouped
frame_g=$(render grouped.json) || fail "grouped: render exited non-zero"

# No prs block in the fixture is the state before the first fetch of a session lands: the title and
# the recorded PR say fetching, never "not fetched" (falsify: drop the fetching branch in
# unlistedChecks or checksLabel).
assert_contains "$frame_g" "Ready for review (1) · snapshot 12s ago · herdr fixture · checks fetching" "grouped: review header says checks fetching before the first fetch"
assert_row "$frame_g" '^│ PR +#41 +ship-alpha +https://github.com/acme/widgets/pull/41 · checks: fetching +acme/widgets +main +- │$' "grouped: recorded PR row says checks fetching before the first fetch"
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
assert_row "$frame_ga" '^│ decide +cutover-… +etl-cutover-runbook +Cut over Friday or Monday\? +- +hyperion +- │$' "--all-homes-needs: keyed child decision"
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
  import { resolveViewer } from '$ROOT/bin/fm-board/lib/viewer.mjs';
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
assert_contains "$frame_d" "herdr disconnected (ECONNREFUSED)" "disconnected fixture: header carries the herdr state"
assert_row "$frame_d" '^│ working +unknown +ship-lost +adding the retry loop ' "disconnected: the missing pane reads unknown, not pane lost"
assert_row "$tags_d" '\{grey-fg\}unknown +\{/grey-fg\}' "disconnected: the unknown cell is grey"
assert_count "$tags_d" "{red-fg}" 0 "disconnected: nothing is red"
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
assert_contains "$frame_p" "fm-board keys" "? opens the help over the landing page"
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
assert_opened "https://github.com/acme/api/pull/8" "after hiding the selected pane, enter acts on the next shown pane"
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
if grep -Fq -- "-firstmate" "$ROOT/bin/fm-board/herdr-plugin.toml"; then fail "herdr-plugin.toml still declares a firstmate pane action"; else pass; fi

# --------------------------------------------------------------- r refresh
# r is the same refresh a timer tick runs: the fleet snapshot and the PR fetch, started together.
# Both scripts log to FETCH_LOG; the start-up read is one pair of lines and r adds the second.
frame_r=$(render_live --keys "r") || fail "refresh default: render exited non-zero"
assert_fetch_log "prs --json --include-prs
prs --json --include-prs
snapshot
snapshot" "r by default runs the snapshot and the PR fetch again (falsify: flip the prs default in parseArgs, or drop runBearingsPrs from refreshLive)"
assert_contains "$frame_r" "refreshed: snapshot and PR checks" "r reports both fetches"
frame_r=$(render_live --keys "r" --prs) || fail "refresh --prs: render exited non-zero"
assert_fetch_log "prs --json --include-prs
prs --json --include-prs
snapshot
snapshot" "--prs is a no-op: the same two pairs (falsify: make --prs disable or double the fetch)"
frame_r=$(render_live --keys "r" --no-prs) || fail "refresh --no-prs: render exited non-zero"
assert_fetch_log "snapshot
snapshot" "r with --no-prs runs only the snapshot again (falsify: call runBearingsPrs unconditionally)"
assert_contains "$frame_r" "PR checks off: start without --no-prs" "r with --no-prs says why the PR pane did not change (falsify: drop the notice)"
assert_not_contains "$frame_r" "fetching" "--no-prs: nothing reads fetching after r"
frame_r=$(render populated.json --keys "r") || fail "refresh fixture: render exited non-zero"
assert_contains "$frame_r" "refresh is not available with --fixture" "r on a fixture render only reports"
# A fixture render runs no script at all, whatever the prs default: with the stand-in home and the log
# in the environment, nothing is logged (falsify: call factsLive or refreshLive when a fixture is given).
rm -f "$FETCH_LOG"
FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" render populated.json --keys "r" >/dev/null || fail "fixture with FM_HOME: render exited non-zero"
if [ -f "$FETCH_LOG" ]; then fail "a fixture render ran a snapshot script: $(cat "$FETCH_LOG")"; else pass; fi

# ------------------------------------------------------------ refresh schedule
# The interactive schedule, run with --headless against a stand-in whose snapshot sleeps 7 s, with
# --refresh 5 (the minimum). From launch: the start refresh runs both scripts at once; the tick at
# 5 s lands while it is still running and is skipped; it finishes at 7 s; the tick at 10 s runs both
# again. Stopped at 12 s, the log holds two of each line (falsify: drop the `state.refreshing` skip
# in refresh, three PR fetches; never clear the flag, or start the interval only after the first
# refresh, one).
SLOW_HOME="$SCRATCH/firstmate-slow"
mkdir -p "$SLOW_HOME/bin"
# shellcheck disable=SC2016 # the fake expands $FM_BOARD_TEST_FETCH_LOG at run time, not here
printf '#!/usr/bin/env bash\necho snapshot >> "$FM_BOARD_TEST_FETCH_LOG"\nsleep 7\ncat "%s"\n' "$FAKE_HOME/snapshot.json" > "$SLOW_HOME/bin/fm-fleet-snapshot.sh"
cp "$FAKE_HOME/bin/fm-bearings-snapshot.sh" "$SLOW_HOME/bin/fm-bearings-snapshot.sh"
chmod +x "$SLOW_HOME/bin/fm-fleet-snapshot.sh" "$SLOW_HOME/bin/fm-bearings-snapshot.sh"
rm -f "$FETCH_LOG"
FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$SLOW_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" "$BOARD" --headless --refresh 5 --no-herdr > "$SCRATCH/headless.log" 2>&1 &
headless_pid=$!
sleep 12
kill "$headless_pid" 2>/dev/null
wait "$headless_pid" 2>/dev/null
headless_log=$(cat "$FETCH_LOG" 2>/dev/null || echo '<absent>')
if [ "$(grep -c '^snapshot$' "$FETCH_LOG" 2>/dev/null)" = 2 ]; then pass; else fail "headless schedule: expected two snapshot runs in 12 s, log is '$headless_log' (board output: $(cat "$SCRATCH/headless.log"))"; fi
if [ "$(grep -c '^prs --json --include-prs$' "$FETCH_LOG" 2>/dev/null)" = 2 ]; then pass; else fail "headless schedule: a tick during a running refresh must not start a second PR fetch, and the next tick must; log is '$headless_log' (board output: $(cat "$SCRATCH/headless.log"))"; fi
if [ -s "$SCRATCH/headless.log" ]; then fail "headless run wrote to the terminal: $(head -c 300 "$SCRATCH/headless.log")"; else pass; fi

# ------------------------------------------------------------------- mouse
# Cells are column,line from 0 at the top-left. In populated.json at 160x40 the lines are: 0 title,
# 1 Needs you title, 3-6 its rows (scout-beta, ship-alpha, decide-vendor, ship-gamma), 8 Ready for
# review title, 10-12 its rows (api#8, ship-alpha #41, ship-gamma #7), 14 In flight title, 15 its
# column header, 16-22 its rows (ship-alpha, tmux-task, remote-sm group, scout-beta, hyperion group,
# ship-gamma, ship-old), 26 Findings title, 28-30 its rows (scout-beta, mobile-fix, old-scout),
# 32 Landed title, 34-37 its rows (etl-index, ship-old, mobile-fix, old-scout), 39 footer.
#
# A left click selects: the pane gets the focus border and the row the inverse style, the same as
# tab/j/k would leave them (falsify: drop the 'select' case from applyAction, or the row zones from
# renderPanes).
tags_m=$(render populated.json --mouse "click:30,29" --tags) || fail "mouse click: render exited non-zero"
assert_row "$tags_m" '\{inverse\}report +\{/inverse\}.*mobile-fix' "click on the second Findings row selects it"
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
# A click on the title line or the footer changes nothing (falsify: give those lines a zone).
frame_m=$(render populated.json --mouse "click:30,0 click:30,39 rclick:30,39") || fail "mouse chrome click: render exited non-zero"
if [ "$frame_m" = "$frame" ]; then pass; else fail "a click on the title line or footer changed the frame: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_m") | head -n 5)"; fi
# The narrow list has zones too (falsify: drop the zones from renderList).
tags_m=$(render narrow.json --mouse "click:10,12" --tags) || fail "mouse narrow click: render exited non-zero"
assert_row "$tags_m" '\{inverse\}merged +\{/inverse\}.*ship-old' "list mode: a click on the Landed row selects it"
assert_row "$tags_m" '\{bold\}\{cyan-fg\}── .*\[5\].*Landed \(1\)' "list mode: the Landed section header takes the focus style"
frame_m=$(render narrow.json --mouse "rclick:10,7") || fail "mouse narrow rclick: render exited non-zero"
assert_contains "$frame_m" "│▸ enter  focus herdr pane │" "list mode: a right-click on the ship-alpha In flight row opens its menu"
assert_widths "$frame_m" 70 "list mode: the menu keeps the lines 70 columns"

# A double-click is enter on that row: two left clicks on one row within 400 ms, recognized in
# lib/controller.mjs, not by the terminal library (falsify: drop the lastClick check from mouseAction, or
# stamp the two dblclick events with different times in driveOnce).
frame_m=$(render_mouse populated.json "dblclick:30,11") || fail "mouse dblclick review: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "double-click on the second Ready for review row opens its PR, as enter does"
assert_contains "$frame_m" "opened https://github.com/acme/widgets/pull/41 (ship-alpha)" "double-click: the footer names the opened PR"
frame_m=$(render_mouse populated.json "click:30,11 click:30,11") || fail "mouse two clicks: render exited non-zero"
assert_not_opened "two single clicks a second apart on one row open nothing"
frame_m=$(render_mouse populated.json "click:30,10 click:30,11 click:30,11 click:30,10") || fail "mouse clicks on different rows: render exited non-zero"
assert_not_opened "clicks alternating between rows never make a double-click"
frame_m=$(render_mouse populated.json "dblclick:30,20") || fail "mouse dblclick group: render exited non-zero"
assert_row "$frame_m" '^│ decide +1 live +!▾ hyperion ' "double-click on the hyperion group row expands it"
assert_contains "$frame_m" "In flight (12)" "double-click on a group: only that group's rows are added"
assert_not_opened "double-click on a group row opens no PR"
frame_m=$(render_mouse populated.json "dblclick:60,28") || fail "mouse dblclick findings: render exited non-zero"
assert_viewed "/fixture/firstmate/data/scout-beta/report.md" "double-click on a Findings row views its report through --viewer-cmd"
frame_m=$(render_mouse populated.json "dblclick:30,16") || fail "mouse dblclick worker: render exited non-zero"
assert_contains "$frame_m" "herdr is off (--no-herdr); cannot focus" "double-click on an In flight worker means herdr focus, refused here as enter is"
assert_not_opened "double-click on a worker opens no PR"
assert_not_viewed "double-click on a worker views no report"

# The right-click menu: the row is selected and a box at the pointer lists that row's actions with their
# keys, the first highlighted with ▸, and nothing the keys would refuse (falsify: change rowActions, the
# labels in menuLabel, or the box format in overlayMenu).
frame_m=$(render_mouse populated.json "rclick:30,11") || fail "mouse rclick review: render exited non-zero"
assert_contains "$frame_m" "│▸ enter  open PR  │" "review row menu: enter opens the PR, highlighted"
assert_contains "$frame_m" "│  x      hide row │" "review row menu: x hides the row"
if [ "$(menu_items "$frame_m")" -eq 2 ]; then pass; else fail "review row menu: expected exactly two items, got $(menu_items "$frame_m")"; fi
assert_not_contains "$frame_m" "expand group" "review row menu: no group action on a PR row"
assert_not_contains "$frame_m" "show hidden rows" "review row menu: H is not offered while nothing is hidden"
assert_not_contains "$frame_m" "unhide all in pane" "review row menu: X is not offered while nothing is hidden"
assert_not_opened "right-click opens nothing by itself"
tags_m=$(render populated.json --mouse "rclick:30,11" --tags) || fail "mouse rclick --tags: render exited non-zero"
assert_row "$tags_m" '\{inverse\}passing +\{/inverse\}' "right-click selects the row it lands on (the box covers the row's ID cell)"
assert_row "$tags_m" '\{inverse\}▸ enter  open PR' "the highlighted menu item is drawn inverse (falsify: drop the selected style from overlayMenu)"
frame_m=$(render_mouse populated.json "rclick:30,20") || fail "mouse rclick group: render exited non-zero"
assert_contains "$frame_m" "│▸ l  expand group │" "collapsed group row menu: l expands, shown instead of the duplicate enter"
assert_contains "$frame_m" "│  x  hide row     │" "collapsed group row menu: x hides"
assert_no_row "$frame_m" '│[▸ ] enter ' "collapsed group row menu: no enter line (it would duplicate l)"
if [ "$(menu_items "$frame_m")" -eq 2 ]; then pass; else fail "collapsed group row menu: expected exactly two items, got $(menu_items "$frame_m")"; fi
assert_not_contains "$frame_m" "open PR" "collapsed group row menu: no PR action"
frame_m=$(render_mouse populated.json "rclick:60,23" --rows 48 --expand all) || fail "mouse rclick child: render exited non-zero"
assert_contains "$frame_m" "│▸ enter  focus herdr pane │" "child row menu: enter focuses the worker"
assert_contains "$frame_m" "│  h      collapse group   │" "child row menu: h collapses the group from a child"
assert_contains "$frame_m" "│  x      hide row         │" "child row menu: x hides"
frame_m=$(render_mouse populated.json "rclick:60,21" --rows 48 --expand all) || fail "mouse rclick expanded group: render exited non-zero"
assert_contains "$frame_m" "│▸ h  collapse group │" "expanded group row menu: h collapses"
assert_not_contains "$frame_m" "expand group" "expanded group row menu: no expand"
frame_m=$(render_mouse populated.json "rclick:60,28") || fail "mouse rclick findings: render exited non-zero"
assert_contains "$frame_m" "│▸ enter  view report │" "Findings row menu: enter views the report"
assert_contains "$frame_m" "│  x      hide row    │" "Findings row menu: x hides"
if [ "$(menu_items "$frame_m")" -eq 2 ]; then pass; else fail "Findings row menu: expected exactly two items, got $(menu_items "$frame_m")"; fi
assert_not_contains "$frame_m" "open PR" "Findings row menu: no PR action"
assert_not_viewed "right-click on a Findings row views nothing by itself"
frame_m=$(render_mouse populated.json "rclick:60,34") || fail "mouse rclick landed: render exited non-zero"
assert_contains "$frame_m" "│▸ enter  open PR  │" "Landed row with a PR: enter opens it"
assert_contains "$frame_m" "│  x      hide row │" "Landed row menu: x hides"
if [ "$(menu_items "$frame_m")" -eq 2 ]; then pass; else fail "Landed row menu: expected exactly two items, got $(menu_items "$frame_m")"; fi
frame_m=$(render_mouse populated.json "rclick:60,37") || fail "mouse rclick landed no url: render exited non-zero"
assert_contains "$frame_m" "│▸ x  hide row │" "Landed row without a PR: hide is the only action"
if [ "$(menu_items "$frame_m")" -eq 1 ]; then pass; else fail "Landed row without a PR: expected exactly one item, got $(menu_items "$frame_m")"; fi
assert_no_row "$frame_m" '│[▸ ] enter ' "Landed row without a PR: no enter line, since enter would only say no PR URL"
assert_lines "$frame_m" 40 "a menu opened on the last row is clamped into the frame (falsify: drop the top clamp in menuBox)"
assert_contains "$frame_m" "└──────────────┘5 panes  r refresh  ? help  q quit" "the clamped menu ends on the footer line"
frame_m=$(render_mouse populated.json "rclick:60,3") || fail "mouse rclick needs worker: render exited non-zero"
assert_contains "$frame_m" "│▸ enter  focus herdr pane │" "Needs-you worker row menu: enter focuses its herdr pane"
frame_m=$(render_mouse populated.json "rclick:60,6") || fail "mouse rclick needs pr: render exited non-zero"
assert_contains "$frame_m" "│▸ enter  open PR  │" "Needs-you merge? row menu: enter opens the PR"
frame_m=$(render_mouse populated.json "rclick:158,3") || fail "mouse rclick edge: render exited non-zero"
assert_widths "$frame_m" 160 "a menu opened at the right edge stays inside the frame (falsify: drop the left clamp in menuBox)"
assert_lines "$frame_m" 40 "a menu at the right edge keeps the frame 40 lines"
assert_contains "$frame_m" "│▸ enter  focus herdr pane │" "a menu at the right edge still lists its items"
# A right-click on empty space (a column header) focuses the pane and opens no menu (falsify: return
# 'open-menu' for a non-row hit).
tags_m=$(render populated.json --mouse "rclick:30,15" --tags) || fail "mouse rclick empty: render exited non-zero"
assert_row "$tags_m" '\{bold\}\{cyan-fg\}┌─ .*\[3\].*In flight \(7\)' "right-click on In flight's column header focuses In flight"
assert_not_contains "$tags_m" "hide row" "right-click on empty space opens no menu"
# The menu gains the unhide actions once something is hidden (falsify: drop the hiddenCount / hiddenRows
# conditions in rowActions).
frame_m=$(render_mouse populated.json "rclick:30,11 down enter rclick:30,11") || fail "mouse menu after hide: render exited non-zero"
assert_contains "$frame_m" "│  X      unhide all in pane │" "after hiding a row in the pane, X is offered"
assert_contains "$frame_m" "│  H      show hidden rows   │" "after hiding a row, H is offered"
frame_m=$(render_mouse populated.json "rclick:30,11 down enter H rclick:30,11") || fail "mouse menu on hidden row: render exited non-zero"
assert_contains "$frame_m" "│  x      unhide row         │" "on a hidden row shown by H, x unhides"
assert_contains "$frame_m" "│  H      hide hidden rows   │" "while hidden rows are shown, H reads hide hidden rows"

# Choosing from the menu presses the item's key, so the action runs through the one key handler
# (falsify: give runMenuItem its own switch, or drop the menu branch from handleKey).
frame_m=$(render_mouse populated.json "rclick:30,11 enter") || fail "mouse menu enter: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "enter on the highlighted first item opens the PR"
assert_not_contains "$frame_m" "│▸" "choosing an item closes the menu"
frame_m=$(render_mouse populated.json "rclick:30,11 down enter") || fail "mouse menu down enter: render exited non-zero"
assert_contains "$frame_m" "Ready for review (2, 1 hidden)" "down then enter runs the second item: the row is hidden"
assert_contains "$frame_m" "hidden ship-alpha" "down then enter: the hide notice names the row"
assert_not_opened "down then enter on a two-item menu opens no PR"
frame_m=$(render_mouse populated.json "rclick:30,11 down up enter") || fail "mouse menu down up enter: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "down then up moves the highlight back: enter opens the PR"
frame_m=$(render_mouse populated.json "rclick:30,11 j j j enter") || fail "mouse menu j past the end: render exited non-zero"
assert_contains "$frame_m" "Ready for review (2, 1 hidden)" "j past the last item stays on it (falsify: let moveMenu wrap)"
frame_m=$(render_mouse populated.json "rclick:30,11 down") || fail "mouse menu down: render exited non-zero"
assert_contains "$frame_m" "│▸ x      hide row │" "down moves the highlight to the second item"
assert_contains "$frame_m" "│  enter  open PR  │" "down: the first item is no longer highlighted"
frame_m=$(render_mouse populated.json "rclick:30,11 wheel:down:30,11") || fail "mouse menu wheel: render exited non-zero"
assert_contains "$frame_m" "│▸ x      hide row │" "the wheel moves the menu highlight while the menu is open"
frame_m=$(render_mouse populated.json "rclick:30,11 click:35,13") || fail "mouse menu click item: render exited non-zero"
assert_contains "$frame_m" "Ready for review (2, 1 hidden)" "a left click on the second item runs it (falsify: drop menuItemAt from handleMouse)"
assert_not_contains "$frame_m" "│▸" "a click on an item closes the menu"
frame_m=$(render_mouse populated.json "rclick:30,11 click:35,11") || fail "mouse menu click border: render exited non-zero"
assert_contains "$frame_m" "│▸ enter  open PR  │" "a click on the menu's border runs nothing and keeps the menu open"
# Dismissal: esc, or a left click anywhere outside, closes the menu and leaves the selection where the
# right-click put it; a right-click elsewhere moves the menu to that row (falsify: drop the escape case
# or the insideMenu check).
frame_m=$(render_mouse populated.json "rclick:30,11 escape") || fail "mouse menu esc: render exited non-zero"
assert_not_contains "$frame_m" "open PR" "esc closes the menu"
assert_not_opened "esc runs nothing"
tags_m=$(render populated.json --mouse "rclick:30,11 escape" --tags) || fail "mouse menu esc --tags: render exited non-zero"
assert_row "$tags_m" '\{inverse\}passing +\{/inverse\}.*ship-alpha' "after esc the right-clicked row stays selected"
frame_m=$(render_mouse populated.json "rclick:30,11 click:30,35") || fail "mouse menu click outside: render exited non-zero"
assert_not_contains "$frame_m" "open PR" "a click outside the menu closes it"
tags_m=$(render populated.json --mouse "rclick:30,11 click:30,35" --tags) || fail "mouse menu click outside --tags: render exited non-zero"
assert_row "$tags_m" '\{inverse\}passing +\{/inverse\}.*ship-alpha' "a click outside only closes: the selection does not move to the clicked row"
assert_no_row "$tags_m" '\{cyan-fg\}┌─ .*\[5\]' "a click outside only closes: Landed is not focused"
frame_m=$(render_mouse populated.json "rclick:30,11 rclick:60,28") || fail "mouse menu rclick elsewhere: render exited non-zero"
assert_contains "$frame_m" "│▸ enter  view report │" "a right-click on another row moves the menu there"
assert_not_contains "$frame_m" "open PR" "a right-click on another row closes the first menu"
# Any other key closes the menu and then means what it always means (falsify: swallow unknown keys in the
# menu branch of handleKey).
frame_m=$(render_mouse populated.json "rclick:30,11 x") || fail "mouse menu x: render exited non-zero"
assert_contains "$frame_m" "Ready for review (2, 1 hidden)" "x while the menu is open closes it and hides the selected row"
assert_not_contains "$frame_m" "│▸" "x while the menu is open closes it"
frame_m=$(render_mouse populated.json "rclick:30,11 ?") || fail "mouse menu ?: render exited non-zero"
assert_contains "$frame_m" "fm-board keys" "? while the menu is open closes it and shows the help"
assert_not_contains "$frame_m" "│▸" "? while the menu is open closes the menu"
# A click while the help is up closes it (falsify: ignore mouse events under view.help).
frame_m=$(render populated.json --keys "?" --mouse "click:30,29") || fail "mouse click on help: render exited non-zero"
assert_not_contains "$frame_m" "fm-board keys" "a click closes the help overlay"

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
assert_row "$tags_m" '\{inverse\}blocked ' "wheel down then up is back on the first row"

# --no-mouse: every gesture is ignored and the frame is the plain one (falsify: drop the opts.mouse guard
# in driveOnce, or make --no-mouse set anything but opts.mouse).
frame_m=$(render populated.json --no-mouse --mouse "click:30,29 dblclick:30,11 rclick:30,20 wheel:down:30,35") || fail "--no-mouse: render exited non-zero"
if [ "$frame_m" = "$frame" ]; then pass; else fail "--no-mouse changed the frame: $(diff <(printf '%s\n' "$frame") <(printf '%s\n' "$frame_m") | head -n 5)"; fi
frame_m=$(render_mouse populated.json "dblclick:30,11" --no-mouse) || fail "--no-mouse dblclick: render exited non-zero"
assert_not_opened "--no-mouse: a double-click opens nothing"
frame_m=$(render populated.json --no-mouse --mouse "rclick:30,11 down enter") || fail "--no-mouse keys in list: render exited non-zero"
assert_contains "$frame_m" "herdr is off (--no-herdr); cannot focus" "--no-mouse: the key tokens of the list still apply (down moved to a worker row, enter tried to focus it)"
assert_not_contains "$frame_m" "1 hidden" "--no-mouse: no menu opened, so down,enter hid nothing"
assert_not_contains "$frame_m" "│▸" "--no-mouse: no menu is drawn"
# The landing page has no mouse targets (falsify: give renderLanding zones).
frame_l=$(render populated.json --keys "1,2,3,4,5")
frame_m=$(render populated.json --keys "1,2,3,4,5" --mouse "click:30,20 rclick:30,20 dblclick:30,20 wheel:down:30,20") || fail "mouse on landing: render exited non-zero"
if [ "$frame_m" = "$frame_l" ]; then pass; else fail "mouse events changed the landing page: $(diff <(printf '%s\n' "$frame_l") <(printf '%s\n' "$frame_m") | head -n 5)"; fi

# The help lists the gestures (falsify: drop the mouse block from HELP_LINES).
frame_m=$(render populated.json --keys "?") || fail "mouse help: render exited non-zero"
assert_contains "$frame_m" "mouse (off with --no-mouse" "help overlay has a mouse section naming --no-mouse"
assert_contains "$frame_m" "click        select that row and focus its pane; a pane title focuses the pane" "help overlay documents click"
assert_contains "$frame_m" "double-click the same as enter on that row" "help overlay documents double-click"
assert_contains "$frame_m" "right-click  menu of the row's actions with their keys" "help overlay documents right-click"
assert_contains "$frame_m" "wheel        move the selection three rows in the focused pane" "help overlay documents the wheel"

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
assert_row "$out" '^fm-board: FM_HOME is not set\. In a terminal:  export FM_HOME=/path/to/firstmate   \(the directory holding bin/fm-fleet-snapshot\.sh\), then run this again\.$' "line 1 carries the export command"
assert_row "$out" '^fm-board: for a herdr plugin action, which carries no FM_HOME:  mkdir -p "\$\(herdr plugin config-dir firstmate\.board\)" && echo /path/to/firstmate > "\$\(herdr plugin config-dir firstmate\.board\)/fm-home"$' "line 2 carries the fm-home command in its herdr-less form"
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
# open runs in place: with the same flags it prints the frame run prints (falsify: drop the
# open -> run mapping after the argument loop, or route plain open to open_detached).
frame_run=$("$BOARD" run --render-once --fixture "$FIX/populated.json" --no-herdr) || fail "wrapper run: render exited non-zero"
frame_open=$("$BOARD" open --render-once --fixture "$FIX/populated.json" --no-herdr) || fail "wrapper open: render exited non-zero"
if [ -n "$frame_open" ] && [ "$frame_open" = "$frame_run" ]; then pass; else fail "open printed a different frame from run: $(diff <(printf '%s\n' "$frame_run") <(printf '%s\n' "$frame_open") | head -n 5)"; fi
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
# line in the header comment of bin/fm-board.sh).
help=$("$BOARD" --help 2>/dev/null)
if printf '%s\n' "$help" | grep -Fq -- "open --detached"; then pass; else fail "wrapper --help lists open --detached"; fi
if printf '%s\n' "$help" | grep -Eq -- 'open \[flags\] +same as run'; then pass; else fail "wrapper --help says plain open is run"; fi
if printf '%s\n' "$help" | grep -Fq -- "its own herdr pane"; then fail "wrapper --help still describes open as opening its own pane"; else pass; fi
# The manifest's palette action has no terminal to run in, so it carries --detached; the pane
# entry keeps running the board in place (falsify: edit either command in herdr-plugin.toml).
if grep -Fq -- '"open", "--detached"]' "$ROOT/bin/fm-board/herdr-plugin.toml"; then pass; else fail "herdr-plugin.toml open action carries --detached"; fi
if grep -Fq -- '"../fm-board.sh", "run"]' "$ROOT/bin/fm-board/herdr-plugin.toml"; then pass; else fail "herdr-plugin.toml pane entry runs the board in place"; fi
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

printf '%s checks, %s failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
