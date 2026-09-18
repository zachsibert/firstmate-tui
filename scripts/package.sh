#!/usr/bin/env bash
# scripts/package.sh - build the fm-board release tarball and its checksum.
#
#   scripts/package.sh <tag> <out-dir>              a release build
#   scripts/package.sh --commit <sha> <out-dir>     a per-commit (beta) build
#
# The release workflow (.github/workflows/release.yml) and the install test
# (tests/install.test.sh) both run this script, so the tarball a test installs
# is the tarball a release publishes. The one version source is the "version"
# in bin/fm-board/package.json.
#
# A release build takes the tag: it must be "v" plus that version (v0.1.0);
# anything else exits 2, which is how a wrong tag fails the release before
# anything is published. A per-commit build takes the commit instead and names
# itself: version <version>-<sha7> (0.1.0-d8b290e), tag v<version>-<sha7>. The
# staged copy's package.json (and lockfile) carry that full version, so an
# installed beta reports the version it really is; the source tree is not
# touched. Every per-commit build is a prerelease.
#
# Output files in <out-dir>:
#   fm-board-<tag>.tar.gz         unpacks to one directory, fm-board-<tag>/,
#                                 holding bin/fm-board.sh, bin/install.sh (so
#                                 `fm-board upgrade` can run the installer that
#                                 matches its own version), bin/fm-board/ with
#                                 its production node_modules (npm ci
#                                 --omit=dev, so an install needs no npm step),
#                                 README.md, and LICENSE when the repository
#                                 has one
#   fm-board-<tag>.tar.gz.sha256  its SHA-256 in sha256sum / shasum format
#
# stdout is key=value lines for the workflow ($GITHUB_OUTPUT): tag, version
# (the version the staged copy reports), prerelease (true when the version has
# a -suffix, so the release is marked as one), tarball and checksum (absolute
# paths). Everything else goes to stderr.
set -euo pipefail

usage() {
  sed -n '2,/^set -euo pipefail/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'package: %s\n' "$*" >&2
  exit 2
}

commit=''
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --commit)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    commit=$2
    out=$3
    ;;
  *)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    tag=$1
    out=$2
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PKG="$ROOT/bin/fm-board/package.json"

command -v npm >/dev/null 2>&1 || die "npm is required to vendor the production dependencies"
command -v node >/dev/null 2>&1 || die "node is required"

# ------------------------------------------------------------------ naming
source_version=$(node -p 'require(process.argv[1]).version' "$PKG") || die "could not read version from $PKG"
printf '%s' "$source_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' \
  || die "bin/fm-board/package.json version '$source_version' is not X.Y.Z or X.Y.Z-<prerelease>"
if [ -n "$commit" ]; then
  # A per-commit build: the seven-character short sha is the version suffix.
  printf '%s' "$commit" | grep -Eq '^[0-9a-f]{7,40}$' \
    || die "--commit '$commit' is not a git sha (7 to 40 lower-case hex characters)"
  sha7=${commit:0:7}
  version="$source_version-$sha7"
  tag="v$version"
else
  # A release build: the tag must be v plus the source version, exactly.
  printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' \
    || die "tag '$tag' is not of the form vX.Y.Z or vX.Y.Z-<prerelease> (for example v0.2.0 or v0.2.0-beta.1)"
  [ "$tag" = "v$source_version" ] \
    || die "tag $tag does not match bin/fm-board/package.json version $source_version (expected v$source_version): bump the version or fix the tag"
  version=$source_version
fi
prerelease=false
case "$version" in
  *-*) prerelease=true ;;
esac

# ---------------------------------------------------------------- staging
name="fm-board-$tag"
stage=$(mktemp -d "${TMPDIR:-/tmp}/fm-board-package.XXXXXX")
trap 'rm -rf -- "${stage:?}"' EXIT
mkdir -p "$stage/$name/bin"
cp "$ROOT/bin/fm-board.sh" "$stage/$name/bin/fm-board.sh"
cp "$ROOT/bin/install.sh" "$stage/$name/bin/install.sh"
cp -R "$ROOT/bin/fm-board" "$stage/$name/bin/fm-board"
# A checkout may carry a dev install; the tarball gets a fresh production one.
rm -rf -- "${stage:?}/$name/bin/fm-board/node_modules" "${stage:?}/$name/bin/fm-board/.gitignore"
cp "$ROOT/README.md" "$stage/$name/README.md"
[ -f "$ROOT/LICENSE" ] && cp "$ROOT/LICENSE" "$stage/$name/LICENSE"
(cd "$stage/$name/bin/fm-board" && npm ci --omit=dev --no-audit --no-fund --loglevel=error 1>&2) \
  || die "npm ci --omit=dev failed"
[ -f "$stage/$name/bin/fm-board/node_modules/neo-blessed/package.json" ] \
  || die "npm ci did not produce node_modules/neo-blessed"
chmod +x "$stage/$name/bin/fm-board.sh" "$stage/$name/bin/install.sh"

# A per-commit build stamps its full version into the staged copy, after npm
# ci so the lockfile check ran against the source version it was written for.
if [ "$version" != "$source_version" ]; then
  node -e '
    const fs = require("fs");
    const [dir, version] = process.argv.slice(1);
    for (const file of ["package.json", "package-lock.json"]) {
      const path = dir + "/" + file;
      if (!fs.existsSync(path)) continue;
      const json = JSON.parse(fs.readFileSync(path, "utf8"));
      json.version = version;
      if (json.packages && json.packages[""]) json.packages[""].version = version;
      fs.writeFileSync(path, JSON.stringify(json, null, 2) + "\n");
    }
  ' "$stage/$name/bin/fm-board" "$version" || die "could not stamp version $version into the staged package.json"
  staged=$(node -p 'require(process.argv[1]).version' "$stage/$name/bin/fm-board/package.json")
  [ "$staged" = "$version" ] || die "staged package.json reports $staged, expected $version"
fi

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
