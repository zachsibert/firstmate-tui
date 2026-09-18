# firstmate-tui

`fm-board`: a live, herdr-hosted terminal board over the [firstmate](https://github.com/kunchenguid/firstmate) fleet snapshot, so all parallel work is visible at a glance instead of buried in a scrolling chat thread.

![The live fm-board filling a dark terminal: five bordered panes stacked top to bottom, each titled with its key badge, a count, the snapshot age and "herdr connected". Pane 1, Needs you, holds three hold rows with their due dates. Pane 2, Ready for review, reads "no recorded pull requests". Pane 3, In flight, shows a working row, a decide row flagged with an exclamation mark and a done row, each with its live herdr worker count. Pane 4, Findings, lists scout and report files by home and age. Pane 5, Landed, lists merged and done work by date. The footer line names the keys, ending with q quit, and "refreshing (timer)" at the right.](docs/fm-board.png)

Panes, top to bottom by urgency:

1. **Needs you** - what the main firstmate needs from you: blocked workers, keyed worker decisions, live captain holds and green PRs whose worker said done while the backlog row is still open. Main home only by default; a secondmate's own decisions (its ledger's open decisions, and the keyed decisions its task record relays into the main home) flag its In flight group instead (`--all-homes-needs` lists them here too)
2. **Ready for review** - one row per recorded pull request of an unfinished task; a task whose backlog row is done, and a PR a secondmate record merely mentions, stay out. The live check, review and mergeable state, and the time the PR was opened, come from GitHub on every refresh (`--no-prs` turns that off), and a PR GitHub reports merged or closed is dropped. AGE is the time since the PR was opened when the live data carries it; otherwise (fetch off, fetch failed, or the PR not in the fetched list) it is the task's file-time age with a trailing `~`, so a GitHub fact and a stand-in for it are never read as the same thing. `enter` opens the PR in your browser
3. **In flight** - one row per main-home worker (a worker that said done while its PR is unmerged reads `awaiting merge`), and one group row per secondmate home: the worst state among the mate, its children and its relayed decisions, the live worker count, the child ids, the shared repo and the age of the newest child event, with a leading `!` when a child has an open decision or is blocked. Expand a group (`l`, `right` or `enter`) to see the mate's own agent row, each worker with the herdr agent state beside firstmate's own state, the home's live captain decisions and the mate's relayed decisions. A worker whose recorded pane is gone from herdr shows **pane lost** in red in the HERDR column (in Needs you, the whole row turns red); while herdr is disconnected the cell reads **unknown** in grey instead, because absence cannot be proved
4. **Findings** - scout reports and other report files, newest first, from every home. `enter` opens the report in a terminal viewer and returns to the board when it exits
5. **Landed** - done backlog rows and every secondmate home's landed work, newest first

Every row carries the repo, the home it belongs to, and an age computed from file modification times (status logs, report files), except in Ready for review, where the age is the time since the PR was opened when the live PR data provides it and the file-time age marked `~` otherwise. Rows from a remote or cached home say so in the HOME column. Every pane header shows the snapshot age and the herdr connection state, so a stale board is visibly stale.

Data comes from `bin/fm-fleet-snapshot.sh --json` on the main home and each secondmate home's `state/home-summary.json` ledger; live PR data comes from GitHub through `gh pr list`, one read-only call per candidate repository (the firstmate home's `bin/fm-bearings-snapshot.sh --include-prs` stands in when gh is not on PATH); agent state comes from `herdr api snapshot` at start and then herdr's socket API (`events.subscribe`), so the board reacts to changes instead of polling herdr. The board is read-only: it never writes into a firstmate home, a project or a state directory. Its actions are jumping to a worker pane (`herdr agent focus`), opening a PR in your browser (`open` on macOS, `xdg-open` on Linux, always with the URL as one argument and never through a shell) and showing a report in a terminal viewer. It never moves or closes a pane; split herdr panes yourself.

### Hiding rows and panes

