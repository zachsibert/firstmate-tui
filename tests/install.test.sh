#!/usr/bin/env bash
# tests/install.test.sh - the release tarball and the installer, offline.
#
# scripts/package.sh builds the tarball the release workflow publishes
# (.github/workflows/release.yml runs that script and nothing else to build
# it), so this suite builds one into a scratch directory, installs it with
# `bin/install.sh --from-file` into a scratch prefix and bin dir, and proves
# the installed `fm-board` command renders a frame from a fixture. Nothing
# reaches GitHub: no tag, no release, no download. --from-file is the switch
# that keeps the installer off the network, and the installer is also run the
# way `curl | bash` runs it, from stdin. Each check's comment names what would
# make it fail.
#
# Needs node and npm (scripts/package.sh runs `npm ci --omit=dev` to vendor
# neo-blessed), plus tar and shasum or sha256sum, which the installer needs
# too. No firstmate home, herdr server or TTY.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PACKAGE="$ROOT/scripts/package.sh"
INSTALL="$ROOT/bin/install.sh"
FIX="$ROOT/tests/fixtures"
WORKFLOW="$ROOT/.github/workflows/release.yml"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-board-install-test.XXXXXX")
# Canonical, because package.sh and the installer print canonical paths and
# macOS hands out TMPDIR with a trailing slash under a /private symlink.
SCRATCH=$(cd "$SCRATCH" && pwd -P)
trap 'rm -rf -- "${SCRATCH:?}"' EXIT

