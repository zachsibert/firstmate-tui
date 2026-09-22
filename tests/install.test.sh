#!/usr/bin/env bash
# tests/install.test.sh - the release tarball, the installer and upgrades, offline.
#
# scripts/package.sh builds the tarball the release workflow publishes
# (.github/workflows/release.yml runs that script and nothing else to build
# it), so this suite builds one into a scratch directory, installs it with
# `bin/install.sh --from-file` into a scratch prefix and bin dir, and proves
# the installed `firstmate-tui` command (and `fm-board`, the alias beside it)
# renders a frame from a fixture. It then builds a per-commit beta with
# `package.sh --commit` and swaps an install between the stable build and the
# beta in both directions through `firstmate-tui upgrade`, with
# tests/fake-curl.sh standing in for GitHub: it serves the releases API and
# the download URLs from a local directory, so the real channel logic in
# install.sh (--stable, --pre, --version) runs offline. Then it covers the
# two names the installer knows (AGENTS.md): the asset is
# firstmate-tui-<tag>.tar.gz with bin/firstmate-tui.sh and bin/firstmate-tui/
# inside since 0.3.0, and the installer still falls back to
# fm-board-<tag>.tar.gz and installs the old layout (bin/fm-board.sh with
# bin/fm-board/), checked against the real 0.2.5 tarball built from the
# v0.2.5 tag. Last it walks the upgrade chains with the installers from the
# tags: a 0.2.5 install reinstalled through the current installer, a 0.2.5
# install's own upgrade, and a 0.1.0 install reaching 0.2.5 by the old asset
# name and nothing newer. The installer reads the release's asset list first
# (/releases/tags/<tag>, api/tags/<tag>.json in a mirror) and tries both
# names only when that read fails, moving past any curl failure on the
# first; the 0.2.5 installer's stop on the exit-56 answer GitHub gives for a
# missing asset is reproduced through tests/fake-curl.sh's FAKE_CURL_FAIL.
# Nothing reaches GitHub: no tag, no release, no download. Each check's
# comment names what would make it fail.
#
# Needs node and npm (scripts/package.sh runs `npm ci --omit=dev` to vendor
# neo-blessed), plus tar and shasum or sha256sum, which the installer needs
# too, and the v0.1.0 and v0.2.5 tags in the clone (git fetch --tags origin).
# No firstmate home, herdr server or TTY.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PACKAGE="$ROOT/scripts/package.sh"
INSTALL="$ROOT/bin/install.sh"
BOARD="$ROOT/bin/firstmate-tui.sh"
FIX="$ROOT/tests/fixtures"
WORKFLOW="$ROOT/.github/workflows/release.yml"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-board-install-test.XXXXXX")
# Canonical, because package.sh and the installer print canonical paths and
# macOS hands out TMPDIR with a trailing slash under a /private symlink.
SCRATCH=$(cd "$SCRATCH" && pwd -P)
trap 'rm -rf -- "${SCRATCH:?}"' EXIT

