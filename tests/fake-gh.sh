#!/usr/bin/env bash
# tests/fake-gh.sh - stands in for the GitHub CLI when tests/fm-board.test.sh
# copies it to PATH as `gh`. It appends its argv to FM_BOARD_TEST_FETCH_LOG and
# answers `pr list --repo <owner/name>` with a canned PR list in gh's --json
# shape (every field the board asks for: title, base branch, draft flag,
# state, creation, merge and close times), so the suite can prove the board's
# own fetch (one call per candidate repository, the field list, the checks
# mapping, the PR age, the STATUS words and the 12-hour window on merged and
# closed PRs) without reaching GitHub. Any other call fails.
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

# A merge time of "now", so the merged PR below sits inside the 12-hour window
# whenever the suite runs (macOS and GNU date both take this format).
just_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

case "$repo" in
  acme/widgets)
    # ship-alpha's PR, opened in 2020 so its age reads as a large day count.
    printf '%s\n' '[{"number":41,"title":"Add the widget cache","url":"https://github.com/acme/widgets/pull/41","headRefName":"fm/ship-alpha","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"createdAt":"2020-01-01T00:00:00Z","isDraft":false,"state":"OPEN","mergedAt":null,"closedAt":null}]'
    ;;
  acme/api)
    # 8: a PR no task recorded, with a failing check. 9: merged just now, so it
    # is listed as MERGED. 10: closed in 2020, outside the window, so the
    # board's fetch drops it before the model sees it.
    printf '[%s,%s,%s]\n' \
      '{"number":8,"title":"Retry on 429","url":"https://github.com/acme/api/pull/8","headRefName":"retry-429","baseRefName":"main","reviewDecision":"CHANGES_REQUESTED","mergeable":"CONFLICTING","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}],"createdAt":"2020-01-01T00:00:00Z","isDraft":false,"state":"OPEN","mergedAt":null,"closedAt":null}' \
      "{\"number\":9,\"title\":\"Bump the retry budget\",\"url\":\"https://github.com/acme/api/pull/9\",\"headRefName\":\"bump-retry\",\"baseRefName\":\"main\",\"reviewDecision\":\"APPROVED\",\"mergeable\":\"UNKNOWN\",\"statusCheckRollup\":[{\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}],\"createdAt\":\"2020-01-01T00:00:00Z\",\"isDraft\":false,\"state\":\"MERGED\",\"mergedAt\":\"$just_now\",\"closedAt\":\"$just_now\"}" \
      '{"number":10,"title":"Old spike","url":"https://github.com/acme/api/pull/10","headRefName":"old-spike","baseRefName":"main","reviewDecision":"","mergeable":"UNKNOWN","statusCheckRollup":[],"createdAt":"2020-01-01T00:00:00Z","isDraft":false,"state":"CLOSED","mergedAt":null,"closedAt":"2020-02-01T00:00:00Z"}'
    ;;
  *)
    printf '[]\n'
    ;;
esac
