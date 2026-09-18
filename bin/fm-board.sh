#!/usr/bin/env bash
# bin/fm-board.sh - launcher for firstmate-tui, the read-only herdr-hosted board
# over the firstmate fleet. The installer writes it into the bin dir as the
# `firstmate-tui` command (and, for one release, as the `fm-board` alias it
# used to be called); from a checkout, run this file. The file keeps its old
# name because a 0.1.0 install upgrades by downloading a tarball with
# bin/fm-board.sh in it; see AGENTS.md.
#
#   firstmate-tui [open] [flags]       run the board in the current terminal: the
#                                      board starts in the pane this command was
#                                      typed in, so split your herdr pane first to
#                                      put it beside firstmate (`run` is accepted
#                                      as a synonym for old launch lines)
#   firstmate-tui open --detached [flags]
#                                      open the board away from this terminal: a
#                                      plugin tab pane in the current workspace
#                                      when firstmate.board is linked, otherwise
#                                      a hidden workspace; prints the pane id
#   firstmate-tui focus [flags]        focus the pane `open --detached` recorded
#   firstmate-tui version              print the installed version and whether it
#                                      is a stable release or a beta (also -V,
#                                      --version)
#   firstmate-tui upgrade [--stable | --pre | --version <v> | --from-file <tar.gz>]
#                                      replace this install with the latest stable
#                                      release (default and --stable), the newest
#                                      release betas included (--pre), or one exact
#                                      version such as 0.1.0-d8b290e (--version);
#                                      runs the bin/install.sh that shipped with
#                                      this copy against the install record
#   firstmate-tui help                 the usage page (also -h, --help); an unknown
#                                      subcommand prints it to stderr and exits 2
#   firstmate-tui --render-once [--fixture <json>] [--no-herdr] [--cols N] [--rows N]
#                               [--keys <list>] [--mouse <list>] [--expand <all|ids>]
#                               [--opener-cmd <argv>] [--viewer-cmd <argv>]
#                               [--view-state <file>] [--tags]
#                                      print one frame to stdout and exit
#   firstmate-tui --headless [flags]   run the refresh schedule with no terminal
#                                      (test mode; stop it with a signal)
#
# --detached is the wrapper's own flag and applies to `open` only. Every other
# flag is passed through to bin/fm-board/index.mjs unchanged, after `open` or
# with no subcommand alike; see `firstmate-tui --help` for the list (--home,
# --refresh, --no-prs, --no-herdr, --no-mouse, --all-homes-needs,
# --opener-cmd, --viewer-cmd, --view-state, --herdr-cmd, --herdr-socket,
# --snapshot-timeout, --keys, --mouse, --expand, --tags, --headless; --prs is
# accepted and does nothing, live PR data being the default).
#
# When this copy runs from an install (an install-record beside bin/) whose
# recorded bin dir has an `fm-board` command but no `firstmate-tui` yet, which
# is what a 0.1.0 install looks like right after `fm-board upgrade` brought it
# here, the launcher writes the `firstmate-tui` command there (the same shim
# bin/install.sh writes) and says so on stderr once.
#
# FM_HOME resolution: the FM_HOME environment variable, else the one-line file
# "$HERDR_PLUGIN_CONFIG_DIR/fm-home" (written once by the captain when the
# board runs as a herdr plugin action, which carries no FM_HOME), else an
# error of two lines, each a command to copy: the export for a terminal launch
# and the mkdir/echo that writes the plugin's fm-home file. A firstmate home
# found above the current directory is named in that error, never adopted.
# --fixture mode needs no home at all.
#
# The board never writes into FM_HOME, a project or a state directory. Its
# files are the pane record under ${XDG_STATE_HOME:-$HOME/.local/state}/fm-board/
# (or $HERDR_PLUGIN_STATE_DIR when herdr provides one) so `focus` can find the
# pane `open --detached` created, and the view-state file (hidden rows and panes) at
# $(herdr plugin config-dir firstmate.board)/view-state.json when herdr is
# present, else $XDG_CONFIG_HOME/fm-board/view-state.json, else
# ~/.config/fm-board/view-state.json (--view-state overrides). Its actions are
# `herdr agent focus`, opening a PR URL in the browser (`open` / `xdg-open`, or
# --opener-cmd) and showing a report in a terminal viewer (glow, $EDITOR, vim,
# less, or --viewer-cmd). It never moves or closes a pane.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BOARD_DIR="$ROOT/fm-board"
ENTRY="$BOARD_DIR/index.mjs"
PLUGIN_ID="firstmate.board"
NAME=firstmate-tui
OLD_NAME=fm-board

