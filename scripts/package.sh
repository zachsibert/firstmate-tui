#!/usr/bin/env bash
# scripts/package.sh - build the fm-board release tarball and its checksum.
#
#   scripts/package.sh <tag> <out-dir>
#
# The release workflow (.github/workflows/release.yml) and the install test
# (tests/install.test.sh) both run this script, so the tarball a test installs
# is the tarball a release publishes. <tag> must be "v" plus the version in
# bin/fm-board/package.json (v0.1.0, v0.2.0-beta.1); anything else exits 2,
# which is how a mistyped tag fails the release before anything is published.
#
# Output files in <out-dir>:
#   fm-board-<tag>.tar.gz         unpacks to one directory, fm-board-<tag>/,
#                                 holding bin/fm-board.sh, bin/fm-board/ with
#                                 its production node_modules (npm ci
#                                 --omit=dev, so an install needs no npm step),
#                                 README.md, and LICENSE when the repository
#                                 has one
#   fm-board-<tag>.tar.gz.sha256  its SHA-256 in sha256sum / shasum format
#
# stdout is key=value lines for the workflow ($GITHUB_OUTPUT): tag, version,
# prerelease (true when the tag has a -suffix, so the release is marked as one),
# tarball and checksum (absolute paths). Everything else goes to stderr.
set -euo pipefail

usage() {
  sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'package: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -eq 2 ] || { usage >&2; exit 2; }
tag=$1
out=$2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PKG="$ROOT/bin/fm-board/package.json"

command -v npm >/dev/null 2>&1 || die "npm is required to vendor the production dependencies"
command -v node >/dev/null 2>&1 || die "node is required"

# ------------------------------------------------------------ tag == version
printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' \
  || die "tag '$tag' is not of the form vX.Y.Z or vX.Y.Z-<prerelease> (for example v0.2.0 or v0.2.0-beta.1)"
version=$(node -p 'require(process.argv[1]).version' "$PKG") || die "could not read version from $PKG"
[ "$tag" = "v$version" ] \
  || die "tag $tag does not match bin/fm-board/package.json version $version (expected v$version): bump the version or fix the tag"
prerelease=false
case "$tag" in
  *-*) prerelease=true ;;
esac

# ---------------------------------------------------------------- staging
name="fm-board-$tag"
stage=$(mktemp -d "${TMPDIR:-/tmp}/fm-board-package.XXXXXX")
trap 'rm -rf -- "${stage:?}"' EXIT
mkdir -p "$stage/$name/bin"
cp "$ROOT/bin/fm-board.sh" "$stage/$name/bin/fm-board.sh"
cp -R "$ROOT/bin/fm-board" "$stage/$name/bin/fm-board"
# A checkout may carry a dev install; the tarball gets a fresh production one.
rm -rf -- "${stage:?}/$name/bin/fm-board/node_modules" "${stage:?}/$name/bin/fm-board/.gitignore"
cp "$ROOT/README.md" "$stage/$name/README.md"
[ -f "$ROOT/LICENSE" ] && cp "$ROOT/LICENSE" "$stage/$name/LICENSE"
(cd "$stage/$name/bin/fm-board" && npm ci --omit=dev --no-audit --no-fund --loglevel=error 1>&2) \
  || die "npm ci --omit=dev failed"
[ -f "$stage/$name/bin/fm-board/node_modules/neo-blessed/package.json" ] \
  || die "npm ci did not produce node_modules/neo-blessed"
chmod +x "$stage/$name/bin/fm-board.sh"

# ------------------------------------------------------------------ output
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
tarball="$out/$name.tar.gz"
checksum="$tarball.sha256"
tar -czf "$tarball" -C "$stage" "$name"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$out" && sha256sum "$name.tar.gz" > "$checksum")
elif command -v shasum >/dev/null 2>&1; then
  (cd "$out" && shasum -a 256 "$name.tar.gz" > "$checksum")
else
  die "sha256sum or shasum is required to write the checksum"
fi

printf 'built %s (%s)\n' "$tarball" "$(du -h "$tarball" | cut -f1 | tr -d ' ')" >&2
printf 'tag=%s\nversion=%s\nprerelease=%s\ntarball=%s\nchecksum=%s\n' \
  "$tag" "$version" "$prerelease" "$tarball" "$checksum"
