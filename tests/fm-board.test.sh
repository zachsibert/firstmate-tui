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
# FM_BOARD_TEST_OPENER_LOG. No browser is ever launched.
#
# Fixtures (tests/fixtures/):
#   populated.json  160x40, every pane has rows: a blocked worker, a keyed
#                   decision, a live captain hold, a secondmate hold, a
#                   green-unmerged PR, recorded PRs, herdr statuses, a tmux
#                   task, a remote cached home, reports and landed rows
#   grouped.json    160x44, In flight grouping: two secondmate homes, one with
#                   four children (a keyed decision, a blocked child with a hold
#                   reason) plus live and dated captain holds, one quiet
#   empty.json      120x40, every pane empty, no herdr block
#   narrow.json     70x24, list mode with section headers, a cached local home
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BOARD="$ROOT/bin/fm-board.sh"
FIX="$ROOT/tests/fixtures"
FAKE_OPENER="bash $ROOT/tests/fake-opener.sh"
OPENER_LOG=$(mktemp "${TMPDIR:-/tmp}/fm-board-opener.XXXXXX")
rm -f "$OPENER_LOG"
trap 'rm -f "$OPENER_LOG"' EXIT

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

# ------------------------------------------------------------- populated
frame=$(render populated.json) || fail "populated: render exited non-zero"

# Pane order and counts (falsify: reorder PANES in lib/layout.mjs, or delete a row source in the fixture).
assert_contains "$frame" "Needs you (4)" "populated needs-you count (main home only)"
assert_contains "$frame" "Ready for review (2)" "populated review count"
assert_contains "$frame" "In flight (6)" "populated in-flight count (four main rows, two home groups)"
assert_contains "$frame" "Findings (3)" "populated findings count"
assert_contains "$frame" "Landed (4)" "populated landed count"
assert_before "$frame" "Needs you \(4\)" "Ready for review \(2\)" "pane order 1"
assert_before "$frame" "Ready for review \(2\)" "In flight \(6\)" "pane order 2"
assert_before "$frame" "In flight \(6\)" "Findings \(3\)" "pane order 3"
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
assert_row "$frame" '^│ working +1 live +!▸ hyperion ' "the home holding that decision is flagged with ! in In flight"
frame_all=$(render populated.json --all-homes-needs) || fail "populated --all-homes-needs: render exited non-zero"
assert_contains "$frame_all" "Needs you (5)" "--all-homes-needs adds the secondmate decision"
assert_row "$frame_all" '^│ hold +- +etl-cutover +Cut over the nightly ETL on Friday\? +acme/etl +hyperion +1d │$' "--all-homes-needs: secondmate captain hold row labelled with its home"
assert_before "$frame_all" '^│ hold +- +etl-cutover' '^│ merge\?' "--all-homes-needs: hold sorts before merge?"

# Ready for review without --prs (falsify: drop the "checks: not fetched" suffix in reviewRows).
assert_row "$frame" '^│ PR +#41 +ship-alpha +https://github.com/acme/widgets/pull/41 · checks: not fetched +acme/widgets +main +- │$' "recorded PR 41 row"
assert_row "$frame" '^│ PR +#7 +ship-gamma +https://github.com/acme/api/pull/7 · checks: not fetched' "recorded PR 7 row"
assert_not_contains "$frame" "passing" "no live check state without --prs"

# In flight rows: state, herdr join, tmux (falsify: remove the herdr agents block, or change
# tmux-task's endpoint target).
assert_row "$frame" '^│ STATE +HERDR +ID +WHAT +REPO +HOME +AGE │$' "in-flight column headers"
assert_row "$frame" '^│ working +working +ship-alpha +harness busy \(claude-hook\) +acme/widgets +main +5m │$' "task with herdr working and status-log age"
assert_row "$frame" '^│ blocked +blocked +scout-beta +\(scout\) gh auth expired +acme/api +main +2h │$' "task with herdr blocked"
assert_row "$frame" '^│ done +done +ship-gamma +PR https://github.com/acme/api/pull/7 checks green +acme/api +main +1m │$' "task with herdr done"
assert_row "$frame" '^│ working +tmux +tmux-task +running the migration +acme/legacy +main +- │$' "tmux-backed task shows tmux in HERDR"
assert_before "$frame" '^│ working +working +ship-alpha' '^│ blocked +blocked +scout-beta' "in flight: working sorts before blocked"
assert_before "$frame" '^│ blocked +blocked +scout-beta' '^│ done +done +ship-gamma' "in flight: blocked sorts before done"