Firstmate retires Done rows on its own (`done_keep` per home, archived to `data/done-archive.md`), so "I have looked at this" is view state that belongs to the board, not to firstmate. `x` hides the selected row, `X` unhides every row of the current pane, and `H` shows hidden rows greyed with a `(hidden)` marker so nothing is lost; the pane header counts them (`Landed (30, 12 hidden)`). Keys `1` to `5` switch a pane off and on (Needs you, Ready for review, In flight, Findings, Landed), `0` shows all five; a hidden pane frees its rows to the others and the title line lists the hidden numbers (`panes hidden: 5`). Each pane title carries its key the way btop does (`[1] Needs you (3)`, `[5] Landed (30, 12 hidden)`, and `── [3] In flight` in the narrow list), so the numbers need no lookup. Any pane may go, the last one too: with all five hidden the grid gives way to a landing page that lists the key for each pane, `0` for all of them and `r`, `?` and `q`, the title reads `all panes hidden`, and every other key only repeats that reminder. Both are remembered in the board's own file, `view-state.json`: at `$(herdr plugin config-dir firstmate.board)/view-state.json` when herdr is present, else `$XDG_CONFIG_HOME/fm-board/view-state.json`, else `~/.config/fm-board/view-state.json` (`--view-state` overrides; a path inside `FM_HOME` is refused). A hidden row's key is pane, home and id, plus the completion date for Landed, so an item that lands again reappears; an all-hidden set is saved like any other, so a restart with everything hidden lands on the key page again.

### Why In flight groups by home

The captain asked for one row per initiative the main firstmate delegated. The secondmate ledger carries `active_children[] {id, kind, state, repo, source, doing}`, `endpoints[] {id, state, source, endpoint.target}`, `holds[] {id, title, reason, source}`, `decisions_open[] {id, key, verb, summary, reason, hold_bucket}` and `queued[] {id, title, repo, kind, hold_*}`. The handoff that delegates an item (`fm-backlog-handoff.sh`, which calls `tasks-axi mv`) moves the backlog block byte-exact and records no origin; a child's task id is the mate's own backlog item id, and no field in the ledger, the fleet snapshot or `state/<id>.meta` names a parent item above it. Grouping by item would therefore give one row per worker again, so the board groups by home, and uses the id links it does have to show a child's decision text (`decisions_open`) or hold title and reason (`holds`) when the group is expanded. The comment above `inflightRows` in `bin/fm-board/lib/model.mjs` names the one function to change when the ledger grows a per-child parent field.

## Status

