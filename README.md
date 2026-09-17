# firstmate-tui

`fm-board`: a live, herdr-hosted terminal board over the [firstmate](https://github.com/kunchenguid/firstmate) fleet snapshot, so all parallel work is visible at a glance instead of buried in a scrolling chat thread.

Panes, top to bottom by urgency:

1. **Needs you** - what the main firstmate needs from you: blocked workers, keyed worker decisions, live captain holds and green PRs whose worker said done while the backlog row is still open. Main home only by default; a secondmate's open decisions flag its In flight group instead (`--all-homes-needs` lists them here too)
2. **Ready for review** - one row per recorded pull request; with `--prs` the live check, review and mergeable state from GitHub. `enter` opens the PR in your browser
3. **In flight** - one row per main-home worker, and one group row per secondmate home: the worst child state, the live worker count, the child ids, the shared repo and the age of the newest child event, with a leading `!` when a child has an open decision or is blocked. Expand a group (`l`, `right` or `enter`) to see the mate's own agent row, each worker with the herdr agent state beside firstmate's own state, and the home's live captain decisions
4. **Findings** - scout reports and other report files, newest first, from every home
5. **Landed** - done backlog rows and every secondmate home's landed work, newest first

Every row carries the repo, the home it belongs to, and an age computed from file modification times (status logs, report files). Rows from a remote or cached home say so in the HOME column. Every pane header shows the snapshot age and the herdr connection state, so a stale board is visibly stale.

Data comes from `bin/fm-fleet-snapshot.sh --json` on the main home and each secondmate home's `state/home-summary.json` ledger; agent state comes from `herdr api snapshot` at start and then herdr's socket API (`events.subscribe`), so the board reacts to changes instead of polling herdr. The board is read-only: it never writes into a firstmate home, a project or a state directory. Its two actions are jumping to a worker pane (`herdr agent focus`) and opening a PR in your browser (`open` on macOS, `xdg-open` on Linux, always with the URL as one argument and never through a shell).

### Why In flight groups by home

The captain asked for one row per initiative the main firstmate delegated. The secondmate ledger carries `active_children[] {id, kind, state, repo, source, doing}`, `endpoints[] {id, state, source, endpoint.target}`, `holds[] {id, title, reason, source}`, `decisions_open[] {id, key, verb, summary, reason, hold_bucket}` and `queued[] {id, title, repo, kind, hold_*}`. The handoff that delegates an item (`fm-backlog-handoff.sh`, which calls `tasks-axi mv`) moves the backlog block byte-exact and records no origin; a child's task id is the mate's own backlog item id, and no field in the ledger, the fleet snapshot or `state/<id>.meta` names a parent item above it. Grouping by item would therefore give one row per worker again, so the board groups by home, and uses the id links it does have to show a child's decision text (`decisions_open`) or hold title and reason (`holds`) when the group is expanded. The comment above `inflightRows` in `bin/fm-board/lib/model.mjs` names the one function to change when the ledger grows a per-child parent field.

## Status

M1, the read-only board, is implemented in this repository, plus the M1b follow-on: `enter` / `o` open a PR in the browser, In flight groups secondmate work by home, and Needs you lists the main home only. The scout report that grounds the plan is in [`docs/scout-report-2026-09-16.md`](docs/scout-report-2026-09-16.md): data availability per pane, herdr capabilities, what is reusable from yimbot as a pattern, stack choice, and the four-milestone plan. Answering decisions, toasts and the findings watermark are later milestones.

## Requirements

- a firstmate home with `bin/fm-fleet-snapshot.sh` (and `bin/fm-bearings-snapshot.sh` for `--prs`)
- herdr 0.8.x or newer (socket API protocol 20); `--no-herdr` runs without it
- Node 20 or newer (already a firstmate dependency) and npm for the one dependency
- `jq` and `bash` (already firstmate dependencies)

## Install

```sh
git clone https://github.com/zachsibert/firstmate-tui.git
cd firstmate-tui/bin/fm-board && npm ci
```

`npm ci` installs the single pinned dependency, `neo-blessed` 0.2.0 (MIT), into `bin/fm-board/node_modules`. The terminal library sits behind one adapter module (`bin/fm-board/lib/tui-blessed.mjs`) so it can be swapped without touching the model, layout or renderer.

## Launch

```sh
export FM_HOME=/path/to/your/firstmate/home

# in the current terminal
bin/fm-board.sh

# in its own herdr pane in the current workspace, without splitting the captain pane
bin/fm-board.sh open
bin/fm-board.sh focus        # bring that pane forward later
```

`open` uses the herdr plugin route when the plugin is linked, and otherwise falls back to a hidden workspace (`herdr workspace create --no-focus` plus `pane run`, the same pattern firstmate's away-mode daemon uses). To link the plugin once:

```sh
herdr plugin link "$PWD/bin/fm-board"
echo "$FM_HOME" > "$(herdr plugin config-dir firstmate.board)/fm-home"   # actions carry no FM_HOME
```

Then `herdr plugin action invoke firstmate.board.open` opens the board and `firstmate.board.focus` brings it forward; bind a key with `[[keys.command]] key = "prefix+y" type = "plugin_action" command = "firstmate.board.focus"` in `~/.config/herdr/config.toml`.

Options (also `bin/fm-board.sh --help`):

| Flag | Meaning |
| --- | --- |
| `--home <path>` | add a secondmate home (repeatable). Default: `FM_HOME` plus every home listed in `FM_HOME/data/secondmates.md` |
| `--refresh <seconds>` | full snapshot cadence, default 30. Herdr events on a known task pane also trigger a refresh, debounced to at most one snapshot per 10 s |
| `--prs` | also run `fm-bearings-snapshot.sh --include-prs` (live GitHub, about 8 s) every 120 s so Ready for review shows checks, review and mergeable state. Off by default; recorded PR URLs then show "checks: not fetched" |
| `--no-herdr` | skip the herdr overlay and the socket subscription |
| `--all-homes-needs` | Needs you also lists every secondmate home's open decisions (default: main home only; secondmate decisions flag their In flight group) |
| `--opener-cmd <argv>` | command that opens a URL in the browser, default `open` on macOS and `xdg-open` on Linux; the URL is appended as one argument |
| `--render-once [--fixture <json>] [--cols N] [--rows N]` | print one frame to stdout and exit (test mode) |
| `--keys <list>` / `--expand <all\|ids>` | with `--render-once`: press these keys (comma or space separated, e.g. `tab,j,enter`) and expand these In flight groups before rendering. A PR open runs `--opener-cmd` when given and is only reported in the footer otherwise; a herdr focus is reported, never run |
| `--herdr-cmd <argv>` / `--herdr-socket <path>` | how to reach herdr when the defaults (`HERDR_BIN_PATH`, `HERDR_SOCKET_PATH`, `herdr status`) do not apply, for example a lab session |

## Keys

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | move the selection |
| `tab` / `shift-tab` | next / previous pane |
| `enter` | Ready for review, or a Needs you row carrying a PR URL: open the PR in the browser. In flight group row: expand or collapse it. In flight worker, or a Needs you worker row: focus its herdr pane (`herdr agent focus`) |
| `o` | open the PR of the selected row in the browser, in any pane that has one (Ready for review, Needs you, In flight, Landed) |
| `l` / `right` | expand the selected In flight group |
| `h` / `left` | collapse the group, from the group row or from one of its children (the selection lands on the group row) |
| `r` | refresh the snapshot now |
| `?` | help overlay |
| `q`, `ctrl-c` | quit |

A transient footer notice names every opened URL and every focused pane.

Below 100 columns the REPO and AGE columns are dropped; below 80 columns the five panes collapse into one scrolling list with section headers. The frame never shrinks below 20 rows.

## Tests

```sh
tests/fm-board.test.sh
```

The test renders fixtures under `tests/fixtures/` through `--render-once --fixture <json> --no-herdr` and asserts on the printed frame: every pane populated, every pane empty, a narrow terminal, the `--prs` path, the width breakpoints, In flight groups collapsed and expanded, Needs you with and without `--all-homes-needs`, and the wrapper's error paths. Key behavior goes through `--keys`; PR opens go to `--opener-cmd bash tests/fake-opener.sh`, which only records its argument, so the suite never launches a browser. No firstmate home, herdr server or TTY is needed.

## Layout of the code

```
bin/fm-board.sh              bash wrapper: FM_HOME, node and herdr checks, open/focus, exec index.mjs
bin/fm-board/index.mjs       entry: argument parsing, --render-once, interactive run
bin/fm-board/lib/args.mjs    option definitions
bin/fm-board/lib/sources.mjs every read against firstmate homes (snapshot, ledgers, mtimes, --prs)
bin/fm-board/lib/model.mjs   pure: firstmate facts -> five panes of rows (scout report section 1)
bin/fm-board/lib/layout.mjs  pure: pane heights, columns, width breakpoints
bin/fm-board/lib/render.mjs  pure: model + view state -> frame lines
bin/fm-board/lib/herdr.mjs   herdr CLI calls and the socket subscription client
bin/fm-board/lib/controller.mjs  pure key semantics (move, expand/collapse, open, focus) shared by the app and --keys
bin/fm-board/lib/opener.mjs  open a URL in the browser: argv spawn of open / xdg-open / --opener-cmd
bin/fm-board/lib/app.mjs     interactive controller: refresh schedule, view state, the effects behind each key
bin/fm-board/lib/tui-blessed.mjs  the only module that imports neo-blessed
bin/fm-board/herdr-plugin.toml    herdr plugin manifest (firstmate.board)
```
