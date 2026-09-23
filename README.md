# firstmate-tui

I built firstmate-tui because I had several coding agents working for me at the same time and no single place to see where things stood. A coding agent is a program that takes a task and writes the code for it on its own. [firstmate](https://github.com/kunchenguid/firstmate) runs a fleet of them from my machine, each in its own pane of [herdr](https://herdr.dev), a terminal multiplexer, which is one terminal window split into many. Every agent ends up with a pull request, a proposed set of code changes waiting for review on GitHub, and every so often one of them stops and asks me something. Scrolling back through their chats didn't tell me who was stuck, what was waiting on me, or which of my pull requests had green checks.

So this is a board that sits in a terminal pane next to the work and puts all of it on one screen: what needs my answer, what each agent is doing right now, my own pull requests and the ones teammates asked me to review, what's queued behind something, and what shipped. It reads the state firstmate keeps on disk, asks GitHub about the pull requests, asks herdr which agent panes are still alive, and refreshes every 30 seconds. It's read-only, with one exception: when an agent has parked a question for me, three keys let me answer it, drop it, or push it to a later date, and those hand the answer to firstmate's own command rather than editing anything themselves. The board never edits a firstmate file itself and never merges anything.

## Install

One line installs the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/zachsibert/firstmate-tui/main/bin/install.sh | bash
```

It downloads the release, verifies its checksum, puts the files under `~/.local/share/fm-board` and the command at `~/.local/bin/firstmate-tui`, and touches nothing else. If `~/.local/bin` isn't on your PATH it says so at the end. Later on, `firstmate-tui upgrade` moves you to the newest release the same way.

Two things have to be true before the first run:

1. `FM_HOME` points at a firstmate home, the folder firstmate runs from, the one with `bin/` and `state/` in it. Put `export FM_HOME=$HOME/firstmate` (or wherever yours is) in your shell profile. The board never guesses this from where you launched it.
2. You're in a terminal, ideally a herdr pane split off next to firstmate (`ctrl+b` then `v` splits one to the right). herdr 0.8.2 or newer and Node 20 or newer need to be installed; the launcher checks both and names the one that's missing. For the two pull request panes you also want `gh`, GitHub's command-line tool, logged in.

Then run `firstmate-tui`. The first launch shows a spinner in each pane for a few seconds while the data lands. After that the board opens on what it showed last time and catches up in the background.

## What you see

![The board rendered from a test fixture with placeholder names, 160 columns by 50 rows on a dark background. The title line names the tool and the firstmate home and counts down to the next refresh. Six bordered panes stack top to bottom. Captain's Call, the focused pane with an amber border, lists six rows: a blocked agent, two decisions with their keys, two holds and a review row for a pull request, with the first row highlighted as the selection. Underway lists six live agents with firstmate's state, the herdr pane state, the task and what the agent is doing. My PRs lists three pull requests with their checks and status. Teammates' PRs lists five pull requests with their author, from in review to merged. Charted Next lists five queued or held items with the reason each one waits. Recently Landed lists five finished items: a report, merged pull requests and reported tasks. The bottom line lists the keys.](docs/fm-board.png)

Six panes, top to bottom. Each pane's number is its key.

1. **Captain's Call** is what needs me right now: every item firstmate is holding for my decision, every agent that's blocked or asked me a question, and a `review` row for each pull request whose agent is done and GitHub says is ready to merge.
2. **Underway** is one row per live agent, with what it's doing, firstmate's state for it (`working`, `blocked`, `awaiting merge` and so on) and whether its herdr pane is still there.
3. **My PRs** is every open pull request I authored plus the ones on unfinished firstmate tasks, with their checks judged from the newest run of each check, and anything of either kind that merged or closed in the last 12 hours.
4. **Teammates' PRs** is the open pull requests where someone asked me to review, filtered by the label rules in the config file.
5. **Charted Next** is work that's queued or waiting on something, with the reason: another task that has to land first, a blocker, or a date I deferred it to.
6. **Recently Landed** is what finished, newest first: merged pull requests, done tasks, reports agents wrote, and the questions I already answered.

## Keys

Press `?` inside the board for the full list. These are the ones I actually use:

| Key | What it does |
| --- | --- |
| `1` to `6` | show or hide that pane |
| `j` / `k` | move down and up; `tab` jumps to the next pane |
| `enter` | act on the row: open its pull request in the browser, show a hold's card or an agent's report in the terminal, or jump to the agent's herdr pane |
| `a` | accept the selected hold: press one of its lettered options or type an answer, and firstmate takes it from there |
| `d` | discard the selected hold; it asks for `y` first |
| `D` | defer the selected hold to a date, prefilled two weeks out |
| `f` | search every pane at once: type a few letters, `enter` jumps to the match |
| `.` | the Settings page: the version, an upgrade from inside the board, and the identity and config file in effect |
| `?` | help |
| `q` | quit |

The mouse works too: click a row to select it, double-click to act on it, scroll with the wheel, and drag a column boundary in a pane's header line to resize it.

## Configuration

There's one file worth knowing about, `config.json`. It holds my GitHub login, so the two pull request panes know who "me" is, and the rules for Teammates' PRs: which repositories to watch (a repository is where a project's code lives on GitHub) and which labels a pull request must carry to show up there. The first launch writes it from the shipped example, so there's a real file to edit. It lives in the directory `herdr plugin config-dir firstmate.board` prints, or in `~/.config/fm-board/` when herdr isn't around. Press `.` for the Settings page to see the login, the config file and the pull request source the board is actually using, and where each came from. [docs/configuration.md](docs/configuration.md) has every key.

## Troubleshooting

- **Both pull request panes show `identity unknown: see Settings (.)`.** gh isn't logged in and the config file has no login. Run `gh auth login` once, or put your login in `identity.github_login` in `config.json`, then press `r`.
- **`firstmate-tui` stops before drawing anything and mentions `FM_HOME`.** It isn't set. Copy the `export` line it prints into your shell profile and run it again.
- **The title line reads `herdr disconnected (...)` in red.** herdr isn't running, so the board can't tell which agent panes are alive. Start herdr, or run the board inside a herdr pane. If you meant to run without it, start with `--no-herdr`.

## More

Everything else lives in `docs/`: [prerequisites](docs/prerequisites.md) (each requirement with a check and an install command), [install](docs/install.md) (what the installer writes, the herdr plugin link, the first run in detail), [upgrade and betas](docs/upgrade.md), [using the board](docs/board.md) (every pane, key, gesture, command and launch flag), [configuration](docs/configuration.md) (the three files the board owns), [troubleshooting](docs/troubleshooting.md) (all six entries), [releasing](docs/releasing.md) and [development](docs/development.md) (running from a checkout, the tests).
