#!/usr/bin/env bash
# bin/install.sh - install or upgrade firstmate-tui from a GitHub Release.
#
#   curl -fsSL https://raw.githubusercontent.com/zachsibert/firstmate-tui/main/bin/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/zachsibert/firstmate-tui/main/bin/install.sh | bash -s -- --pre
#   curl -fsSL https://raw.githubusercontent.com/zachsibert/firstmate-tui/main/bin/install.sh | bash -s -- --version 0.1.0-d8b290e
#   bin/install.sh [flags]          the same, from a checkout
#   firstmate-tui upgrade [flags]   the same, from an install: runs the copy of
#                                   this script that shipped in the tarball
#
# Downloads the release tarball and its .sha256, verifies the checksum,
# unpacks the tarball into --prefix and writes a `firstmate-tui` command into
# --bin-dir that runs the installed launcher, plus `fm-board`, the command's
# former name, as an alias for one release.
# Re-running upgrades in place: the download is verified and unpacked beside
# the prefix first, then the previous install is replaced as a whole and the
# commands are rewritten. Versions are never compared, so moving from a beta
# back to the stable release (a lower version) is the same step as any
# upgrade. Nothing else is touched: no shell rc file, no herdr config, nothing
# outside --prefix and --bin-dir; the board's view state lives outside both.
#
# Two names, on purpose. Since 0.3.0 the release asset is
# firstmate-tui-<tag>.tar.gz and the launcher and package inside it are
# bin/firstmate-tui.sh and bin/firstmate-tui/. Up to 0.2.x they were
# fm-board-<tag>.tar.gz, bin/fm-board.sh and bin/fm-board/, after the
# command's name up to 0.1.0. An install upgrades by running the copy of this
# script that shipped in its own tarball, so this installer keeps both names:
# it asks for firstmate-tui-<tag>.tar.gz first and falls back to
# fm-board-<tag>.tar.gz when the release has no asset under the new name
# (which is how `firstmate-tui upgrade --version 0.2.5` goes back to a 0.2.x
# release), accepts either layout inside the tarball (bin/firstmate-tui.sh
# with bin/firstmate-tui/, or bin/fm-board.sh with bin/fm-board/, never a
# mix), writes the commands to run whichever launcher the tree has, and notes
# the layout in the install record (layout=). The 0.2.5 installer was the
# first to do this, so an install older than 0.2.5, whose installer downloads
# the old name only, reaches 0.3.0 by upgrading to 0.2.5 first. The default
# prefix stays ~/.local/share/fm-board. AGENTS.md carries the history.
#
# The install record, <prefix>/install-record, is one key=value file naming
# the prefix, the bin dir, the repository, what was installed and the layout.
# `firstmate-tui upgrade` reads it and runs this script again with those values.
#
# Needs curl (for the download), tar, and sha256sum or shasum. The installed
# board still needs what the README lists under "Prerequisites": a firstmate
# home in FM_HOME, herdr 0.8.x, Node 20 or newer, jq and bash.
#
# Everything runs from main() on the last line, so a download that breaks off
# part way through `curl | bash` runs nothing.
set -euo pipefail

REPO_DEFAULT=zachsibert/firstmate-tui
NAME=firstmate-tui
OLD_NAME=fm-board

usage() {
  cat <<'EOF'
usage: install.sh [--stable | --pre | --version <version>] [--prefix <dir>]
                  [--bin-dir <dir>] [--from-file <tarball>] [--repo <owner/name>]

  --stable              the latest release that is not a beta (the default)
  --pre                 the newest release, betas included
  --version <version>   exactly this version, for example 0.2.0 or the beta
                        0.1.0-d8b290e (a leading v is accepted: v0.2.0)
  --prefix <dir>        where the files go
                        (default: $XDG_DATA_HOME/fm-board, i.e. ~/.local/share/fm-board)
  --bin-dir <dir>       where the firstmate-tui command goes, with fm-board, its
                        former name, beside it as an alias (default: ~/.local/bin)
  --from-file <tar.gz>  install this local tarball instead of downloading one
                        (firstmate-tui-<tag>.tar.gz or fm-board-<tag>.tar.gz);
                        a <tar.gz>.sha256 beside it is verified when present
  --repo <owner/name>   GitHub repository to download from
                        (default: zachsibert/firstmate-tui)
  -h, --help            this text

Re-running upgrades in place, in either direction: a beta can replace the
stable release and --stable brings the stable release back. Once installed,
`firstmate-tui upgrade` takes the same channel flags. To uninstall, delete
the prefix directory and the firstmate-tui and fm-board commands in the bin
dir.
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

# fetch <url> <destination file>: status 0 when downloaded. Status 22, curl's
# own status for an HTTP error under -f, means the URL is not there (GitHub
# answers 404 for an asset a release does not have), so the caller may try
# another name; curl does not retry a 404. Any other failure (no connection,
# a broken transfer) is an error here and now.
fetch() {
  local status=0
  curl -fsSL --retry 3 --retry-delay 1 -o "$2" "$1" || status=$?
  case "$status" in
    0) return 0 ;;
    22) rm -f -- "${2:?}"; return 22 ;;
    *) die "download failed: $1 (curl exit $status)" ;;
  esac
}

