#!/usr/bin/env bash
# tests/fake-node.sh - stands in for node on PATH when tests/fm-board.test.sh
# checks the relaunch loop of bin/firstmate-tui.sh run. The launcher probes the
# version with `node -p ...`, which this answers with 26; every other call
# (the board itself) is logged as one line to FM_BOARD_TEST_NODE_LOG and exits
# FM_BOARD_TEST_NODE_FIRST_EXIT (default 75, the board's relaunch status) on
# the first call and 0 on every later one, so the test can count how many
# times the launcher started the board. It runs no JavaScript.
set -u
if [ "${1:-}" = -p ]; then
  echo 26
  exit 0
fi
[ -n "${FM_BOARD_TEST_NODE_LOG:-}" ] || { echo "fake-node: FM_BOARD_TEST_NODE_LOG is not set" >&2; exit 2; }
printf 'node %s\n' "$*" >> "$FM_BOARD_TEST_NODE_LOG"
calls=$(wc -l < "$FM_BOARD_TEST_NODE_LOG" | tr -d ' ')
if [ "$calls" -eq 1 ]; then
  exit "${FM_BOARD_TEST_NODE_FIRST_EXIT:-75}"
fi
exit 0
