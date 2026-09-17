#!/usr/bin/env bash
# tests/fake-opener.sh - stands in for `open` / `xdg-open` under
# --opener-cmd in tests. Appends its arguments, one per line, to the file named
# by FM_BOARD_TEST_OPENER_LOG and exits 0. It never launches a browser.
set -u
[ -n "${FM_BOARD_TEST_OPENER_LOG:-}" ] || { echo "fake-opener: FM_BOARD_TEST_OPENER_LOG is not set" >&2; exit 2; }
printf '%s\n' "$@" >> "$FM_BOARD_TEST_OPENER_LOG"