VERSION=$(node -p 'require(process.argv[1]).version' "$ROOT/bin/fm-board/package.json")
TAG="v$VERSION"
TAG_RE=${TAG//./\\.}

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
# assert_no_leftovers <dir> <label>: no staging or previous-install directory was left behind
assert_no_leftovers() {
  local left
  left=$(find "$1" -maxdepth 1 -name '.fm-board-*' 2>/dev/null)
  if [ -z "$left" ]; then pass; else fail "$2: leftover directories: $left"; fi
}

# ------------------------------------------------------------- packaging
DIST="$SCRATCH/dist"
if pkg_out=$("$PACKAGE" "$TAG" "$DIST" 2>"$SCRATCH/package.err"); then pass; else fail "package.sh $TAG exited non-zero: $(cat "$SCRATCH/package.err")"; fi
TARBALL="$DIST/fm-board-$TAG.tar.gz"
CHECKSUM="$TARBALL.sha256"
# stdout is only key=value lines because the workflow appends it to $GITHUB_OUTPUT (falsify: let npm ci write to stdout)
if printf '%s\n' "$pkg_out" | grep -Evq '^[a-z]+=' ; then fail "package.sh stdout has a line that is not key=value: $pkg_out"; else pass; fi
assert_contains "$pkg_out" "tag=$TAG" "package.sh reports the tag"
assert_contains "$pkg_out" "version=$VERSION" "package.sh reports the package.json version"
assert_contains "$pkg_out" "prerelease=false" "a plain vX.Y.Z tag is not a prerelease (falsify: test the version string for '-' instead of the tag)"
assert_contains "$pkg_out" "tarball=$TARBALL" "package.sh reports the tarball path"
assert_contains "$pkg_out" "checksum=$CHECKSUM" "package.sh reports the checksum path"
assert_file "$TARBALL" "the tarball exists"
assert_file "$CHECKSUM" "the checksum file exists"

listing=$(tar -tzf "$TARBALL")
tops=$(printf '%s\n' "$listing" | sed 's#/.*##' | sort -u)
if [ "$tops" = "fm-board-$TAG" ]; then pass; else fail "the tarball unpacks to one directory fm-board-$TAG, got: $(printf '%s' "$tops" | tr '\n' ' ') (falsify: tar the staging contents without the top directory)"; fi
assert_contains "$listing" "fm-board-$TAG/bin/fm-board.sh" "the wrapper ships"
assert_contains "$listing" "fm-board-$TAG/bin/fm-board/index.mjs" "the entry point ships"
assert_contains "$listing" "fm-board-$TAG/bin/fm-board/package.json" "package.json ships (the installer reads the version from it)"
assert_contains "$listing" "fm-board-$TAG/bin/fm-board/package-lock.json" "the lockfile ships"
assert_contains "$listing" "fm-board-$TAG/bin/fm-board/herdr-plugin.toml" "the herdr plugin manifest ships"
for f in "$ROOT"/bin/fm-board/lib/*.mjs; do
  assert_contains "$listing" "fm-board-$TAG/bin/fm-board/lib/$(basename "$f")" "every lib module ships (falsify: copy lib files by name in package.sh and miss one)"
done
assert_contains "$listing" "fm-board-$TAG/bin/fm-board/node_modules/neo-blessed/package.json" "production node_modules are vendored (falsify: drop npm ci from package.sh)"
assert_contains "$listing" "fm-board-$TAG/README.md" "the README ships"
for unwanted in "/tests/" "/docs/" "/scripts/" "/.git" "install.sh" ".gitignore" "/.claude/"; do
  assert_not_contains "$listing" "$unwanted" "the tarball carries no $unwanted (falsify: tar the repository root)"
done

assert_match "$(cat "$CHECKSUM")" "^[0-9a-f]{64}  fm-board-$TAG_RE\.tar\.gz\$" "the checksum file is sha256sum format with the bare file name (falsify: hash the tarball by absolute path)"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$DIST" && sha256sum -c -- "fm-board-$TAG.tar.gz.sha256") >/dev/null 2>&1
else
  (cd "$DIST" && shasum -a 256 -c -- "fm-board-$TAG.tar.gz.sha256") >/dev/null 2>&1
fi
# shellcheck disable=SC2181 # the command above is a two-way branch; its status is what is tested
if [ "$?" -eq 0 ]; then pass; else fail "the checksum file verifies the tarball in -c mode, as the workflow checks it"; fi

# A tag that is not v<package.json version> is refused before anything is built
# (falsify: drop the tag = v$version check in package.sh).
if out=$("$PACKAGE" v9.9.9 "$SCRATCH/dist-bad" 2>&1); then fail "package.sh v9.9.9 against version $VERSION should exit non-zero"; else pass; fi
assert_contains "$out" "v9.9.9" "the mismatch error names the tag"
assert_contains "$out" "$VERSION" "the mismatch error names the package.json version"
assert_absent "$SCRATCH/dist-bad/fm-board-v9.9.9.tar.gz" "nothing is built for a mismatched tag"
if out=$("$PACKAGE" "$VERSION" "$SCRATCH/dist-bad" 2>&1); then fail "a tag without the v prefix should be refused"; else pass; fi
assert_contains "$out" "vX.Y.Z" "the malformed-tag error shows the expected shape"

# A prerelease version: a copy of the tree at 0.2.0-beta.1 packages under
# v0.2.0-beta.1 and is flagged prerelease=true; v0.2.0 against it is refused.
PRE_VERSION=0.2.0-beta.1
PRE_TAG="v$PRE_VERSION"
PRE_REPO="$SCRATCH/pre-repo"
mkdir -p "$PRE_REPO/bin" "$PRE_REPO/scripts"
cp "$ROOT/bin/fm-board.sh" "$PRE_REPO/bin/fm-board.sh"
cp -R "$ROOT/bin/fm-board" "$PRE_REPO/bin/fm-board"
rm -rf -- "${PRE_REPO:?}/bin/fm-board/node_modules"
cp "$PACKAGE" "$PRE_REPO/scripts/package.sh"
cp "$ROOT/README.md" "$PRE_REPO/README.md"
sed -i.bak "s/\"version\": \"$VERSION\"/\"version\": \"$PRE_VERSION\"/" "$PRE_REPO/bin/fm-board/package.json" "$PRE_REPO/bin/fm-board/package-lock.json"
rm -f -- "${PRE_REPO:?}/bin/fm-board/"*.bak
if pre_out=$("$PRE_REPO/scripts/package.sh" "$PRE_TAG" "$SCRATCH/dist-pre" 2>"$SCRATCH/pre.err"); then pass; else fail "package.sh $PRE_TAG exited non-zero: $(cat "$SCRATCH/pre.err")"; fi
assert_contains "$pre_out" "prerelease=true" "a tag with a -suffix is flagged as a prerelease for the workflow (falsify: drop the *-* case in package.sh)"
assert_contains "$pre_out" "version=$PRE_VERSION" "the prerelease version is reported"
assert_file "$SCRATCH/dist-pre/fm-board-$PRE_TAG.tar.gz" "the prerelease tarball carries the full tag in its name"
if "$PRE_REPO/scripts/package.sh" v0.2.0 "$SCRATCH/dist-pre-bad" >/dev/null 2>&1; then fail "v0.2.0 against version $PRE_VERSION should be refused"; else pass; fi

# -------------------------------------------------------------- install
PREFIX="$SCRATCH/prefix"
BIN="$SCRATCH/bin"
if inst_out=$("$INSTALL" --from-file "$TARBALL" --prefix "$PREFIX" --bin-dir "$BIN" 2>&1); then pass; else fail "install.sh --from-file exited non-zero: $inst_out"; fi
assert_contains "$inst_out" "checksum verified" "the .sha256 beside a local tarball is verified (falsify: skip verification under --from-file)"
assert_contains "$inst_out" "fm-board $VERSION installed" "the report names the installed version (falsify: stop reading package.json in the installer)"
assert_contains "$inst_out" "files:   $PREFIX" "the report names the prefix"
assert_contains "$inst_out" "command: $BIN/fm-board" "the report names the command"
assert_contains "$inst_out" "$BIN is not on your PATH" "a bin dir that is not on PATH gets the one-line note (falsify: drop the PATH check)"
assert_file "$PREFIX/bin/fm-board.sh" "the wrapper is installed"
assert_exec "$PREFIX/bin/fm-board.sh" "the wrapper is executable"
assert_file "$PREFIX/bin/fm-board/index.mjs" "the entry point is installed"
assert_file "$PREFIX/bin/fm-board/node_modules/neo-blessed/package.json" "the vendored dependency is installed"
assert_file "$PREFIX/README.md" "the README is installed"
assert_exec "$BIN/fm-board" "the fm-board command is executable"
assert_contains "$(cat "$BIN/fm-board")" "$PREFIX/bin/fm-board.sh" "the command runs the installed wrapper, not the checkout (falsify: point the shim at the checkout)"
assert_no_leftovers "$SCRATCH" "a successful install leaves no staging directory"

# The installed command renders a frame from a fixture, from an unrelated
# working directory (falsify: leave lib/ out of the tarball, or make the shim
# a symlink so fm-board.sh resolves ROOT to the bin dir).
if frame=$(cd / && "$BIN/fm-board" --render-once --fixture "$FIX/populated.json" --no-herdr 2>&1); then pass; else fail "installed fm-board --render-once exited non-zero: $frame"; fi
assert_contains "$frame" "Needs you (4)" "the installed command prints the Needs you pane"
assert_contains "$frame" "In flight" "the installed command prints the In flight pane"
assert_contains "$frame" "blocked: gh auth expired" "the installed command prints fixture rows"
# The vendored neo-blessed loads from the installed tree (a one-shot render
# never imports it, so this is the check that the vendoring is complete;
# falsify: delete node_modules/neo-blessed/lib from the tarball).
loaded=$(cd "$PREFIX/bin/fm-board" && node --input-type=module -e "const b = (await import('neo-blessed')).default; process.stdout.write(typeof b.screen);" 2>&1)
if [ "$loaded" = function ]; then pass; else fail "neo-blessed does not load from the installed tree: $loaded"; fi

# The command runs the installed copy: a marker written into the installed
# wrapper's usage text shows through the command (falsify: exec the checkout).
sed -i.bak '2s/^#/# INSTALLED-COPY-MARKER/' "$PREFIX/bin/fm-board.sh" && rm -f -- "${PREFIX:?}/bin/fm-board.sh.bak"
assert_contains "$("$BIN/fm-board" --help 2>&1)" "INSTALLED-COPY-MARKER" "fm-board --help comes from the installed wrapper"

# Re-running upgrades in place: the old tree goes as a whole, the report names
# the replaced version, and the command still works.
touch "$PREFIX/stale-file"
if up_out=$("$INSTALL" --from-file "$TARBALL" --prefix "$PREFIX" --bin-dir "$BIN" 2>&1); then pass; else fail "second install.sh run exited non-zero: $up_out"; fi
assert_contains "$up_out" "installed (replaced $VERSION)" "a second run reports the version it replaced (falsify: read the old version after the move)"
assert_absent "$PREFIX/stale-file" "the previous install is replaced as a whole, not overlaid (falsify: extract over the existing prefix)"
assert_not_contains "$("$BIN/fm-board" --help 2>&1)" "INSTALLED-COPY-MARKER" "the wrapper is the fresh copy after the upgrade"
if frame=$(cd / && "$BIN/fm-board" --render-once --fixture "$FIX/empty.json" --no-herdr 2>&1); then pass; else fail "installed fm-board after upgrade exited non-zero: $frame"; fi
assert_contains "$frame" "Needs you (0)" "the upgraded command renders"
assert_no_leftovers "$SCRATCH" "an upgrade leaves no staging or previous directory"

# A wrong checksum stops the install and leaves the existing one alone
# (falsify: log the mismatch instead of exiting).
BAD="$SCRATCH/bad"
mkdir -p "$BAD"
cp "$TARBALL" "$CHECKSUM" "$BAD/"
first=$(cut -c1 "$BAD/fm-board-$TAG.tar.gz.sha256")
flipped=0
[ "$first" = 0 ] && flipped=1
sed -i.bak "s/^./$flipped/" "$BAD/fm-board-$TAG.tar.gz.sha256" && rm -f -- "${BAD:?}/"*.bak
touch "$PREFIX/untouched-marker"
if out=$("$INSTALL" --from-file "$BAD/fm-board-$TAG.tar.gz" --prefix "$PREFIX" --bin-dir "$BIN" 2>&1); then fail "a wrong checksum should stop the install"; else pass; fi
assert_contains "$out" "checksum mismatch" "the error names the checksum mismatch"
assert_file "$PREFIX/untouched-marker" "a failed verification leaves the existing install alone"
assert_file "$PREFIX/bin/fm-board.sh" "the existing install survives a failed verification"
assert_no_leftovers "$SCRATCH" "a failed install leaves no staging directory"
rm -f -- "${PREFIX:?}/untouched-marker"
# A damaged tarball beside a correct checksum file fails the same way.
cp "$TARBALL" "$CHECKSUM" "$BAD/"
printf 'x' >> "$BAD/fm-board-$TAG.tar.gz"
if out=$("$INSTALL" --from-file "$BAD/fm-board-$TAG.tar.gz" --prefix "$SCRATCH/prefix-damaged" --bin-dir "$BIN" 2>&1); then fail "a damaged tarball should stop the install"; else pass; fi
assert_contains "$out" "checksum mismatch" "the damaged tarball is caught by the checksum"
assert_absent "$SCRATCH/prefix-damaged" "a damaged tarball installs nothing"

# A local tarball with no .sha256 beside it installs and says the checksum was skipped.
NOSUM="$SCRATCH/nosum"
mkdir -p "$NOSUM"
cp "$TARBALL" "$NOSUM/"
if out=$("$INSTALL" --from-file "$NOSUM/fm-board-$TAG.tar.gz" --prefix "$SCRATCH/prefix-nosum" --bin-dir "$SCRATCH/bin-nosum" 2>&1); then pass; else fail "install without a checksum file exited non-zero: $out"; fi
assert_contains "$out" "skipping the checksum" "a missing .sha256 is reported, not silent (falsify: drop the else branch)"
assert_file "$SCRATCH/prefix-nosum/bin/fm-board.sh" "the install without a checksum file completes"

# A prefix that exists and is not an fm-board install is refused untouched
# (falsify: remove the prefix without looking at it).
mkdir -p "$SCRATCH/other"
echo keep > "$SCRATCH/other/keep.txt"
if out=$("$INSTALL" --from-file "$TARBALL" --prefix "$SCRATCH/other" --bin-dir "$BIN" 2>&1); then fail "a prefix holding unrelated files should be refused"; else pass; fi
assert_contains "$out" "not an fm-board install" "the refusal says why"
assert_file "$SCRATCH/other/keep.txt" "the unrelated prefix is left alone"

# Defaults: ~/.local/share/fm-board and ~/.local/bin under HOME, XDG_DATA_HOME
# honored, and nothing else under HOME is written (falsify: append to ~/.bashrc).
FAKE_HOME="$SCRATCH/home"
mkdir -p "$FAKE_HOME"
if out=$(cd "$SCRATCH" && env -u XDG_DATA_HOME HOME="$FAKE_HOME" "$INSTALL" --from-file "$TARBALL" 2>&1); then pass; else fail "install with default paths exited non-zero: $out"; fi
assert_file "$FAKE_HOME/.local/share/fm-board/bin/fm-board.sh" "the default prefix is ~/.local/share/fm-board"
assert_file "$FAKE_HOME/.local/bin/fm-board" "the default bin dir is ~/.local/bin"
others=$(find "$FAKE_HOME" -type f ! -path "$FAKE_HOME/.local/share/fm-board/*" ! -path "$FAKE_HOME/.local/bin/fm-board")
if [ -z "$others" ]; then pass; else fail "the installer wrote outside the prefix and the bin dir: $others"; fi
if out=$(env XDG_DATA_HOME="$SCRATCH/xdg" HOME="$FAKE_HOME" "$INSTALL" --from-file "$TARBALL" --bin-dir "$SCRATCH/bin-xdg" 2>&1); then pass; else fail "install with XDG_DATA_HOME exited non-zero: $out"; fi
assert_file "$SCRATCH/xdg/fm-board/bin/fm-board.sh" "XDG_DATA_HOME moves the default prefix"
# Relative --prefix, --bin-dir and --from-file resolve against the working directory.
if out=$(cd "$SCRATCH" && "$INSTALL" --from-file "dist/fm-board-$TAG.tar.gz" --prefix rel-prefix --bin-dir rel-bin 2>&1); then pass; else fail "install with relative paths exited non-zero: $out"; fi
assert_file "$SCRATCH/rel-prefix/bin/fm-board.sh" "a relative --prefix lands under the working directory"
assert_contains "$(cat "$SCRATCH/rel-bin/fm-board")" "$SCRATCH/rel-prefix/bin/fm-board.sh" "the shim carries the absolute prefix even when --prefix was relative"

# `curl | bash` shape: the script runs from stdin, with arguments after `-s --`,
# and never reads BASH_SOURCE (falsify: derive usage from BASH_SOURCE, or move
# code out of main()).
if out=$(bash -s -- --from-file "$TARBALL" --prefix "$SCRATCH/prefix-stdin" --bin-dir "$SCRATCH/bin-stdin" < "$INSTALL" 2>&1); then pass; else fail "install.sh from stdin exited non-zero: $out"; fi
assert_file "$SCRATCH/prefix-stdin/bin/fm-board.sh" "the stdin run installs"
assert_not_contains "$(cat "$INSTALL")" "BASH_SOURCE" "install.sh never reads BASH_SOURCE (empty under curl | bash)"
if [ "$(tail -n 1 "$INSTALL")" = 'main "$@"' ]; then pass; else fail "install.sh must end with main \"\$@\" so a truncated download runs nothing"; fi

# Flag errors and --help (falsify: drop the guard named in each label).
if out=$("$INSTALL" --version v1.0.0 --pre 2>&1); then fail "--version with --pre should exit non-zero"; else pass; fi
assert_contains "$out" "exclude each other" "--version and --pre are named as exclusive"
if out=$("$INSTALL" --from-file "$SCRATCH/nope.tar.gz" --prefix "$SCRATCH/p" --bin-dir "$SCRATCH/b" 2>&1); then fail "a missing --from-file should exit non-zero"; else pass; fi
assert_contains "$out" "no such tarball" "a missing tarball is named"
if out=$("$INSTALL" --from-file "$TARBALL" --version v1.0.0 2>&1); then fail "--version with --from-file should exit non-zero"; else pass; fi
assert_contains "$out" "no effect" "--version under --from-file is refused, not ignored"
if out=$("$INSTALL" --bogus 2>&1); then fail "an unknown flag should exit non-zero"; else pass; fi
assert_contains "$out" "unknown option --bogus" "the unknown flag is named"
if out=$("$INSTALL" --prefix 2>&1); then fail "--prefix without a value should exit non-zero"; else pass; fi
assert_contains "$out" "--prefix needs a directory" "--prefix without a value is named"
if help=$("$INSTALL" --help 2>&1); then pass; else fail "--help should exit 0"; fi
for flag in --version --pre --prefix --bin-dir --from-file --repo; do
  assert_contains "$help" "$flag" "--help lists $flag"
done

# ------------------------------------------------------------- workflow
# Grep-level pins on the release workflow; actionlint is the structural check
# (see README "Releasing").
wf=$(cat "$WORKFLOW")
assert_contains "$wf" "scripts/package.sh" "the workflow builds with the script this suite ran (falsify: inline tar in the workflow)"
assert_contains "$wf" "- 'v*'" "the workflow runs on v* tags"
assert_contains "$wf" "contents: write" "the token permission is contents: write"
assert_not_contains "$wf" "secrets." "no secret beyond the built-in token (falsify: add a PAT)"
assert_contains "$wf" "github.token" "the built-in token is used"
assert_contains "$wf" "gh release create" "the release is created with gh from the runner"
assert_contains "$wf" "--prerelease" "a prerelease tag is marked as one"
assert_contains "$wf" "steps.package.outputs.prerelease" "the prerelease flag comes from package.sh"
if printf '%s\n' "$wf" | grep -E '^[[:space:]]*-?[[:space:]]*uses:' | grep -Evq '@v[0-9]+[[:space:]]*$'; then fail "every action must be pinned to a major version tag: $(printf '%s\n' "$wf" | grep -E 'uses:' | tr -s ' ' | tr '\n' ' ')"; else pass; fi

printf '%s checks, %s failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
