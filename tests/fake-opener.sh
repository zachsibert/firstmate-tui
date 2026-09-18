#!/usr/bin/env bash
# tests/fake-opener.sh - stands in for `open` / `xdg-open` under
# --opener-cmd in tests. Appends its arguments, one per line, to the file named
# by FM_BOARD_TEST_OPENER_LOG and exits 0. It never launches a browser. With
# FM_BOARD_TEST_OPENER_TRACE set as well, one line per invocation with its
# pid, its parent pid and the whole argv goes there too, so two calls from the
# board and one call that an opener repeats on its own tell apart.
set -u
[ -n "${FM_BOARD_TEST_OPENER_LOG:-}" ] || { echo "fake-opener: FM_BOARD_TEST_OPENER_LOG is not set" >&2; exit 2; }
printf '%s\n' "$@" >> "$FM_BOARD_TEST_OPENER_LOG"
[ -z "${FM_BOARD_TEST_OPENER_TRACE:-}" ] || printf 'pid=%s ppid=%s argv=%s\n' "$$" "$PPID" "$*" >> "$FM_BOARD_TEST_OPENER_TRACE"