# In flight groups, collapsed: one row per secondmate home with worst state, live count, child ids,
# shared repo and newest child age; the mate's own agent row is folded into its group (falsify:
# remove child-one from hyperion's active_children, w2A:p2 from the herdr block, or the mateTaskFor
# fold in inflightRows).
assert_row "$frame" '^│ working +1 live +!▸ hyperion +child-one, child-failed +acme/etl +hyperion +1h │$' "hyperion group: worst state working, one live worker, flagged, newest age 1h"
assert_row "$frame" '^│ working +1 live +▸ remote-sm +remote-child +acme/mobile +remote-sm \(remote\) +- │$' "remote home group row, not flagged"
assert_no_row "$frame" '^│ working +idle +hyperion ' "the secondmate agent row is folded into its group when collapsed"
assert_not_contains "$frame" "child-one  " "children are hidden while collapsed (id appears only in the group text)"
assert_not_contains "$frame" "↳" "no child rows while collapsed"
assert_before "$frame" '^│ working +1 live +!▸ hyperion' '^│ blocked +blocked +scout-beta' "a working group sorts with the working rows, before blocked"

# In flight groups, expanded with --expand all (falsify: drop the children list in ledgerGroup, or
# the etl-cutover decision from hyperion's decisions_open).
frame_x=$(render populated.json --expand all) || fail "populated --expand all: render exited non-zero"
assert_contains "$frame_x" "In flight (11)" "expanding both groups adds the mate rows, children and home decisions"
assert_row "$frame_x" '^│ working +1 live +!▾ hyperion +child-one, child-failed +acme/etl +hyperion +1h │$' "expanded group row shows ▾"
assert_row "$frame_x" '^│ working +idle +↳ hyperion +\(secondmate\) supervising two children +hyperion +main +- │$' "expanded: the secondmate agent row is the first child"
assert_row "$frame_x" '^│ working +working +↳ child-one +writing the loader +acme/etl +hyperion +3d │$' "expanded: active child with age from its home state file"
assert_row "$frame_x" '^│ failed +absent +↳ child-failed +endpoint default:w2B:p2 \(run-step\) +- +hyperion +1h │$' "expanded: failed endpoint child with no herdr agent"
assert_row "$frame_x" '^│ hold +- +↳ etl-cutover +Cut over the nightly ETL on Friday\? +acme/etl +hyperion +1d │$' "expanded: the home's live captain hold lists under the group"
assert_row "$frame_x" '^│ working +absent +↳ remote-child +porting the login screen +acme/mobile +remote-sm \(remote\) +- │$' "expanded: remote home child row labelled remote"
assert_before "$frame_x" '!▾ hyperion' '↳ child-one' "children follow their group row"
assert_before "$frame_x" '↳ etl-cutover' '▾ remote-sm' "the next group starts after the previous group's children"
assert_before "$frame_x" '↳ child-one' '↳ child-failed' "children sort working before failed"

# Findings (falsify: remove scout_reports[0], the mobile-fix report_path, or the report mtimes).
assert_row "$frame" '^│ scout +- +scout-beta +data/scout-beta/report.md +acme/api +main +10m │$' "scout report with age from the report mtime"
assert_row "$frame" '^│ report +reported +mobile-fix +data/mobile-fix/report.md +- +remote-sm \(remote\) +4d │$' "remote home report in findings"
assert_row "$frame" '^│ scout +reported +old-scout +data/old-scout/report.md +acme/legacy +main +10d │$' "older scout report with backlog verb"
assert_before "$frame" 'data/scout-beta/report.md' 'data/mobile-fix/report.md' "findings newest first (1)"
assert_before "$frame" 'data/mobile-fix/report.md' 'data/old-scout/report.md' "findings newest first (2)"

# Landed (falsify: change ship-old's state from done, or etl-index's completion date).
assert_row "$frame" '^│ merged +09-14 +ship-old +Rename the widget table · https://github.com/acme/widgets/pull/30 +acme/widgets +main +2d │$' "landed merged row with PR"
assert_row "$frame" '^│ merged +09-15 +etl-index +Add the ETL index · https://github.com/acme/etl/pull/12 +acme/etl +hyperion +1d │$' "secondmate landed row"
assert_row "$frame" '^│ reported +09-06 +old-scout +Scout: legacy import path +acme/legacy +main +10d │$' "reported row in landed"
assert_before "$frame" '^│ merged +09-15 +etl-index' '^│ merged +09-14 +ship-old' "landed newest first"

# Frame geometry (falsify: change the fixture cols/rows, or break padding in render.mjs).
assert_lines "$frame" 40 "populated frame is 40 lines"
assert_widths "$frame" 160 "populated frame lines are 160 columns"
assert_row "$frame" '^│ STATE +KEY +ID +WHAT +REPO +HOME +AGE │$' "wide layout keeps REPO and AGE"
assert_row "$frame" '^ j/k move  tab pane  enter open/focus  o open PR  l/h expand  r refresh  \? help  q quit +$' "footer keys"

