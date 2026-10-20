#!/usr/bin/env bash
# tests/fake-claude.sh - stands in for the claude CLI when tests/fm-board.test.sh
# copies it to PATH as `claude`. It answers the one call the board makes,
# `claude -p ... --system-prompt <prompt>` with the text on stdin between
# <item> and </item> (a Charted Next row) or <document> and </document> (a
# card or a report), the way lib/summary.mjs parses it:
#
#   row       WHAT: Summary of <the item's Title line>
#             WHY: <the item's Waits for line, else `fake why` when it has a
#                  Reason line, else ->
#   document  - Summary of <the document's first # heading, else its first line>
#             - Fake summary line two
#             - Fake summary line three
#
# Each call appends one line to FM_BOARD_TEST_CLAUDE_LOG when it is set:
# `claude <kind> <title> | <argv>`, the argv shell-quoted with the system
# prompt's text replaced by <prompt>, so a test can count calls per text and
# check the flags. FAKE_CLAUDE_FAIL makes it print one stderr line and exit
# 1; FAKE_CLAUDE_SLEEP sleeps that many seconds first; FAKE_CLAUDE_EMPTY
# prints nothing and exits 0.
set -u
input=$(cat)
args=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--system-prompt" ]; then args="$args <prompt>"; else args="$args $(printf '%q' "$a")"; fi
  prev=$a
done
case $input in
  "<item>"*) kind=row ;;
  "<document>"*) kind=doc ;;
  *) kind=unknown ;;
esac
if [ "$kind" = row ]; then
  title=$(printf '%s\n' "$input" | sed -n 's/^Title: //p' | head -n 1)
  why=$(printf '%s\n' "$input" | sed -n 's/^Waits for: //p' | head -n 1)
  if [ -z "$why" ]; then
    if printf '%s\n' "$input" | grep -q '^Reason: '; then why="fake why"; else why=-; fi
  fi
else
  title=$(printf '%s\n' "$input" | sed -n 's/^# //p' | head -n 1)
  [ -n "$title" ] || title=$(printf '%s\n' "$input" | sed -n '2p')
fi
[ -z "${FM_BOARD_TEST_CLAUDE_LOG:-}" ] || echo "claude $kind $title |$args" >> "$FM_BOARD_TEST_CLAUDE_LOG"
[ -z "${FAKE_CLAUDE_SLEEP:-}" ] || sleep "$FAKE_CLAUDE_SLEEP"
if [ -n "${FAKE_CLAUDE_FAIL:-}" ]; then
  echo "API Error: 401 authentication required" >&2
  exit 1
fi
[ -z "${FAKE_CLAUDE_EMPTY:-}" ] || exit 0
if [ "$kind" = row ]; then
  printf 'WHAT: Summary of %s\nWHY: %s\n' "$title" "$why"
else
  printf -- '- Summary of %s\n- Fake summary line two\n- Fake summary line three\n' "$title"
fi
