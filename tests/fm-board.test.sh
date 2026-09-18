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
# the fake on PATH and no real viewer ever runs. Hidden rows and panes go to
# `--view-state <temp file>`. The r key is checked against a stand-in firstmate
# home whose bin/fm-fleet-snapshot.sh and bin/fm-bearings-snapshot.sh only log
# that they ran and print canned JSON, so a live --render-once with --keys r
# shows exactly which fetches a refresh triggers without GitHub or a real home.
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
# render_live [flags]: a one-shot render of the stand-in home (no fixture), fetch log reset first
render_live() {
  rm -f "$FETCH_LOG"
  FM_BOARD_TEST_FETCH_LOG="$FETCH_LOG" FM_HOME="$FAKE_HOME" XDG_CONFIG_HOME="$SCRATCH/xdg" "$BOARD" --render-once --no-herdr "$@"
}
assert_fetch_log() { # <expected lines> <label>
  if [ -f "$FETCH_LOG" ] && [ "$(cat "$FETCH_LOG")" = "$1" ]; then pass; else fail "$2: fetch log is '$(cat "$FETCH_LOG" 2>/dev/null || echo '<absent>')', expected '$1'"; fi
}

# ------------------------------------------------------------- populated
frame=$(render populated.json) || fail "populated: render exited non-zero"

# Pane order and counts (falsify: reorder PANES in lib/layout.mjs, or delete a row source in the fixture).
assert_contains "$frame" "Needs you (4)" "populated needs-you count (main home only)"
assert_contains "$frame" "Ready for review (2)" "populated review count"
assert_contains "$frame" "In flight (7)" "populated in-flight count (five main rows, two home groups)"
assert_contains "$frame" "Findings (3)" "populated findings count"
assert_contains "$frame" "Landed (4)" "populated landed count"
assert_before "$frame" "Needs you \(4\)" "Ready for review \(2\)" "pane order 1"
assert_before "$frame" "Ready for review \(2\)" "In flight \(7\)" "pane order 2"
assert_before "$frame" "In flight \(7\)" "Findings \(3\)" "pane order 3"
assert_before "$frame" "Findings \(3\)" "Landed \(4\)" "pane order 4"

# Freshness header on every pane (falsify: drop herdrLabel() from paneHeader in lib/model.mjs).
assert_count "$frame" "snapshot 12s ago · herdr fixture" 6 "title plus five pane headers carry snapshot age and herdr state"
assert_contains "$frame" "checks not fetched" "review header says checks not fetched without --prs"
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

# Ready for review without --prs (falsify: drop the "checks: not fetched" suffix in reviewRows).
assert_row "$frame" '^│ PR +#41 +ship-alpha +https://github.com/acme/widgets/pull/41 · checks: not fetched +acme/widgets +main +- │$' "recorded PR 41 row"
assert_row "$frame" '^│ PR +#7 +ship-gamma +https://github.com/acme/api/pull/7 · checks: not fetched' "recorded PR 7 row"
assert_not_contains "$frame" "passing" "no live check state without --prs"
# Finished work stays out (falsify: drop the taskBacklogState or the secondmate check in recordedPrs).
assert_no_row "$frame" '^│ PR +#30 ' "a task whose backlog row is done does not list its PR"
assert_no_row "$frame" '^│ PR +#12 ' "a PR mentioned on a secondmate record is not ready for review"

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

# Opening a PR: enter in Ready for review, on a Needs-you PR row and on a Landed row with a PR,
# through the injected opener only (falsify: drop the url field from reviewRows, the merge? row or
# landedRows, drop 'landed' from OPEN_PANES, or drop the 'open' case in keyAction). The opener
# receives the exact URL as its only argument.
frame_o=$(render_open populated.json "tab,enter") || fail "open review: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "enter on the first Ready for review row opens its PR"
assert_contains "$frame_o" "opened https://github.com/acme/widgets/pull/41 (ship-alpha)" "footer notice names the opened URL"
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

# --prs path (falsify: remove candidate_prs from the fixture or the enabled branch in reviewRows).
frame_prs=$(render populated.json --prs) || fail "populated --prs: render exited non-zero"
assert_contains "$frame_prs" "Ready for review (3)" "--prs adds the unrecorded candidate"
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
assert_row "$frame_narrow" '^── Needs you \(1\) · snapshot 12s ago · herdr fixture ─+$' "narrow: section header padded with dashes"
assert_contains "$frame_narrow" "── In flight (2)" "narrow: in-flight section"
assert_contains "$frame_narrow" "── Landed (1)" "narrow: landed section"
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
assert_contains "$frame_v" "r            refresh now: the snapshot, and the PR checks when --prs is on" "help overlay documents r"
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
frame_p=$(render populated.json --view-state "$vs" --keys "3") || fail "panes last: render exited non-zero"
assert_contains "$frame_p" "at least one pane stays visible" "the last visible pane cannot be hidden (falsify: drop the shown <= 1 guard)"
assert_count "$frame_p" "┌─" 1 "the last visible pane is still drawn"
frame_p=$(render populated.json --view-state "$vs" --keys "0") || fail "panes 0: render exited non-zero"
assert_count "$frame_p" "┌─" 5 "0 shows every pane again"
assert_contains "$frame_p" "all panes shown" "0 leaves a notice"
assert_not_contains "$frame_p" "panes hidden" "0 clears the title note"
assert_file_contains "$vs" '"hidden_panes": []' "0 empties the persisted list"
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
if grep -Fq -- "-firstmate" "$ROOT/bin/fm-board/herdr-plugin.toml"; then fail "herdr-plugin.toml still declares a firstmate pane action"; else pass; fi

# --------------------------------------------------------------- r refresh
# r is a full refresh: the snapshot, and with --prs an immediate PR fetch instead of waiting for the
# 120 s PR cadence. Both scripts log to FETCH_LOG; the start-up read is the first pair of lines.
frame_r=$(render_live --keys "r" --prs) || fail "refresh --prs: render exited non-zero"
assert_fetch_log "snapshot
prs --json --include-prs
snapshot
prs --json --include-prs" "r with --prs runs the snapshot and the PR fetch again (falsify: drop the prsNow / opts.prs branch from the refresh)"
assert_contains "$frame_r" "refreshed: snapshot and PR checks" "r with --prs reports both fetches"
frame_r=$(render_live --keys "r") || fail "refresh without --prs: render exited non-zero"
assert_fetch_log "snapshot
snapshot" "r without --prs runs only the snapshot again (falsify: call runBearingsPrs unconditionally)"
assert_contains "$frame_r" "checks not fetched: start with --prs" "r without --prs says why the PR pane did not change (falsify: drop the notice)"
frame_r=$(render populated.json --keys "r") || fail "refresh fixture: render exited non-zero"
assert_contains "$frame_r" "refresh is not available with --fixture" "r on a fixture render only reports"

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