# Keys through --render-once --keys (falsify: change keyAction in lib/controller.mjs).
frame_k=$(render populated.json --keys "tab,tab,j,j,l") || fail "keys l: render exited non-zero"
assert_row "$frame_k" '^│ working +1 live +!▾ hyperion ' "l on the third In flight row expands the hyperion group"
assert_contains "$frame_k" "↳ child-one" "expanded by key: child rows appear"
assert_contains "$frame_k" "In flight (10)" "expanded by key: only hyperion's rows are added"
assert_not_contains "$frame_k" "▾ remote-sm" "expanded by key: the other group stays collapsed"
frame_k=$(render populated.json --keys "tab,tab,j,j,l,j,h") || fail "keys h: render exited non-zero"
assert_not_contains "$frame_k" "▾" "h from a child row collapses its group"
assert_contains "$frame_k" "In flight (6)" "collapsed again by key"
frame_k=$(render populated.json --keys "tab,tab,j,j,enter") || fail "keys enter group: render exited non-zero"
assert_row "$frame_k" '^│ working +1 live +!▾ hyperion ' "enter on a group row expands it"
frame_k=$(render populated.json --keys "tab,tab,enter") || fail "keys enter worker: render exited non-zero"
assert_contains "$frame_k" "herdr is off (--no-herdr); cannot focus" "enter on an In flight worker still means herdr focus"
frame_k=$(render populated.json --keys "?") || fail "keys ?: render exited non-zero"
assert_contains "$frame_k" "o            open the PR of the selected row in the browser (any pane)" "help overlay documents o"
assert_contains "$frame_k" "l / right    expand the selected In flight group" "help overlay documents l/right"

# Opening a PR: enter in Ready for review, enter and o on a Needs-you PR row, through the injected
# opener only (falsify: drop the url field from reviewRows or the merge? row, or the 'open' case in
# keyAction). The opener receives the exact URL as its only argument.
frame_o=$(render_open populated.json "tab,enter") || fail "open review: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "enter on the first Ready for review row opens its PR"
assert_contains "$frame_o" "opened https://github.com/acme/widgets/pull/41 (ship-alpha)" "footer notice names the opened URL"
frame_o=$(render_open populated.json "j,j,j,enter") || fail "open needs enter: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/7" "enter on the Needs-you merge? row opens its PR"
frame_o=$(render_open populated.json "j,j,j,o") || fail "open needs o: render exited non-zero"
assert_opened "https://github.com/acme/api/pull/7" "o on the Needs-you merge? row opens its PR"
frame_o=$(render_open populated.json "tab,tab,o") || fail "open inflight o: render exited non-zero"
assert_opened "https://github.com/acme/widgets/pull/41" "o on an In flight worker with a recorded PR opens it"
frame_o=$(render_open populated.json "o") || fail "open no url: render exited non-zero"
assert_not_opened "o on a row without a PR URL calls no opener"
assert_contains "$frame_o" "scout-beta: no PR URL on this row" "o without a URL says so"
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
assert_before "$frame_prs" '^│ failing +changes' '^│ passing +review' "failing sorts before passing"

# Medium width: REPO and AGE drop below 100 columns (falsify: change WIDE_BREAKPOINT in lib/layout.mjs).
frame_med=$(render populated.json --cols 90 --rows 30) || fail "medium: render exited non-zero"
assert_contains "$frame_med" "Needs you (4)" "medium keeps five panes"
assert_row "$frame_med" '^│ STATE +HERDR +ID +WHAT +HOME +│$' "medium keeps the HERDR column and drops REPO and AGE"
assert_no_row "$frame_med" ' REPO +HOME' "medium drops REPO"
assert_no_row "$frame_med" ' HOME +AGE' "medium drops AGE"
assert_widths "$frame_med" 90 "medium frame lines are 90 columns"
assert_lines "$frame_med" 30 "medium frame is 30 lines"
assert_row "$frame_med" '^ j/k move  tab pane  enter  o open  l/h expand  r  \? help  q quit +$' "medium width uses the short footer"

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

# ----------------------------------------------------------- wrapper checks
# (falsify: delete the FM_HOME die() in bin/fm-board.sh, or the default case in lib/args.mjs)
if out=$(env -u FM_HOME "$BOARD" --render-once --no-herdr 2>&1); then
  fail "wrapper without FM_HOME should exit non-zero"
else
  pass
fi
if printf '%s\n' "$out" | grep -Fq "FM_HOME is not set"; then pass; else fail "wrapper names FM_HOME in its error: $out"; fi
if "$BOARD" --help 2>/dev/null | grep -Fq -- "--render-once"; then pass; else fail "wrapper --help lists --render-once"; fi
if "$BOARD" --help 2>/dev/null | grep -Fq -- "--keys"; then pass; else fail "wrapper --help lists --keys"; fi
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