die() {
  printf '%s: %s\n' "$NAME" "$*" >&2
  exit 2
}

# ------------------------------------------------------- version, upgrade
# An install is <prefix>/bin/fm-board.sh plus <prefix>/install-record, the
# key=value file bin/install.sh writes (prefix, bin_dir, repo, version,
# installed_from). A checkout has no record. The version is the "version" in
# bin/fm-board/package.json: X.Y.Z is a stable release, X.Y.Z-<7 hex> is a
# per-commit beta (the release workflow stamps the short commit sha), and any
# other -suffix is some other prerelease.
PREFIX_DIR="$(dirname "$ROOT")"
RECORD="$PREFIX_DIR/install-record"
INSTALL_URL="https://raw.githubusercontent.com/zachsibert/firstmate-tui/main/bin/install.sh"

package_version() { # <package.json>: the "version" field, no node needed
  sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

version_kind() { # <version>: stable | beta | prerelease
  case "$1" in
    *-*)
      case "${1##*-}" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf 'beta' ;;
        *) printf 'prerelease' ;;
      esac ;;
    *) printf 'stable' ;;
  esac
}

record_get() { # <key>: that key's value from the install record, or nothing
  sed -n "s/^$1=//p" "$RECORD" | head -n 1
}

# The usage page. Written for someone who has just installed the board: what
# it is, the subcommands, the flags most people reach for, where the rest
# are, and where this copy lives. The header comment above stays the
# reference for the test-mode flags and the file layout.
usage() {
  cat <<'EOF'
firstmate-tui: a live, read-only terminal board over the firstmate fleet, hosted in herdr.

usage: firstmate-tui [open] [flags]          run the board in this terminal (the default)
       firstmate-tui open --detached [flags] open it away from this terminal, in its own
                                             herdr pane, and print the pane id
       firstmate-tui focus                   bring that detached pane forward
       firstmate-tui upgrade [--stable | --pre | --version <v>]
                                             replace this install with the latest stable
                                             release, the newest beta, or one exact version
       firstmate-tui version                 print the installed version (also -V, --version)
       firstmate-tui help                    this page (also -h, --help)

common flags, after `open` or with no subcommand:
  --refresh <seconds>    how often the board refreshes (default 30)
  --no-prs               skip the live GitHub PR fetch on every refresh
  --home <path>          add a secondmate home (repeatable; the default is FM_HOME plus
                         every home in FM_HOME/data/secondmates.md)
  --no-herdr             run without herdr: no live agent state, no pane placement
  --no-mouse             ignore the mouse (click, double-click, wheel) and leave the
                         terminal's own text selection alone

more flags, same places: --all-homes-needs, --opener-cmd <argv>, --viewer-cmd <argv>,
  --view-state <path>, --herdr-cmd <argv>, --herdr-socket <path>, --snapshot-timeout <s>;
  test mode: --render-once, --fixture <json>, --cols N, --rows N, --keys <list>,
  --mouse <list>, --expand <all|ids>, --tags, --headless. The README's Launch section
  explains each one.

The board reads the firstmate home in FM_HOME (export it first). Press ? inside the
board for the keys.
EOF
  if [ -f "$RECORD" ]; then
    printf '\nthis install: %s (from %s); firstmate-tui upgrade replaces it\n' "$PREFIX_DIR" "$(record_get installed_from)"
  else
    printf '\nrunning from a checkout at %s\n' "$PREFIX_DIR"
  fi
}

show_version() {
  [ "$#" -eq 0 ] || die "version takes no arguments"
  local v
  v=$(package_version "$BOARD_DIR/package.json")
  [ -n "$v" ] || die "could not read the version from $BOARD_DIR/package.json"
  case "$(version_kind "$v")" in
    stable) printf '%s %s (stable release)\n' "$NAME" "$v" ;;
    beta) printf '%s %s (beta: %s at commit %s)\n' "$NAME" "$v" "${v%-*}" "${v##*-}" ;;
    *) printf '%s %s (prerelease)\n' "$NAME" "$v" ;;
  esac
  if [ -f "$RECORD" ]; then
    printf 'installed at %s (from %s); %s upgrade replaces it\n' "$PREFIX_DIR" "$(record_get installed_from)" "$NAME"
  else
    printf 'running from %s (not an installed copy)\n' "$PREFIX_DIR"
  fi
}