# The GitHub releases API is JSON; the installer needs less than the board
# does, so the tag is read with grep and sed rather than jq or node.
first_tag_name() {
  grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/'
}

# resolve_tag <repo> <version> <pre>: print the tag to install. --version
# names it directly (with or without the v); --pre takes the most recently
# published release of any kind; the default is GitHub's "latest", which is
# never a prerelease.
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
      || die "could not find the latest release of $repo (no release yet? for a beta use --pre)"
  fi
  tag=$(printf '%s' "$body" | first_tag_name)
  [ -n "$tag" ] || die "the releases of $repo carry no tag_name; nothing to install"
  printf '%s' "$tag"
}

# tree_layout <dir>: the layout of the install or unpacked tarball under
# <dir>, named after its launcher: firstmate-tui (bin/firstmate-tui.sh and
# bin/firstmate-tui/) or fm-board (bin/fm-board.sh and bin/fm-board/), the
# new name first. Prints nothing and returns 1 when <dir> has neither.
tree_layout() {
  local layout
  for layout in "$NAME" "$OLD_NAME"; do
    if [ -f "$1/bin/$layout.sh" ]; then
      printf '%s' "$layout"
      return 0
    fi
  done
  return 1
}

# check_prefix <dir>: the prefix is either absent, empty, or a previous install
check_prefix() {
  local prefix=$1
  [ "$prefix" != / ] && [ "$prefix" != "${HOME%/}" ] || die "refusing to install into $prefix"
  [ -e "$prefix" ] || return 0
  [ -d "$prefix" ] || die "$prefix exists and is not a directory"
  if ! tree_layout "$prefix" >/dev/null && [ -n "$(ls -A "$prefix")" ]; then
    die "$prefix exists and is not a $NAME install (no bin/$NAME.sh or bin/$OLD_NAME.sh in it); pick another --prefix"
  fi
}

