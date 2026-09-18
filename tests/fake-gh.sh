#!/usr/bin/env bash
# tests/fake-gh.sh - stands in for the GitHub CLI when tests/fm-board.test.sh
# copies it to PATH as `gh`. It appends each call to FM_BOARD_TEST_FETCH_LOG
# and answers the two calls the board makes:
#
#   api user --jq .login     the logged-in login: FM_BOARD_TEST_GH_LOGIN
#                            (default captain), or a failure when
#                            FM_BOARD_TEST_GH_LOGIN_FAIL is set (not logged in)
#   api graphql -f query=... the board's searches and its recorded-PR lookup,
#     [-f q=... -F n=...]    dispatched on the search string in q (author:,
#                            review-requested:, is:open, closed:>=) or, without
#                            one, on the aliased repository(owner, name) {
#                            pullRequest(number) } fields in the query; each
#                            answer is the GraphQL shape the board reads
#                            (search.issueCount and nodes, or r<i>.pullRequest)
#
# Any other call, `pr list` above all, fails, so the old per-repository fetch
# cannot survive unnoticed. The log line for a search is `gh api graphql
# q=<search string>` with the closed:>= time stamp replaced by <since>, so a
# test can compare the whole log; a lookup logs the targets it was asked for.
#
# The canned PRs, for the login captain (the stand-in snapshot's candidate
# repositories are acme/widgets, acme/api and acme/etl, and the example
# config adds MatthewsREIS/gemini with the ready-to-merge rule):
#   My PRs open      captain/dotfiles#5, captain's own PR in a repository no
#                    fleet task touches; acme/api#12, captain's own PR that
#                    asks captain's team for a review (it is answered for the
#                    review-requested searches too, as GitHub would without
#                    the -author: term, and the board must drop it there);
#                    MatthewsREIS/gemini#6148, captain's own PR with the real
#                    PR 6148 rollup (SUPERSEDED below: six runs of one check,
#                    one cancelled and re-run), merge state BLOCKED and a
#                    review required: CHECKS must read passing and STATUS
#                    IN REVIEW, never failing
#   My PRs tail      acme/api#9, captain's PR merged at run time (inside the
#                    12-hour window); acme/api#10, closed in 2020 (the board's
#                    window filter drops it)
#   lookup           acme/widgets#41, ship-alpha's recorded PR, authored by
#                    the bot fm-bot (My PRs lists it through the union);
#                    acme/widgets#30, ship-old's PR merged in 2020 (dropped);
#                    anything else null, so ship-gamma's acme/api#7 stays a
#                    `-` row
#   To review open   MatthewsREIS/gemini#120 with the ready-to-merge label
#                    (listed) and #121 without (dropped by the label rule);
#                    acme/api#8 in a repository with no rule (listed, checks
#                    failing); acme/etl#15, a request to captain's team (the
#                    fake answering it for review-requested: is the contract),
#                    carrying the same SUPERSEDED rollup and BLOCKED state as
#                    gemini#6148 so the Teammates' PRs pane proves the rule too;
#                    acme/widgets#45, which captain already approved (STATUS
#                    APPROVED); and acme/api#12 from above (dropped: captain
#                    wrote it)
#   To review tail   acme/etl#14, merged at run time after captain's approval
# When the search string carries repo: qualifiers, only PRs in those
# repositories are answered, so a configured repository must be in the query
# to be listed. FM_BOARD_TEST_GH_CAPPED=1 reports issueCount 51 on every
# search, the way a capped search reads.
set -eu

log() { echo "gh $*" >> "${FM_BOARD_TEST_FETCH_LOG:?}"; }

case "${1:-} ${2:-}" in
  "api user")
    log "$@"
    if [ -n "${FM_BOARD_TEST_GH_LOGIN_FAIL:-}" ]; then
      echo "fake gh: not logged in to github.com" >&2
      exit 1
    fi
    printf '%s\n' "${FM_BOARD_TEST_GH_LOGIN:-captain}"
    exit 0
    ;;
  "api graphql") ;;
  *)
    log "$@"
    echo "fake gh: unsupported call: $*" >&2
    exit 1
    ;;
esac

