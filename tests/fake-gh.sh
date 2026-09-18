#!/usr/bin/env bash
# tests/fake-gh.sh - stands in for the GitHub CLI when tests/fm-board.test.sh
# copies it to PATH as `gh`. It appends its argv to FM_BOARD_TEST_FETCH_LOG and
# answers `pr list --repo <owner/name>` with a canned open-PR list in gh's
# --json shape, createdAt included, so the suite can prove the board's own
# fetch (one call per candidate repository, the field list, the checks mapping
# and the PR age) without reaching GitHub. Any other call fails.
set -eu

echo "gh $*" >> "${FM_BOARD_TEST_FETCH_LOG:?}"

if [ "${1:-} ${2:-}" != "pr list" ]; then
  echo "fake gh: unsupported call: $*" >&2
  exit 1
fi

repo=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--repo" ]; then repo=$a; fi
  prev=$a
done

case "$repo" in
  acme/widgets)
    # ship-alpha's PR, opened in 2020 so its age reads as a large day count.
    printf '%s\n' '[{"number":41,"title":"Add the widget cache","url":"https://github.com/acme/widgets/pull/41","headRefName":"fm/ship-alpha","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"createdAt":"2020-01-01T00:00:00Z"}]'
    ;;
  acme/api)
    # A PR no task recorded, with a failing check.
    printf '%s\n' '[{"number":8,"title":"Retry on 429","url":"https://github.com/acme/api/pull/8","headRefName":"retry-429","reviewDecision":"CHANGES_REQUESTED","mergeable":"CONFLICTING","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}],"createdAt":"2020-01-01T00:00:00Z"}]'
    ;;
  *)
    printf '[]\n'
    ;;
esac
