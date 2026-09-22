# firstmate-tui

firstmate-tui is a live terminal board over the work your coding agents are doing for you, plus the pull requests waiting on you.
It reads the state that [firstmate](https://github.com/kunchenguid/firstmate), a supervisor that runs coding agents from a checkout on your machine, keeps on disk.
It asks GitHub about your pull requests, and it asks [herdr](https://herdr.dev), the terminal multiplexer those agents run in, which agent panes are still alive.
All of it lands on one screen that refreshes itself: what needs your answer, your own pull requests and their checks, the pull requests teammates asked you to review, what is being worked on right now, the reports the agents wrote, and what shipped.
You want it when several agents work for you at once and scrolling back through a chat no longer tells you where things stand.
The board is read-only, with two exceptions: discarding a hold you set and deferring one to a later date.
Each of those asks you to confirm first and then runs firstmate's own `fm-captain-hold.sh` in the home that owns the hold; the board never edits a firstmate file itself, never answers a question with words of its own and never merges anything.
Its other actions are jumping to an agent's pane, opening a pull request in your browser and showing a report or a hold card in the terminal.

![The 0.6.4 board, before the four-section layout of 0.7.0 described below: a dark terminal filled by the board. The top line names the tool, the fleet directory and 4 homes, with next refresh in 15s at the right edge. Below it six bordered panes stack top to bottom, each titled with its number key and a count: 1 In flight (4) lists a task on hold after a failed run and three homes with 0 live panes, one waiting on a decision in amber, one blocked in red and one idle, with state, herdr, id, what, repo, home and age columns; 2 Needs you (5) lists five items on hold, two of them deferred to a date, with state, key, id, what, repo, home and age columns; 3 My PRs (2), the focused pane, drawn with an amber border and title, lists two merged pull requests with checks, status, id, title, base branch and age columns, its first row highlighted as the selection; 4 Teammates' PRs (4) lists four pull requests in review, three with passing checks and one pending, with checks, status, id, author, title, base branch and age columns; 5 Findings (15, 6 hidden) lists six reports by kind, verb, id, report path, repo, home and age with plus 9 more at its foot; 6 Landed (22, 18 hidden) lists four items merged on 09-20 and 09-21 and one reported on 09-19 by verb, date, id, what, repo, home and age with plus 17 more at its foot. The bottom line lists the keys: j/k move, tab pane, enter open/focus/view, l/h expand, x hide, H hidden, 1-6 panes, r refresh, . settings, ? help, q quit.](docs/fm-board.png)

The current board has the six panes listed under [Using the board](#using-the-board).

## Prerequisites

Two words this README uses that are firstmate's own:

- A **firstmate home** is a checkout of the firstmate repository that firstmate runs from, with its `bin/` scripts and the `state/` and `data/` directories it fills.
  The board reads one main home, the one `FM_HOME` points at.
- firstmate can hand part of its work to a second copy of itself running from another home.
  firstmate calls that copy a secondmate; this README calls it a **delegate home**.
  The board finds delegate homes through the main home's `data/secondmates.md` and lists their work too.

### Required

The launcher checks the firstmate home, Node and herdr before it starts and stops with a message when one is missing.
Nothing checks bash or jq up front.

**bash 3.2 or newer.**
The `firstmate-tui` command and the installer are bash scripts.
macOS ships bash 3.2 and Linux ships 5.x, so there is nothing to install.
Check: `bash --version` prints the version on its first line.

**A firstmate home, in `FM_HOME`.**
The board runs that home's `bin/fm-fleet-snapshot.sh` for its data on every refresh.
The launcher stops unless `FM_HOME` names a directory holding an executable `bin/fm-fleet-snapshot.sh`; it never guesses the path from where you started it.
Check: `ls "$FM_HOME/bin/fm-fleet-snapshot.sh"` prints the path instead of an error.
Get one: `git clone https://github.com/kunchenguid/firstmate.git ~/firstmate` (any path works), then put `export FM_HOME=$HOME/firstmate` in your shell profile so it is set in every terminal.

**herdr 0.8.2 or newer.**
herdr hosts the board's pane and tells it which agent panes are alive.
The launcher checks that a `herdr` command is on `PATH`.
The 0.8.2 minimum is the one the board's plugin manifest declares, and herdr enforces it when you link the plugin.
`--no-herdr` runs the board without herdr; the title line then says so.
Check: `herdr --version` prints `herdr 0.8.2` or higher.
Install: macOS `brew install herdr`.
Linux, or macOS without Homebrew: `curl -fsSL https://herdr.dev/install.sh | sh`.
herdr's install page, https://herdr.dev/install, covers the other routes and `herdr update`.

**Node 20 or newer.**
Node runs the board.
The launcher reads Node's major version and stops below 20.
npm is needed only for the [development install](#development), because a release tarball already carries the one dependency.
Check: `node --version` prints `v20` or higher.
Install: macOS `brew install node`.
Debian and Ubuntu: `sudo apt install nodejs` when the packaged version is 20 or newer (Ubuntu 24.04 packages Node 18, which is too old), otherwise the packages and version managers at https://nodejs.org/en/download.

**jq 1.5 or newer.**
jq is a command that reads JSON.
`firstmate-tui open --detached` and `firstmate-tui focus` read herdr's answers with it; the board itself does not use it.
Nothing checks for it up front, so those two commands fail without it.
Check: `jq --version` prints `jq-1.5` or higher.
Install: macOS `brew install jq`.
Debian and Ubuntu: `sudo apt install jq`.
Other systems: https://jqlang.github.io/jq/download/.

**For the installer: curl, tar, and sha256sum or shasum.**
The installer downloads the release with curl, unpacks it with tar and verifies the checksum with sha256sum or, when that is missing, shasum.
It checks for all three before it downloads anything and names the missing one.
All of them ship with macOS and with every common Linux.
Check: `curl --version`, `tar --version` and `shasum --version` (or `sha256sum --version`) each print a version.
Install, Debian and Ubuntu, when one is missing: `sudo apt install curl tar coreutils`.

### Optional

**gh, the GitHub CLI, logged in.**
gh gives the two pull request panes their data.
After every fleet snapshot the board runs `gh api graphql` itself, at most four searches plus one lookup, without holding the rest of the board for the answer, and once per session `gh api user` for your GitHub login unless the [config file](#configuration) names it.
Without gh on `PATH`, My PRs falls back to a firstmate script that needs gh as well, so in practice that pane reports a failed fetch, and Teammates' PRs reads `gh not on PATH: Teammates' PRs needs the GitHub CLI`.
The config file's `prs.source` can pick that script on purpose ([Configuration](#configuration)); it needs gh just the same, so neither choice removes this prerequisite.
`--no-prs` runs the board without any GitHub call; the two panes then list only the pull request links firstmate recorded.
Check: `gh auth status` prints `Logged in to github.com`.
Install: macOS `brew install gh`.
Debian and Ubuntu: `sudo apt install gh`, or the packages at https://github.com/cli/cli/blob/trunk/docs/install_linux.md.
Then run `gh auth login` once.

**glow.**
glow renders a Markdown report, or a hold card, in the terminal when you press `enter` on a Recently Landed row with a report or on a held task.
Without it the board uses `$EDITOR`, then `vim`, then `less`.
Check: `glow --version`.
Install: macOS `brew install glow`.
Linux: the packages listed at https://github.com/charmbracelet/glow.

**python3, for the test suite only.**
The last section of `tests/fm-board.test.sh` drives the real board on a pseudo-terminal through a Python script.
Without python3 that section is skipped with a note.
Check: `python3 --version`.
Install: macOS `brew install python@3`.
Debian and Ubuntu: `sudo apt install python3`.

## Install

One command installs the latest stable release:

```sh
curl -fsSL https://raw.githubusercontent.com/zachsibert/firstmate-tui/main/bin/install.sh | bash
```

It asks GitHub for the latest release, downloads the release tarball `firstmate-tui-<tag>.tar.gz` and its `.sha256` file, verifies the checksum, unpacks the tarball and writes the command.
A failed download or a checksum mismatch stops it before anything is replaced.
It writes three things and nothing else: no shell profile, no herdr config.

| What | Where |
| --- | --- |
| The files | `~/.local/share/fm-board`, or `$XDG_DATA_HOME/fm-board` when that variable is set. This is the prefix. The directory keeps the board's former name, so an upgrade moves nothing |
| The command | `~/.local/bin/firstmate-tui`, a one-line script that runs the launcher inside the prefix. `~/.local/bin/fm-board` is written beside it as an alias, the command's former name, and goes away in the next release |
| The install record | `<prefix>/install-record`, a key=value file naming the prefix, the bin dir, the repository, the installed version and the tarball layout. `firstmate-tui upgrade` reads it |

When the bin dir is not on your `PATH`, the installer ends with this line:

```
install: note: /Users/you/.local/bin is not on your PATH; add it, or run /Users/you/.local/bin/firstmate-tui by its full path
```

Add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile yourself; the installer never edits it.
For other locations add the flags after `bash -s --`, for example `bash -s -- --prefix /opt/firstmate-tui --bin-dir /usr/local/bin`.
`bin/install.sh --help` lists every flag, including `--from-file <tarball>` for a tarball you already have.
To uninstall, delete the prefix directory and the `firstmate-tui` and `fm-board` commands in the bin dir.

### Link the herdr plugin (once)

Linking registers the board's plugin manifest with herdr.
After that herdr's command palette has two entries, one that opens the board in a tab pane and one that focuses it, and `firstmate-tui open --detached` places the board in a tab pane of the current workspace instead of a hidden workspace.
Linking is optional: without it `firstmate-tui` still runs in whatever terminal you type it in.
It is also user-global, so it affects every herdr session on the machine.

```sh
herdr plugin link ~/.local/share/fm-board/bin/firstmate-tui
echo "$FM_HOME" > "$(herdr plugin config-dir firstmate.board)/fm-home"
```

The second line matters because a palette action carries no environment: the plugin reads `FM_HOME` from that `fm-home` file.
To bind a key to the focus action, add this to `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+y"
type = "plugin_action"
command = "firstmate.board.focus"
```

A plugin linked before 0.3.0 points at `.../bin/fm-board`, a directory the upgrade removed.
Run `herdr plugin unlink firstmate.board` once and link the new path as above; the plugin id stays, so the config directory and the `fm-home` file are kept.

### First run

```sh
export FM_HOME=/path/to/your/firstmate/home
firstmate-tui
```

The launcher checks the home, Node and herdr, then the board fills the terminal with six bordered panes.
Each pane's body starts with a spinner line naming what it waits on (the fleet snapshot, then for the two pull request panes your GitHub identity, then the GitHub checks or the GitHub review requests) until that data first lands, about five seconds for the snapshot and a few more for GitHub.
From the second launch on, the board draws what it showed last time at once, each pane title marked `(cached 12m ago)` until that pane's live data lands, and puts the cursor back on the row you were on; [state-cache.json](#state-cachejson) explains both.
The first launch also writes the board's config file from the shipped example, so you have a real file to edit; [Configuration](#configuration) says where it lives and what is in it.
Press `?` inside the board for the keys, `.` for the Settings page and `q` to quit.

Without `FM_HOME` the launcher stops and prints two commands to copy: the `export` for a terminal launch and the `mkdir` plus `echo` that write the plugin's `fm-home` file.
When a firstmate home sits above the current directory the `export` names it, but the board never adopts one on its own.

The two pull request panes are built around one GitHub login, yours.
The board takes it from the config file's `identity.github_login` when set, else from the account gh is logged in as (`gh api user`, once per session), else from git's `github.user` setting.
While the board asks them, on the first refresh and again on `r` while the login is unknown, both panes show the spinner line `resolving GitHub identity`.
When none of the three answers, both panes show one row, `identity unknown: see Settings (.)`, and fetch nothing; [Troubleshooting](#troubleshooting) has the fix.

Inside herdr, `firstmate-tui` runs in the pane you type it in.
To put the board beside firstmate, split the pane first (herdr's defaults are `ctrl+b` then `v` for a pane to the right and `ctrl+b` then `-` for one below), run `firstmate-tui` in the new pane, and close that pane yourself when done.
`firstmate-tui open --detached` opens the board away from your terminal instead, in its own herdr pane, and `firstmate-tui focus` brings that pane forward later.

## Upgrade and betas

`firstmate-tui version` prints what is installed and where:

```
firstmate-tui 0.4.2 (stable release)
installed at /Users/you/.local/share/fm-board (from release v0.4.2); firstmate-tui upgrade replaces it
```

A stable release is numbered `X.Y.Z`.
A beta is that number plus the short hash of the commit it was built from, such as `0.4.2-d8b290e`; every push to a branch other than `main` publishes one as a GitHub prerelease, so a beta names one exact commit you can install.
On a beta the first line reads `firstmate-tui 0.4.2-d8b290e (beta: 0.4.2 at commit d8b290e)`.
Betas are deleted when their pull request closes, and at most 30 are kept at a time, so a beta is for trying a branch, not for staying on.

```sh
firstmate-tui upgrade                            # to the latest stable release
firstmate-tui upgrade --pre                      # to the newest release, betas included
firstmate-tui upgrade --version 0.4.2-d8b290e    # to one exact version, beta or release (v0.4.2 works too)
firstmate-tui upgrade --stable                   # from a beta back to the latest stable release
```

`firstmate-tui upgrade` runs the installer that shipped inside your install against the prefix and bin dir in the install record.
It downloads and verifies the new tarball, unpacks it beside the install and swaps the whole directory in, so a failed download or checksum leaves what you have.
Versions are never compared, so going back is the same step as going forward.
Your config file and view state live outside the prefix and come through unchanged.
The same three flags work on the install command after `bash -s --`, which is how to start on a beta with nothing installed yet.
From a git checkout, `firstmate-tui upgrade` refuses and prints the `git pull` that updates a checkout instead.

**From inside the board.**
Press `.` for the Settings page.
It shows the running version, where it is installed and from which release, the latest stable release with its date and a verdict (`upgrade available`, `up to date`, or that you are on a beta), the launch flags in effect, and the identity, config file and PR source the pull request panes use.
From an install it offers `Upgrade to <version>`, a **Betas** submenu listing the prereleases newest first with their commit and date, and `Back to stable`.
Choosing one shows the exact command it stands for and asks `y to confirm, esc to cancel`; only `y` runs it, through the same `firstmate-tui upgrade` as the command line, with the installer's lines appearing on the page.
On success the page reads `restart to use <version>` and `R` restarts the board on the new copy.
A failure leaves the installer's output on the page and the current install untouched.
`r` fetches the release list again; `.`, `esc` or `q` returns to the board.
Release data is fetched only when the page opens and on `r`, never on the refresh tick.

**Older installs.**
Since 0.3.0 the tarball is `firstmate-tui-<tag>.tar.gz`; up to 0.2.x it was `fm-board-<tag>.tar.gz` with `bin/fm-board.sh` and `bin/fm-board/` inside.
The current installer knows both names and both layouts, so `firstmate-tui upgrade --version 0.2.6` still goes back to a 0.2.x release.
An install at 0.2.5 or 0.2.6 should run the install command above once more, because the installers that shipped in those two versions stop on a missing asset instead of trying the other name; after that reinstall `firstmate-tui upgrade` works as usual.
An install older than 0.2.5 first runs its own `fm-board upgrade --version 0.2.5`, the last release under the old asset name, and then reinstalls the same way.

## Using the board

The six panes, top to bottom; each pane's key is its number.
The four fleet panes follow the four sections of firstmate's bearings digest, and they keep its rules: one scannable row per item, a hold you set in exactly one pane, nothing that needs no action from you in Captain's Call, and a delegate home never drawn as a row of work.

1. **Captain's Call**: what needs your own action now, from every home: every hold you set that is live (not deferred to a date, not waiting on a blocker, not aged past firstmate's threshold), from the main home and from every delegate home; blocked agents and decisions an agent asked for; and one `review` row per pull request that is yours to review because its agent is done and GitHub reports the pull request open and mergeable.
   A hold appears here once, whichever home holds it: a delegate's hold that firstmate also relayed into the main home is drawn from the delegate's own ledger and the relay is dropped.
   `enter` on a hold, decision or blocked row shows its card in the terminal viewer: the task's facts, the full hold reason, the backlog body, the pull request, the first 40 lines of its report, its brief and other files under `data/<id>/`, and the last 10 lines of its status log, read from the home that owns it; `d` discards the hold and `D` defers it (the Keys table below).
2. **Underway**: one row per live agent, in the main home and in every delegate home, with the task's title and what the agent is doing in WHAT, firstmate's state (`working`, `blocked`, `paused`, `failed`, `awaiting merge` when a done agent's pull request waits for your merge, `repairing PR` when an agent is fixing a pull request it once called done) beside herdr's pane state in HERDR. A delegate home with two or more live agents draws a group row over them (`working 2 live`, expanding to the agents); a home with one live agent draws that agent directly with HOME naming the home; a home with none draws nothing here. Holds and decisions are never rows in this pane: an agent whose task is also waiting on you carries `!` in front of its id, and its hold is in Captain's Call or Charted Next. Finished work appears only in Recently Landed.
3. **My PRs**: every open pull request your GitHub login authored, in any repository, plus the pull requests recorded on unfinished firstmate tasks whoever opened them, plus either kind that merged or closed in the last 12 hours; the columns are CHECKS (`passing`, `pending` or `failing`, judged from the newest run of each check on the head commit, so a run that a re-run superseded does not count), STATUS, ID, TITLE, BASE (the branch it targets) and AGE.
   With the config file's `prs.source` set to `firstmate`, or without gh on `PATH`, the pane lists what firstmate's own `fm-bearings-snapshot.sh` reports instead; [config.json](#configjson) says what that shows and leaves out.
4. **Teammates' PRs**: the open pull requests where you are a requested reviewer, directly or through a team, and not the author, in the repositories firstmate works in plus the ones the config file names, filtered by the config file's label rules, with the same columns plus AUTHOR.
5. **Charted Next**: queued and gated work with the reason it waits, from every home: queued items (`queued`, or `blocked` with `by <blocker>` in WHY when another task must finish first), the holds you set that are not live (`dated` with `until MM-DD`, `blocked` with its blocker, `aged` with `held Nd`), and an in-flight item held from outside (a vendor, a dependency) whose agent is not working (`queued`, with the hold reason in WHAT), each once, newest filed first, with the filed date in FILED. Warnings come first and are not counted in the title: a delegate home whose state firstmate cannot read, an agent whose current state is unavailable, a pane that is gone, or a main inventory that does not add up. `enter` on a queued or held row shows its card, and `d` and `D` act on a held row as in Captain's Call; a warning has nothing to open.
6. **Recently Landed**: finished work and reports, newest first: merged pull requests, done tasks and reported scouts from every home, with the pull request URL or report path in WHAT; the holds you answered or discarded, with VERB `answered`, so your own words stay one `enter` away; and every report an agent wrote whose task has no completion row, with VERB `report` and the file's date.

A refresh is two independent cycles.
The fleet snapshot runs first and the four panes built from it, Captain's Call, Underway, Charted Next and Recently Landed, repaint the moment it lands; the GitHub fetch then starts on its own and the two pull request panes repaint when it returns, keeping their previous rows with `(updating)` in their titles meanwhile.
A slow or failed GitHub call never delays the fleet panes, the countdown or the next snapshot.
The title line names the main home and the number of homes, counts down to the next snapshot (`next refresh in 18s`), reads `refreshing...` while the snapshot runs, and after a failed snapshot or GitHub fetch reads `refresh failed 40s ago, retrying in 20s` in red until both are clean again, while the pane whose data failed carries `(stale)` in its title.
Each pane title carries its key and its row count, as in `[1] Captain's Call (3)`; Charted Next names its warnings apart, as in `[5] Charted Next (43, 2 warnings)`.
The selected row is drawn inverse, in your theme's own colours, and the focused pane's border is amber (palette colour 214 on a 256-colour terminal, your terminal's yellow on one with fewer colours); the other panes keep their blue border.
In the HERDR column, `pane lost` in red means herdr no longer has that agent's pane, and `unknown` in grey means herdr is disconnected so the board cannot tell.
The bottom line lists the keys, and `?` shows them all.

| Key or gesture | Action |
| --- | --- |
| `j` / `k`, arrows | move the selection |
| `tab` / `shift-tab` | next / previous pane |
| `enter`, or a double-click | act on the row: open its pull request in your browser; on a Captain's Call hold, decision or blocked row, on a Charted Next queued or held row, or on an Underway or Recently Landed row whose task is a captain hold, show its card in the terminal viewer; on an Underway group expand or collapse it; on an agent row focus its herdr pane; on a Recently Landed row without a pull request show its report, else focus its pane |
| `f` | focus the selected row's herdr pane, whatever the pane; a row without one says so |
| `d` | discard the selected hold: the footer asks `y to discard, esc to cancel`, then firstmate's `fm-captain-hold.sh answer` closes the task in its home with the decision `Discarded by <your GitHub login> from firstmate-tui on <date>: no action; closed as not wanted.`; the task's rows leave the board at once, the cursor moves to the next row and a refresh follows so firstmate's own state catches up; a refusal from the command shows in red and changes nothing |
| `D` | defer the selected hold: the footer takes a date (`YYYY-MM-DD`, prefilled with today plus 14 days; digits and dashes edit it, `enter` defers, `esc` cancels), then `fm-captain-hold.sh hold --until <date>` records it in the hold's home with the hold's own reason and the row leaves Captain's Call at once, as after `d`, to reappear in Charted Next as `dated` on the next refresh; a hold in a delegate home is deferred only when that home's full reason is readable here |
| `l` / `right`, `h` / `left` | expand / collapse the selected Underway group |
| `x`, `X`, `H` | hide the selected row; unhide every row in the pane; show hidden rows greyed and marked `(hidden)` |
| `1` to `6`, `0` | show or hide that pane; show every pane (with all six hidden the board lists these keys, and `r`, `.`, `?` and `q`) |
| `r` | refresh now: the fleet snapshot, drawn as soon as it lands, then the GitHub fetch behind it |
| `.` | the Settings page ([Upgrade and betas](#upgrade-and-betas)) |
| `=` | reset every column width to its automatic size |
| `?`, `q` or `ctrl-c` | help overlay; quit |
| click | select that row and focus its pane; a click on a pane title focuses the pane |
| wheel | move the selection three rows in the focused pane |
| drag a column boundary in a pane's header line | resize that column; the width is saved and kept across restarts; a double-click on the boundary resets it |

Only the left mouse button is bound; the right button opens herdr's own pane menu.
While the board runs, your terminal reports mouse events to it, so hold your terminal's text-selection modifier to select text, or start with `--no-mouse`.
Inside herdr the mouse reaches the board with herdr's default `mouse_capture = true`, which passes the mouse to pane programs that ask for it.
Column widths are computed from the values on screen.
Below 100 columns the REPO and AGE columns are dropped (the pull request panes drop BASE instead), and below 80 columns the six panes become one scrolling list with section headers.

### Commands

| Command | Meaning |
| --- | --- |
| `firstmate-tui [flags]`, `firstmate-tui open [flags]` | run the board in this terminal |
| `firstmate-tui open --detached [flags]` | open the board in its own herdr pane and print the pane id |
| `firstmate-tui focus` | bring that detached pane forward |
| `firstmate-tui upgrade [--stable \| --pre \| --version <v>]` | replace the install with another release |
| `firstmate-tui version` | print the installed version and whether it is a stable release or a beta (also `-V`, `--version`) |
| `firstmate-tui help` | the usage page (also `-h`, `--help`); an unknown subcommand prints it and exits 2 |

### Launch flags

Flags go after `open` or directly after `firstmate-tui`.
`firstmate-tui --help` names the common ones.

| Flag | Meaning |
| --- | --- |
| `--refresh <seconds>` | how often the board refreshes, default 30. Each tick runs the fleet snapshot, draws it, and starts the GitHub fetch without waiting for it; one fetch runs at a time, and a snapshot that lands while one is out leaves one follow-up fetch behind it. `r` and a herdr event on a known agent pane refresh at once; a tick that lands during a running snapshot is skipped |
| `--no-prs` | skip the GitHub fetch and the `gh api user` call. My PRs lists recorded pull request links with `checks: off (--no-prs)`, and Teammates' PRs reads `PR fetch off (--no-prs)` |
| `--home <path>` | add a delegate home (repeatable). Default: `FM_HOME` plus every home in `FM_HOME/data/secondmates.md` |
| `--no-herdr` | run without herdr: no live pane state and no herdr calls |
| `--no-mouse` | ignore the mouse and leave the terminal's own text selection alone |
| `--all-homes-needs` | accepted and ignored since 0.7.0: Captain's Call lists every home's live holds by default |
| `--config <path>`, `--view-state <path>`, `--cache <path>` | where the board's three files live ([Configuration](#configuration)); a path inside `FM_HOME` is refused |
| `--cache-max-age <seconds>` | ignore a state cache whose data is older than this and start with the spinners instead, default 3600 |
| `--no-cache` | never read the state cache, so every launch starts with the spinners; the file is still written for the next launch |
| `--opener-cmd <argv>` | the command that opens a URL, default `open` on macOS and `xdg-open` on Linux; the URL is appended as one argument |
| `--viewer-cmd <argv>` | the command that shows a report or a hold card, default `glow -p`, else `$EDITOR`, else `vim`, else `less`; the path is appended |
| `--snapshot-timeout <seconds>` | kill a snapshot run after this long, default 60 |
| `--herdr-cmd <argv>`, `--herdr-socket <path>` | how to reach herdr when `HERDR_BIN_PATH`, `HERDR_SOCKET_PATH` and `herdr status` do not apply |
| `--render-once`, `--fixture`, `--cols`, `--rows`, `--keys`, `--mouse`, `--expand`, `--tags`, `--headless`, `--curl-cmd`, `--install-root` | test mode: print one frame, or run the schedule without a terminal. `bin/firstmate-tui/lib/args.mjs` documents each one |

## Configuration

The board owns three files and writes nowhere else: never into a firstmate home, a project or a `state/` directory (the `d` and `D` keys change a hold through firstmate's own command, not through a file the board edits).
All three live in the same directory: the one `herdr plugin config-dir firstmate.board` prints when herdr answers, else `$XDG_CONFIG_HOME/fm-board/`, else `~/.config/fm-board/`.
`--config`, `--view-state` and `--cache` override the three paths one at a time.

### config.json

The config file holds the three things about the pull request panes that are yours to set.
When no file exists at startup, the board writes this example, [`docs/config.example.json`](docs/config.example.json), byte for byte, and never touches the file again:

```json
{
  "schema": "firstmate-tui-config.v1",
  "identity": {
    "github_login": null
  },
  "review": {
    "default_labels": [],
    "repos": {
      "example-corp/portal": {
        "labels": [
          "ready-to-merge"
        ]
      }
    }
  },
  "prs": {
    "source": "board"
  }
}
```

| Key | Meaning |
| --- | --- |
| `schema` | must be `firstmate-tui-config.v1`; a file with another schema is refused as a whole |
| `identity.github_login` | the GitHub login the two pull request panes are built around, such as `zachsibert`, never a name or an email. `null` means resolve it: the account gh is logged in as, else git's `github.user`, else unknown |
| `review.default_labels` | the labels a pull request must carry one of to be listed in Teammates' PRs, in every repository without its own entry under `repos`; an empty list means no filter |
| `review.repos` | one entry per repository, `"owner/name": { "labels": [...] }`. Each named repository is searched even when firstmate has no work in it, and its `labels` list is its own rule; an empty list means no filter there whatever `default_labels` says |
| `prs.source` | where the pull request panes get their data. `board` (the default, and what a file without the key means) is the board's own GitHub fetch described under [Using the board](#using-the-board), which still falls back to firstmate's script when gh is not on `PATH`. `firstmate` runs firstmate's own `FM_HOME/bin/fm-bearings-snapshot.sh --include-prs` on every refresh instead, whether or not gh is there. That script lists open pull requests only, in the repositories firstmate works in, without titles, base branches, creation times, authors or labels, so a row shows the recorded task's title or the URL, `-` under BASE and the task's status-log age marked `~` under AGE; its CHECKS word is the script's own verdict; and Teammates' PRs reads `config prs.source = firstmate: Teammates' PRs needs the board's own fetch`. The script calls gh itself, so this source needs gh on `PATH` and logged in exactly as the default does |

The example's `example-corp/portal` entry is a placeholder, not a real repository.
To add your own rule, replace it with the repository as GitHub spells it, `owner/name`, and list the labels a pull request there must carry one of; add one entry per repository, or delete the entry to search only the repositories firstmate works in.
Unknown keys are ignored.
A malformed file (bad JSON, a wrong type, a repository name that is not `owner/name`, a `prs.source` other than the two words) is reported once in the footer and on the Settings page, and the board runs with the defaults: no login from the file, no label rules, no extra repositories, the `board` source.
The Settings page (`.`) shows the identity and where it came from, such as `Identity  zachsibert  (from gh api user)`, the config file's path with `(created from the example)` or `(using defaults: <reason>)` when that applies, the PR source the last refresh used and why (`PR source  board: the board's own GitHub fetch (default)`, `(config)` when the file set it, `firstmate: fm-bearings-snapshot.sh (config prs.source)`, or `(gh not on PATH; the script needs gh too, so both sources fail the same way)` when gh is missing whatever the file says), and the label rules in effect.

**What the `firstmate` source cannot show yet.**
The board judges CHECKS from the newest run of each check, so a run that a re-run superseded does not count.
It applies that rule to the script's rows too, but only when a row carries the head commit's check runs, and today `fm-bearings-snapshot.sh` prints one `checks` word per pull request and no runs.
That word comes from the script's own rule, which reads any cancelled run as failing, so on the `firstmate` source a pull request whose cancelled run was re-run and passed still reads `failing` until the script itself changes; the `board` source reads it `passing`.
The board does not change or copy the script: it lives in firstmate's repository.

### view-state.json

The view state remembers what you hid and how you sized the columns: hidden rows (by pane, home and id, plus the completion date for Recently Landed, so an item that lands again reappears), hidden panes, and every column width you dragged.
The pane ids in the file are older than the pane titles (`needs` is Captain's Call, `inflight` is Underway, `landed` is Recently Landed, `charted` is Charted Next), so a file written before 0.7.0 keeps its meaning; its entries for the former Findings pane are dropped on read, and a report you had hidden there reappears once in Recently Landed.
firstmate retires done rows on its own, so hiding a row is the board's business and never a firstmate write.
A hold you discarded or deferred is not a hidden row: it leaves the board for the rest of the session because firstmate's own state now carries the answer, so it is not in this file and `H` does not show it.
`=` resets every column width, and the Settings page has a `Reset column widths` entry that does the same.
Since 0.5.0 the file also remembers where you were: the focused pane, the selected row, the expanded Underway groups and each pane's scroll offset.
The board saves them whenever it saves the file anyway, about 1.5 seconds after your last key or click, and when you quit.
At the next launch the cursor goes back to that row as soon as its pane has data; a row that is gone gives way to the row at the same position, and a board that quit before any data landed keeps the file's selection rather than recording an empty one.

### state-cache.json

The state cache holds the last data the board drew that came from outside: the fleet snapshot, the delegate homes' ledgers, the pull request data with the GitHub login it was fetched for, and the herdr pane states.
The board writes it when the fleet snapshot lands and again when the GitHub fetch lands, as long as neither has failed, and once more when you quit, and stamps it with the time the data landed; a snapshot or fetch that failed never overwrites it, and neither does a quit while that failure stands.
At the next launch, when the file is younger than `--cache-max-age` seconds (default 3600, one hour), the panes draw it at once and every pane title carries `(cached 12m ago)`, the age in the AGE column's shape.
The title line reads the refreshing label and the launch snapshot starts immediately, exactly as it would without a cache; nothing is skipped or delayed.
As each source lands live its panes drop the marker: the fleet snapshot clears Captain's Call, Underway, Charted Next and Recently Landed, and each pull request pane clears its own when its GitHub fetch answers.
A pane whose live fetch failed keeps its cached rows, its marker and the `(stale)` word.
Every cached row works as usual, and `enter` on a pull request row whose pane still shows cached data opens the pull request and says `opening PR from data cached 12m ago` in the footer, so you know what you are acting on; there is no prompt.
With no cache, a cache older than the limit or `--no-cache`, the first frame is the spinner-per-pane start described in [First run](#first-run); `--no-cache` skips the read only, and the file is still written.
A cache that fails to parse, names another schema or was written for another firstmate home is ignored with a footer notice and replaced by the next clean refresh.

### The pane record

`firstmate-tui open --detached` records the pane it created under `~/.local/state/fm-board/` (or `$XDG_STATE_HOME/fm-board/`, or the directory herdr provides in `HERDR_PLUGIN_STATE_DIR`), so `firstmate-tui focus` can find it later.

## Troubleshooting

**The title line reads `refresh failed ... ago, retrying in ...` in red and the pull request panes say `(stale)`.**
Symptom: the title line turns red with a line such as `refresh failed 40s ago, retrying in 20s`, both pull request panes carry `(stale)` in their titles and keep their old rows, a footer notice starting `PR fetch: My PRs:` names the error once, and a recorded pull request in My PRs reads `checks: fetch failed`.
Cause: the board's GitHub fetch failed, most often because the machine cannot reach or resolve `github.com` (a dropped network, a VPN that is not up, a DNS outage).
Confirm: run `gh api user` in a terminal.
It prints your GitHub account as JSON when GitHub is reachable, and a connection error when it is not.
Fix: restore the network.
The board retries on every tick and `r` retries at once; the red text clears on the first clean refresh.

**Both pull request panes show one row, `identity unknown: see Settings (.)`.**
Symptom: My PRs and Teammates' PRs each show that single row and fetch nothing, the footer shows once `GitHub identity unknown (<what was tried>); set identity.github_login in <config path> or run gh auth login`, and the Settings page's Identity line reads `identity unknown: set identity.github_login in <config path>, or run gh auth login`.
A spinner line reading `resolving GitHub identity` in both panes for a few seconds after a start is not this: it is the board asking the three sources, and the row appears only once all three have failed.
Cause: the board could not learn your GitHub login: the config file's `identity.github_login` is `null`, gh is not logged in (or not installed, or the board runs with `--no-prs`), and git has no `github.user` setting.
Fix: either write your login into the config file's `identity.github_login`, or run `gh auth login` once.
Then press `r`; while the identity is unknown a refresh asks again, so no restart is needed.
Check: the Settings page's Identity line reads your login followed by `(from config)` or `(from gh api user)`.

**My PRs reads `failing` for a pull request whose checks are green on GitHub, and the Settings page's PR source line starts with `firstmate`.**
Symptom: a pull request whose check was cancelled once and then re-run to success reads `failing` under CHECKS; its row has `-` under BASE and a `~` after its age, and the footer said once `PR data from fm-bearings-snapshot.sh (...)`.
Cause: the pull request data comes from firstmate's script, either because the config file's `prs.source` is `firstmate` or because gh is not on `PATH`, and that script reads any cancelled run as failing ([config.json](#configjson) says why the board cannot regroup those rows).
Fix: set `prs.source` to `board` (or remove the key) and make sure gh is on `PATH`; then press `r`.
Check: the Settings page's PR source line reads `board: the board's own GitHub fetch`.

**The footer reads `state cache ignored: <path>: <reason>` once, and the panes start with spinners.**
Symptom: right after launch the footer names the state cache file with `bad JSON`, `not an object`, `unexpected schema` or `written for another home`, and the board starts as if it had no cache.
Cause: the file at that path is damaged, was written by another version of the board, or belongs to a board that runs against a different `FM_HOME`; the board never draws data it cannot trust.
Fix: nothing, unless the notice repeats on every launch: the next refresh that lands cleanly writes a fresh cache over the file, and `--no-cache` skips the read for good if you want a spinner start every time.

**`d` or `D` ends with a red line in the footer and the hold is still there.**
Symptom: after `y` on the discard prompt, or `enter` on the defer prompt, the footer shows a red line such as `fm-captain-hold: task <id> is not held for the captain; hold it first or name the right task`, and the row stays.
Cause: the board ran firstmate's `fm-captain-hold.sh` in the hold's home and the command refused; the line is the command's own words, and nothing was changed.
Check: run the same command in that home (`FM_HOME=<home> <home>/bin/fm-captain-hold.sh open <id>` shows what firstmate knows about the hold).
Fix: whatever the message asks for; a hold whose home is on another machine cannot be changed from here at all, and the board says so before it prompts.

**The title line reads `herdr disconnected (<reason>)` in red.**
Symptom: the title line carries that warning, and the HERDR column in Underway reads `unknown` in grey instead of a live pane state.
Cause: the board cannot hold its subscription to herdr's socket.
The reason in the parentheses says why: `--no-herdr` means you started it that way; `connecting` means it has not connected yet; a socket error such as `ECONNREFUSED` or `ENOENT` means herdr's server is not running or its socket has moved; `herdr status did not report a socket path` means the board found a `herdr` command but that command could not name a server.
Check: run `herdr status`.
It reports the running server, or fails when there is none.
Fix: start herdr, or run the board from inside a herdr pane, where the socket is known through the environment; the board reconnects on its own and the warning goes as soon as the subscription is back.
Outside herdr on purpose, start with `--no-herdr` and read the warning as a reminder rather than a fault.

## Releasing

Releases are GitHub Releases, published by `.github/workflows/release.yml`; nobody tags by hand.
Every merge to `main` is a release.
The one version source is `version` in `bin/firstmate-tui/package.json`, and `scripts/next-version.sh` decides what the next release is called: package.json's version when the tag `v<version>` does not exist yet, else the next free patch number.
When the picked version differs from package.json, the workflow writes it into package.json and the lockfile, commits that bump to `main` as `github-actions[bot]` with the skip-ci marker in the message, and releases at that commit; otherwise it releases at the merge commit itself.
Every push to any other branch publishes a beta, a prerelease named `v<next>-<sha7>` and built with `scripts/package.sh --commit <sha>`, so a beta carries the version the next merge will release.
When a pull request closes, merged or not, the workflow deletes the betas of its commits; after each new beta it also prunes betas beyond the newest 30, oldest first.
Stable releases are never deleted.

Nothing needs a version bump to be released, so never open a pull request only to bump the version.
To move the minor or major number, change it in the pull request that earns it:

```sh
(cd bin/firstmate-tui && npm version 0.5.0 --no-git-tag-version)   # sets package.json and the lockfile
git commit -am "Rework the panes; firstmate-tui 0.5.0"
```

One rule for every commit you push: its message must never contain the literal skip-ci marker, the bracketed words the bot's bump commit uses, because GitHub then skips the pull request's own checks and its beta.
The workflow's bump commit is the only place that marker belongs; in prose, spell it out as "the skip-ci marker".
`scripts/package.sh` is the one place that builds the tarball, for the workflow and for the tests alike, and it refuses a release tag that is not `v` plus the source version.
`.github/workflows/test.yml` runs both test suites, ShellCheck and actionlint on every pull request and on every push to a branch other than `main`.
After editing a workflow, lint it with `actionlint` and run `tests/install.test.sh`, which pins the workflow lines the installer and this README depend on.

## Development

```sh
git clone https://github.com/zachsibert/firstmate-tui.git
cd firstmate-tui
(cd bin/firstmate-tui && npm ci)   # installs the one dependency, neo-blessed 0.2.0
bin/firstmate-tui.sh version       # from a checkout the command is bin/firstmate-tui.sh
```

The tests:

```sh
env -u FORCE_COLOR bash tests/fm-board.test.sh    # the board: renders fixtures and asserts on the frames
env -u FORCE_COLOR bash tests/install.test.sh     # the installer, the upgrade paths and the release workflow
```

The board suite renders fixtures under `tests/fixtures/` through `--render-once` and asserts on the printed frame; it needs Node, and its last section needs python3 and the installed `node_modules`, and is skipped with a note without them.
One check compares node's plain output, so `FORCE_COLOR` must be unset.
The narrow-layout checks match the box-drawing dashes in a section header, so the shell needs a UTF-8 locale (`LANG=en_US.UTF-8`); under a bare environment with no locale two of them fail on that alone.
The install suite builds the release tarball, installs it into a scratch prefix and walks the upgrade chains against a fake GitHub; it needs npm and a full clone, because it builds the 0.1.0 and 0.2.5 tarballs from their tags.
Neither suite touches GitHub, a real herdr server or a browser.
ShellCheck 0.11.0 must pass on every shell script: `npx --yes shellcheck@4.1.0 --norc bin/*.sh scripts/*.sh tests/*.sh`.
[`AGENTS.md`](AGENTS.md) describes the layout of the code, the rules the board keeps and how each part is tested.
The design report that grounds the board is [`docs/scout-report-2026-09-16.md`](docs/scout-report-2026-09-16.md).
