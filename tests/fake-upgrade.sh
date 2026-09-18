#!/usr/bin/env bash
# tests/fake-upgrade.sh - stands in for <prefix>/bin/firstmate-tui.sh when the
# Settings page runs an upgrade in tests. tests/fm-board.test.sh copies it to
# a fake install prefix as bin/firstmate-tui.sh and points the board at that prefix
# with --install-root, so `bash <prefix>/bin/firstmate-tui.sh upgrade ...` reaches
# this file and never the real launcher or bin/install.sh.
#
# It appends its arguments as one line to FM_BOARD_TEST_UPGRADE_LOG, prints
# the three progress lines install.sh prints (download, verify, swap) and
# exits 0; with FM_BOARD_TEST_UPGRADE_EXIT set to a non-zero status it prints
# an install.sh-style error to stderr instead of the swap line and exits with
# that status. It downloads, verifies and swaps nothing.
set -u
[ -n "${FM_BOARD_TEST_UPGRADE_LOG:-}" ] || { echo "fake-upgrade: FM_BOARD_TEST_UPGRADE_LOG is not set" >&2; exit 2; }
printf '%s\n' "$*" >> "$FM_BOARD_TEST_UPGRADE_LOG"
echo "install: downloading firstmate-tui-v0.2.0.tar.gz from acme/fm-board-test release v0.2.0"
echo "install: checksum verified"
if [ "${FM_BOARD_TEST_UPGRADE_EXIT:-0}" != 0 ]; then
  echo "install: error: checksum mismatch for firstmate-tui-v0.2.0.tar.gz: expected 'abc', got 'def'" >&2
  exit "$FM_BOARD_TEST_UPGRADE_EXIT"
fi
echo "install: firstmate-tui 0.2.0 installed (replaced 0.1.0)"