package_version() { # <package.json>: the "version" field, no node needed
  sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

# write_command <bin dir> <name> <prefix> <launcher>: the command that runs
# <prefix>/<launcher> (bin/firstmate-tui.sh or bin/fm-board.sh, whichever the
# install has), written whole to a temporary name and moved into place.
# bin/firstmate-tui.sh carries a write_command of its own so a launcher whose
# bin dir has only the fm-board command can add the firstmate-tui command
# itself; the shim text must stay byte for byte the same here and there
# (tests/install.test.sh compares the two).
write_command() {
  local bin_dir=$1 name=$2 prefix=$3 launcher=$4 shim_tmp
  shim_tmp="$bin_dir/.$name.$$"
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$name" = "$OLD_NAME" ]; then
      printf '# %s: the former name of %s, kept for one release; written by install.sh.\n' "$name" "$NAME"
    else
      printf '# %s: written by install.sh.\n' "$name"
    fi
    printf '# The board lives in %s; run "%s upgrade" to upgrade,\n' "$prefix" "$NAME"
    printf '# or delete that directory and the %s and %s commands here to uninstall.\n' "$NAME" "$OLD_NAME"
    printf 'exec bash %q "$@"\n' "$prefix/$launcher"
  } > "$shim_tmp"
  chmod +x "$shim_tmp"
  mv -f "$shim_tmp" "$bin_dir/$name"
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
  local version='' pre=0 stable=0 prefix='' bin_dir='' from_file='' repo=$REPO_DEFAULT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --version) [ "$#" -ge 2 ] || die "--version needs a version"; version=$2; shift ;;
      --pre) pre=1 ;;
      --stable) stable=1 ;;
      --prefix) [ "$#" -ge 2 ] || die "--prefix needs a directory"; prefix=$2; shift ;;
      --bin-dir) [ "$#" -ge 2 ] || die "--bin-dir needs a directory"; bin_dir=$2; shift ;;
      --from-file) [ "$#" -ge 2 ] || die "--from-file needs a tarball"; from_file=$2; shift ;;
      --repo) [ "$#" -ge 2 ] || die "--repo needs owner/name"; repo=$2; shift ;;
      *) die "unknown option $1 (see --help)" ;;
    esac
    shift
  done
  local channels=0
  [ -n "$version" ] && channels=$((channels + 1))
  [ "$pre" -eq 1 ] && channels=$((channels + 1))
  [ "$stable" -eq 1 ] && channels=$((channels + 1))
  [ "$channels" -le 1 ] || die "--stable, --pre and --version exclude each other"
  [ -n "$version" ] && [ -n "$from_file" ] && die "--version has no effect with --from-file"
  [ "$pre" -eq 1 ] && [ -n "$from_file" ] && die "--pre has no effect with --from-file"
  [ "$stable" -eq 1 ] && [ -n "$from_file" ] && die "--stable has no effect with --from-file"

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
  local tag='' tarball checksum='' installed_from
  if [ -n "$from_file" ]; then
    [ -f "$from_file" ] || die "no such tarball: $from_file"
    tarball=$from_file
    [ -f "$from_file.sha256" ] && checksum="$from_file.sha256"
    installed_from="file $from_file"
    log "installing from $from_file"
  else
    tag=$(resolve_tag "$repo" "$version" "$pre")
    local base="https://github.com/$repo/releases/download/$tag"
    local new_asset="$NAME-$tag.tar.gz" old_asset="$OLD_NAME-$tag.tar.gz" asset
    installed_from="release $tag"
    # The asset's new name first, its former name when the release has no
    # asset under the new one (see the header). fetch stops the install
    # itself on any failure that is not a missing asset.
    log "downloading $new_asset from $repo release $tag"
    if fetch "$base/$new_asset" "$tmp/$new_asset"; then
      asset=$new_asset
    elif fetch "$base/$old_asset" "$tmp/$old_asset"; then
      asset=$old_asset
      log "release $tag has no $new_asset; downloaded $old_asset, the asset's former name, instead"
    else
      die "download failed: release $tag of $repo has neither $new_asset nor $old_asset (looked under $base)"
    fi
    fetch "$base/$asset.sha256" "$tmp/$asset.sha256" \
      || die "download failed: $base/$asset.sha256 (the release has $asset but not its checksum)"
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
  # Either layout (see the header), and nothing in between: the launcher and
  # the package directory beside it carry the same name.
  local layout launcher pkg_dir
  layout=$(tree_layout "$staging") \
    || die "the tarball has neither bin/$NAME.sh nor bin/$OLD_NAME.sh; not a $NAME release"
  launcher="bin/$layout.sh"
  pkg_dir="bin/$layout"
  [ -f "$staging/$pkg_dir/node_modules/neo-blessed/package.json" ] \
    || die "the tarball has $launcher but no vendored $pkg_dir/node_modules/neo-blessed; not a $NAME release"
  chmod +x "$staging/$launcher"
  [ ! -f "$staging/bin/install.sh" ] || chmod +x "$staging/bin/install.sh"
  local new_version old_version='' old_layout=''
  new_version=$(package_version "$staging/$pkg_dir/package.json")
  # The version being replaced is read from the previous install's own layout.
  old_layout=$(tree_layout "$prefix") || old_layout=''
  [ -n "$old_layout" ] && [ -f "$prefix/bin/$old_layout/package.json" ] \
    && old_version=$(package_version "$prefix/bin/$old_layout/package.json")

  # The install record goes into the staged tree, so it is swapped in with the
  # rest and an install never carries a record from a different location.
  {
    printf '# written by %s install.sh and read by %s upgrade; do not edit\n' "$NAME" "$NAME"
    printf 'prefix=%s\n' "$prefix"
    printf 'bin_dir=%s\n' "$bin_dir"
    printf 'repo=%s\n' "$repo"
    printf 'version=%s\n' "${new_version:-?}"
    printf 'installed_from=%s\n' "$installed_from"
    printf 'layout=%s\n' "$layout"
  } > "$staging/install-record"

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
  write_command "$bin_dir" "$NAME" "$prefix" "$launcher"
  write_command "$bin_dir" "$OLD_NAME" "$prefix" "$launcher"

  # ------------------------------------------------------------- report
  if [ -n "$old_version" ]; then
    log "$NAME ${new_version:-?} installed (replaced $old_version)"
  else
    log "$NAME ${new_version:-?} installed"
  fi
  log "  files:   $prefix"
  log "  command: $bin_dir/$NAME (and $bin_dir/$OLD_NAME, its former name, for one more release)"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) log "note: $bin_dir is not on your PATH; add it, or run $bin_dir/$NAME by its full path" ;;
  esac
  if [ -z "$old_version" ]; then
    log "next: export FM_HOME=<your firstmate home> and run $NAME (README: Prerequisites, First run)"
  fi
}

main "$@"