# write_command <bin dir> <name>: the shim bin/install.sh writes into the bin
# dir, one line that runs this install's bin/fm-board.sh. Kept identical to
# the installer's write_command so a shim written here and one written there
# cannot be told apart.
write_command() {
  local bin_dir=$1 name=$2 shim_tmp
  shim_tmp="$bin_dir/.$name.$$"
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$name" = "$OLD_NAME" ]; then
      printf '# %s: the former name of %s, kept for one release; written by install.sh.\n' "$name" "$NAME"
    else
      printf '# %s: written by install.sh.\n' "$name"
    fi
    printf '# The board lives in %s; run "%s upgrade" to upgrade,\n' "$PREFIX_DIR" "$NAME"
    printf '# or delete that directory and the %s and %s commands here to uninstall.\n' "$NAME" "$OLD_NAME"
    printf 'exec bash %q "$@"\n' "$PREFIX_DIR/bin/fm-board.sh"
  } > "$shim_tmp" || return 1
  chmod +x "$shim_tmp" && mv -f "$shim_tmp" "$bin_dir/$name"
}

# A 0.1.0 install that ran `fm-board upgrade` was upgraded by the 0.1.0
# installer, which only knows the `fm-board` command. Finish the rename here:
# when the recorded bin dir has `fm-board` and no `firstmate-tui`, write the
# `firstmate-tui` command and say so once. A checkout has no record and a
# fresh install has both commands, so this is a no-op for them.
ensure_new_command() {
  [ -f "$RECORD" ] || return 0
  local bin_dir
  bin_dir=$(record_get bin_dir)
  [ -n "$bin_dir" ] && [ -d "$bin_dir" ] || return 0
  [ -e "$bin_dir/$OLD_NAME" ] && [ ! -e "$bin_dir/$NAME" ] || return 0
  if write_command "$bin_dir" "$NAME" 2>/dev/null; then
    printf '%s: the command is now %s (fm-board still works this release); wrote %s\n' "$NAME" "$NAME" "$bin_dir/$NAME" >&2
  else
    printf '%s: could not write %s beside %s; re-run the installer once to add it:  curl -fsSL %s | bash\n' "$NAME" "$bin_dir/$NAME" "$bin_dir/$OLD_NAME" "$INSTALL_URL" >&2
  fi
}

# firstmate-tui upgrade: one implementation of download, verify and swap lives
# in bin/install.sh, and the copy that shipped in this tarball is the one that
# runs, against the prefix, bin dir and repository the record names. Channel
# flags pass through unchanged; install.sh checks that they exclude each
# other and never compares versions, so --stable from a beta is a plain swap.
run_upgrade() {
  local flags=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        printf 'usage: %s upgrade [--stable | --pre | --version <version> | --from-file <tarball>]\n\n' "$NAME"
        printf '  --stable              the latest stable release (the default)\n'
        printf '  --pre                 the newest release, betas included\n'
        printf '  --version <version>   exactly this version: 0.2.0, or a beta such as 0.1.0-d8b290e\n'
        printf '  --from-file <tar.gz>  a release tarball you already have\n\n'
        printf 'The download is verified and unpacked beside the install before the swap;\n'
        printf 'view state (hidden rows and panes) lives outside the install and is kept.\n'
        exit 0 ;;
      --stable|--pre) flags+=("$1") ;;
      --version|--from-file) [ "$#" -ge 2 ] || die "upgrade $1 needs a value"; flags+=("$1" "$2"); shift ;;
      *) die "unknown upgrade option $1: $NAME upgrade [--stable | --pre | --version <version> | --from-file <tarball>]" ;;
    esac
    shift
  done
  if [ ! -f "$RECORD" ]; then
    if [ -e "$PREFIX_DIR/.git" ]; then
      die "this $NAME is a git checkout at $PREFIX_DIR, not an installed copy; upgrade is for installs. Update the checkout with git:  git -C $(printf '%q' "$PREFIX_DIR") pull   (then (cd bin/fm-board && npm ci) when the lockfile changed)"
    fi
    die "no install record at $RECORD, so this copy was not put here by install.sh; install one with:  curl -fsSL $INSTALL_URL | bash"
  fi
  local prefix bin_dir repo here
  prefix=$(record_get prefix)
  bin_dir=$(record_get bin_dir)
  repo=$(record_get repo)
  [ -n "$prefix" ] && [ -n "$bin_dir" ] && [ -n "$repo" ] \
    || die "install record $RECORD is incomplete (needs prefix, bin_dir and repo); re-run the installer:  curl -fsSL $INSTALL_URL | bash"
  here=$(cd "$prefix" 2>/dev/null && pwd -P) || here=
  [ "$here" = "$PREFIX_DIR" ] \
    || die "install record names prefix $prefix but this copy runs from $PREFIX_DIR (was the install moved?); re-run the installer with --prefix $(printf '%q' "$PREFIX_DIR")"
  [ -f "$ROOT/install.sh" ] \
    || die "no bin/install.sh beside this copy (an install from before upgrade existed?); re-run the installer once:  curl -fsSL $INSTALL_URL | bash"
  exec bash "$ROOT/install.sh" --prefix "$prefix" --bin-dir "$bin_dir" --repo "$repo" "${flags[@]+"${flags[@]}"}"
}

