#!/usr/bin/env bash
# bin/install.sh - install or upgrade fm-board from a GitHub Release.
#
#   curl -fsSL https://raw.githubusercontent.com/zachsibert/firstmate-tui/main/bin/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/zachsibert/firstmate-tui/main/bin/install.sh | bash -s -- --pre
#   curl -fsSL https://raw.githubusercontent.com/zachsibert/firstmate-tui/main/bin/install.sh | bash -s -- --version v0.2.0-beta.1
#   bin/install.sh [flags]          the same, from a checkout
#
# Downloads fm-board-<tag>.tar.gz and its .sha256 from the release, verifies
# the checksum, unpacks the tarball into --prefix and writes an `fm-board`
# command into --bin-dir that runs the installed bin/fm-board.sh. Re-running
# upgrades in place: the previous install under --prefix is replaced as a
# whole and the command is rewritten. Nothing else is touched: no shell rc
# file, no herdr config, nothing outside --prefix and --bin-dir.
#
# Needs curl (for the download), tar, and sha256sum or shasum. The installed
# board still needs what the README lists under "Requirements": a firstmate
# home in FM_HOME, herdr 0.8.x, Node 20 or newer, jq and bash.
#
# Everything runs from main() on the last line, so a download that breaks off
# part way through `curl | bash` runs nothing.
set -euo pipefail

REPO_DEFAULT=zachsibert/firstmate-tui

usage() {
  cat <<'EOF'
usage: install.sh [--version <tag> | --pre] [--prefix <dir>] [--bin-dir <dir>]
                  [--from-file <tarball>] [--repo <owner/name>]

  --version <tag>       install exactly this release tag, for example v0.2.0
                        or v0.2.0-beta.1 (default: the latest release that is
                        not a prerelease)
  --pre                 install the newest release, prereleases included
  --prefix <dir>        where the files go
                        (default: $XDG_DATA_HOME/fm-board, i.e. ~/.local/share/fm-board)
  --bin-dir <dir>       where the fm-board command goes (default: ~/.local/bin)
  --from-file <tar.gz>  install this local tarball instead of downloading one;
                        a <tar.gz>.sha256 beside it is verified when present
  --repo <owner/name>   GitHub repository to download from
                        (default: zachsibert/firstmate-tui)
  -h, --help            this text

Re-running upgrades in place. To uninstall, delete the prefix directory and
the fm-board command in the bin dir.
EOF
}

log() { printf 'install: %s\n' "$*"; }
die() {
  printf 'install: error: %s\n' "$*" >&2
  exit 2
}