VERSION=$(node -p 'require(process.argv[1]).version' "$ROOT/bin/firstmate-tui/package.json")
TAG="v$VERSION"
TAG_RE=${TAG//./\\.}
# The tarball is firstmate-tui-<tag>.tar.gz and unpacks to firstmate-tui-<tag>/.
DIRNAME="firstmate-tui-$TAG"

fails=0
checks=0
pass() { checks=$((checks + 1)); }
fail() {
  fails=$((fails + 1))
  checks=$((checks + 1))
  printf 'FAIL: %s\n' "$*" >&2
}

# assert_contains <text> <fixed string> <label>
assert_contains() {
  if printf '%s\n' "$1" | grep -Fq -- "$2"; then pass; else fail "$3: expected to find '$2'"; fi
}
assert_not_contains() {
  if printf '%s\n' "$1" | grep -Fq -- "$2"; then fail "$3: did not expect '$2'"; else pass; fi
}
# assert_match <text> <extended regex> <label>
assert_match() {
  if printf '%s\n' "$1" | grep -Eq -- "$2"; then pass; else fail "$3: nothing matches /$2/"; fi
}
assert_file() { if [ -f "$1" ]; then pass; else fail "$2: missing file $1"; fi; }
assert_exec() { if [ -x "$1" ]; then pass; else fail "$2: not executable: $1"; fi; }
assert_absent() { if [ -e "$1" ]; then fail "$2: unexpected path $1"; else pass; fi; }
assert_equal() { if [ "$1" = "$2" ]; then pass; else fail "$3: expected '$2', got '$1'"; fi; }
# assert_no_leftovers <dir> <label>: no staging or previous-install directory was left behind
assert_no_leftovers() {
  local left
  left=$(find "$1" -maxdepth 1 -name '.fm-board-*' 2>/dev/null)
  if [ -z "$left" ]; then pass; else fail "$2: leftover directories: $left"; fi
}
file_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# ------------------------------------------------------------- packaging
DIST="$SCRATCH/dist"
if pkg_out=$("$PACKAGE" "$TAG" "$DIST" 2>"$SCRATCH/package.err"); then pass; else fail "package.sh $TAG exited non-zero: $(cat "$SCRATCH/package.err")"; fi
TARBALL="$DIST/firstmate-tui-$TAG.tar.gz"
CHECKSUM="$TARBALL.sha256"
# The asset carries the new name and nothing is built under the old one
# (falsify: put asset=fm-board-$tag back in package.sh, or build both).
assert_file "$TARBALL" "the asset is named firstmate-tui-$TAG.tar.gz"
assert_absent "$DIST/fm-board-$TAG.tar.gz" "the old asset name is no longer built"
assert_absent "$DIST/fm-board-$TAG.tar.gz.sha256" "no checksum is written under the old asset name"
# stdout is only key=value lines because the workflow appends it to $GITHUB_OUTPUT (falsify: let npm ci write to stdout)
if printf '%s\n' "$pkg_out" | grep -Evq '^[a-z]+=' ; then fail "package.sh stdout has a line that is not key=value: $pkg_out"; else pass; fi
assert_contains "$pkg_out" "tag=$TAG" "package.sh reports the tag"
assert_contains "$pkg_out" "version=$VERSION" "package.sh reports the package.json version"
assert_contains "$pkg_out" "prerelease=false" "a release build is not a prerelease (falsify: flag every build as one)"
assert_contains "$pkg_out" "tarball=$TARBALL" "package.sh reports the tarball path"
assert_contains "$pkg_out" "checksum=$CHECKSUM" "package.sh reports the checksum path"
assert_file "$TARBALL" "the tarball exists"
assert_file "$CHECKSUM" "the checksum file exists"

listing=$(tar -tzf "$TARBALL")
tops=$(printf '%s\n' "$listing" | sed 's#/.*##' | sort -u)
if [ "$tops" = "$DIRNAME" ]; then pass; else fail "the tarball unpacks to one directory $DIRNAME, got: $(printf '%s' "$tops" | tr '\n' ' ') (falsify: tar the staging contents without the top directory, or name it after the asset)"; fi
assert_contains "$listing" "$DIRNAME/bin/firstmate-tui.sh" "the wrapper ships as bin/firstmate-tui.sh (falsify: copy it under another name in package.sh)"
assert_not_contains "$listing" "$DIRNAME/bin/fm-board" "no bin/fm-board path ships (falsify: stage the launcher or the package under the old name too)"
assert_contains "$listing" "$DIRNAME/bin/install.sh" "the installer ships beside the wrapper, so firstmate-tui upgrade runs the one that matches its version (falsify: drop the cp in package.sh)"
if [ "$(printf '%s\n' "$listing" | grep -c 'install.sh')" -eq 1 ]; then pass; else fail "install.sh ships once, at bin/install.sh: $(printf '%s\n' "$listing" | grep 'install.sh' | tr '\n' ' ')"; fi
assert_contains "$listing" "$DIRNAME/bin/firstmate-tui/index.mjs" "the entry point ships"
assert_contains "$listing" "$DIRNAME/bin/firstmate-tui/package.json" "package.json ships (the installer reads the version from it)"
assert_contains "$listing" "$DIRNAME/bin/firstmate-tui/package-lock.json" "the lockfile ships"
assert_contains "$listing" "$DIRNAME/bin/firstmate-tui/herdr-plugin.toml" "the herdr plugin manifest ships"
for f in "$ROOT"/bin/firstmate-tui/lib/*.mjs; do
  assert_contains "$listing" "$DIRNAME/bin/firstmate-tui/lib/$(basename "$f")" "every lib module ships (falsify: copy lib files by name in package.sh and miss one)"
done
assert_contains "$listing" "$DIRNAME/bin/firstmate-tui/node_modules/neo-blessed/package.json" "production node_modules are vendored (falsify: drop npm ci from package.sh)"
assert_contains "$listing" "$DIRNAME/README.md" "the README ships"
for unwanted in "/tests/" "/docs/" "/scripts/" "/.git" ".gitignore" "/.claude/" "install-record"; do
  assert_not_contains "$listing" "$unwanted" "the tarball carries no $unwanted (falsify: tar the repository root)"
done

assert_match "$(cat "$CHECKSUM")" "^[0-9a-f]{64}  firstmate-tui-$TAG_RE\.tar\.gz\$" "the checksum file is sha256sum format with the bare file name (falsify: hash the tarball by absolute path)"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$DIST" && sha256sum -c -- "firstmate-tui-$TAG.tar.gz.sha256") >/dev/null 2>&1
else
  (cd "$DIST" && shasum -a 256 -c -- "firstmate-tui-$TAG.tar.gz.sha256") >/dev/null 2>&1
fi
# shellcheck disable=SC2181 # the command above is a two-way branch; its status is what is tested
if [ "$?" -eq 0 ]; then pass; else fail "the checksum file verifies the tarball in -c mode, as the workflow checks it"; fi

# A tag that is not v<package.json version> is refused before anything is built
# (falsify: drop the tag = v$version check in package.sh).
if out=$("$PACKAGE" v9.9.9 "$SCRATCH/dist-bad" 2>&1); then fail "package.sh v9.9.9 against version $VERSION should exit non-zero"; else pass; fi
assert_contains "$out" "v9.9.9" "the mismatch error names the tag"
assert_contains "$out" "$VERSION" "the mismatch error names the package.json version"
assert_absent "$SCRATCH/dist-bad/firstmate-tui-v9.9.9.tar.gz" "nothing is built for a mismatched tag"
if out=$("$PACKAGE" "$VERSION" "$SCRATCH/dist-bad" 2>&1); then fail "a tag without the v prefix should be refused"; else pass; fi
assert_contains "$out" "vX.Y.Z" "the malformed-tag error shows the expected shape"

# A prerelease version: a copy of the tree at 0.2.0-beta.1 packages under
# v0.2.0-beta.1 and is flagged prerelease=true; v0.2.0 against it is refused.
PRE_VERSION=0.2.0-beta.1
PRE_TAG="v$PRE_VERSION"
PRE_REPO="$SCRATCH/pre-repo"
mkdir -p "$PRE_REPO/bin" "$PRE_REPO/scripts"
cp "$ROOT/bin/firstmate-tui.sh" "$PRE_REPO/bin/firstmate-tui.sh"
cp "$ROOT/bin/install.sh" "$PRE_REPO/bin/install.sh"
cp -R "$ROOT/bin/firstmate-tui" "$PRE_REPO/bin/firstmate-tui"
rm -rf -- "${PRE_REPO:?}/bin/firstmate-tui/node_modules"
cp "$PACKAGE" "$PRE_REPO/scripts/package.sh"
cp "$ROOT/README.md" "$PRE_REPO/README.md"
# Only the root version fields change: a dependency may share the package's
# version number (neo-blessed is 0.2.0), and a blanket substitution would put
# the lockfile out of step with package.json and fail npm ci.
stamp_version() { # <package dir> <version>: package.json and the lockfile's root entries
  node -e '
    const fs = require("fs");
    const [dir, version] = process.argv.slice(1);
    for (const file of ["package.json", "package-lock.json"]) {
      const path = dir + "/" + file;
      const json = JSON.parse(fs.readFileSync(path, "utf8"));
      json.version = version;
      if (json.packages && json.packages[""]) json.packages[""].version = version;
      fs.writeFileSync(path, JSON.stringify(json, null, 2) + "\n");
    }
  ' "$1" "$2"
}
stamp_version "$PRE_REPO/bin/firstmate-tui" "$PRE_VERSION"
if pre_out=$("$PRE_REPO/scripts/package.sh" "$PRE_TAG" "$SCRATCH/dist-pre" 2>"$SCRATCH/pre.err"); then pass; else fail "package.sh $PRE_TAG exited non-zero: $(cat "$SCRATCH/pre.err")"; fi
assert_contains "$pre_out" "prerelease=true" "a version with a -suffix is flagged as a prerelease for the workflow (falsify: drop the *-* case in package.sh)"
assert_contains "$pre_out" "version=$PRE_VERSION" "the prerelease version is reported"
assert_file "$SCRATCH/dist-pre/firstmate-tui-$PRE_TAG.tar.gz" "the prerelease tarball carries the full tag in its name"
if "$PRE_REPO/scripts/package.sh" v0.2.0 "$SCRATCH/dist-pre-bad" >/dev/null 2>&1; then fail "v0.2.0 against version $PRE_VERSION should be refused"; else pass; fi

# ------------------------------------------------------- per-commit build
# `package.sh --commit <sha>` names itself: version <version>-<sha7>, tag
# v<version>-<sha7>, always a prerelease. The staged package.json and lockfile
# carry the full version so an installed beta reports what it is; the source
# tree is left alone.
COMMIT_SHA=d8b290e6b1d1c3a4f5e6d7c8b9a0f1e2d3c4b5a6
SHA7=${COMMIT_SHA:0:7}
BETA_VERSION="$VERSION-$SHA7"
BETA_TAG="v$BETA_VERSION"
if beta_out=$("$PACKAGE" --commit "$COMMIT_SHA" "$DIST" 2>"$SCRATCH/beta.err"); then pass; else fail "package.sh --commit exited non-zero: $(cat "$SCRATCH/beta.err")"; fi
BETA_TARBALL="$DIST/firstmate-tui-$BETA_TAG.tar.gz"
BETA_CHECKSUM="$BETA_TARBALL.sha256"
assert_contains "$beta_out" "tag=$BETA_TAG" "a per-commit build is tagged v<version>-<7-char sha> (falsify: use the full sha)"
assert_contains "$beta_out" "version=$BETA_VERSION" "the reported version is <version>-<sha7>"
assert_contains "$beta_out" "prerelease=true" "every per-commit build is a prerelease (falsify: test the source version for '-')"
assert_contains "$beta_out" "tarball=$BETA_TARBALL" "the beta tarball carries the beta tag in its name"
assert_file "$BETA_TARBALL" "the beta tarball exists"
assert_file "$BETA_CHECKSUM" "the beta checksum file exists"
staged_pkg=$(tar -xzOf "$BETA_TARBALL" "firstmate-tui-$BETA_TAG/bin/firstmate-tui/package.json")
assert_contains "$staged_pkg" "\"version\": \"$BETA_VERSION\"" "the staged package.json carries the full beta version (falsify: skip the stamp)"
staged_lock=$(tar -xzOf "$BETA_TARBALL" "firstmate-tui-$BETA_TAG/bin/firstmate-tui/package-lock.json")
assert_contains "$staged_lock" "\"version\": \"$BETA_VERSION\"" "the staged lockfile carries the beta version too"
# Both root fields of the lockfile carry the beta version (a dependency's own
# "version" line is not the package's, so the fields are read, not grepped).
# shellcheck disable=SC2016 # the ${...} are JavaScript template fields, not shell expansions
lock_roots=$(printf '%s' "$staged_lock" | node -e 'let s = ""; process.stdin.on("data", (d) => (s += d)); process.stdin.on("end", () => { const j = JSON.parse(s); process.stdout.write(`${j.version} ${j.packages[""].version}`); });')
assert_equal "$lock_roots" "$BETA_VERSION $BETA_VERSION" "the staged lockfile's root version and packages[\"\"].version both say $BETA_VERSION (falsify: stamp only one of them)"
assert_contains "$(cat "$ROOT/bin/firstmate-tui/package.json")" "\"version\": \"$VERSION\"" "the source package.json is untouched (falsify: stamp the source tree instead of the staged copy)"
assert_contains "$(tar -tzf "$BETA_TARBALL")" "firstmate-tui-$BETA_TAG/bin/firstmate-tui/node_modules/neo-blessed/package.json" "the beta tarball is vendored like a release"
# A seven-character sha is enough; a non-sha is refused before anything is built.
if out=$("$PACKAGE" --commit "$SHA7" "$SCRATCH/dist-short" 2>/dev/null); then pass; else fail "package.sh --commit with a 7-char sha should work"; fi
assert_contains "$out" "tag=$BETA_TAG" "a short sha yields the same tag as the full one"
if out=$("$PACKAGE" --commit notasha "$SCRATCH/dist-bad" 2>&1); then fail "--commit notasha should exit non-zero"; else pass; fi
assert_contains "$out" "not a git sha" "the malformed-sha error says what a sha looks like"
assert_absent "$SCRATCH/dist-bad/firstmate-tui-v$VERSION-notasha.tar.gz" "nothing is built for a malformed sha"
if out=$("$PACKAGE" --commit "$SHA7" 2>&1); then fail "--commit without an out dir should exit non-zero"; else pass; fi
# A per-commit build of a source version that is itself a prerelease chains the suffixes.
if out=$("$PRE_REPO/scripts/package.sh" --commit "$COMMIT_SHA" "$SCRATCH/dist-pre-commit" 2>/dev/null); then pass; else fail "package.sh --commit on a prerelease source version should work"; fi
assert_contains "$out" "tag=v$PRE_VERSION-$SHA7" "a beta of a prerelease source version is v<version>-<suffix>-<sha7>"

# -------------------------------------------------------------- install
PREFIX="$SCRATCH/prefix"
BIN="$SCRATCH/bin"
if inst_out=$("$INSTALL" --from-file "$TARBALL" --prefix "$PREFIX" --bin-dir "$BIN" 2>&1); then pass; else fail "install.sh --from-file exited non-zero: $inst_out"; fi
assert_contains "$inst_out" "checksum verified" "the .sha256 beside a local tarball is verified (falsify: skip verification under --from-file)"
assert_contains "$inst_out" "firstmate-tui $VERSION installed" "the report names the installed version under the new name (falsify: stop reading package.json in the installer)"
assert_contains "$inst_out" "files:   $PREFIX" "the report names the prefix"
assert_contains "$inst_out" "command: $BIN/firstmate-tui" "the report names the firstmate-tui command"
assert_contains "$inst_out" "$BIN/fm-board" "the report names the fm-board alias too"
assert_contains "$inst_out" "$BIN is not on your PATH" "a bin dir that is not on PATH gets the one-line note (falsify: drop the PATH check)"
assert_contains "$inst_out" "next: export FM_HOME" "a first install gets the next-step line"
assert_file "$PREFIX/bin/firstmate-tui.sh" "the wrapper is installed"
assert_exec "$PREFIX/bin/firstmate-tui.sh" "the wrapper is executable"
assert_file "$PREFIX/bin/install.sh" "the installer is installed beside the wrapper"
assert_exec "$PREFIX/bin/install.sh" "the installed installer is executable"
assert_file "$PREFIX/bin/firstmate-tui/index.mjs" "the entry point is installed"
assert_file "$PREFIX/bin/firstmate-tui/node_modules/neo-blessed/package.json" "the vendored dependency is installed"
assert_file "$PREFIX/README.md" "the README is installed"
assert_exec "$BIN/firstmate-tui" "the firstmate-tui command is executable"
assert_contains "$(cat "$BIN/firstmate-tui")" "$PREFIX/bin/firstmate-tui.sh" "the command runs the installed wrapper, not the checkout (falsify: point the shim at the checkout)"
# The former name is written beside it for one release (falsify: drop the
# second write_command call in install.sh).
assert_exec "$BIN/fm-board" "the fm-board alias is executable"
assert_contains "$(cat "$BIN/fm-board")" "$PREFIX/bin/firstmate-tui.sh" "the alias runs the same installed wrapper"
assert_contains "$(cat "$BIN/fm-board")" "former name" "the alias says it is the former name"
assert_not_contains "$(cat "$BIN/firstmate-tui")" "former name" "the firstmate-tui command is not marked as an alias"
assert_no_leftovers "$SCRATCH" "a successful install leaves no staging directory"
# The install record names the prefix, bin dir and repository for
# firstmate-tui upgrade (falsify: write it after the swap, or leave a field out).
assert_file "$PREFIX/install-record" "the install record is written under the prefix"
record=$(cat "$PREFIX/install-record")
assert_contains "$record" "prefix=$PREFIX" "the record names the prefix"
assert_contains "$record" "bin_dir=$BIN" "the record names the bin dir"
assert_contains "$record" "repo=zachsibert/firstmate-tui" "the record names the default repository"
assert_contains "$record" "version=$VERSION" "the record names the installed version"
assert_contains "$record" "installed_from=file $TARBALL" "the record names the tarball a --from-file install came from"
assert_contains "$record" "layout=firstmate-tui" "the record names the layout that was installed (falsify: leave layout= out of the record)"

# The installed command renders a frame from a fixture, from an unrelated
# working directory (falsify: leave lib/ out of the tarball, or make the shim
# a symlink so firstmate-tui.sh resolves ROOT to the bin dir).
if frame=$(cd / && "$BIN/firstmate-tui" --render-once --fixture "$FIX/populated.json" --no-herdr 2>&1); then pass; else fail "installed firstmate-tui --render-once exited non-zero: $frame"; fi
assert_contains "$frame" "Captain's Call (6)" "the installed command prints the Captain's Call pane"
assert_contains "$frame" "Underway" "the installed command prints the Underway pane"
assert_contains "$frame" "blocked: gh auth expired" "the installed command prints fixture rows"
if alias_frame=$(cd / && "$BIN/fm-board" --render-once --fixture "$FIX/populated.json" --no-herdr 2>&1); then pass; else fail "installed fm-board alias --render-once exited non-zero: $alias_frame"; fi
assert_equal "$alias_frame" "$frame" "the fm-board alias prints the same frame as firstmate-tui"
# The usage page from the installed command: exit 0 for --help and help, the
# page names this install, an unknown subcommand prints the page to stderr and
# exits 2 with nothing on stdout (falsify: drop the help case or the catch-all
# in the launcher's subcommand case, or let usage() print to stdout there).
if help_out=$(cd / && "$BIN/firstmate-tui" --help 2>/dev/null); then pass; else fail "installed firstmate-tui --help should exit 0"; fi
assert_contains "$help_out" "this install: $PREFIX" "--help says where this install lives (falsify: print the checkout line regardless of the record)"
assert_contains "$help_out" "firstmate-tui upgrade" "--help names the upgrade subcommand"
assert_contains "$help_out" "Press ? inside the" "--help points at ? for the keys"
if help_sub=$(cd / && "$BIN/firstmate-tui" help 2>/dev/null); then pass; else fail "installed firstmate-tui help should exit 0"; fi
assert_equal "$help_sub" "$help_out" "help prints the same page as --help"
if [ "$(cd / && "$BIN/firstmate-tui" -h 2>/dev/null)" = "$help_out" ]; then pass; else fail "-h prints the same page as --help"; fi
bogus_out=$(cd / && "$BIN/firstmate-tui" bogus 2>"$SCRATCH/bogus.err")
bogus_status=$?
assert_equal "$bogus_status" 2 "an unknown subcommand exits 2"
assert_equal "$bogus_out" "" "an unknown subcommand prints nothing on stdout"
assert_contains "$(cat "$SCRATCH/bogus.err")" "unknown subcommand bogus" "the unknown subcommand is named on stderr"
assert_contains "$(cat "$SCRATCH/bogus.err")" "usage: firstmate-tui [open] [flags]" "the usage page follows on stderr"
# The vendored neo-blessed loads from the installed tree (a one-shot render
# never imports it, so this is the check that the vendoring is complete;
# falsify: delete node_modules/neo-blessed/lib from the tarball).
loaded=$(cd "$PREFIX/bin/firstmate-tui" && node --input-type=module -e "const b = (await import('neo-blessed')).default; process.stdout.write(typeof b.screen);" 2>&1)
if [ "$loaded" = function ]; then pass; else fail "neo-blessed does not load from the installed tree: $loaded"; fi

# The command runs the installed copy: a marker written into the installed
# wrapper's usage page shows through the command (falsify: exec the checkout).
sed -i.bak 's/^firstmate-tui: a live, read-only/INSTALLED-COPY-MARKER firstmate-tui: a live, read-only/' "$PREFIX/bin/firstmate-tui.sh" && rm -f -- "${PREFIX:?}/bin/firstmate-tui.sh.bak"
grep -Fq INSTALLED-COPY-MARKER "$PREFIX/bin/firstmate-tui.sh" || fail "test setup: the marker did not land in the installed wrapper's usage page"
assert_contains "$("$BIN/firstmate-tui" --help 2>&1)" "INSTALLED-COPY-MARKER" "firstmate-tui --help comes from the installed wrapper"

# Re-running upgrades in place: the old tree goes as a whole, the report names
# the replaced version, and the command still works.
touch "$PREFIX/stale-file"
if up_out=$("$INSTALL" --from-file "$TARBALL" --prefix "$PREFIX" --bin-dir "$BIN" 2>&1); then pass; else fail "second install.sh run exited non-zero: $up_out"; fi
assert_contains "$up_out" "installed (replaced $VERSION)" "a second run reports the version it replaced (falsify: read the old version after the move)"
assert_not_contains "$up_out" "next: export FM_HOME" "an upgrade does not repeat the first-run line"
assert_absent "$PREFIX/stale-file" "the previous install is replaced as a whole, not overlaid (falsify: extract over the existing prefix)"
assert_not_contains "$("$BIN/firstmate-tui" --help 2>&1)" "INSTALLED-COPY-MARKER" "the wrapper is the fresh copy after the upgrade"
if frame=$(cd / && "$BIN/firstmate-tui" --render-once --fixture "$FIX/empty.json" --no-herdr 2>&1); then pass; else fail "installed firstmate-tui after upgrade exited non-zero: $frame"; fi
assert_contains "$frame" "Captain's Call (0)" "the upgraded command renders"
assert_no_leftovers "$SCRATCH" "an upgrade leaves no staging or previous directory"

# A wrong checksum stops the install and leaves the existing one alone
# (falsify: log the mismatch instead of exiting).
BAD="$SCRATCH/bad"
mkdir -p "$BAD"
cp "$TARBALL" "$CHECKSUM" "$BAD/"
first=$(cut -c1 "$BAD/firstmate-tui-$TAG.tar.gz.sha256")
flipped=0
[ "$first" = 0 ] && flipped=1
sed -i.bak "s/^./$flipped/" "$BAD/firstmate-tui-$TAG.tar.gz.sha256" && rm -f -- "${BAD:?}/"*.bak
touch "$PREFIX/untouched-marker"
if out=$("$INSTALL" --from-file "$BAD/firstmate-tui-$TAG.tar.gz" --prefix "$PREFIX" --bin-dir "$BIN" 2>&1); then fail "a wrong checksum should stop the install"; else pass; fi
assert_contains "$out" "checksum mismatch" "the error names the checksum mismatch"
assert_file "$PREFIX/untouched-marker" "a failed verification leaves the existing install alone"
assert_file "$PREFIX/bin/firstmate-tui.sh" "the existing install survives a failed verification"
assert_no_leftovers "$SCRATCH" "a failed install leaves no staging directory"
rm -f -- "${PREFIX:?}/untouched-marker"
# A damaged tarball beside a correct checksum file fails the same way.
cp "$TARBALL" "$CHECKSUM" "$BAD/"
printf 'x' >> "$BAD/firstmate-tui-$TAG.tar.gz"
if out=$("$INSTALL" --from-file "$BAD/firstmate-tui-$TAG.tar.gz" --prefix "$SCRATCH/prefix-damaged" --bin-dir "$BIN" 2>&1); then fail "a damaged tarball should stop the install"; else pass; fi
assert_contains "$out" "checksum mismatch" "the damaged tarball is caught by the checksum"
assert_absent "$SCRATCH/prefix-damaged" "a damaged tarball installs nothing"

# A local tarball with no .sha256 beside it installs and says the checksum was skipped.
NOSUM="$SCRATCH/nosum"
mkdir -p "$NOSUM"
cp "$TARBALL" "$NOSUM/"
if out=$("$INSTALL" --from-file "$NOSUM/firstmate-tui-$TAG.tar.gz" --prefix "$SCRATCH/prefix-nosum" --bin-dir "$SCRATCH/bin-nosum" 2>&1); then pass; else fail "install without a checksum file exited non-zero: $out"; fi
assert_contains "$out" "skipping the checksum" "a missing .sha256 is reported, not silent (falsify: drop the else branch)"
assert_file "$SCRATCH/prefix-nosum/bin/firstmate-tui.sh" "the install without a checksum file completes"

# A prefix that exists and is not an fm-board install is refused untouched
# (falsify: remove the prefix without looking at it).
mkdir -p "$SCRATCH/other"
echo keep > "$SCRATCH/other/keep.txt"
if out=$("$INSTALL" --from-file "$TARBALL" --prefix "$SCRATCH/other" --bin-dir "$BIN" 2>&1); then fail "a prefix holding unrelated files should be refused"; else pass; fi
assert_contains "$out" "not a firstmate-tui install" "the refusal says why"
assert_file "$SCRATCH/other/keep.txt" "the unrelated prefix is left alone"

# Defaults: ~/.local/share/fm-board and ~/.local/bin under HOME, XDG_DATA_HOME
# honored, and nothing else under HOME is written (falsify: append to ~/.bashrc).
FAKE_HOME="$SCRATCH/home"
mkdir -p "$FAKE_HOME"
if out=$(cd "$SCRATCH" && env -u XDG_DATA_HOME HOME="$FAKE_HOME" "$INSTALL" --from-file "$TARBALL" 2>&1); then pass; else fail "install with default paths exited non-zero: $out"; fi
assert_file "$FAKE_HOME/.local/share/fm-board/bin/firstmate-tui.sh" "the default prefix is ~/.local/share/fm-board"
assert_file "$FAKE_HOME/.local/bin/firstmate-tui" "the default bin dir is ~/.local/bin"
assert_file "$FAKE_HOME/.local/bin/fm-board" "the alias lands in the same bin dir"
others=$(find "$FAKE_HOME" -type f ! -path "$FAKE_HOME/.local/share/fm-board/*" ! -path "$FAKE_HOME/.local/bin/firstmate-tui" ! -path "$FAKE_HOME/.local/bin/fm-board")
if [ -z "$others" ]; then pass; else fail "the installer wrote outside the prefix and the bin dir: $others"; fi
if out=$(env XDG_DATA_HOME="$SCRATCH/xdg" HOME="$FAKE_HOME" "$INSTALL" --from-file "$TARBALL" --bin-dir "$SCRATCH/bin-xdg" 2>&1); then pass; else fail "install with XDG_DATA_HOME exited non-zero: $out"; fi
assert_file "$SCRATCH/xdg/fm-board/bin/firstmate-tui.sh" "XDG_DATA_HOME moves the default prefix"
# Relative --prefix, --bin-dir and --from-file resolve against the working directory.
if out=$(cd "$SCRATCH" && "$INSTALL" --from-file "dist/firstmate-tui-$TAG.tar.gz" --prefix rel-prefix --bin-dir rel-bin 2>&1); then pass; else fail "install with relative paths exited non-zero: $out"; fi
assert_file "$SCRATCH/rel-prefix/bin/firstmate-tui.sh" "a relative --prefix lands under the working directory"
assert_contains "$(cat "$SCRATCH/rel-bin/firstmate-tui")" "$SCRATCH/rel-prefix/bin/firstmate-tui.sh" "the shim carries the absolute prefix even when --prefix was relative"

# `curl | bash` shape: the script runs from stdin, with arguments after `-s --`,
# and never reads BASH_SOURCE (falsify: derive usage from BASH_SOURCE, or move
# code out of main()).
if out=$(bash -s -- --from-file "$TARBALL" --prefix "$SCRATCH/prefix-stdin" --bin-dir "$SCRATCH/bin-stdin" < "$INSTALL" 2>&1); then pass; else fail "install.sh from stdin exited non-zero: $out"; fi
assert_file "$SCRATCH/prefix-stdin/bin/firstmate-tui.sh" "the stdin run installs"
assert_not_contains "$(cat "$INSTALL")" "BASH_SOURCE" "install.sh never reads BASH_SOURCE (empty under curl | bash)"
if [ "$(tail -n 1 "$INSTALL")" = 'main "$@"' ]; then pass; else fail "install.sh must end with main \"\$@\" so a truncated download runs nothing"; fi

# Flag errors and --help (falsify: drop the guard named in each label).
if out=$("$INSTALL" --version v1.0.0 --pre 2>&1); then fail "--version with --pre should exit non-zero"; else pass; fi
assert_contains "$out" "exclude each other" "--version and --pre are named as exclusive"
if out=$("$INSTALL" --stable --pre 2>&1); then fail "--stable with --pre should exit non-zero"; else pass; fi
assert_contains "$out" "exclude each other" "--stable and --pre are named as exclusive"
if out=$("$INSTALL" --stable --version 1.0.0 2>&1); then fail "--stable with --version should exit non-zero"; else pass; fi
if out=$("$INSTALL" --from-file "$SCRATCH/nope.tar.gz" --prefix "$SCRATCH/p" --bin-dir "$SCRATCH/b" 2>&1); then fail "a missing --from-file should exit non-zero"; else pass; fi
assert_contains "$out" "no such tarball" "a missing tarball is named"
if out=$("$INSTALL" --from-file "$TARBALL" --version v1.0.0 2>&1); then fail "--version with --from-file should exit non-zero"; else pass; fi
assert_contains "$out" "no effect" "--version under --from-file is refused, not ignored"
if out=$("$INSTALL" --from-file "$TARBALL" --stable 2>&1); then fail "--stable with --from-file should exit non-zero"; else pass; fi
assert_contains "$out" "no effect" "--stable under --from-file is refused, not ignored"
if out=$("$INSTALL" --bogus 2>&1); then fail "an unknown flag should exit non-zero"; else pass; fi
assert_contains "$out" "unknown option --bogus" "the unknown flag is named"
if out=$("$INSTALL" --prefix 2>&1); then fail "--prefix without a value should exit non-zero"; else pass; fi
assert_contains "$out" "--prefix needs a directory" "--prefix without a value is named"
if help=$("$INSTALL" --help 2>&1); then pass; else fail "--help should exit 0"; fi
for flag in --stable --version --pre --prefix --bin-dir --from-file --repo; do
  assert_contains "$help" "$flag" "--help lists $flag"
done

# --------------------------------------------------- version and upgrade
# `firstmate-tui version` reports the version and its kind; `firstmate-tui
# upgrade` swaps an install between the stable build and a hash beta in both directions
# by running the installed bin/install.sh against the install record. GitHub
# is stood in for by tests/fake-curl.sh first on PATH: it serves
# api/latest.json (the latest release), api/newest.json (the newest release,
# prereleases included) and download/<tag>/<asset> from $MIRROR and logs each
# URL to $CURL_LOG, so the real --stable, --pre and --version paths in
# install.sh run and nothing reaches the network.
MIRROR="$SCRATCH/mirror"
mkdir -p "$MIRROR/api/tags" "$MIRROR/download/$TAG" "$MIRROR/download/$BETA_TAG"
cp "$TARBALL" "$CHECKSUM" "$MIRROR/download/$TAG/"
cp "$BETA_TARBALL" "$BETA_CHECKSUM" "$MIRROR/download/$BETA_TAG/"
printf '{\n  "tag_name": "%s",\n  "prerelease": false\n}\n' "$TAG" > "$MIRROR/api/latest.json"
printf '[\n  {\n    "tag_name": "%s",\n    "prerelease": true\n  }\n]\n' "$BETA_TAG" > "$MIRROR/api/newest.json"
# The two asset names (AGENTS.md): the current one, and the one every release
# carried up to 0.2.x, which the installer still falls back to.
NEW_ASSET="firstmate-tui-$TAG.tar.gz"
OLD_ASSET="fm-board-$TAG.tar.gz"
# release_json <tag> [asset...]: a release as GET /releases/tags/<tag> returns
# it, with the fields the installer reads (each asset's browser_download_url,
# whose last segment is the asset's name) and the release's own "name", which
# a grep for "name" would mistake for an asset.
release_json() {
  local tag=$1 sep='' a
  shift
  printf '{\n  "tag_name": "%s",\n  "name": "firstmate-tui %s",\n  "prerelease": false,\n  "assets": [' "$tag" "$tag"
  for a in "$@"; do
    printf '%s\n    {\n      "name": "%s",\n      "browser_download_url": "https://github.com/zachsibert/firstmate-tui/releases/download/%s/%s"\n    }' "$sep" "$a" "$tag" "$a"
    sep=','
  done
  printf '\n  ]\n}\n'
}
release_json "$TAG" "$NEW_ASSET" "$NEW_ASSET.sha256" > "$MIRROR/api/tags/$TAG.json"
release_json "$BETA_TAG" "firstmate-tui-$BETA_TAG.tar.gz" "firstmate-tui-$BETA_TAG.tar.gz.sha256" > "$MIRROR/api/tags/$BETA_TAG.json"
FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cp "$ROOT/tests/fake-curl.sh" "$FAKEBIN/curl"
chmod +x "$FAKEBIN/curl"
CURL_LOG="$SCRATCH/curl.log"
# offline_from <mirror root> <command...>: run with the fake curl first on
# PATH, serving <mirror root>, and a fresh URL log; offline <command...> is
# the same against $MIRROR. FAKE_CURL_FAIL set on the call (see
# tests/fake-curl.sh) makes the fake answer matching URLs with a failure.
offline_from() {
  local root=$1
  shift
  : > "$CURL_LOG"
  env PATH="$FAKEBIN:$PATH" FAKE_CURL_ROOT="$root" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-}" "$@"
}
offline() { offline_from "$MIRROR" "$@"; }
SWAP="$SCRATCH/swap"
SWAP_PREFIX="$SWAP/prefix"
SWAP_BIN="$SWAP/bin"
FM="$SWAP_BIN/firstmate-tui"
# A view-state file where the board keeps it (outside the prefix, see
# bin/firstmate-tui.sh) must come through every swap byte for byte, and the wrapper
# must never derive its default view-state path from its own location.
VIEW_STATE="$SWAP/config/fm-board/view-state.json"
mkdir -p "$(dirname "$VIEW_STATE")"
printf '{"hiddenRows":["needs:1"],"hiddenPanes":[2]}\n' > "$VIEW_STATE"
VIEW_STATE_SHA=$(file_sha "$VIEW_STATE")
assert_not_contains "$(grep -F 'view-state' "$BOARD")" "\$ROOT" "the wrapper never puts view-state.json under its own directory (falsify: default --view-state to \$ROOT/...)"

# From a git checkout there is no install record: version says so, upgrade
# explains that git updates a checkout and exits non-zero without running the
# installer (falsify: fall through to install.sh with default paths).
if out=$("$BOARD" version 2>&1); then pass; else fail "firstmate-tui.sh version from a checkout should exit 0: $out"; fi
assert_contains "$out" "firstmate-tui $VERSION (stable release)" "version from the checkout reports the source version as stable, under the new name"
assert_contains "$out" "not an installed copy" "version from the checkout says it is not an install"
assert_equal "$("$BOARD" --version 2>&1)" "$out" "--version is the same as the version command"
assert_equal "$("$BOARD" -V 2>&1)" "$out" "-V is the same as the version command"
if out=$("$BOARD" version extra 2>&1); then fail "version with an argument should exit non-zero"; else pass; fi
if out=$(cd / && offline "$BOARD" upgrade 2>&1); then fail "upgrade from a checkout should exit non-zero"; else pass; fi
assert_contains "$out" "git checkout" "upgrade from a checkout names the checkout"
assert_contains "$out" "git -C" "upgrade from a checkout gives the git command that updates it"
assert_contains "$out" "$ROOT" "upgrade from a checkout names the checkout path"
if [ -s "$CURL_LOG" ]; then fail "upgrade from a checkout must not touch the network: $(cat "$CURL_LOG")"; else pass; fi
if out=$("$BOARD" upgrade --bogus 2>&1); then fail "an unknown upgrade flag should exit non-zero"; else pass; fi
assert_contains "$out" "unknown upgrade option --bogus" "the unknown upgrade flag is named"
if out=$("$BOARD" upgrade --version 2>&1); then fail "upgrade --version without a value should exit non-zero"; else pass; fi
assert_contains "$out" "needs a value" "upgrade --version without a value is named"
if out=$("$BOARD" upgrade --help 2>&1); then pass; else fail "upgrade --help should exit 0"; fi
for flag in --stable --pre --version --from-file; do
  assert_contains "$out" "$flag" "upgrade --help lists $flag"
done

# 1. First install, default channel: the latest release through the API, its
# asset list read, the stable tarball and its checksum downloaded and verified.
if out=$(offline "$INSTALL" --prefix "$SWAP_PREFIX" --bin-dir "$SWAP_BIN" 2>&1); then pass; else fail "install through the fake network exited non-zero: $out"; fi
assert_contains "$(cat "$CURL_LOG")" "/releases/latest" "the default channel asks GitHub for the latest release (falsify: default to --pre)"
assert_contains "$(cat "$CURL_LOG")" "/releases/tags/$TAG" "the release's asset list is read before the download (falsify: download the names blind)"
assert_contains "$(cat "$CURL_LOG")" "/releases/download/$TAG/firstmate-tui-$TAG.tar.gz" "the stable tarball is downloaded from the release"
assert_contains "$(cat "$CURL_LOG")" "/releases/download/$TAG/firstmate-tui-$TAG.tar.gz.sha256" "its checksum is downloaded too"
assert_contains "$out" "checksum verified" "the download is verified"
assert_contains "$out" "firstmate-tui $VERSION installed" "the stable version is installed"
assert_contains "$(cat "$SWAP_PREFIX/install-record")" "installed_from=release $TAG" "the record names the release tag"
if out=$("$FM" version 2>&1); then pass; else fail "installed firstmate-tui version exited non-zero: $out"; fi
assert_contains "$out" "firstmate-tui $VERSION (stable release)" "version reports the stable release (falsify: call every version a beta)"
assert_equal "$("$SWAP_BIN/fm-board" version 2>&1)" "$out" "the fm-board alias answers version the same way"
assert_contains "$out" "installed at $SWAP_PREFIX" "version names the install prefix"
assert_contains "$out" "from release $TAG" "version names the release it came from"
assert_not_contains "$out" "beta" "a stable install is not called a beta"

# The installed installer is the one that runs, not the checkout's: a marker
# in the installed copy shows in the upgrade output (falsify: exec the
# checkout's install.sh, or a copy fetched from the network).
sed -i.bak 's/^main() {$/main() { log INSTALLED-INSTALLER-MARKER;/' "$SWAP_PREFIX/bin/install.sh" && rm -f -- "${SWAP_PREFIX:?}/bin/install.sh.bak"
grep -Fq INSTALLED-INSTALLER-MARKER "$SWAP_PREFIX/bin/install.sh" || fail "test setup: the marker did not land in the installed install.sh"

# 2. Stable to beta with --pre: the newest release through the API, the beta
# tarball verified, the swap reported, and version reports the beta.
if out=$(cd / && offline "$FM" upgrade --pre 2>&1); then pass; else fail "firstmate-tui upgrade --pre exited non-zero: $out"; fi
assert_contains "$out" "INSTALLED-INSTALLER-MARKER" "upgrade runs the install.sh that shipped with the install"
assert_contains "$(cat "$CURL_LOG")" "/releases?per_page=1" "--pre asks for the newest release, prereleases included (falsify: reuse /latest)"
assert_contains "$(cat "$CURL_LOG")" "/releases/download/$BETA_TAG/firstmate-tui-$BETA_TAG.tar.gz" "the beta tarball is downloaded"
assert_contains "$(cat "$CURL_LOG")" "/releases/download/$BETA_TAG/firstmate-tui-$BETA_TAG.tar.gz.sha256" "the beta checksum is downloaded"
assert_contains "$out" "checksum verified" "the beta download is verified before the swap"
assert_contains "$out" "firstmate-tui $BETA_VERSION installed (replaced $VERSION)" "the swap to the beta is reported with both versions"
if out=$("$FM" version 2>&1); then pass; else fail "firstmate-tui version after --pre exited non-zero: $out"; fi
assert_contains "$out" "firstmate-tui $BETA_VERSION (beta: $VERSION at commit $SHA7)" "version reports the beta with its base version and commit (falsify: drop the sha pattern)"
assert_contains "$out" "from release $BETA_TAG" "version names the beta release it came from"
assert_contains "$(cat "$SWAP_PREFIX/install-record")" "prefix=$SWAP_PREFIX" "the beta's record still names the same prefix"
assert_contains "$(cat "$SWAP_PREFIX/install-record")" "bin_dir=$SWAP_BIN" "the beta's record still names the same bin dir"
assert_contains "$(cat "$SWAP_PREFIX/install-record")" "version=$BETA_VERSION" "the record carries the beta version"
assert_equal "$(file_sha "$VIEW_STATE")" "$VIEW_STATE_SHA" "view state outside the prefix survives the swap to the beta"
assert_no_leftovers "$SWAP" "the swap to the beta leaves no staging or previous directory"
if [ -z "$(find "$SWAP_PREFIX" -name 'view-state*' 2>/dev/null)" ]; then pass; else fail "the install carries no view-state file (falsify: ship one in the tarball)"; fi

# 3. Beta back to stable with --stable: a lower version by sort order, and it
# installs like any other (falsify: refuse a downgrade in install.sh).
if out=$(cd / && offline "$FM" upgrade --stable 2>&1); then pass; else fail "firstmate-tui upgrade --stable from a beta exited non-zero: $out"; fi
assert_contains "$(cat "$CURL_LOG")" "/releases/latest" "--stable asks for the latest release, never a prerelease"
assert_contains "$out" "firstmate-tui $VERSION installed (replaced $BETA_VERSION)" "the swap back to stable is reported"
assert_contains "$("$FM" version 2>&1)" "firstmate-tui $VERSION (stable release)" "version reports stable again after --stable"
assert_equal "$(file_sha "$VIEW_STATE")" "$VIEW_STATE_SHA" "view state survives the swap back to stable"

# 4. An exact beta by version, without the v: --version adds it (falsify: pass
# the version to the download URL as typed). No channel is resolved, but the
# named release's asset list is still read.
if out=$(cd / && offline "$FM" upgrade --version "$BETA_VERSION" 2>&1); then pass; else fail "firstmate-tui upgrade --version $BETA_VERSION exited non-zero: $out"; fi
assert_not_contains "$(cat "$CURL_LOG")" "/releases/latest" "--version asks for no latest release"
assert_not_contains "$(cat "$CURL_LOG")" "per_page" "--version lists no releases"
assert_contains "$(cat "$CURL_LOG")" "/releases/tags/$BETA_TAG" "--version reads the named release's asset list (falsify: skip the read under --version)"
assert_contains "$(cat "$CURL_LOG")" "/releases/download/$BETA_TAG/firstmate-tui-$BETA_TAG.tar.gz" "--version without the v downloads the v-tagged asset"
assert_contains "$out" "firstmate-tui $BETA_VERSION installed (replaced $VERSION)" "the exact beta replaces stable"
assert_contains "$("$FM" version 2>&1)" "(beta: $VERSION at commit $SHA7)" "version reports the exact beta"

# 5. A plain `firstmate-tui upgrade` from a beta lands on the latest stable release.
if out=$(cd / && offline "$FM" upgrade 2>&1); then pass; else fail "plain firstmate-tui upgrade exited non-zero: $out"; fi
assert_contains "$(cat "$CURL_LOG")" "/releases/latest" "a plain upgrade is the stable channel (falsify: default to --pre)"
assert_contains "$out" "installed (replaced $BETA_VERSION)" "a plain upgrade from a beta swaps to stable"
assert_contains "$("$FM" version 2>&1)" "(stable release)" "version reports stable after a plain upgrade"

# 6. An exact version with the v is accepted as typed.
if out=$(cd / && offline "$FM" upgrade --version "$BETA_TAG" 2>&1); then pass; else fail "firstmate-tui upgrade --version $BETA_TAG exited non-zero: $out"; fi
assert_contains "$(cat "$CURL_LOG")" "/releases/download/$BETA_TAG/" "--version with the v downloads that tag"
assert_contains "$("$FM" version 2>&1)" "firstmate-tui $BETA_VERSION (beta" "version reports the beta after --version v..."

# 7. A version that has no release fails before the swap and leaves the
# install alone (falsify: swap in whatever was staged).
touch "$SWAP_PREFIX/keep-me"
if out=$(cd / && offline "$FM" upgrade --version 0.9.9-abcdef0 2>&1); then fail "upgrade to a version with no release should exit non-zero"; else pass; fi
assert_contains "$out" "download failed" "the missing release is reported as a failed download"
assert_file "$SWAP_PREFIX/keep-me" "a failed upgrade leaves the current install in place"
assert_contains "$("$FM" version 2>&1)" "firstmate-tui $BETA_VERSION" "the version is unchanged after a failed upgrade"
assert_no_leftovers "$SWAP" "a failed upgrade leaves no staging directory"
rm -f -- "${SWAP_PREFIX:?}/keep-me"

# 8. Two channel flags are refused by the one implementation in install.sh;
# --from-file passes through for a tarball already on disk.
if out=$(cd / && offline "$FM" upgrade --stable --pre 2>&1); then fail "upgrade --stable --pre should exit non-zero"; else pass; fi
assert_contains "$out" "exclude each other" "two channel flags are refused with the installer's message"
if [ -s "$CURL_LOG" ]; then fail "refused flags must not reach the network: $(cat "$CURL_LOG")"; else pass; fi
if out=$(cd / && offline "$FM" upgrade --from-file "$TARBALL" 2>&1); then pass; else fail "firstmate-tui upgrade --from-file exited non-zero: $out"; fi
assert_contains "$out" "installed (replaced $BETA_VERSION)" "--from-file swaps from the local tarball"
if [ -s "$CURL_LOG" ]; then fail "--from-file must not touch the network: $(cat "$CURL_LOG")"; else pass; fi
assert_contains "$("$FM" version 2>&1)" "(stable release)" "version reports stable after --from-file"
assert_equal "$(file_sha "$VIEW_STATE")" "$VIEW_STATE_SHA" "view state survives every swap in this section"
assert_no_leftovers "$SWAP" "the swap section leaves no staging or previous directory"
# The command still renders after all the swaps.
if frame=$(cd / && "$FM" --render-once --fixture "$FIX/empty.json" --no-herdr 2>&1); then pass; else fail "firstmate-tui after the swaps exited non-zero: $frame"; fi
assert_contains "$frame" "Captain's Call (0)" "the swapped command renders"

# 9. A moved install and a missing record are refused with a pointer to the
# installer (falsify: install into the recorded prefix regardless).
cp -R "$SWAP_PREFIX" "$SWAP/moved"
if out=$(cd / && offline bash "$SWAP/moved/bin/firstmate-tui.sh" upgrade 2>&1); then fail "upgrade from a moved install should exit non-zero"; else pass; fi
assert_contains "$out" "was the install moved" "a moved install is named as the cause"
rm -f -- "${SWAP:?}/moved/install-record"
if out=$(cd / && offline bash "$SWAP/moved/bin/firstmate-tui.sh" upgrade 2>&1); then fail "upgrade without a record should exit non-zero"; else pass; fi
assert_contains "$out" "no install record" "a missing record is named"
assert_contains "$out" "install.sh | bash" "a missing record points at the installer"
assert_contains "$(bash "$SWAP/moved/bin/firstmate-tui.sh" version 2>&1)" "not an installed copy" "version without a record says so"

# ------------------------------------------- asset name and tarball layout
# The rename is done (AGENTS.md, the header of bin/install.sh): the asset is
# firstmate-tui-<tag>.tar.gz with bin/firstmate-tui.sh and bin/firstmate-tui/
# inside, and the installer still downloads fm-board-<tag>.tar.gz from a
# release that has only that name and installs a tarball of either layout,
# so a 0.2.x release can be installed again. The old layout is the real
# thing: the 0.2.5 tree from the v0.2.5 tag, packaged by its own
# scripts/package.sh (fm-board-v0.2.5.tar.gz, unpacking to
# firstmate-tui-v0.2.5/), with its installer from git show for the upgrade
# chains further down. The 0.1.0 tree and installer come the same way.
MID_TAG=v0.2.5
MID_VERSION=0.2.5
MID_SRC="$SCRATCH/src-$MID_TAG"
MID_INSTALLER="$SCRATCH/install-$MID_TAG.sh"
MID_NEW_ASSET="firstmate-tui-$MID_TAG.tar.gz"
MID_OLD_ASSET="fm-board-$MID_TAG.tar.gz"
OLD_TAG=v0.1.0
OLD_VERSION=0.1.0
OLD_SRC="$SCRATCH/src-$OLD_TAG"
OLD_INSTALLER="$SCRATCH/install-$OLD_TAG.sh"
mkdir -p "$MID_SRC" "$OLD_SRC"
tags_ok=1
for tagged in "$MID_TAG:$MID_SRC:$MID_INSTALLER" "$OLD_TAG:$OLD_SRC:$OLD_INSTALLER"; do
  IFS=: read -r t src inst <<< "$tagged"
  if git -C "$ROOT" archive --format=tar "$t" 2>/dev/null | tar -x -C "$src" && git -C "$ROOT" show "$t:bin/install.sh" > "$inst" 2>/dev/null; then
    pass
  else
    fail "the $t tag is needed for the layout and upgrade-chain checks (git fetch --tags origin)"
    tags_ok=0
  fi
done
if [ "$tags_ok" -eq 1 ]; then
  if "$MID_SRC/scripts/package.sh" "$MID_TAG" "$SCRATCH/dist-mid" >/dev/null 2>"$SCRATCH/mid.err"; then pass; else fail "package.sh from $MID_TAG exited non-zero: $(cat "$SCRATCH/mid.err")"; fi
  MID_TARBALL="$SCRATCH/dist-mid/$MID_OLD_ASSET"
  assert_file "$MID_TARBALL" "the 0.2.5 tarball is built under the old asset name"
  mid_listing=$(tar -tzf "$MID_TARBALL")
  assert_contains "$mid_listing" "firstmate-tui-$MID_TAG/bin/fm-board.sh" "the 0.2.5 tarball carries bin/fm-board.sh, the old layout"
  assert_contains "$mid_listing" "firstmate-tui-$MID_TAG/bin/fm-board/node_modules/neo-blessed/package.json" "the 0.2.5 tarball carries the package under bin/fm-board/"
  assert_not_contains "$mid_listing" "firstmate-tui-$MID_TAG/bin/firstmate-tui" "the 0.2.5 tarball carries no firstmate-tui path"
  if "$OLD_SRC/scripts/package.sh" "$OLD_TAG" "$SCRATCH/dist-old" >/dev/null 2>"$SCRATCH/old.err"; then pass; else fail "package.sh from $OLD_TAG exited non-zero: $(cat "$SCRATCH/old.err")"; fi
  OLD_TARBALL="$SCRATCH/dist-old/fm-board-$OLD_TAG.tar.gz"
  assert_file "$OLD_TARBALL" "the 0.1.0 tarball is built under the old asset name"
  assert_equal "$(tar -tzf "$OLD_TARBALL" | sed 's#/.*##' | sort -u)" "fm-board-$OLD_TAG" "the 0.1.0 tarball unpacks to fm-board-$OLD_TAG, the old top directory (every installer strips it)"

  # 1. --from-file with the old layout: the tree is accepted, both commands run
  # bin/fm-board.sh, the record notes the layout, and version and a render
  # work from it (falsify: look for bin/firstmate-tui.sh alone after the
  # unpack, read the version from bin/firstmate-tui/package.json alone, or
  # write the shim's exec line with a fixed launcher name).
  OLDLAY="$SCRATCH/oldlay"
  OL_PREFIX="$OLDLAY/prefix"
  OL_BIN="$OLDLAY/bin"
  if out=$("$INSTALL" --from-file "$MID_TARBALL" --prefix "$OL_PREFIX" --bin-dir "$OL_BIN" 2>&1); then pass; else fail "install.sh --from-file with the 0.2.5 tarball exited non-zero: $out"; fi
  assert_contains "$out" "checksum verified" "the 0.2.5 tarball's checksum is verified"
  assert_contains "$out" "firstmate-tui $MID_VERSION installed" "the version is read from bin/fm-board/package.json"
  assert_exec "$OL_PREFIX/bin/fm-board.sh" "the old launcher is installed and executable (falsify: chmod bin/firstmate-tui.sh by name)"
  assert_absent "$OL_PREFIX/bin/firstmate-tui.sh" "the old layout is installed as is, with no bin/firstmate-tui.sh"
  assert_file "$OL_PREFIX/bin/fm-board/node_modules/neo-blessed/package.json" "the vendored dependency is installed under the old directory"
  assert_contains "$(cat "$OL_BIN/firstmate-tui")" "$OL_PREFIX/bin/fm-board.sh" "the firstmate-tui command runs the launcher the tree has"
  assert_not_contains "$(cat "$OL_BIN/firstmate-tui")" "firstmate-tui.sh" "the firstmate-tui command names no launcher that is not there"
  assert_contains "$(cat "$OL_BIN/fm-board")" "$OL_PREFIX/bin/fm-board.sh" "the fm-board alias runs the same launcher"
  assert_contains "$(cat "$OL_PREFIX/install-record")" "layout=fm-board" "the record notes the old layout"
  if out=$(cd / && "$OL_BIN/firstmate-tui" version 2>&1); then pass; else fail "firstmate-tui version from the old layout exited non-zero: $out"; fi
  assert_contains "$out" "firstmate-tui $MID_VERSION (stable release)" "firstmate-tui version works from the old layout"
  assert_contains "$out" "installed at $OL_PREFIX" "version names the old-layout install's prefix"
  assert_equal "$(cd / && "$OL_BIN/fm-board" version 2>&1)" "$out" "the fm-board alias answers version the same way from the old layout"
  if frame=$(cd / && "$OL_BIN/firstmate-tui" --render-once --fixture "$FIX/empty.json" --no-herdr 2>&1); then pass; else fail "the old layout does not render: $frame"; fi
  assert_contains "$frame" "Needs you (0)" "the old layout renders a frame"
  assert_no_leftovers "$OLDLAY" "the old-layout install leaves no staging directory"

  # 2. `firstmate-tui upgrade` swaps between the layouts in both directions and
  # re-points both commands at whichever launcher lands, each report naming the
  # version it replaced, read from the other layout's package.json. The first
  # swap runs the 0.2.5 installer that shipped in the 0.2.5 tarball, the swap
  # back runs the current one (falsify: read the old version from
  # bin/firstmate-tui/package.json alone, or write the shims only on a first
  # install).
  if out=$(cd / && offline "$OL_BIN/firstmate-tui" upgrade --from-file "$TARBALL" 2>&1); then pass; else fail "upgrade from the old layout to the current one exited non-zero: $out"; fi
  assert_contains "$out" "firstmate-tui $VERSION installed (replaced $MID_VERSION)" "the swap to the current layout names the version it replaced, read from bin/fm-board/package.json"
  if [ -s "$CURL_LOG" ]; then fail "upgrade --from-file must not touch the network: $(cat "$CURL_LOG")"; else pass; fi
  assert_exec "$OL_PREFIX/bin/firstmate-tui.sh" "the current layout is in place after the swap"
  assert_absent "$OL_PREFIX/bin/fm-board.sh" "the old launcher went with the previous install (falsify: extract over the prefix)"
  assert_contains "$(cat "$OL_BIN/firstmate-tui")" "$OL_PREFIX/bin/firstmate-tui.sh" "the firstmate-tui command now runs bin/firstmate-tui.sh"
  assert_contains "$(cat "$OL_BIN/fm-board")" "$OL_PREFIX/bin/firstmate-tui.sh" "the alias follows the launcher"
  assert_contains "$(cat "$OL_PREFIX/install-record")" "layout=firstmate-tui" "the record now says layout=firstmate-tui"
  assert_contains "$(cd / && "$OL_BIN/firstmate-tui" version 2>&1)" "firstmate-tui $VERSION (stable release)" "version works after the swap to the current layout"
  if out=$(cd / && offline "$OL_BIN/firstmate-tui" upgrade --from-file "$MID_TARBALL" 2>&1); then pass; else fail "upgrade from the current layout back to the old one exited non-zero: $out"; fi
  assert_contains "$out" "firstmate-tui $MID_VERSION installed (replaced $VERSION)" "the swap back names the version it replaced, read from bin/firstmate-tui/package.json"
  assert_exec "$OL_PREFIX/bin/fm-board.sh" "the old layout is back"
  assert_absent "$OL_PREFIX/bin/firstmate-tui.sh" "the current launcher went with the previous install"
  assert_contains "$(cat "$OL_BIN/fm-board")" "$OL_PREFIX/bin/fm-board.sh" "the alias follows the launcher on every swap"
  assert_contains "$(cat "$OL_PREFIX/install-record")" "layout=fm-board" "the record says layout=fm-board again"
  assert_contains "$(cd / && "$OL_BIN/fm-board" version 2>&1)" "firstmate-tui $MID_VERSION (stable release)" "version works after the swap back"
  assert_no_leftovers "$OLDLAY" "the layout swaps leave no staging or previous directory"

  # 3. A tree that is neither layout is refused untouched: bin/firstmate-tui.sh
  # beside bin/fm-board/ (falsify: accept a launcher without checking the
  # package directory of the same name beside it).
  MIXED="$SCRATCH/mixed"
  mkdir -p "$MIXED/tree"
  tar -xzf "$MID_TARBALL" -C "$MIXED/tree"
  mv "$MIXED/tree/firstmate-tui-$MID_TAG/bin/fm-board.sh" "$MIXED/tree/firstmate-tui-$MID_TAG/bin/firstmate-tui.sh"
  MIXED_TARBALL="$MIXED/mixed-$MID_TAG.tar.gz"
  tar -czf "$MIXED_TARBALL" -C "$MIXED/tree" "firstmate-tui-$MID_TAG"
  if out=$("$INSTALL" --from-file "$MIXED_TARBALL" --prefix "$MIXED/prefix" --bin-dir "$MIXED/bin" 2>&1); then fail "a tarball with bin/firstmate-tui.sh but bin/fm-board/ should be refused"; else pass; fi
  assert_contains "$out" "not a firstmate-tui release" "the mixed tree is refused as not a release"
  assert_absent "$MIXED/prefix" "a refused tarball installs nothing"
  assert_no_leftovers "$MIXED" "a refused tarball leaves no staging directory"

  # 4. Through the fake network. The installer reads the release's asset list
  # (GET /releases/tags/<tag>, api/tags/<tag>.json in a mirror) and asks only
  # for a name the release has; a mirror without that file answers the read
  # with exit 22, as GitHub does for a tag it has no release for, and the
  # installer then tries both names blind. The releases: the new asset name
  # only ($MIRROR, what every release from 0.3.0 on looks like), the old name
  # only (the 0.2.5 release, what every release before looked like), both
  # (the current tarball under the new name, the 0.2.5 tarball under the old,
  # so the launcher that lands tells which one was taken; the old name listed
  # first, so the preference and not the order decides), one whose assets
  # carry neither name, and the 0.2.5 release with no asset list to read.
  MIRROR_OLD="$SCRATCH/mirror-old"
  MIRROR_BOTH="$SCRATCH/mirror-both"
  MIRROR_NEITHER="$SCRATCH/mirror-neither"
  MIRROR_BLIND="$SCRATCH/mirror-blind"
  mkdir -p "$MIRROR_OLD/api/tags" "$MIRROR_OLD/download/$MID_TAG" "$MIRROR_BOTH/api/tags" "$MIRROR_BOTH/download/$TAG" "$MIRROR_NEITHER/api/tags" "$MIRROR_BLIND/api" "$MIRROR_BLIND/download/$MID_TAG"
  printf '{\n  "tag_name": "%s",\n  "prerelease": false\n}\n' "$MID_TAG" > "$MIRROR_OLD/api/latest.json"
  cp "$MID_TARBALL" "$MID_TARBALL.sha256" "$MIRROR_OLD/download/$MID_TAG/"
  release_json "$MID_TAG" "$MID_OLD_ASSET" "$MID_OLD_ASSET.sha256" > "$MIRROR_OLD/api/tags/$MID_TAG.json"
  cp "$MIRROR/api/latest.json" "$MIRROR_BOTH/api/latest.json"
  cp "$TARBALL" "$CHECKSUM" "$MIRROR_BOTH/download/$TAG/"
  cp "$MID_TARBALL" "$MIRROR_BOTH/download/$TAG/$OLD_ASSET"
  printf '%s  %s\n' "$(file_sha "$MID_TARBALL")" "$OLD_ASSET" > "$MIRROR_BOTH/download/$TAG/$OLD_ASSET.sha256"
  release_json "$TAG" "$OLD_ASSET" "$OLD_ASSET.sha256" "$NEW_ASSET" "$NEW_ASSET.sha256" > "$MIRROR_BOTH/api/tags/$TAG.json"
  cp "$MIRROR/api/latest.json" "$MIRROR_NEITHER/api/latest.json"
  release_json "$TAG" "release-notes.txt" "fm-board-$TAG.zip" > "$MIRROR_NEITHER/api/tags/$TAG.json"
  cp "$MIRROR_OLD/api/latest.json" "$MIRROR_BLIND/api/latest.json"
  cp "$MID_TARBALL" "$MID_TARBALL.sha256" "$MIRROR_BLIND/download/$MID_TAG/"
  NET="$SCRATCH/net"
  # url_order <first substring> <second substring> <label>: the first URL
  # containing <first> was logged before the first containing <second>.
  url_order() {
    local a b
    a=$(grep -nF -- "$1" "$CURL_LOG" | head -n 1 | cut -d: -f1)
    b=$(grep -nF -- "$2" "$CURL_LOG" | head -n 1 | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then pass; else fail "$3: $(tr '\n' ' ' < "$CURL_LOG")"; fi
  }

  # New name only: the asset list is read, the new asset downloaded and
  # verified under its name, the old name never asked for, no fallback line
  # (falsify: download the names blind, prefer the old name, or fetch both).
  if out=$(offline "$INSTALL" --prefix "$NET/new/prefix" --bin-dir "$NET/new/bin" 2>&1); then pass; else fail "install from a release holding the new asset name exited non-zero: $out"; fi
  assert_contains "$(cat "$CURL_LOG")" "/releases/tags/$TAG" "the release's asset list is read"
  url_order "/releases/tags/$TAG" "/$NEW_ASSET" "the asset list is read before any download (falsify: download first, read on failure)"
  assert_not_contains "$out" "could not read" "the asset list was read, so no blind attempt is reported"
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$TAG/$NEW_ASSET" "the new asset is downloaded"
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$TAG/$NEW_ASSET.sha256" "its checksum is downloaded under the new name"
  assert_not_contains "$(cat "$CURL_LOG")" "$OLD_ASSET" "the old name is never asked for when the new one is there"
  assert_contains "$out" "downloading $NEW_ASSET" "the log names the new asset"
  assert_not_contains "$out" "has no $NEW_ASSET" "no fallback is reported when none happened"
  assert_contains "$out" "checksum verified" "the new-name download is verified (falsify: skip the checksum under the new name)"
  assert_contains "$out" "firstmate-tui $VERSION installed" "a release under the new name installs"
  assert_exec "$NET/new/prefix/bin/firstmate-tui.sh" "the new-name release installs the current layout"
  assert_contains "$(cat "$NET/new/prefix/install-record")" "layout=firstmate-tui" "the record notes the current layout of a network install"
  assert_contains "$(cat "$NET/new/prefix/install-record")" "installed_from=release $TAG" "the record names the release"

  # Old name only, the 0.2.5 release, asset list readable: the release is read
  # first, the new name is never asked for, the old name is downloaded with its
  # own checksum, the log says so, and 0.2.5 lands in its own layout (falsify:
  # ask for the new name blind before reading the release, stay silent about
  # the fallback, or fetch the checksum under the new name).
  if out=$(offline_from "$MIRROR_OLD" "$INSTALL" --prefix "$NET/old/prefix" --bin-dir "$NET/old/bin" 2>&1); then pass; else fail "install from the 0.2.5 release exited non-zero: $out"; fi
  assert_contains "$(cat "$CURL_LOG")" "/releases/tags/$MID_TAG" "the release's asset list is read"
  assert_not_contains "$(cat "$CURL_LOG")" "/$MID_NEW_ASSET" "a name the release does not have is never asked for"
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$MID_TAG/$MID_OLD_ASSET" "the old asset name is downloaded"
  url_order "/releases/tags/$MID_TAG" "/$MID_OLD_ASSET" "the asset list is read before any download"
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$MID_TAG/$MID_OLD_ASSET.sha256" "the checksum is fetched under the name that was found"
  assert_not_contains "$(cat "$CURL_LOG")" "$MID_NEW_ASSET.sha256" "no checksum is fetched under a name the release does not have"
  assert_contains "$out" "has no $MID_NEW_ASSET" "the log says the new name is missing"
  assert_contains "$out" "downloading $MID_OLD_ASSET" "the log names the asset that was used"
  assert_not_contains "$out" "could not read" "the asset list was read, so no blind attempt is reported"
  assert_contains "$out" "checksum verified" "the fallback download is verified"
  assert_contains "$out" "firstmate-tui $MID_VERSION installed" "the 0.2.5 release installs"
  assert_exec "$NET/old/prefix/bin/fm-board.sh" "the fallback installed the old layout"
  assert_contains "$(cat "$NET/old/prefix/install-record")" "layout=fm-board" "the record notes the old layout of a network install"
  assert_contains "$(cd / && "$NET/old/bin/firstmate-tui" version 2>&1)" "firstmate-tui $MID_VERSION (stable release)" "the 0.2.5 install from the network works"
  # Going back: `firstmate-tui upgrade --version 0.2.5` from the current
  # release runs the current installer, which takes the old name through the
  # fallback and lands the old layout, both commands following (falsify: drop
  # the fallback, or rewrite the shims only on a first install).
  if out=$(cd / && offline_from "$MIRROR_OLD" "$NET/new/bin/firstmate-tui" upgrade --version "$MID_VERSION" 2>&1); then pass; else fail "firstmate-tui upgrade --version $MID_VERSION from the current release exited non-zero: $out"; fi
  assert_contains "$out" "downloading $MID_OLD_ASSET" "going back to 0.2.5 takes the old asset name through the fallback"
  assert_contains "$out" "firstmate-tui $MID_VERSION installed (replaced $VERSION)" "going back to 0.2.5 names both versions"
  assert_exec "$NET/new/prefix/bin/fm-board.sh" "going back to 0.2.5 lands the old layout"
  assert_absent "$NET/new/prefix/bin/firstmate-tui.sh" "the current launcher went with the replaced install"
  assert_contains "$(cat "$NET/new/bin/firstmate-tui")" "$NET/new/prefix/bin/fm-board.sh" "the command follows the launcher back"
  assert_contains "$(cat "$NET/new/bin/fm-board")" "$NET/new/prefix/bin/fm-board.sh" "the alias follows the launcher back"
  assert_contains "$(cd / && "$NET/new/bin/firstmate-tui" version 2>&1)" "firstmate-tui $MID_VERSION (stable release)" "version reports 0.2.5 after going back"
  assert_no_leftovers "$NET/new" "going back leaves no staging or previous directory"

  # Both names: the new one wins whatever order the release lists them in, and
  # it is the current tarball that lands (falsify: take the first asset listed,
  # prefer the old name, or download both and unpack the old).
  if out=$(offline_from "$MIRROR_BOTH" "$INSTALL" --prefix "$NET/both/prefix" --bin-dir "$NET/both/bin" 2>&1); then pass; else fail "install from a release holding both asset names exited non-zero: $out"; fi
  assert_not_contains "$(cat "$CURL_LOG")" "$OLD_ASSET" "with both names present the old one is never asked for"
  assert_exec "$NET/both/prefix/bin/firstmate-tui.sh" "the tarball under the new name is the one installed"
  assert_contains "$(cd / && "$NET/both/bin/firstmate-tui" version 2>&1)" "firstmate-tui $VERSION (stable release)" "the current tarball landed"

  # Neither name among the assets: the installer stops before any download and
  # names both what it looked for and what the release has (falsify: try the
  # downloads anyway, or report only the names it wanted).
  if out=$(offline_from "$MIRROR_NEITHER" "$INSTALL" --prefix "$NET/neither/prefix" --bin-dir "$NET/neither/bin" 2>&1); then fail "a release whose assets carry neither name should stop the install"; else pass; fi
  assert_contains "$out" "neither $NEW_ASSET nor $OLD_ASSET" "the error names both asset names it looked for"
  assert_equal "${out##*its assets: }" "release-notes.txt fm-board-$TAG.zip" "the error lists exactly the assets the release has, not its own name (falsify: grep the assets by their name field)"
  assert_not_contains "$(cat "$CURL_LOG")" "/releases/download/" "nothing is downloaded from a release that has neither name"
  assert_absent "$NET/neither/prefix" "nothing is installed from a release with neither name"
  release_json "$TAG" > "$MIRROR_NEITHER/api/tags/$TAG.json"
  if out=$(offline_from "$MIRROR_NEITHER" "$INSTALL" --prefix "$NET/neither/prefix" --bin-dir "$NET/neither/bin" 2>&1); then fail "a release with no assets at all should stop the install"; else pass; fi
  assert_contains "$out" "its assets: none" "a release with no assets says so"

  # A missing checksum is an error under either name, never a reason to try the
  # other name; the asset list is not consulted for it, the download is what
  # proves it is there (falsify: fall back to the old name on any failed download).
  MIRROR_NOSUM="$SCRATCH/mirror-nosum"
  mkdir -p "$MIRROR_NOSUM/api/tags" "$MIRROR_NOSUM/download/$TAG"
  cp "$MIRROR/api/latest.json" "$MIRROR_NOSUM/api/latest.json"
  cp "$MIRROR/api/tags/$TAG.json" "$MIRROR_NOSUM/api/tags/$TAG.json"
  cp "$TARBALL" "$MIRROR_NOSUM/download/$TAG/"
  if out=$(offline_from "$MIRROR_NOSUM" "$INSTALL" --prefix "$NET/nosum/prefix" --bin-dir "$NET/nosum/bin" 2>&1); then fail "a release with the tarball but no checksum should stop the install"; else pass; fi
  assert_contains "$out" "download failed" "the missing checksum is a failed download"
  assert_contains "$out" "$NEW_ASSET.sha256" "the error names the checksum file"
  assert_not_contains "$(cat "$CURL_LOG")" "$OLD_ASSET" "a missing checksum does not send the installer to the old name"
  assert_absent "$NET/nosum/prefix" "nothing is installed without the checksum"

  # The asset list cannot be read (no api/tags file: exit 22, GitHub's answer
  # for a tag without a release, and the same path for a rate limit or no
  # connection), the release holding the old name only: the installer says
  # so, asks for the new name first, and on the fake's exit 22 goes on to the
  # old name, which installs (falsify: stop when the read fails, or try the
  # old name first).
  if out=$(offline_from "$MIRROR_BLIND" "$INSTALL" --prefix "$NET/blind/prefix" --bin-dir "$NET/blind/bin" 2>&1); then pass; else fail "install with the asset list unreadable exited non-zero: $out"; fi
  assert_contains "$(cat "$CURL_LOG")" "/releases/tags/$MID_TAG" "the read was attempted"
  assert_contains "$out" "could not read the asset list" "the failed read is reported, not hidden"
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$MID_TAG/$MID_NEW_ASSET" "the new name is asked for first when the list is unreadable"
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$MID_TAG/$MID_OLD_ASSET" "the old name follows"
  url_order "/$MID_NEW_ASSET" "/$MID_OLD_ASSET" "the new name is asked for before the old one (falsify: try the old name first)"
  assert_contains "$out" "downloading $MID_OLD_ASSET" "the fallback is reported"
  assert_contains "$out" "checksum verified" "the blind fallback is verified"
  assert_contains "$out" "firstmate-tui $MID_VERSION installed" "the blind fallback installs"

  # The shapes curl gives for a first name that is missing or unreachable, each
  # on the blind path. Exit 56 with the 404 text is what GitHub's redirect to
  # the download host sent a 0.2.5 install, and the 0.2.5 installer stopped
  # there instead of falling back (the chains below pin that); exit 7 is no
  # connection at all. Each falls through to the old name and installs, with
  # curl's own message on record (falsify: read exit 22 alone as "not there",
  # as the 0.2.5 installer did, or stop on exit 7).
  for shape in "56 curl: (56) The requested URL returned error: 404" "7 curl: (7) Failed to connect to objects.githubusercontent.com port 443"; do
    status=${shape%% *}
    message=${shape#* }
    rm -rf -- "${NET:?}/shape"
    if out=$(FAKE_CURL_FAIL="/$MID_NEW_ASSET $status $message" offline_from "$MIRROR_BLIND" "$INSTALL" --prefix "$NET/shape/prefix" --bin-dir "$NET/shape/bin" 2>&1); then pass; else fail "curl exit $status on the new asset name should fall back to the old name: $out"; fi
    assert_contains "$(cat "$CURL_LOG")" "/$MID_NEW_ASSET" "exit $status: the new name was asked for"
    assert_contains "$out" "$message" "exit $status: curl's message says why the first name failed"
    assert_contains "$(cat "$CURL_LOG")" "/releases/download/$MID_TAG/$MID_OLD_ASSET" "exit $status: the old name is downloaded after the failure"
    assert_contains "$out" "firstmate-tui $MID_VERSION installed" "exit $status: the install completes"
  done

  # The API itself unreachable (exit 7 on the asset-list read) while the release
  # holds only the old name: the read fails with curl's message shown, both
  # names are tried, the old one installs (falsify: die when the read fails).
  if out=$(FAKE_CURL_FAIL="/releases/tags/ 7 curl: (7) Failed to connect to api.github.com port 443" offline_from "$MIRROR_OLD" "$INSTALL" --prefix "$NET/noapi/prefix" --bin-dir "$NET/noapi/bin" 2>&1); then pass; else fail "install with the API unreachable exited non-zero: $out"; fi
  assert_contains "$out" "could not read the asset list" "the unreachable API is reported"
  assert_contains "$out" "Failed to connect to api.github.com" "curl's message for the failed read is shown"
  assert_contains "$(cat "$CURL_LOG")" "/$MID_NEW_ASSET" "the new name is tried when the API is unreachable"
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$MID_TAG/$MID_OLD_ASSET" "the old name follows"
  assert_contains "$out" "firstmate-tui $MID_VERSION installed" "the install completes with the API unreachable"

  # A release the API does not know and neither download there: fails before
  # the swap, and the error names both asset names and both curl messages
  # (falsify: report only the last name tried).
  if out=$(cd / && offline "$NET/both/bin/firstmate-tui" upgrade --version 0.9.9-abcdef0 2>&1); then fail "upgrade to a version with no release should exit non-zero"; else pass; fi
  assert_contains "$out" "could not read the asset list" "the unknown release fails the asset-list read first"
  assert_contains "$out" "download failed" "the missing release is a failed download"
  assert_contains "$out" "neither firstmate-tui-v0.9.9-abcdef0.tar.gz nor fm-board-v0.9.9-abcdef0.tar.gz" "the error names both asset names it tried"
  assert_contains "$out" "firstmate-tui-v0.9.9-abcdef0.tar.gz: fake-curl: 404" "the error carries the first name's curl message"
  assert_contains "$out" "fm-board-v0.9.9-abcdef0.tar.gz: fake-curl: 404" "the error carries the second name's curl message"
  assert_contains "$(cd / && "$NET/both/bin/firstmate-tui" version 2>&1)" "firstmate-tui $VERSION (stable release)" "the install is unchanged after the failed upgrade"
  assert_no_leftovers "$NET/both" "the failed upgrade leaves no staging directory"

  # --------------------------------------------------------- upgrade chains
  # The real installers from the tags, through the fake network. An install
  # upgrades with the installer that shipped in its own tarball, so what a
  # 0.2.5 or a 0.1.0 install can reach is decided by that installer, not by
  # this tree's. MIRROR_CHAIN holds every release the chains touch, each with
  # its asset list; its latest release is switched between steps. SHAPE56 is
  # the answer GitHub gave a 0.2.5 install for the missing new name of a 0.2.x
  # release, API_DOWN an asset-list read that cannot connect.
  MIRROR_CHAIN="$SCRATCH/mirror-chain"
  mkdir -p "$MIRROR_CHAIN/api/tags" "$MIRROR_CHAIN/download/$OLD_TAG" "$MIRROR_CHAIN/download/$MID_TAG" "$MIRROR_CHAIN/download/$TAG"
  cp "$OLD_TARBALL" "$OLD_TARBALL.sha256" "$MIRROR_CHAIN/download/$OLD_TAG/"
  cp "$MID_TARBALL" "$MID_TARBALL.sha256" "$MIRROR_CHAIN/download/$MID_TAG/"
  cp "$TARBALL" "$CHECKSUM" "$MIRROR_CHAIN/download/$TAG/"
  release_json "$OLD_TAG" "fm-board-$OLD_TAG.tar.gz" "fm-board-$OLD_TAG.tar.gz.sha256" > "$MIRROR_CHAIN/api/tags/$OLD_TAG.json"
  release_json "$MID_TAG" "$MID_OLD_ASSET" "$MID_OLD_ASSET.sha256" > "$MIRROR_CHAIN/api/tags/$MID_TAG.json"
  release_json "$TAG" "$NEW_ASSET" "$NEW_ASSET.sha256" > "$MIRROR_CHAIN/api/tags/$TAG.json"
  chain_latest() { printf '{\n  "tag_name": "%s",\n  "prerelease": false\n}\n' "$1" > "$MIRROR_CHAIN/api/latest.json"; }
  chain() { offline_from "$MIRROR_CHAIN" "$@"; }
  SHAPE56="/$MID_NEW_ASSET 56 curl: (56) The requested URL returned error: 404"
  API_DOWN="/releases/tags/ 7 curl: (7) Failed to connect to api.github.com port 443"

  # 1. A 0.2.5 install made by the 0.2.5 installer (git show
  # v0.2.5:bin/install.sh), then reinstalled through the current installer
  # from stdin, the `curl | bash` shape the README documents for 0.2.5 and
  # 0.2.6 installs, against a latest release holding the current tarball under
  # the new name only: the new asset is downloaded, the new layout lands, both
  # commands work, the record says so, and a view-state file outside the
  # prefix comes through byte for byte (falsify: change the default prefix or
  # bin dir between releases, write the shims with a fixed launcher name, or
  # put view state under the prefix).
  CHAIN="$SCRATCH/chain"
  C_PREFIX="$CHAIN/prefix"
  C_BIN="$CHAIN/bin"
  C_VIEW="$CHAIN/config/fm-board/view-state.json"
  mkdir -p "$(dirname "$C_VIEW")"
  printf '{"schema":"fm-board-view-state.v1","hidden":["needs:1"],"hidden_panes":["landed"]}\n' > "$C_VIEW"
  C_VIEW_SHA=$(file_sha "$C_VIEW")
  chain_latest "$MID_TAG"
  if out=$(chain bash "$MID_INSTALLER" --prefix "$C_PREFIX" --bin-dir "$C_BIN" 2>&1); then pass; else fail "the 0.2.5 installer exited non-zero: $out"; fi
  assert_contains "$out" "firstmate-tui $MID_VERSION installed" "the 0.2.5 installer reports 0.2.5"
  assert_contains "$out" "downloaded $MID_OLD_ASSET" "the 0.2.5 installer fell back to the old name on the fake's exit 22"
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$MID_TAG/$MID_OLD_ASSET" "the 0.2.5 installer took the old asset name for the 0.2.5 release"
  assert_exec "$C_PREFIX/bin/fm-board.sh" "a 0.2.5 install has bin/fm-board.sh"
  assert_exec "$C_BIN/firstmate-tui" "a 0.2.5 install has the firstmate-tui command"
  assert_exec "$C_BIN/fm-board" "a 0.2.5 install has the fm-board alias"
  assert_contains "$(cat "$C_PREFIX/install-record")" "layout=fm-board" "the 0.2.5 record says layout=fm-board"
  assert_contains "$(cd / && "$C_BIN/firstmate-tui" version 2>&1)" "firstmate-tui $MID_VERSION (stable release)" "the 0.2.5 install calls itself firstmate-tui 0.2.5"
  chain_latest "$TAG"
  if out=$(cd / && chain bash -s -- --prefix "$C_PREFIX" --bin-dir "$C_BIN" < "$INSTALL" 2>&1); then pass; else fail "the reinstall through the current installer exited non-zero: $out"; fi
  assert_contains "$(cat "$CURL_LOG")" "/releases/latest" "the reinstall asks for the latest release"
  assert_contains "$(cat "$CURL_LOG")" "/releases/tags/$TAG" "the reinstall reads the release's asset list"
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$TAG/$NEW_ASSET" "the reinstall downloads the new asset name"
  assert_not_contains "$(cat "$CURL_LOG")" "$OLD_ASSET" "the reinstall never asks for the old name"
  assert_contains "$out" "checksum verified" "the reinstall verifies the download"
  assert_contains "$out" "firstmate-tui $VERSION installed (replaced $MID_VERSION)" "the reinstall reports the swap from 0.2.5"
  assert_exec "$C_PREFIX/bin/firstmate-tui.sh" "the new layout is installed"
  assert_absent "$C_PREFIX/bin/fm-board.sh" "the old launcher went with the previous install"
  assert_file "$C_PREFIX/bin/firstmate-tui/node_modules/neo-blessed/package.json" "the vendored dependency is installed under the new directory"
  assert_contains "$(cat "$C_PREFIX/install-record")" "layout=firstmate-tui" "the record names the new layout"
  assert_contains "$(cat "$C_PREFIX/install-record")" "version=$VERSION" "the record carries $VERSION"
  if out=$(cd / && "$C_BIN/firstmate-tui" version 2>&1); then pass; else fail "firstmate-tui version after the chain exited non-zero: $out"; fi
  assert_contains "$out" "firstmate-tui $VERSION (stable release)" "firstmate-tui version reports $VERSION"
  assert_contains "$out" "installed at $C_PREFIX" "version names the same prefix"
  if alias_out=$(cd / && "$C_BIN/fm-board" version 2>&1); then pass; else fail "fm-board version through the alias exited non-zero: $alias_out"; fi
  assert_equal "$alias_out" "$out" "fm-board version still works through the alias and says the same"
  assert_not_contains "$alias_out" "the command is now" "the alias prints nothing special (falsify: make ensure_new_command fire when both commands exist)"
  assert_contains "$(cat "$C_BIN/fm-board")" "$C_PREFIX/bin/firstmate-tui.sh" "the alias runs the new launcher"
  assert_contains "$(cat "$C_BIN/fm-board")" "former name" "the alias is marked as the former name"
  assert_equal "$(file_sha "$C_VIEW")" "$C_VIEW_SHA" "a view-state file outside the prefix is untouched by the chain"
  if frame=$(cd / && "$C_BIN/firstmate-tui" --render-once --fixture "$FIX/empty.json" --no-herdr --view-state "$C_VIEW" 2>&1); then pass; else fail "the upgraded command does not render: $frame"; fi
  # The file names the pane by id (landed), so its key number, 6 since the two PR panes moved together, is read from the current board.
  assert_contains "$frame" "· panes hidden: 6" "the upgraded command reads the view state kept from before (falsify: change the file shape between releases)"
  assert_equal "$(file_sha "$C_VIEW")" "$C_VIEW_SHA" "reading the view state does not rewrite it"
  assert_no_leftovers "$CHAIN" "the chain leaves no staging or previous directory"
  # From here on, `firstmate-tui upgrade` runs the current installer as usual.
  assert_equal "$(file_sha "$C_PREFIX/bin/install.sh")" "$(file_sha "$INSTALL")" "the install carries this tree's installer"
  if out=$(cd / && chain "$C_BIN/firstmate-tui" upgrade 2>&1); then pass; else fail "firstmate-tui upgrade after the reinstall exited non-zero: $out"; fi
  assert_contains "$out" "firstmate-tui $VERSION installed (replaced $VERSION)" "after the reinstall, firstmate-tui upgrade runs the current installer"
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$TAG/$NEW_ASSET" "and downloads the new asset name"
  # That installer never meets the answer that stopped 0.2.5 when the release
  # is readable, because it asks only for a name the release has; with the
  # API unreachable it meets it and moves past it to the old name. Both are
  # shown by going back to 0.2.5, whose new name is missing, and coming
  # forward again (falsify: bring back the exit-22 test in fetch, or die when
  # the asset-list read fails).
  if out=$(cd / && FAKE_CURL_FAIL="$SHAPE56" chain "$C_BIN/firstmate-tui" upgrade --version "$MID_VERSION" 2>&1); then pass; else fail "going back to 0.2.5 with the release readable exited non-zero: $out"; fi
  assert_not_contains "$(cat "$CURL_LOG")" "/$MID_NEW_ASSET" "with the release readable, the missing new name is never asked for"
  assert_contains "$out" "firstmate-tui $MID_VERSION installed (replaced $VERSION)" "going back to 0.2.5 completes"
  assert_equal "$(file_sha "$C_PREFIX/bin/install.sh")" "$(file_sha "$MID_INSTALLER")" "the install carries the 0.2.5 installer again"
  if out=$(cd / && chain "$C_BIN/firstmate-tui" upgrade 2>&1); then pass; else fail "coming forward through the 0.2.5 installer exited non-zero: $out"; fi
  assert_contains "$out" "firstmate-tui $VERSION installed (replaced $MID_VERSION)" "the 0.2.5 installer comes forward: the new name is there on its first try"
  if out=$(cd / && FAKE_CURL_FAIL="$API_DOWN"$'\n'"$SHAPE56" chain "$C_BIN/firstmate-tui" upgrade --version "$MID_VERSION" 2>&1); then pass; else fail "going back to 0.2.5 with the API unreachable should survive the exit-56 shape: $out"; fi
  assert_contains "$out" "could not read the asset list" "with the API unreachable the failed read is reported"
  assert_contains "$out" "The requested URL returned error: 404" "the exit-56 message is shown and moved past"
  assert_contains "$out" "downloading $MID_OLD_ASSET" "the upgrade fell back to the old name"
  assert_contains "$out" "firstmate-tui $MID_VERSION installed (replaced $VERSION)" "the upgrade survives the shape that stopped 0.2.5"
  if out=$(cd / && chain "$C_BIN/firstmate-tui" upgrade 2>&1); then pass; else fail "coming forward again exited non-zero: $out"; fi
  assert_contains "$(cd / && "$C_BIN/firstmate-tui" version 2>&1)" "firstmate-tui $VERSION (stable release)" "the chain ends on $VERSION"
  assert_equal "$(file_sha "$C_VIEW")" "$C_VIEW_SHA" "view state survives every step of the chain"
  assert_no_leftovers "$CHAIN" "the back-and-forth leaves no staging or previous directory"
  # The launcher's own write_command is the installer's, byte for byte: with
  # the firstmate-tui command deleted from the bin dir, one run through the
  # alias writes it back and says so once (falsify: change write_command in
  # one file only, or drop ensure_new_command).
  installer_shim=$(cat "$C_BIN/firstmate-tui")
  rm -f -- "${C_BIN:?}/firstmate-tui"
  if out=$(cd / && "$C_BIN/fm-board" version 2>&1); then pass; else fail "fm-board version with the firstmate-tui command missing exited non-zero: $out"; fi
  assert_contains "$out" "the command is now firstmate-tui" "the launcher says it wrote the command back"
  assert_exec "$C_BIN/firstmate-tui" "the firstmate-tui command is back"
  assert_equal "$(cat "$C_BIN/firstmate-tui")" "$installer_shim" "the launcher's shim and the installer's shim are identical"
  assert_not_contains "$(cd / && "$C_BIN/fm-board" version 2>&1)" "the command is now" "the line is printed once, not on every run"

  # 2. A second 0.2.5 install's own `firstmate-tui upgrade`. First the
  # reproduction: the 0.2.5 installer read curl exit 22 alone as "not there",
  # so against the exit-56 answer GitHub gave for the missing new name of a
  # 0.2.x release it stops with curl's status and never asks for the old name,
  # which is why the README documents the reinstall above (if this passes,
  # the fake no longer sends what GitHub sent). Then the same installer
  # against the current release: it asks for the new name first and finds it,
  # so that upgrade lands in one step (falsify: rename the asset again).
  CHAIN2="$SCRATCH/chain2"
  chain_latest "$MID_TAG"
  if out=$(chain bash "$MID_INSTALLER" --prefix "$CHAIN2/prefix" --bin-dir "$CHAIN2/bin" 2>&1); then pass; else fail "the second 0.2.5 install exited non-zero: $out"; fi
  if out=$(cd / && FAKE_CURL_FAIL="$SHAPE56" chain "$CHAIN2/bin/firstmate-tui" upgrade --version "$MID_VERSION" 2>&1); then fail "the 0.2.5 installer should stop on curl exit 56 for the new asset name (the fake no longer sends what GitHub sent): $out"; else pass; fi
  assert_contains "$out" "download failed" "the 0.2.5 installer reports a failed download"
  assert_contains "$out" "curl exit 56" "the 0.2.5 installer stops with curl's status"
  assert_not_contains "$(cat "$CURL_LOG")" "$MID_OLD_ASSET" "the 0.2.5 installer never asks for the old name after exit 56"
  assert_contains "$(cd / && "$CHAIN2/bin/firstmate-tui" version 2>&1)" "firstmate-tui $MID_VERSION (stable release)" "the failed run leaves the 0.2.5 install alone"
  chain_latest "$TAG"
  if out=$(cd / && chain "$CHAIN2/bin/firstmate-tui" upgrade 2>&1); then pass; else fail "firstmate-tui upgrade from a 0.2.5 install exited non-zero: $out"; fi
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$TAG/$NEW_ASSET" "the 0.2.5 installer downloads the new asset name"
  assert_contains "$out" "firstmate-tui $VERSION installed (replaced $MID_VERSION)" "the 0.2.5 installer installs the current release"
  assert_exec "$CHAIN2/prefix/bin/firstmate-tui.sh" "the 0.2.5 installer installs the new layout"
  assert_contains "$(cat "$CHAIN2/prefix/install-record")" "layout=firstmate-tui" "the 0.2.5 installer records the new layout"
  assert_contains "$(cd / && "$CHAIN2/bin/firstmate-tui" version 2>&1)" "firstmate-tui $VERSION (stable release)" "the upgraded command reports $VERSION"
  assert_contains "$(cd / && "$CHAIN2/bin/fm-board" version 2>&1)" "firstmate-tui $VERSION (stable release)" "the alias works after a 0.2.5 install's own upgrade"

  # 3. A 0.1.0 install made by the 0.1.0 installer runs that installer on
  # `fm-board upgrade`; it downloads fm-board-<tag>.tar.gz only, strips the
  # top-level directory whatever it is called, and looks for bin/fm-board.sh
  # inside, so it reaches 0.2.5, the last release under that name, and the
  # upgraded launcher then writes the firstmate-tui command (falsify: drop
  # ensure_new_command from the launcher, which 0.2.5 already carries, or
  # point the walk at a release that has no old asset).
  OLD="$SCRATCH/old"
  OLD_PREFIX="$OLD/prefix"
  OLD_BIN="$OLD/bin"
  chain_latest "$OLD_TAG"
  if out=$(chain bash "$OLD_INSTALLER" --prefix "$OLD_PREFIX" --bin-dir "$OLD_BIN" 2>&1); then pass; else fail "the 0.1.0 installer exited non-zero: $out"; fi
  assert_contains "$out" "fm-board $OLD_VERSION installed" "the 0.1.0 installer reports fm-board 0.1.0"
  assert_exec "$OLD_BIN/fm-board" "a 0.1.0 install has the fm-board command"
  assert_absent "$OLD_BIN/firstmate-tui" "a 0.1.0 install has no firstmate-tui command"
  assert_contains "$("$OLD_BIN/fm-board" version 2>&1)" "fm-board $OLD_VERSION (stable release)" "the 0.1.0 install calls itself fm-board 0.1.0"
  chain_latest "$MID_TAG"
  if out=$(cd / && chain "$OLD_BIN/fm-board" upgrade 2>&1); then pass; else fail "fm-board upgrade from the 0.1.0 install to 0.2.5 exited non-zero: $out"; fi
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$MID_TAG/$MID_OLD_ASSET" "the 0.1.0 installer downloads 0.2.5 under the old asset name"
  assert_not_contains "$(cat "$CURL_LOG")" "$MID_NEW_ASSET" "the 0.1.0 installer knows only the old asset name"
  assert_contains "$out" "checksum verified" "the 0.1.0 installer verifies the 0.2.5 tarball"
  assert_contains "$out" "fm-board $MID_VERSION installed (replaced $OLD_VERSION)" "the 0.1.0 installer reports the swap to 0.2.5 (in its own words)"
  assert_file "$OLD_PREFIX/bin/fm-board.sh" "the 0.2.5 install has bin/fm-board.sh where the 0.1.0 shim points"
  assert_absent "$OLD_BIN/firstmate-tui" "the 0.1.0 installer alone writes no firstmate-tui command; the launcher does, next"
  if out=$("$OLD_BIN/fm-board" version 2>&1); then pass; else fail "fm-board version after the upgrade to 0.2.5 exited non-zero: $out"; fi
  assert_contains "$out" "firstmate-tui $MID_VERSION (stable release)" "the upgraded install reports firstmate-tui 0.2.5"
  assert_contains "$out" "the command is now firstmate-tui" "the 0.2.5 launcher says it wrote the new command"
  assert_exec "$OLD_BIN/firstmate-tui" "the firstmate-tui command now exists beside fm-board"
  assert_contains "$(cat "$OLD_BIN/firstmate-tui")" "$OLD_PREFIX/bin/fm-board.sh" "the new command runs the 0.2.5 install"
  assert_not_contains "$("$OLD_BIN/firstmate-tui" version 2>&1)" "the command is now" "the rename line is printed once"
  assert_contains "$(cd / && "$OLD_BIN/firstmate-tui" --help 2>&1)" "this install: $OLD_PREFIX" "--help on the new command names the install"
  assert_no_leftovers "$OLD" "the 0.1.0 walk leaves no staging or previous directory"

  # 4. The same 0.1.0 installer pointed at the current release fails without
  # touching the install: that release carries no fm-board-<tag>.tar.gz, so an
  # install older than 0.2.5 must go through 0.2.5 (falsify: publish the
  # current tarball under the old name too).
  OLD2="$SCRATCH/old2"
  chain_latest "$OLD_TAG"
  if out=$(chain bash "$OLD_INSTALLER" --prefix "$OLD2/prefix" --bin-dir "$OLD2/bin" 2>&1); then pass; else fail "the second 0.1.0 install exited non-zero: $out"; fi
  chain_latest "$TAG"
  if out=$(cd / && chain "$OLD2/bin/fm-board" upgrade 2>&1); then fail "fm-board upgrade from a 0.1.0 install straight to $VERSION should fail: the release has no old-name asset"; else pass; fi
  assert_contains "$(cat "$CURL_LOG")" "/releases/download/$TAG/$OLD_ASSET" "the 0.1.0 installer asked for the old asset name"
  assert_not_contains "$(cat "$CURL_LOG")" "$NEW_ASSET" "the 0.1.0 installer never asks for the new one"
  assert_contains "$out" "download failed" "the 0.1.0 installer reports the missing asset as a failed download"
  assert_contains "$("$OLD2/bin/fm-board" version 2>&1)" "fm-board $OLD_VERSION (stable release)" "the 0.1.0 install is untouched by the failed upgrade"
  assert_absent "$OLD2/bin/firstmate-tui" "no firstmate-tui command appears after the failed upgrade"
  assert_no_leftovers "$OLD2" "the failed 0.1.0 upgrade leaves no staging directory"
fi

# --------------------------------------------------------- next-version
# scripts/next-version.sh picks the version the release workflow publishes:
# package.json's when its tag is free, else the next free patch counted from
# package.json; a minor or major bump in package.json wins while its tag is
# free; beta tags (v0.2.5-d8b290e) never count as taken; a version that is not
# X.Y.Z is refused with exit 2 before anything is built (falsify: compare tag
# prefixes instead of whole tags, count from the newest tag instead of
# package.json, or accept a -suffix).
NEXT="$ROOT/scripts/next-version.sh"
assert_next() { # <expected> <version> [tags...]
  local expected=$1 got
  shift
  got=$(bash "$NEXT" "$@" 2>&1) || true
  if [ "$got" = "$expected" ]; then pass; else fail "next-version $*: expected '$expected', got '$got'"; fi
}
assert_next 0.2.5 0.2.4 v0.2.4 v0.1.0 v0.2.5-d8b290e
assert_next 0.2.5 0.2.5 v0.2.4 v0.1.0
assert_next 0.2.6 0.2.4 v0.2.4 v0.2.5
assert_next 0.3.0 0.3.0 v0.2.4 v0.2.5
assert_next 0.2.4 0.2.4
next_err=$(mktemp "${TMPDIR:-/tmp}/fm-board-next.XXXXXX")
if bash "$NEXT" 0.2 v0.2.4 >/dev/null 2>"$next_err"; then fail "next-version: a two-part version must be refused"; else pass; fi
if grep -q "malformed version '0.2'" "$next_err"; then pass; else fail "next-version: the refusal names the malformed version, got '$(cat "$next_err")'"; fi
if bash "$NEXT" 0.2.5-d8b290e v0.2.4 >/dev/null 2>&1; then fail "next-version: a version with a -suffix must be refused"; else pass; fi
if bash "$NEXT" >/dev/null 2>&1; then fail "next-version: no arguments must be refused"; else pass; fi
rm -f "${next_err:?}"

# ------------------------------------------------------------- workflow
# Grep-level pins on the release workflow; actionlint is the structural check
# (see README "Releasing"). Each pin names the behavior the README promises.
wf=$(cat "$WORKFLOW")
# Every merge to main releases: both jobs pick the version with next-version.sh from the repository's
# tags, the main job commits a bump under the bot identity with the [skip ci] guard and pushes it with
# the built-in token, and the release is created at that commit (falsify: read the version from
# package.json alone, drop the marker, or target GITHUB_SHA after a bump).
if [ "$(printf '%s\n' "$wf" | grep -cF -- "bash scripts/next-version.sh \"\$version\"")" -eq 2 ]; then pass; else fail "both jobs pick the version with scripts/next-version.sh"; fi
assert_contains "$wf" "git ls-remote --tags --refs origin 'refs/tags/v*'" "the version pick reads the repository's tags"
assert_contains "$wf" "npm version \"\$next\" --no-git-tag-version" "a beta is stamped with the coming version in the checkout"
assert_contains "$wf" "npm version \"\$VERSION\" --no-git-tag-version" "the bump writes package.json and the lockfile with npm version"
assert_contains "$wf" "git commit -m \"Release \$VERSION [skip ci]\"" "the bump commit carries the [skip ci] guard"
assert_contains "$wf" "github-actions[bot]" "the bump is committed under the workflow's identity"
assert_contains "$wf" "git push origin HEAD:main" "the bump is pushed to main"
assert_contains "$wf" "steps.bump.outputs.sha || github.sha" "the release targets the bump commit when there is one"
assert_contains "$wf" "--target \"\$TARGET\"" "the release is created at that target"
assert_contains "$wf" "already released as" "a released package.json version is logged and the next free patch released instead"
assert_contains "$wf" "scripts/package.sh --commit \"\$GITHUB_SHA\"" "a branch push builds a per-commit beta with package.sh --commit (falsify: inline tar in the workflow)"
assert_contains "$wf" "scripts/package.sh \"\$TAG\"" "a main push builds the release with package.sh and the v<version> tag"
# The renamed package directory is the one the workflows read and bump; no
# bin/fm-board path is left in either (falsify: rename the directory back in
# one job).
if [ "$(printf '%s\n' "$wf" | grep -cF -- 'require("./bin/firstmate-tui/package.json")')" -eq 2 ]; then pass; else fail "both jobs read the version from bin/firstmate-tui/package.json"; fi
assert_contains "$wf" "cd bin/firstmate-tui && npm version" "the bump runs npm version in bin/firstmate-tui"
assert_not_contains "$wf" "bin/fm-board" "no bin/fm-board path is left in the release workflow"
assert_not_contains "$(cat "$ROOT/.github/workflows/test.yml")" "bin/fm-board" "no bin/fm-board path is left in the test workflow"
assert_contains "$(cat "$ROOT/.github/workflows/test.yml")" "working-directory: bin/firstmate-tui" "the test workflow installs the dependencies in bin/firstmate-tui"
assert_not_contains "$wf" "tags:" "no tag trigger: the workflow creates every tag itself (falsify: bring back the v* trigger)"
assert_contains "$wf" "branches: ['**']" "every branch push runs the workflow"
assert_contains "$wf" "github.ref != 'refs/heads/main'" "the beta job skips main"
assert_contains "$wf" "github.ref == 'refs/heads/main'" "the release job runs on main only"
assert_contains "$wf" "pull_request:" "a closed pull request runs the cleanup"
assert_contains "$wf" "types: [closed]" "only the closed event, merged or not"
assert_contains "$wf" "workflow_dispatch:" "a job can be re-run by hand"
assert_contains "$wf" "concurrency:" "pushes to one ref never race"
assert_contains "$wf" "group: release-\${{ github.ref }}" "the concurrency group is per ref"
assert_contains "$wf" "contents: write" "the token permission is contents: write"
assert_not_contains "$wf" "secrets." "no secret beyond the built-in token (falsify: add a PAT)"
assert_contains "$wf" "github.token" "the built-in token is used"
assert_contains "$wf" "gh release create" "releases are created with gh from the runner"
assert_contains "$wf" "--prerelease" "a beta is marked as a prerelease"
assert_contains "$wf" "--target \"\$GITHUB_SHA\"" "the tag is created at the pushed commit, never by hand"
assert_contains "$wf" "gh release delete" "betas are deleted with gh"
assert_contains "$wf" "--cleanup-tag" "deleting a beta deletes its tag too"
assert_contains "$wf" "KEEP_BETAS: 30" "at most 30 hash betas are kept"
assert_contains "$wf" "pulls/\$PR/commits" "the cleanup walks the PR's commits"
if printf '%s\n' "$wf" | grep -E '^[[:space:]]*-?[[:space:]]*uses:' | grep -Evq '@v[0-9]+[[:space:]]*$'; then fail "every action must be pinned to a major version tag: $(printf '%s\n' "$wf" | grep -E 'uses:' | tr -s ' ' | tr '\n' ' ')"; else pass; fi
# The README documents the same numbers and commands (falsify: change the
# retention in the workflow and not the README).
readme=$(cat "$ROOT/README.md")
assert_contains "$readme" "at most 30" "the README states the retention limit"
for cmd in "firstmate-tui upgrade --pre" "firstmate-tui upgrade --stable" "firstmate-tui upgrade --version" "firstmate-tui version" "firstmate-tui help" "firstmate-tui open --detached" "firstmate-tui focus"; do
  assert_contains "$readme" "$cmd" "the README documents $cmd"
done
# The release notes and the README name the command users type (falsify: leave
# `fm-board upgrade` in the workflow's notes or reintroduce it as a README command).
assert_contains "$wf" "printf 'firstmate-tui upgrade" "the release notes say firstmate-tui upgrade"
assert_not_contains "$wf" "printf 'fm-board upgrade" "the release notes no longer say fm-board upgrade"
assert_contains "$readme" "alias" "the README explains the fm-board alias"
assert_contains "$readme" "firstmate-tui-<tag>.tar.gz" "the README names the renamed asset"
assert_contains "$readme" "herdr plugin unlink firstmate.board" "the README says a plugin linked at the old path is relinked once"

printf '%s checks, %s failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