# ---------------------------------------------------------------- arguments
# The first word is the subcommand when it does not start with a dash: `open`
# (the default when there is none), `focus`, `version`, `upgrade`, `help`, and
# `run`, the old name of the default, kept so existing launch lines work. Any
# other bare word is a typo of one of these, so the usage page goes to stderr
# with exit 2 instead of reaching the board as a flag error.
ensure_new_command
command=run
case "${1:-}" in
  run|open|focus|version|upgrade) command=$1; shift ;;
  help) usage; exit 0 ;;
  -V|--version) command=version; shift ;;
  -*|'') ;;
  *) printf '%s: unknown subcommand %s\n\n' "$NAME" "$1" >&2; usage >&2; exit 2 ;;
esac
case "$command" in
  version) show_version "$@"; exit 0 ;;
  upgrade) run_upgrade "$@" ;; # execs install.sh or dies
esac

want_herdr=1
render_once=0
headless=0
detached=0
fixture=
view_state=
herdr_cmd=${HERDR_BIN_PATH:-herdr}
pass=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-herdr) want_herdr=0; pass+=("$1") ;;
    --detached) detached=1 ;;
    --render-once) render_once=1; pass+=("$1") ;;
    --headless) headless=1; pass+=("$1") ;;
    --fixture) [ "$#" -ge 2 ] || die "--fixture needs a value"; fixture=$2; pass+=("$1" "$2"); shift ;;
    --herdr-cmd) [ "$#" -ge 2 ] || die "--herdr-cmd needs a value"; herdr_cmd=$2; pass+=("$1" "$2"); shift ;;
    --view-state) [ "$#" -ge 2 ] || die "--view-state needs a value"; view_state=$2; pass+=("$1" "$2"); shift ;;
    --home|--refresh|--cols|--rows|--herdr-socket|--snapshot-timeout|--fm-home|--keys|--mouse|--expand|--opener-cmd|--viewer-cmd)
      [ "$#" -ge 2 ] || die "$1 needs a value"; pass+=("$1" "$2"); shift ;;
    *) pass+=("$1") ;;
  esac
  shift
done

# `open` is `run` unless --detached asks for the old routes: the board starts
# in the pane this command was typed in, so the captain splits his own pane
# first and runs the board in the half he wants.
if [ "$detached" -eq 1 ] && [ "$command" != open ]; then
  die "--detached applies to 'open' only: $NAME open --detached"
fi
if [ "$command" = open ] && [ "$detached" -eq 0 ]; then
  command=run
fi

# ---------------------------------------------------------------- herdr cli
herdr_run() {
  # shellcheck disable=SC2086 # the prefix is a deliberate whitespace-split argv
  $herdr_cmd "$@"
}

# herdr's per-plugin config directory, where the fm-home file and
# view-state.json live: $HERDR_PLUGIN_CONFIG_DIR inside a plugin pane, else
# what `herdr plugin config-dir firstmate.board` prints when herdr is wanted
# and answers (the path is printed whether or not the plugin is linked), else
# nothing.
plugin_config_dir() {
  local dir=
  if [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ]; then
    dir=$HERDR_PLUGIN_CONFIG_DIR
  elif [ "$want_herdr" -eq 1 ]; then
    dir=$(herdr_run plugin config-dir "$PLUGIN_ID" 2>/dev/null | head -n 1)
  fi
  [ -n "$dir" ] && printf '%s' "${dir%/}"
}

