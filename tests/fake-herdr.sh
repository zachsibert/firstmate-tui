#!/usr/bin/env bash
# tests/fake-herdr.sh - stands in for the herdr CLI in tests of the firstmate
# pane toggle (fm-board.sh split-firstmate / unsplit-firstmate /
# toggle-firstmate). The suite installs it on PATH under the name `herdr`.
#
# Every call appends its argv, space-joined, as one line to
# FM_BOARD_TEST_HERDR_LOG. Read-only queries answer from canned JSON files:
#   agent list      -> contents of FM_BOARD_TEST_HERDR_AGENTS
#   pane get <id>   -> contents of FM_BOARD_TEST_HERDR_PANE
#   status --json   -> a socket path that does not exist
# pane move and agent focus answer an ok envelope and move nothing. Anything
# else exits 3 so an unexpected call fails the test loudly. No real herdr is
# ever reached.
set -u
[ -n "${FM_BOARD_TEST_HERDR_LOG:-}" ] || { echo "fake-herdr: FM_BOARD_TEST_HERDR_LOG is not set" >&2; exit 2; }
printf '%s\n' "$*" >> "$FM_BOARD_TEST_HERDR_LOG"
case "${1:-} ${2:-}" in
  "agent list") cat "${FM_BOARD_TEST_HERDR_AGENTS:?FM_BOARD_TEST_HERDR_AGENTS is not set}" ;;
  "pane get") cat "${FM_BOARD_TEST_HERDR_PANE:?FM_BOARD_TEST_HERDR_PANE is not set}" ;;
  "pane move"|"agent focus"|"workspace focus") printf '{"id":"fake","result":{"type":"ok"}}\n' ;;
  "status --json") printf '{"server":{"socket":"/nonexistent/fake-herdr.sock"}}\n' ;;
  "plugin list") printf 'No plugins installed.\n' ;;
  "plugin config-dir") printf '%s\n' "${FM_BOARD_TEST_HERDR_CONFIG_DIR:-/nonexistent/plugins/config/firstmate.board}" ;;
  *) echo "fake-herdr: unexpected call: $*" >&2; exit 3 ;;
esac
