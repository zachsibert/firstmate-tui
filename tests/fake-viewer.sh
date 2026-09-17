#!/usr/bin/env bash
# tests/fake-viewer.sh - stands in for glow / $EDITOR / vim / less in tests.
# Appends its arguments, one per line, to the file named by
# FM_BOARD_TEST_VIEWER_LOG and exits 0. It never takes over the terminal.
# The suite also installs it on PATH under the name `glow` to exercise the
# PATH lookup in lib/viewer.mjs.
set -u
[ -n "${FM_BOARD_TEST_VIEWER_LOG:-}" ] || { echo "fake-viewer: FM_BOARD_TEST_VIEWER_LOG is not set" >&2; exit 2; }
printf '%s\n' "$@" >> "$FM_BOARD_TEST_VIEWER_LOG"