# ------------------------------------------------------------------ FM_HOME
# FM_HOME is explicit. The one automatic fallback is the plugin's fm-home
# file, which the captain writes once because plugin actions carry no FM_HOME.
resolve_fm_home() {
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s' "${FM_HOME%/}"
    return 0
  fi
  if [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -r "$HERDR_PLUGIN_CONFIG_DIR/fm-home" ]; then
    local from_file
    from_file=$(head -n 1 "$HERDR_PLUGIN_CONFIG_DIR/fm-home")
    [ -n "$from_file" ] && { printf '%s' "${from_file%/}"; return 0; }
  fi
  return 1
}

# The first directory at or above the current one that holds
# bin/fm-fleet-snapshot.sh. Only ever suggested in the error below: the board
# never infers FM_HOME from where it was started.
suggest_fm_home() {
  local dir
  dir=$(pwd -P)
  while :; do
    if [ -x "$dir/bin/fm-fleet-snapshot.sh" ]; then
      printf '%s' "$dir"
      return 0
    fi
    [ "$dir" = / ] && return 1
    dir=$(dirname "$dir")
  done
}

# Two lines, each with a command to copy: the export for a terminal launch,
# and the mkdir/echo that writes the plugin's fm-home file, with the config
# directory resolved through herdr when it answers.
die_no_home() {
  local found cfg home
  found=$(suggest_fm_home) || found=
  home=${found:-/path/to/firstmate}
  cfg=$(plugin_config_dir) || cfg=
  {
    if [ -n "$found" ]; then
      printf '%s: FM_HOME is not set. Found a firstmate home above the current directory; it is used only once you export it. In a terminal:  export FM_HOME=%q   then run this again.\n' "$NAME" "$found"
    else
      printf '%s: FM_HOME is not set. In a terminal:  export FM_HOME=/path/to/firstmate   (the directory holding bin/fm-fleet-snapshot.sh), then run this again.\n' "$NAME"
    fi
    if [ -n "$cfg" ]; then
      printf '%s: for a herdr plugin action, which carries no FM_HOME:  mkdir -p %q && echo %q > %q\n' "$NAME" "$cfg" "$home" "$cfg/fm-home"
    else
      # shellcheck disable=SC2016 # the $(...) is for the reader's shell, not this one
      printf '%s: for a herdr plugin action, which carries no FM_HOME:  mkdir -p "$(herdr plugin config-dir firstmate.board)" && echo %q > "$(herdr plugin config-dir firstmate.board)/fm-home"\n' "$NAME" "$home"
    fi
  } >&2
  exit 2
}

if [ -z "$fixture" ]; then
  FM_HOME=$(resolve_fm_home) || die_no_home
  [ -x "$FM_HOME/bin/fm-fleet-snapshot.sh" ] || die "FM_HOME=$FM_HOME has no executable bin/fm-fleet-snapshot.sh; is it a firstmate home?"
  export FM_HOME
fi

# ------------------------------------------------------------------- tools
command -v node >/dev/null 2>&1 || die "node is required (firstmate's toolchain already needs it); install Node 20 or newer"
node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[ "$node_major" -ge 20 ] 2>/dev/null || die "node 20 or newer is required (found $(node --version 2>/dev/null || echo unknown))"

herdr_bin=${herdr_cmd%% *}
if [ "$want_herdr" -eq 1 ]; then
  command -v "$herdr_bin" >/dev/null 2>&1 || die "herdr is required for the live overlay (found none as '$herdr_bin'); install herdr 0.8.x or pass --no-herdr"
fi

if [ "$command" = run ] && [ "$render_once" -eq 0 ] && [ "$headless" -eq 0 ] && [ ! -d "$BOARD_DIR/node_modules/neo-blessed" ]; then
  die "neo-blessed is not installed; run: (cd '$BOARD_DIR' && npm ci)"
fi

# ------------------------------------------------------------- pane record
record_dir() {
  if [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]; then
    printf '%s' "$HERDR_PLUGIN_STATE_DIR"
  else
    printf '%s/fm-board' "${XDG_STATE_HOME:-$HOME/.local/state}"
  fi
}

record_path() {
  local key
  key=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  printf '%s/pane-%s' "$(record_dir)" "$key"
}

plugin_linked() {
  herdr_run plugin list 2>/dev/null | grep -Fq "$PLUGIN_ID"
}