# The -f/-F pairs: query=<graphql>, q=<search string>, n=<first>.
query=""
q=""
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    -f|-F)
      [ "$#" -ge 2 ] || { echo "fake gh: $1 needs a value" >&2; exit 1; }
      kv=$2
      case "${kv%%=*}" in
        query) query=${kv#*=} ;;
        q) q=${kv#*=} ;;
      esac
      shift
      ;;
  esac
  shift
done

# A merge time of "now", so the merged PRs below sit inside the 12-hour window
# whenever the suite runs (macOS and GNU date both take this format).
just_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# check <name> <workflow> <conclusion> <startedAt> <completedAt>: one completed
# CheckRun of GitHub Actions in the GraphQL shape GH_PR_FIELDS asks for (name,
# times, app and workflow), so the board can group re-runs of one check.
check() {
  printf '{"__typename":"CheckRun","name":"%s","status":"COMPLETED","conclusion":"%s","startedAt":"%s","completedAt":"%s","checkSuite":{"app":{"name":"GitHub Actions"},"workflowRun":{"workflow":{"name":"%s"}}}}' "$1" "$3" "$4" "$5" "$2"
}
PASSING="{\"contexts\":{\"nodes\":[$(check build CI SUCCESS 2020-01-01T00:01:00Z 2020-01-01T00:02:00Z)]}}"
FAILING="{\"contexts\":{\"nodes\":[$(check build CI FAILURE 2020-01-01T00:01:00Z 2020-01-01T00:02:00Z)]}}"
PENDING='{"contexts":{"nodes":[{"__typename":"StatusContext","context":"ci/lint","state":"PENDING","createdAt":"2020-01-01T00:01:00Z"}]}}'
# MatthewsREIS/gemini#6148's head commit as GitHub returned it on 2026-09-18:
# six runs of "check graphql schema (hive)", five SUCCESS and one CANCELLED
# (listed first, and superseded by the run that started 23 seconds later),
# beside one "merge check". Only the newest run of each check may count, so
# this rollup reads passing; judging every run reads failing.
hive='check graphql schema (hive)'
schema_wf='GraphQL Schema Check'
SUPERSEDED="{\"contexts\":{\"nodes\":[$(check "$hive" "$schema_wf" CANCELLED 2026-09-18T19:38:34Z 2026-09-18T19:38:39Z),$(check 'merge check' CI SUCCESS 2026-09-18T19:32:55Z 2026-09-18T19:33:00Z),$(check "$hive" "$schema_wf" SUCCESS 2026-09-18T19:33:17Z 2026-09-18T19:33:31Z),$(check "$hive" "$schema_wf" SUCCESS 2026-09-18T19:36:52Z 2026-09-18T19:36:58Z),$(check "$hive" "$schema_wf" SUCCESS 2026-09-18T19:38:57Z 2026-09-18T19:39:05Z),$(check "$hive" "$schema_wf" SUCCESS 2026-09-18T19:41:33Z 2026-09-18T19:41:39Z),$(check "$hive" "$schema_wf" SUCCESS 2026-09-18T19:42:10Z 2026-09-18T19:42:16Z)]}}"
NO_CHECKS='null'
NO_LABELS='[]'
READY='[{"name":"ready-to-merge"}]'
NO_REVIEWS='[]'
MY_APPROVAL='[{"state":"APPROVED","author":{"login":"captain"}}]'

# pr <repo> <number> <title> <head> <author> <state> <createdAt> <mergedAt json> <closedAt json> <labels json> <reviews json> <checks json> [reviewDecision] [isDraft] [mergeStateStatus]
pr() {
  printf '{"number":%s,"title":"%s","url":"https://github.com/%s/pull/%s","headRefName":"%s","baseRefName":"main","reviewDecision":"%s","mergeable":"MERGEABLE","mergeStateStatus":"%s","isDraft":%s,"state":"%s","createdAt":"%s","mergedAt":%s,"closedAt":%s,"author":{"login":"%s"},"repository":{"nameWithOwner":"%s"},"labels":{"nodes":%s},"latestReviews":{"nodes":%s},"commits":{"nodes":[{"commit":{"statusCheckRollup":%s}}]}}' \
    "$2" "$3" "$1" "$2" "$4" "${13:-REVIEW_REQUIRED}" "${15:-CLEAN}" "${14:-false}" "$6" "$7" "$8" "$9" "$5" "$1" "${10}" "${11}" "${12}"
}

# One line per canned PR: "<repo> <json>", so a search can filter on the repository.
mine_open() {
  printf '%s %s\n' captain/dotfiles "$(pr captain/dotfiles 5 'Tidy the zsh prompt' tidy-prompt captain OPEN 2020-01-01T00:00:00Z null null "$NO_LABELS" "$NO_REVIEWS" "$PASSING")"
  printf '%s %s\n' acme/api "$(pr acme/api 12 'Retry budget: ask the API team' team-review captain OPEN 2020-01-02T00:00:00Z null null "$NO_LABELS" "$NO_REVIEWS" "$PENDING")"
  printf '%s %s\n' MatthewsREIS/gemini "$(pr MatthewsREIS/gemini 6148 'Hide the Primary Sub Type row behind a feature flag' eng-2399-sub-type-flag captain OPEN 2020-01-03T00:00:00Z null null "$NO_LABELS" "$NO_REVIEWS" "$SUPERSEDED" REVIEW_REQUIRED false BLOCKED)"
}
mine_closed() {
  printf '%s %s\n' acme/api "$(pr acme/api 9 'Bump the retry budget' bump-retry captain MERGED 2020-01-01T00:00:00Z "\"$just_now\"" "\"$just_now\"" "$NO_LABELS" "$NO_REVIEWS" "$PASSING" APPROVED)"
  printf '%s %s\n' acme/api "$(pr acme/api 10 'Old spike' old-spike captain CLOSED 2020-01-01T00:00:00Z null '"2020-02-01T00:00:00Z"' "$NO_LABELS" "$NO_REVIEWS" "$NO_CHECKS" '')"
}
review_open() {
  printf '%s %s\n' MatthewsREIS/gemini "$(pr MatthewsREIS/gemini 120 'Gemini: index the parcel table' parcel-index teammate OPEN 2020-01-01T00:00:00Z null null "$READY" "$NO_REVIEWS" "$PASSING")"
  printf '%s %s\n' MatthewsREIS/gemini "$(pr MatthewsREIS/gemini 121 'Gemini: still cooking' cooking teammate OPEN 2020-01-01T00:00:00Z null null "$NO_LABELS" "$NO_REVIEWS" "$PASSING")"
  printf '%s %s\n' acme/api "$(pr acme/api 8 'Retry on 429' retry-429 teammate OPEN 2020-01-01T00:00:00Z null null "$NO_LABELS" "$NO_REVIEWS" "$FAILING" CHANGES_REQUESTED)"
  printf '%s %s\n' acme/etl "$(pr acme/etl 15 'ETL: nightly loader for the team' team-loader teammate OPEN 2020-01-01T00:00:00Z null null "$NO_LABELS" "$NO_REVIEWS" "$SUPERSEDED" REVIEW_REQUIRED false BLOCKED)"
  printf '%s %s\n' acme/widgets "$(pr acme/widgets 45 'Widget: approved by captain' approved-widget teammate OPEN 2020-01-01T00:00:00Z null null "$NO_LABELS" "$MY_APPROVAL" "$PASSING" APPROVED)"
  printf '%s %s\n' acme/api "$(pr acme/api 12 'Retry budget: ask the API team' team-review captain OPEN 2020-01-02T00:00:00Z null null "$NO_LABELS" "$NO_REVIEWS" "$PENDING")"
}
review_closed() {
  printf '%s %s\n' acme/etl "$(pr acme/etl 14 'ETL: merged after review' merged-loader teammate MERGED 2020-01-01T00:00:00Z "\"$just_now\"" "\"$just_now\"" "$NO_LABELS" "$MY_APPROVAL" "$PASSING" APPROVED)"
}

