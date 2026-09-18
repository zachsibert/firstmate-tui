#!/usr/bin/env bash
# tests/fake-curl.sh - a stand-in for curl that serves GitHub from a directory.
#
# tests/install.test.sh copies this file to <dir>/curl and puts <dir> first on
# PATH, so bin/install.sh resolves and downloads releases without the network;
# tests/fm-board.test.sh passes it as `--curl-cmd` so the board's Settings
# page reads its release list offline. The curl shapes they use are answered
# from $FAKE_CURL_ROOT:
#
#   https://api.github.com/repos/<repo>/releases/latest        api/latest.json
#   https://api.github.com/repos/<repo>/releases?per_page=1    api/newest.json
#   https://api.github.com/repos/<repo>/releases[?per_page=N]  api/releases.json
#   https://github.com/<repo>/releases/download/<tag>/<asset>  download/<tag>/<asset>
#
# -o <file> writes the answer to that file, otherwise it goes to stdout. Every
# other flag (-fsSL, --retry N, --retry-delay N, -H <header>) is accepted and
# ignored. A URL with no file behind it exits 22, curl's own status for an
# HTTP error under -f. Each URL is appended to $FAKE_CURL_LOG when that is set.
set -u

out=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -H|--retry|--retry-delay) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
[ -n "$url" ] || { echo "fake-curl: no url" >&2; exit 2; }
[ -n "${FAKE_CURL_ROOT:-}" ] || { echo "fake-curl: FAKE_CURL_ROOT is not set" >&2; exit 2; }
[ -z "${FAKE_CURL_LOG:-}" ] || printf '%s\n' "$url" >> "$FAKE_CURL_LOG"

case "$url" in
  https://api.github.com/repos/*/releases/latest) file="$FAKE_CURL_ROOT/api/latest.json" ;;
  https://api.github.com/repos/*/releases\?per_page=1) file="$FAKE_CURL_ROOT/api/newest.json" ;;
  https://api.github.com/repos/*/releases|https://api.github.com/repos/*/releases\?*) file="$FAKE_CURL_ROOT/api/releases.json" ;;
  https://github.com/*/releases/download/*/*)
    rest=${url#https://github.com/}
    rest=${rest#*/*/releases/download/}
    file="$FAKE_CURL_ROOT/download/$rest" ;;
  *) echo "fake-curl: unexpected url $url" >&2; exit 22 ;;
esac
[ -f "$file" ] || { echo "fake-curl: 404 $url (no $file)" >&2; exit 22; }
if [ -n "$out" ]; then
  cp "$file" "$out"
else
  cat "$file"
fi
