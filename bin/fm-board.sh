#!/usr/bin/env bash
# bin/fm-board.sh - launcher for fm-board, the read-only herdr-hosted board over
# the firstmate fleet.
#
#   fm-board.sh [run] [flags]          run the board in the current terminal
#   fm-board.sh open  [flags]          open the board in its own herdr pane in
#                                      the captain workspace (plugin pane when
#                                      firstmate.board is linked, otherwise a
#                                      hidden workspace); prints the pane id
#   fm-board.sh focus [flags]          focus the pane recorded by `open`
#   fm-board.sh --render-once [--fixture <json>] [--no-herdr] [--cols N] [--rows N]
#                             [--keys <list>] [--expand <all|ids>] [--opener-cmd <argv>]
#                                      print one frame to stdout and exit
#
# Flags are passed through to bin/fm-board/index.mjs unchanged; see
# `fm-board.sh --help` for the list (--home, --refresh, --prs, --no-herdr,
# --all-homes-needs, --opener-cmd, --herdr-cmd, --herdr-socket,
# --snapshot-timeout, --keys, --expand).
#
# FM_HOME resolution: the FM_HOME environment variable, else the one-line file
# "$HERDR_PLUGIN_CONFIG_DIR/fm-home" (written once by the captain when the
# board runs as a herdr plugin action, which carries no FM_HOME), else a clear
# error. --fixture mode needs no home at all.
#
# The board never writes into FM_HOME, a project or a state directory. Its only
# file is the pane record under ${XDG_STATE_HOME:-$HOME/.local/state}/fm-board/
# (or $HERDR_PLUGIN_STATE_DIR when herdr provides one) so `focus` can find the
# pane `open` created. Its two actions are `herdr agent focus` and opening a
# PR URL in the browser (`open` / `xdg-open`, or --opener-cmd).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BOARD_DIR="$ROOT/fm-board"
ENTRY="$BOARD_DIR/index.mjs"
PLUGIN_ID="firstmate.board"

die() {
  printf 'fm-board: %s\n' "$*" >&2
  exit 2
}

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------- arguments
command=run
case "${1:-}" in
  run|open|focus) command=$1; shift ;;
esac

want_herdr=1
render_once=0
fixture=
herdr_cmd=${HERDR_BIN_PATH:-herdr}
pass=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-herdr) want_herdr=0; pass+=("$1") ;;
    --render-once) render_once=1; pass+=("$1") ;;
    --fixture) [ "$#" -ge 2 ] || die "--fixture needs a value"; fixture=$2; pass+=("$1" "$2"); shift ;;
    --herdr-cmd) [ "$#" -ge 2 ] || die "--herdr-cmd needs a value"; herdr_cmd=$2; pass+=("$1" "$2"); shift ;;
    --home|--refresh|--cols|--rows|--herdr-socket|--snapshot-timeout|--fm-home|--keys|--expand|--opener-cmd)
      [ "$#" -ge 2 ] || die "$1 needs a value"; pass+=("$1" "$2"); shift ;;
    *) pass+=("$1") ;;
  esac
  shift
done

# ------------------------------------------------------------------ FM_HOME
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

if [ -z "$fixture" ]; then
  FM_HOME=$(resolve_fm_home) || die "FM_HOME is not set. Export FM_HOME=<your firstmate home> (the directory holding bin/fm-fleet-snapshot.sh), or write it to \$HERDR_PLUGIN_CONFIG_DIR/fm-home for plugin launches."
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

if [ "$render_once" -eq 0 ] && [ ! -d "$BOARD_DIR/node_modules/neo-blessed" ]; then
  die "neo-blessed is not installed; run: (cd '$BOARD_DIR' && npm ci)"
fi

# ---------------------------------------------------------------- herdr cli
herdr_run() {
  # shellcheck disable=SC2086 # the prefix is a deliberate whitespace-split argv
  $herdr_cmd "$@"
}

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

# Open the board in its own pane without splitting the captain's pane.
# Route 1: the linked plugin, placement=tab in the current workspace.
# Route 2: a hidden workspace (the fm-afk-launch pattern) plus `pane run`.
open_board() {
  [ "$want_herdr" -eq 1 ] || die "open needs herdr; drop --no-herdr or use 'run'"
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
    out=$(herdr_run workspace create --cwd "$FM_HOME" --label "fm-board" --no-focus 2>&1) || die "workspace create failed: $out"
    wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
    pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
    [ -n "$wsid" ] && [ -n "$pane" ] || die "workspace create returned no ids: $out"
    local cmd
    cmd=$(printf 'exec env FM_HOME=%q bash %q run --herdr-cmd %q' "$FM_HOME" "$ROOT/fm-board.sh" "$herdr_cmd")
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
  [ -r "$rec" ] || die "no board pane recorded at $rec; run 'fm-board.sh open' first"
  read -r pane wsid route < "$rec"
  [ -n "$pane" ] || die "empty board pane record at $rec; run 'fm-board.sh open' again"
  herdr_run pane get "$pane" >/dev/null 2>&1 || die "recorded pane $pane no longer exists; run 'fm-board.sh open' again"
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
  open) open_board ;;
  focus) focus_board ;;
  run) exec node "$ENTRY" "${pass[@]+"${pass[@]}"}" ;;
esac