# lookup_pr <owner/name> <number>: the JSON of a recorded PR, or null.
lookup_pr() {
  case "$1#$2" in
    acme/widgets#41) pr acme/widgets 41 'Add the widget cache' fm/ship-alpha fm-bot OPEN 2020-01-01T00:00:00Z null null "$NO_LABELS" "$NO_REVIEWS" "$PASSING" ;;
    acme/widgets#30) pr acme/widgets 30 'Rename the widget table' fm/ship-old fm-bot MERGED 2020-01-01T00:00:00Z '"2020-03-01T00:00:00Z"' '"2020-03-01T00:00:00Z"' "$NO_LABELS" "$NO_REVIEWS" "$PASSING" APPROVED ;;
    *) printf 'null' ;;
  esac
}

# The lookup: aliases in the query's order, each answered by lookup_pr.
if [ -z "$q" ]; then
  targets=$(printf '%s' "$query" | grep -oE 'repository\(owner: "[^"]+", name: "[^"]+"\) \{ pullRequest\(number: [0-9]+\)' | sed -E 's/repository\(owner: "([^"]+)", name: "([^"]+)"\) \{ pullRequest\(number: ([0-9]+)\)/\1\/\2#\3/')
  [ -n "$targets" ] || { log "api graphql: no search string and no lookup in the query"; echo "fake gh: unsupported graphql query" >&2; exit 1; }
  log "api graphql lookup=$(printf '%s' "$targets" | tr '\n' ',' | sed 's/,$//')"
  out='{"data":{'
  i=0
  sep=''
  for t in $targets; do
    out="$out$sep\"r$i\":{\"pullRequest\":$(lookup_pr "${t%#*}" "${t#*#}")}"
    sep=','
    i=$((i + 1))
  done
  printf '%s}}\n' "$out"
  exit 0
fi

log "api graphql q=$(printf '%s' "$q" | sed -E 's/closed:>=[^ ]+/closed:>=<since>/')"

case "$q" in
  *review-requested:*) kind=review ;;
  *author:*) kind=mine ;;
  *) echo "fake gh: unsupported search: $q" >&2; exit 1 ;;
esac
case "$q" in
  *is:open*) when=open ;;
  *'closed:>='*) when=closed ;;
  *) echo "fake gh: search names neither is:open nor closed:>=: $q" >&2; exit 1 ;;
esac

# The repo: qualifiers, if any, limit the answer to those repositories.
repos=$(printf '%s' "$q" | grep -oE 'repo:[^ ]+' | sed 's/^repo://' || true)

nodes=''
sep=''
count=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  repo=${line%% *}
  json=${line#* }
  if [ -n "$repos" ] && ! printf '%s\n' "$repos" | grep -Fxq -- "$repo"; then continue; fi
  nodes="$nodes$sep$json"
  sep=','
  count=$((count + 1))
done <<EOF
$("${kind}_${when}")
EOF
issue_count=$count
[ -n "${FM_BOARD_TEST_GH_CAPPED:-}" ] && issue_count=51
printf '{"data":{"search":{"issueCount":%s,"nodes":[%s]}}}\n' "$issue_count" "$nodes"
