#!/usr/bin/env bash
# tests/fake-captain-hold.sh - stands in for <home>/bin/fm-captain-hold.sh in
# tests. tests/fm-board.test.sh copies it into the scratch homes its hold
# fixture names, so the board's d and D keys reach this file and never
# firstmate's real command. It appends one record per call to the file named
# by FM_BOARD_TEST_HOLD_LOG: the FM_HOME it was given, its working directory,
# its arguments, and the contents of the file after --decision-file when
# there is one (the board removes that file right after the command exits,
# so the log is the only place to read it back). It then answers as the real
# command does: `answered: <id>` for answer, the bare id for hold, exit 0.
# With FAKE_HOLD_FAIL set it prints one fixed refusal line to stderr and
# exits 1 instead, after logging the call. It edits nothing.
set -u
[ -n "${FM_BOARD_TEST_HOLD_LOG:-}" ] || { echo "fake-captain-hold: FM_BOARD_TEST_HOLD_LOG is not set" >&2; exit 2; }
{
  printf 'FM_HOME=%s\n' "${FM_HOME:-<unset>}"
  printf 'cwd=%s\n' "$PWD"
  printf 'argv=%s\n' "$*"
  prev=''
  for a in "$@"; do
    if [ "$prev" = --decision-file ]; then printf 'decision=%s\n' "$(cat "$a")"; fi
    prev=$a
  done
} >> "$FM_BOARD_TEST_HOLD_LOG"
if [ -n "${FAKE_HOLD_FAIL:-}" ]; then
  echo "fm-captain-hold: task ${2:-?} is not held for the captain; hold it first or name the right task" >&2
  exit 1
fi
case "${1:-}" in
  answer) echo "answered: ${2:-?}" ;;
  hold) echo "${2:-?}" ;;
  *) echo "fake-captain-hold: unknown subcommand ${1:-}" >&2; exit 2 ;;
esac