M1, the read-only board, is implemented in this repository, plus the M1b follow-on (`enter` opens a PR in the browser, In flight groups secondmate work by home, and Needs you lists the main home only) and M2: `enter` on a Findings row opens the report in a terminal viewer, lost panes show in red, `x` / `X` / `H` hide and unhide rows, `1`-`5` / `0` hide and show panes (each title carries its key; with all five hidden a key page replaces the grid), `r` refreshes the snapshot and the live PR checks at once, and `.` opens a Settings page that upgrades an installed board from inside it ([Upgrade from inside the board](#upgrade-from-inside-the-board)). The scout report that grounds the plan is in [`docs/scout-report-2026-09-16.md`](docs/scout-report-2026-09-16.md): data availability per pane, herdr capabilities, what is reusable from yimbot as a pattern, stack choice, and the four-milestone plan. Answering decisions, toasts and the findings watermark are later milestones.

## Prerequisites

fm-board is a terminal program that reads a firstmate home and talks to herdr. Put each item below in place before installing; the check command shows what you have. On macOS the install commands use [Homebrew](https://brew.sh); Linux commands are given where they differ.

**Required**

1. **Node 20 or newer.** Runs the board. npm is needed only for the [development install](#development-install), since a release tarball carries the one dependency.
   Check: `node --version` prints `v20` or higher.
   Install: macOS `brew install node`. Linux: the distribution package when it is 20 or newer (`sudo apt install nodejs` on Debian and Ubuntu is often older), otherwise the packages or version managers listed at https://nodejs.org/en/download.
2. **herdr 0.8.x or newer** (socket API protocol 20). Hosts the board's pane and supplies live agent state; `--no-herdr` runs the board without it.
   Check: `herdr --version` prints `herdr 0.8.2` or higher.
   Install: macOS `brew install herdr`. Linux, or macOS without Homebrew: `curl -fsSL https://herdr.dev/install.sh | sh`. Both come from herdr's own install page, https://herdr.dev/install, which also covers mise, Nix, manual downloads and `herdr update`.
3. **A firstmate home.** A checkout of https://github.com/kunchenguid/firstmate with `bin/fm-fleet-snapshot.sh` in it; the board runs that script for its data (and `bin/fm-bearings-snapshot.sh` for the live PR data only when gh is not on PATH). Secondmate homes are read from that home's `data/secondmates.md`.
   Get one: `git clone https://github.com/kunchenguid/firstmate.git ~/firstmate` (any path works).
   Point the board at it: `export FM_HOME=/path/to/that/checkout`, and add the line to your shell profile so it is set in every terminal. The board never guesses this path.
   Check: `ls "$FM_HOME/bin/fm-fleet-snapshot.sh"` prints the path instead of an error.
4. **jq 1.5 or newer.** The launcher reads herdr's JSON replies with it (only `-r` and the `//` operator).
   Check: `jq --version` prints `jq-1.5` or higher.
   Install: macOS `brew install jq`. Linux `sudo apt install jq` or `sudo dnf install jq`.
5. **bash 3.2 or newer.** The launcher and the installer are bash scripts. They use nothing beyond bash 3.1 features (arrays with `+=`, `printf %q`, `BASH_SOURCE`), and both were run under macOS's stock `/bin/bash` 3.2.57 as the check. macOS ships 3.2 and Linux ships 5.x, so there is nothing to install.
   Check: `bash --version` prints the version on its first line.
6. **curl and tar** for the installer, plus `shasum` or `sha256sum` for the checksum; all ship with macOS and with every Linux. If missing on Linux: `sudo apt install curl tar`.
   Check: `curl --version` and `tar --version` each print a version line.

**Optional**

- **glow** (optional). Renders a Findings report in the terminal when you press `enter` on it; without glow the viewer falls back to `$EDITOR`, then `vim`, then `less`.
  Check: `glow --version`. Install: macOS `brew install glow`. Linux: packages for apt, dnf and others are listed at https://github.com/charmbracelet/glow.
- **gh, the GitHub CLI, logged in** (optional). The board runs `gh pr list` itself on every refresh, one call per candidate repository, for each pull request's checks, review and mergeable state and the time it was opened (the AGE column of Ready for review). Without gh on PATH the board falls back to the firstmate home's `bin/fm-bearings-snapshot.sh --include-prs`, which needs gh as well, so in practice the Ready for review title then reads `checks failed` and the footer says why once; `--no-prs` runs the board without the fetch.
  Check: `gh auth status` prints `Logged in to github.com`. Install: macOS `brew install gh`. Linux: https://github.com/cli/cli/blob/trunk/docs/install_linux.md. Then `gh auth login` once.

## Install

One command installs the latest stable release:

```sh
curl -fsSL https://raw.githubusercontent.com/zachsibert/firstmate-tui/main/bin/install.sh | bash
```

It downloads `fm-board-<tag>.tar.gz` and its `.sha256` from the [GitHub Release](https://github.com/zachsibert/firstmate-tui/releases), verifies the checksum, unpacks into `~/.local/share/fm-board` (`$XDG_DATA_HOME/fm-board` when that is set) and writes an `fm-board` command into `~/.local/bin`. The tarball carries the one dependency, so no npm step runs. It prints where everything went, plus a one-line note if `~/.local/bin` is not on your `PATH`. It writes nothing else: no shell rc file, no herdr config. For other locations add `--prefix /opt/fm-board --bin-dir /usr/local/bin` after `bash -s --`. The installer needs `curl`, `tar` and `shasum` or `sha256sum`; the board itself still needs the [Prerequisites](#prerequisites) above.

Once installed, `fm-board` stands for `bin/fm-board.sh` in every command below (`fm-board open`, `fm-board --help`), and the plugin directory to link is `~/.local/share/fm-board/bin/fm-board`.

### Versions and betas

`fm-board version` prints the installed version and what it is:

```
fm-board 0.1.0 (stable release)
installed at /Users/you/.local/share/fm-board (from release v0.1.0); fm-board upgrade replaces it
```

A stable release is `X.Y.Z`, the `version` in `bin/fm-board/package.json` on `main`. A beta is that same version plus the short hash of the commit it was built from, `0.1.0-d8b290e`: every push to a branch other than `main` publishes one as a GitHub prerelease (see [Releasing](#releasing)), so a beta names one exact commit you can install. `fm-board version` on a beta prints `fm-board 0.1.0-d8b290e (beta: 0.1.0 at commit d8b290e)`. Betas are deleted when their pull request closes and at most 30 are kept at a time, so a beta is for trying a branch, not for staying on.

### Upgrade and switch

`fm-board upgrade` replaces the install with another version, in either direction. It runs the installer that shipped inside the install against the same prefix and bin dir (the installer records both, and the repository, in `install-record` under the prefix), downloads and verifies the new tarball, unpacks it beside the install and swaps it in as a whole, so a failed download or checksum leaves what you have. Hidden rows and panes live outside the install ([Hiding rows and panes](#hiding-rows-and-panes)) and come through unchanged. Versions are never compared, so going back is the same step as going forward:

```sh
fm-board upgrade                            # to the latest stable release
fm-board upgrade --pre                      # to the newest release, betas included
fm-board upgrade --version 0.1.0-d8b290e    # to one exact version, beta or release (v0.1.0-d8b290e works too)
fm-board upgrade --stable                   # from a beta back to the latest stable release, although the beta sorts higher
```

The same three flags work on the install command after `bash -s --` (`--pre`, `--version 0.1.0-d8b290e`, `--stable`), which is how to start on a beta with nothing installed yet. `fm-board upgrade` from a git checkout refuses and prints the `git pull` that updates a checkout instead. To uninstall, delete the prefix directory and the `fm-board` command. `bin/install.sh --help` lists every flag, including `--from-file <tarball>` for a tarball you already have.

### Upgrade from inside the board

Press `.` in the running board to open the Settings page; `.`, `esc` or `q` brings the board back with its selection intact. The page shows the running version in the words `fm-board version` prints, where the copy is installed and from which release, the latest stable release with its publish date and a verdict (`upgrade available`, `up to date`, or that you are on a beta), and the launch flags it can read (`--refresh`, PR data, the herdr overlay), read-only. From an install it offers one action, `Upgrade to <version>`, plus a **Betas** submenu that lists the prereleases newest first with the commit each was built from and its date, and a `Back to stable` entry. Choosing any of them shows one line naming the exact version and the command it stands for (`install 0.2.0 (fm-board upgrade --version 0.2.0)? y to confirm, esc to cancel`), and only `y` runs it; any other key cancels. The install is `fm-board upgrade --version <v>` (or `--stable` for Back to stable) run through the installed launcher, so it is the same download, verify and swap as the command line, and its progress lines appear on the page as they arrive. On success the page reads `restart to use <version>` and `R` quits and relaunches the board: the board exits with status 75 and the launcher starts the copy at the same path again, which is now the new one. A failure leaves the installer's output on the page verbatim (a failed download or checksum leaves the current install untouched) and the page stays usable. From a git checkout the page says so, shows the `git -C <checkout> pull` command instead of upgrade actions, and still lists the betas read-only. Release data is fetched only when the page opens and on `r` inside it, never on the refresh tick, so the GitHub API sees two calls per visit. `--curl-cmd <argv>` names the curl to use (tests point it at a fake) and `--install-root <dir>` where the page looks for the install (test mode).

### Development install

```sh
git clone https://github.com/zachsibert/firstmate-tui.git
cd firstmate-tui/bin/fm-board && npm ci
```

`npm ci` installs the single pinned dependency, `neo-blessed` 0.2.0 (MIT), into `bin/fm-board/node_modules`. The terminal library sits behind one adapter module (`bin/fm-board/lib/tui-blessed.mjs`) so it can be swapped without touching the model, layout or renderer. From a checkout the command is `bin/fm-board.sh`.

## First run

```sh
export FM_HOME=/path/to/your/firstmate/checkout   # the home from Prerequisites, step 3
fm-board                                          # from a checkout: bin/fm-board.sh
```

The board fills the terminal with five bordered panes, top to bottom: `[1] Needs you`, `[2] Ready for review`, `[3] In flight`, `[4] Findings` and `[5] Landed`. Each title carries its key badge, the row count, the snapshot age and the herdr connection state (`[1] Needs you (3) · snapshot 15s ago · herdr connected`), as in the screenshot at the top. The bottom line lists the keys. Move with `j` and `k`, switch panes with `tab`, press `enter` on a row to open or focus it, `?` for the help overlay, and `q` to quit. `fm-board --help` lists every flag; [Launch](#launch) covers running the board inside herdr, and [Keys](#keys) has every key.

## Launch

```sh
export FM_HOME=/path/to/your/firstmate/home

# in the current terminal: a plain shell, or the herdr pane you typed this in
bin/fm-board.sh open         # `bin/fm-board.sh` alone does the same

# away from this terminal: a herdr plugin tab pane, or a hidden workspace
bin/fm-board.sh open --detached
bin/fm-board.sh focus        # bring that detached pane forward later
```

Without `FM_HOME` the launcher stops and prints two lines, each a command to copy: the `export` for a terminal launch, and the `mkdir -p` plus `echo` that writes the plugin's `fm-home` file (with the directory resolved through `herdr plugin config-dir` when herdr answers). When a firstmate home sits above the current directory, the `export` names it; the board never adopts one on its own.

`open` runs the board where you typed it, so you decide where it sits. To put it beside firstmate in herdr 0.8.2 (default keys, prefix `ctrl+b`; `herdr --default-config` prints them and `[keys]` in `~/.config/herdr/config.toml` rebinds them):

1. Split the pane firstmate runs in: `ctrl+b` then `v` puts the new pane to the right (`split_vertical`), `ctrl+b` then `-` puts it below (`split_horizontal`). From a shell, `herdr pane split --current --direction right` (or `--direction down`) does the same.
2. In the new pane, run `bin/fm-board.sh open` with `FM_HOME` exported.
3. When done, `q` quits the board, then `ctrl+b` then `x` closes the pane (`close_pane`), or `herdr pane close <pane-id>` with the id that `herdr pane current` prints.

`open --detached` keeps the old placement: the herdr plugin route when the plugin is linked, otherwise a hidden workspace (`herdr workspace create --no-focus` plus `pane run`, the same pattern firstmate's away-mode daemon uses). `focus` brings that pane forward. To link the plugin once:

```sh
herdr plugin link "$PWD/bin/fm-board"     # from a checkout; after an install: ~/.local/share/fm-board/bin/fm-board
echo "$FM_HOME" > "$(herdr plugin config-dir firstmate.board)/fm-home"   # actions carry no FM_HOME
```

Then `herdr plugin action invoke firstmate.board.open` opens the board as a detached tab pane (the palette has no terminal to run it in, so the manifest passes `--detached`) and `firstmate.board.focus` brings it forward; bind a key with `[[keys.command]] key = "prefix+y" type = "plugin_action" command = "firstmate.board.focus"` in `~/.config/herdr/config.toml`.

Options (also `bin/fm-board.sh --help`):

| Flag | Meaning |
| --- | --- |
| `--home <path>` | add a secondmate home (repeatable). Default: `FM_HOME` plus every home listed in `FM_HOME/data/secondmates.md` |
| `--refresh <seconds>` | refresh cadence, default 30. Every tick runs the fleet snapshot and then, unless `--no-prs`, the live GitHub PR fetch (one `gh pr list` per candidate repository, all at once), so nothing on screen is older than this plus the two steps. Herdr events on a known task pane bring a tick forward, debounced to at most one start per 10 s. A tick that lands while a refresh is still running is skipped, and each pane title keeps showing the age of the data it has |
| `--no-prs` | skip the live GitHub PR fetch (`gh pr list`; `fm-bearings-snapshot.sh --include-prs` when gh is not on PATH). Ready for review then lists recorded PR URLs only, marked `checks: off (--no-prs)` with the file-time age marked `~`, and `r` says `PR checks off: start without --no-prs`. `--prs` is still accepted and does nothing, since the live data is the default |
| `--no-herdr` | skip the herdr overlay and the socket subscription |
| `--all-homes-needs` | Needs you also lists every secondmate home's open decisions (default: main home only; secondmate decisions flag their In flight group) |
| `--opener-cmd <argv>` | command that opens a URL in the browser, default `open` on macOS and `xdg-open` on Linux; the URL is appended as one argument |
| `--viewer-cmd <argv>` | command that shows a Findings report in the terminal; default `glow -p` when glow is on PATH, else `$EDITOR`, else `vim`, else `less`; the report path is appended as one argument |
| `--view-state <path>` | where hidden rows and hidden panes are remembered; default `$(herdr plugin config-dir firstmate.board)/view-state.json` via the wrapper, else `$XDG_CONFIG_HOME/fm-board/view-state.json`, else `~/.config/fm-board/view-state.json`; never inside `FM_HOME` |
| `--curl-cmd <argv>` | command the Settings page (`.`) fetches the GitHub releases API with, default `curl`; in `--render-once` nothing is fetched without it |
| `--install-root <dir>` | where the Settings page looks for `bin/fm-board/package.json`, `install-record` and `bin/fm-board.sh`; default the directory two levels above the package (the install prefix, or the checkout). Test mode: points the page at a fake prefix |
| `--render-once [--fixture <json>] [--cols N] [--rows N]` | print one frame to stdout and exit (test mode) |
| `--keys <list>` / `--expand <all\|ids>` | with `--render-once`: press these keys (comma or space separated, e.g. `tab,j,enter`) and expand these In flight groups before rendering. A PR open runs `--opener-cmd` when given and is only reported in the footer otherwise; a Findings enter runs `--viewer-cmd` when given and otherwise reports the viewer the chain resolved to; a herdr focus is reported, never run; `r` against a fixture only reports that it cannot refresh |
| `--tags` | with `--render-once`: print the frame with its color tags (`{red-fg}pane lost{/red-fg}`) instead of plain text |
| `--herdr-cmd <argv>` / `--herdr-socket <path>` | how to reach herdr when the defaults (`HERDR_BIN_PATH`, `HERDR_SOCKET_PATH`, `herdr status`) do not apply, for example a lab session |
| `--headless` | run the refresh schedule with no terminal: nothing is drawn, no key is read (test mode; the suite stops it with a signal) |

What the live PR data costs: the board asks GitHub directly. Every refresh runs one `gh pr list` call per candidate repository (the repositories with recorded PR URLs and live worktrees, at most ten, the same rule firstmate's `fm-bearings-snapshot.sh` applies), all started at once after the fleet snapshot, so at the default 30 seconds that is two GitHub API calls per repository per minute, 1,200 an hour with ten repositories against the authenticated limit of 5,000. The fleet snapshot itself runs once per tick: the board used to run the firstmate PR script instead, which takes its own snapshot, so every tick ran it twice. A larger `--refresh` or `--no-prs` reduces the GitHub calls. Until the first fetch of a session lands, Ready for review reads `checks fetching`; when a fetch fails, the previous PR data and its age stay on screen, marked stale, and the footer names the failure once, as it names the script fallback once when gh is not on PATH.

## Keys

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | move the selection |
| `tab` / `shift-tab` | next / previous pane |
| `enter` | Ready for review, Landed, or a Needs you row carrying a PR URL: open the PR in the browser. In flight group row: expand or collapse it. In flight worker, or a Needs you worker row: focus its herdr pane (`herdr agent focus`); a row whose pane is lost gets a notice instead. Findings row: open the report in the viewer (`glow -p`, else `$EDITOR`, else `vim`, else `less`) and come back when it exits |
| `l` / `right` | expand the selected In flight group |
| `h` / `left` | collapse the group, from the group row or from one of its children (the selection lands on the group row) |
| `x` | hide the selected row from view (on a hidden row shown by `H`: unhide it) |
| `X` | unhide every row in the current pane |
| `H` | toggle showing hidden rows, greyed and marked `(hidden)` |
| `1` .. `5` | show or hide a pane: 1 Needs you, 2 Ready for review, 3 In flight, 4 Findings, 5 Landed; each pane title shows its key (`[1] Needs you`). With all five hidden the board shows a page listing these keys instead of the grid |
| `0` | show every pane |
| `r` | refresh now: the fleet snapshot and then the live GitHub PR fetch, the same as a timer tick (with `--no-prs` the footer says `PR checks off: start without --no-prs`). Pressed while a refresh is running, it queues one follow-up |
| `.` | Settings page: the running version, where it is installed, the latest stable release and whether an upgrade is available, the read-only launch flags; `enter` on `Upgrade to <version>`, a beta in the **Betas** submenu or `Back to stable` asks `y to confirm, esc to cancel` and then runs the launcher's own `fm-board upgrade`; `r` refetches the release data; after a success `R` quits and relaunches; `.`, `esc` or `q` returns to the board ([Upgrade from inside the board](#upgrade-from-inside-the-board)) |
| `?` | help overlay |
| `q`, `ctrl-c` | quit |

A transient footer notice names every opened URL, every focused pane, every viewed report and every hide; the notice takes precedence over the key hint when the two do not fit side by side.

Below 100 columns the REPO and AGE columns are dropped; below 80 columns the five panes collapse into one scrolling list with section headers. The frame never shrinks below 20 rows.

## Tests

```sh
tests/fm-board.test.sh
tests/install.test.sh
```

The test renders fixtures under `tests/fixtures/` through `--render-once --fixture <json> --no-herdr` and asserts on the printed frame: every pane populated, every pane empty, a narrow terminal, the live PR data (the default, `--prs` as a no-op and `--no-prs`), the width breakpoints, In flight groups collapsed and expanded, Needs you with and without `--all-homes-needs`, lost and unknown panes (plain and with `--tags`), hide / unhide / show-hidden with a restart in between, the `[n]` key badge on every pane title in both layouts, pane toggles with one, four and all five panes hidden (the landing page, its restart from a saved all-hidden state, and `0` bringing the grid back), and the wrapper: `open` prints the same frame as `run`, `open --detached --no-herdr` refuses (against a fake `herdr` on `HERDR_BIN_PATH` and PATH that logs any call, so nothing reaches a live server), and its error paths. Key behavior goes through `--keys`; PR opens go to `--opener-cmd bash tests/fake-opener.sh` and report views to `--viewer-cmd bash tests/fake-viewer.sh`, which only record their arguments (the same fake is put on PATH as `glow` to pin the viewer chain), so the suite never launches a browser or an editor. The `r` key runs against a stand-in firstmate home whose `bin/fm-fleet-snapshot.sh` and `bin/fm-bearings-snapshot.sh` only log that they ran, with `tests/fake-gh.sh` on PATH as `gh` (it logs its argv and answers canned open-PR lists with `createdAt`), so the suite asserts that `r` re-runs the snapshot and then one `gh pr list` per candidate repository with `createdAt` in the field list and never the firstmate PR script, only the snapshot with `--no-prs`, the script fallback under a PATH holding no gh, and that a fixture render runs nothing, without touching GitHub. The fetch's slug, checks-mapping, projection and candidate rules are checked directly against two scratch git repositories. The PR age has its own fixture: a PR with a creation time, one without, a future and a malformed one, `--no-prs`, and the 100, 90 and 70 column widths. The refresh schedule runs with `--headless` (no terminal, no keys) against a second stand-in whose snapshot sleeps past a 5-second `--refresh`, proving that a tick landing during a running refresh starts no second fetch, that the next tick does, and that each refresh runs the snapshot before its gh calls. `o` and `f` are asserted to be no-ops. The Settings page is driven with `--install-root` pointing at a fake install prefix (a `package.json` version, an `install-record`, and `tests/fake-upgrade.sh` as its `bin/fm-board.sh`, which logs its arguments and prints installer-like lines) or at a directory with no record for the checkout case, and with `--curl-cmd bash tests/fake-curl.sh` serving the releases API from `tests/fixtures/releases/api`: the page render, upgrade available versus up to date, the API unreachable, the Betas list newest first with commit and date, the confirm line with `y` alone starting the fake upgrade and every other key cancelling without running it, the fake's lines and a verbatim failure on the page, the checkout hint with no actions, and `esc` / `.` / `q` returning to the board with the selection intact. The launcher's relaunch loop (exit 75 starts the board again with the same arguments, once) runs against `tests/fake-node.sh` on PATH. No real firstmate home, herdr server, TTY, GitHub call or install is needed.

`tests/install.test.sh` covers distribution without touching GitHub. It builds the release tarball with `scripts/package.sh` (the same script the release workflow runs) into a scratch directory, checks its layout and checksum file, refuses a tag that does not match `package.json`, flags a `-beta` tag as a prerelease, builds a per-commit beta with `--commit` and checks that the staged `package.json` carries `<version>-<sha7>` while the source tree is unchanged, installs the tarball with `bin/install.sh --from-file` into a scratch prefix and bin dir (also from stdin, the way `curl | bash` runs it) and proves the installed `fm-board` command renders a fixture frame. It then upgrades in place, rejects a wrong checksum and a damaged tarball without touching the existing install, refuses a prefix holding unrelated files, and checks that the default paths under a scratch `HOME` leave nothing else behind. With `tests/fake-curl.sh` standing in for GitHub (it serves the releases API and the download URLs from a directory and logs each URL), it installs through the default channel, swaps to the beta with `fm-board upgrade --pre`, back with `--stable`, to an exact version with and without the `v`, and through `--from-file`, checks `fm-board version` after each step, that a view-state file outside the prefix is byte for byte unchanged, that a failed download leaves the install alone, that `upgrade` from a checkout refuses with the git command, and pins the workflow lines the installer and the README depend on. It needs `npm` for the vendoring step.

## Releasing

Releases are GitHub Releases, published by `.github/workflows/release.yml`, and nobody tags by hand. The one version source is `version` in `bin/fm-board/package.json`. The workflow publishes two kinds of release:

- **A stable release** appears when a version bump reaches `main`. On every push to `main` the workflow reads the version and looks for the tag `v<version>`. When the tag does not exist, it builds `fm-board-v<version>.tar.gz` with `scripts/package.sh`, creates the tag at that commit and publishes the release with the tarball, its `.sha256`, the install command and auto-generated notes. When the tag exists, the job logs that the version is already released and exits 0, so a merge that does not bump the version publishes nothing.
- **A beta** is published for every push to any other branch. `scripts/package.sh --commit <sha>` builds `fm-board-v<version>-<sha7>.tar.gz` with the full version `<version>-<sha7>` (`0.1.0-d8b290e`) stamped into the tarball's `package.json`, and a prerelease tagged `v<version>-<sha7>` is created at that commit, titled with the version. The default install skips prereleases; `--pre` or `--version` picks one up ([Upgrade and switch](#upgrade-and-switch)).

To cut a release, bump the version in a PR and merge it:

```sh
git checkout -b release-0.2.0
(cd bin/fm-board && npm version 0.2.0 --no-git-tag-version)   # sets package.json and the lockfile
git commit -am "fm-board 0.2.0"
# push, open the PR, merge it: the Release run on main publishes v0.2.0
```

Retention: when a pull request closes, merged or not, the workflow deletes the beta release and tag of every commit in it. After each new beta it also deletes hash betas beyond the newest 30, oldest first, which catches the betas of commits that were force-pushed away or pushed without a PR. Stable releases are never deleted.

The workflow uses the built-in `GITHUB_TOKEN` with `contents: write` and nothing broader, pins each action to a major version, and runs one job per ref at a time so two pushes never race. `scripts/package.sh` refuses a release tag that is not `v` plus the source version, so nothing can publish under the wrong name. `workflow_dispatch` re-runs the job for whichever branch it is started on. After editing the workflow, lint it with `actionlint` and run `tests/install.test.sh`, which builds both kinds of tarball the same way and pins the workflow lines the installer and this section depend on.

## Layout of the code

```
bin/install.sh               installer: download a release tarball (or --from-file), verify the checksum, unpack into --prefix, write the fm-board command into --bin-dir and the install record; ships in the tarball so fm-board upgrade runs it
scripts/package.sh           build fm-board-<tag>.tar.gz and its .sha256 for a release (<tag>) or a per-commit beta (--commit <sha>, version <version>-<sha7>); run by the release workflow and by tests/install.test.sh
.github/workflows/release.yml  the one release path: a prerelease per push to a branch, the v<version> release once when main carries a new version, beta cleanup when a PR closes
bin/fm-board.sh              bash wrapper: FM_HOME, node and herdr checks, open --detached/focus, version/upgrade, view-state path, run index.mjs (and run it again when it exits 75, the Settings page's relaunch)
bin/fm-board/index.mjs       entry: argument parsing, --render-once, interactive run
bin/fm-board/lib/args.mjs    option definitions
bin/fm-board/lib/sources.mjs every read against firstmate homes and GitHub (snapshot, ledgers, mtimes, the gh pr list fetch and its script fallback, the GitHub releases fetch for the Settings page)
bin/fm-board/lib/settings.mjs  pure: the Settings page state, its entries, its key meanings, the releases API parse
bin/fm-board/lib/upgrade.mjs the install record and running version (readInstall) and the upgrade child (bash <prefix>/bin/fm-board.sh upgrade ...) with its lines streamed
bin/fm-board/lib/model.mjs   pure: firstmate facts -> five panes of rows (scout report section 1)
bin/fm-board/lib/layout.mjs  pure: pane heights, columns, width breakpoints
bin/fm-board/lib/render.mjs  pure: model + view state -> frame lines
bin/fm-board/lib/herdr.mjs   herdr CLI calls and the socket subscription client
bin/fm-board/lib/controller.mjs  pure key semantics (move, expand/collapse, open, focus, view, hide, panes, refresh, the Settings page) shared by the app and --keys
bin/fm-board/lib/opener.mjs  open a URL in the browser: argv spawn of open / xdg-open / --opener-cmd
bin/fm-board/lib/viewer.mjs  show a report in the terminal: the glow / $EDITOR / vim / less chain and the argv spawn
bin/fm-board/lib/viewstate.mjs  the board-owned view-state.json: hidden row keys and hidden panes, where it lives, atomic save
bin/fm-board/lib/app.mjs     interactive controller: refresh schedule, view state, the effects behind each key (suspend/resume around the viewer)
bin/fm-board/lib/tui-blessed.mjs  the only module that imports neo-blessed
bin/fm-board/herdr-plugin.toml    herdr plugin manifest (firstmate.board: board pane, open/focus actions)
```