# Where hidden rows and hidden panes are remembered: herdr's per-plugin config
# directory when herdr is present, else index.mjs falls back to
# $XDG_CONFIG_HOME/fm-board or ~/.config/fm-board. A fixture render gets no
# default so the frame depends on the fixture alone. Never FM_HOME.
if [ -z "$view_state" ] && [ -z "$fixture" ] && [ "$command" = run ]; then
  vs=$(plugin_config_dir) || vs=
  [ -n "$vs" ] && pass+=(--view-state "$vs/view-state.json")
fi

# `open --detached`: open the board in its own pane without splitting the
# captain's pane.
# Route 1: the linked plugin, placement=tab in the current workspace.
# Route 2: a hidden workspace (the fm-afk-launch pattern) plus `pane run`.
open_detached() {
  [ "$want_herdr" -eq 1 ] || die "open --detached needs herdr to place the pane; drop --no-herdr, or run '$NAME open' without --detached to use this terminal"
  herdr_run status >/dev/null 2>&1 || die "herdr server is not running (herdr status failed)"
  local out pane wsid
  if plugin_linked; then
    local args=(plugin pane open --plugin "$PLUGIN_ID" --entrypoint board --placement tab --no-focus --env "FM_HOME=$FM_HOME")
    [ -n "${HERDR_WORKSPACE_ID:-}" ] && args+=(--workspace "$HERDR_WORKSPACE_ID")
    out=$(herdr_run "${args[@]}" 2>&1) || die "plugin pane open failed: $out"
    pane=$(printf '%s' "$out" | jq -r '.result.pane_id // .result.pane.pane_id // empty' 2>/dev/null)
    [ -n "$pane" ] || pane=$(printf '%s' "$out" | grep -oE 'w[0-9A-Za-z]+:p[0-9A-Za-z]+' | head -n 1)
    [ -n "$pane" ] || die "plugin pane opened but no pane id came back: $out"
    printf 'route=plugin pane=%s\n' "$pane"
  else
    out=$(herdr_run workspace create --cwd "$FM_HOME" --label "$NAME" --no-focus 2>&1) || die "workspace create failed: $out"
    wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
    pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
    [ -n "$wsid" ] && [ -n "$pane" ] || die "workspace create returned no ids: $out"
    local cmd
    cmd=$(printf 'exec env FM_HOME=%q bash %q open --herdr-cmd %q' "$FM_HOME" "$ROOT/fm-board.sh" "$herdr_cmd")
    herdr_run pane run "$pane" "$cmd" >/dev/null 2>&1 || die "pane run failed in $pane"
    printf 'route=workspace workspace=%s pane=%s\n' "$wsid" "$pane"
  fi
  # Record: "<pane-id> <workspace-id-or-'-'> <route>" on one line.
  local route=plugin
  [ -n "${wsid:-}" ] && route=workspace
  mkdir -p "$(record_dir)" 2>/dev/null && printf '%s %s %s\n' "$pane" "${wsid:--}" "$route" > "$(record_path)"
}

focus_board() {
  [ "$want_herdr" -eq 1 ] || die "focus needs herdr"
  local rec pane wsid route
  rec=$(record_path)
  [ -r "$rec" ] || die "no board pane recorded at $rec; run '$NAME open --detached' first"
  read -r pane wsid route < "$rec"
  [ -n "$pane" ] || die "empty board pane record at $rec; run '$NAME open --detached' again"
  herdr_run pane get "$pane" >/dev/null 2>&1 || die "recorded pane $pane no longer exists; run '$NAME open --detached' again"
  if [ "$route" = plugin ] && herdr_run plugin pane focus "$pane" >/dev/null 2>&1; then
    printf 'focused %s (plugin pane)\n' "$pane"
    return 0
  fi
  # The workspace route hosts the board in its own hidden workspace, so
  # focusing that workspace brings the board forward; a plain pane has no
  # agent for `agent focus` to target.
  if [ -n "$wsid" ] && [ "$wsid" != - ] && herdr_run workspace focus "$wsid" >/dev/null 2>&1; then
    printf 'focused %s (workspace %s)\n' "$pane" "$wsid"
    return 0
  fi
  herdr_run agent focus "$pane" >/dev/null 2>&1 || die "could not focus $pane"
  printf 'focused %s\n' "$pane"
}

case "$command" in
  open) open_detached ;; # plain open became run above; only --detached lands here
  focus) focus_board ;;
  run) exec node "$ENTRY" "${pass[@]+"${pass[@]}"}" ;;
esac