abspath() {
  local p=${1%/}
  case "$p" in
    /*) printf '%s' "$p" ;;
    *) printf '%s/%s' "$PWD" "$p" ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

fetch() { # <url> <destination file>
  curl -fsSL --retry 3 --retry-delay 1 -o "$2" "$1" || die "download failed: $1"
}

# The GitHub releases API is JSON; the installer needs less than the board
# does, so the tag is read with grep and sed rather than jq or node.
first_tag_name() {
  grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/'
}

# resolve_tag <repo> <version> <pre>: print the tag to install
resolve_tag() {
  local repo=$1 version=$2 pre=$3 api body tag
  if [ -n "$version" ]; then
    case "$version" in
      v*) printf '%s' "$version" ;;
      *) printf 'v%s' "$version" ;;
    esac
    return 0
  fi
  api="https://api.github.com/repos/$repo/releases"
  if [ "$pre" -eq 1 ]; then
    body=$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "$api?per_page=1") \
      || die "could not list the releases of $repo (is the repository public, and does it have a release yet?)"
  else
    body=$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "$api/latest") \
      || die "could not find the latest release of $repo (no release yet? for a prerelease use --pre)"
  fi
  tag=$(printf '%s' "$body" | first_tag_name)
  [ -n "$tag" ] || die "the releases of $repo carry no tag_name; nothing to install"
  printf '%s' "$tag"
}

# check_prefix <dir>: the prefix is either absent, empty, or a previous install
check_prefix() {
  local prefix=$1
  [ "$prefix" != / ] && [ "$prefix" != "${HOME%/}" ] || die "refusing to install into $prefix"
  [ -e "$prefix" ] || return 0
  [ -d "$prefix" ] || die "$prefix exists and is not a directory"
  if [ ! -f "$prefix/bin/fm-board.sh" ] && [ -n "$(ls -A "$prefix")" ]; then
    die "$prefix exists and is not an fm-board install (no bin/fm-board.sh in it); pick another --prefix"
  fi
}

package_version() { # <package.json>: the "version" field, no node needed
  sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

# Scratch paths the EXIT trap removes: the download directory, the staging
# directory beside the prefix, and the previous install while it is being
# replaced. Script-level rather than local to main() so the trap still sees
# them after main returns, and every rm is guarded so an empty variable fails
# instead of widening the path.
tmp=''
staging=''
previous=''
cleanup() {
  [ -z "$tmp" ] || rm -rf -- "${tmp:?}"
  [ -z "$staging" ] || rm -rf -- "${staging:?}"
  [ -z "$previous" ] || rm -rf -- "${previous:?}"
}

main() {
  local version='' pre=0 prefix='' bin_dir='' from_file='' repo=$REPO_DEFAULT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --version) [ "$#" -ge 2 ] || die "--version needs a tag"; version=$2; shift ;;
      --pre) pre=1 ;;
      --prefix) [ "$#" -ge 2 ] || die "--prefix needs a directory"; prefix=$2; shift ;;
      --bin-dir) [ "$#" -ge 2 ] || die "--bin-dir needs a directory"; bin_dir=$2; shift ;;
      --from-file) [ "$#" -ge 2 ] || die "--from-file needs a tarball"; from_file=$2; shift ;;
      --repo) [ "$#" -ge 2 ] || die "--repo needs owner/name"; repo=$2; shift ;;
      *) die "unknown option $1 (see --help)" ;;
    esac
    shift
  done
  [ -n "$version" ] && [ "$pre" -eq 1 ] && die "--version and --pre exclude each other"
  [ -n "$version" ] && [ -n "$from_file" ] && die "--version has no effect with --from-file"
  [ -n "$from_file" ] && [ "$pre" -eq 1 ] && die "--pre has no effect with --from-file"

  prefix=$(abspath "${prefix:-${XDG_DATA_HOME:-$HOME/.local/share}/fm-board}")
  bin_dir=$(abspath "${bin_dir:-$HOME/.local/bin}")
  [ -n "$from_file" ] && from_file=$(abspath "$from_file")

  command -v tar >/dev/null 2>&1 || die "tar is required"
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || die "sha256sum or shasum is required to verify the download"
  [ -n "$from_file" ] || command -v curl >/dev/null 2>&1 || die "curl is required to download the release"
  check_prefix "$prefix"

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-board-install.XXXXXX")
  trap cleanup EXIT

  # ------------------------------------------------------------- obtain
  local tag='' tarball checksum=''
  if [ -n "$from_file" ]; then
    [ -f "$from_file" ] || die "no such tarball: $from_file"
    tarball=$from_file
    [ -f "$from_file.sha256" ] && checksum="$from_file.sha256"
    log "installing from $from_file"
  else
    tag=$(resolve_tag "$repo" "$version" "$pre")
    local asset="fm-board-$tag.tar.gz"
    local base="https://github.com/$repo/releases/download/$tag"
    log "downloading $asset from $repo release $tag"
    fetch "$base/$asset" "$tmp/$asset"
    fetch "$base/$asset.sha256" "$tmp/$asset.sha256"
    tarball="$tmp/$asset"
    checksum="$tmp/$asset.sha256"
  fi

  # ------------------------------------------------------------- verify
  if [ -n "$checksum" ]; then
    local expected actual
    expected=$(cut -d' ' -f1 < "$checksum")
    actual=$(sha256_of "$tarball")
    [ -n "$expected" ] && [ "$expected" = "$actual" ] \
      || die "checksum mismatch for $(basename "$tarball"): expected '$expected', got '$actual'"
    log "checksum verified"
  else
    log "no $(basename "$tarball").sha256 beside the tarball; skipping the checksum"
  fi
  local tops
  tops=$(tar -tzf "$tarball" | sed 's#^\./##; s#/.*##' | sort -u)
  [ "$(printf '%s\n' "$tops" | wc -l | tr -d ' ')" -eq 1 ] \
    || die "unexpected tarball layout: expected one top-level directory, found: $(printf '%s' "$tops" | tr '\n' ' ')"

  # ------------------------------------------------------------- unpack
  local parent
  parent=$(dirname "$prefix")
  mkdir -p "$parent"
  staging="$parent/.fm-board-install.$$"
  rm -rf -- "${staging:?}"
  mkdir "$staging"
  tar -xzf "$tarball" -C "$staging" --strip-components=1 || die "could not unpack $(basename "$tarball")"
  [ -f "$staging/bin/fm-board.sh" ] || die "the tarball has no bin/fm-board.sh; not an fm-board release"
  [ -f "$staging/bin/fm-board/node_modules/neo-blessed/package.json" ] \
    || die "the tarball has no vendored node_modules/neo-blessed; not an fm-board release"
  chmod +x "$staging/bin/fm-board.sh"
  local new_version old_version=''
  new_version=$(package_version "$staging/bin/fm-board/package.json")
  [ -f "$prefix/bin/fm-board/package.json" ] && old_version=$(package_version "$prefix/bin/fm-board/package.json")

  # -------------------------------------------------------------- place
  if [ -d "$prefix" ]; then
    previous="$parent/.fm-board-previous.$$"
    rm -rf -- "${previous:?}"
    mv "$prefix" "$previous"
  fi
  mv "$staging" "$prefix"
  staging=''
  [ -z "$previous" ] || rm -rf -- "${previous:?}"
  previous=''

  mkdir -p "$bin_dir"
  local shim="$bin_dir/fm-board" shim_tmp="$bin_dir/.fm-board.$$"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# fm-board: written by install.sh. The board lives in %s;\n' "$prefix"
    printf '# re-run install.sh to upgrade, or delete that directory and this file to uninstall.\n'
    printf 'exec bash %q "$@"\n' "$prefix/bin/fm-board.sh"
  } > "$shim_tmp"
  chmod +x "$shim_tmp"
  mv -f "$shim_tmp" "$shim"

  # ------------------------------------------------------------- report
  if [ -n "$old_version" ]; then
    log "fm-board ${new_version:-?} installed (replaced $old_version)"
  else
    log "fm-board ${new_version:-?} installed"
  fi
  log "  files:   $prefix"
  log "  command: $shim"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) log "note: $bin_dir is not on your PATH; add it, or run $shim by its full path" ;;
  esac
  log "next: export FM_HOME=<your firstmate home> and run fm-board (README: Requirements, Launch)"
}

main "$@"
