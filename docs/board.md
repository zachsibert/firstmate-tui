# Using the board

The six panes pane by pane, the two refresh cycles, the title line, the full key and gesture table, the commands and every launch flag. The README's What you see and Keys sections have the short version.

The six panes, top to bottom; each pane's key is its number.
The four fleet panes follow the four sections of firstmate's bearings digest, and they keep its rules: one scannable row per item, a hold you set in exactly one pane, nothing that needs no action from you in Captain's Call, and a delegate home never drawn as a row of work.

1. **Captain's Call**: what needs your own action now, from every home: every hold you set that is live (not deferred to a date, not waiting on a blocker, not aged past firstmate's threshold), from the main home and from every delegate home; blocked agents and decisions an agent asked for; and one `review` row per pull request that is yours to review because its agent is done and GitHub reports the pull request open and mergeable.
   A hold appears here once, whichever home holds it: a delegate's hold that firstmate also relayed into the main home is drawn from the delegate's own ledger and the relay is dropped.
   `enter` on a hold, decision or blocked row shows its card in the terminal viewer: the task's facts, the full hold reason, the backlog body, the pull request, the first 40 lines of its report, its brief and other files under `data/<id>/`, and the last 10 lines of its status log, read from the home that owns it; `a` accepts the hold with your answer, `d` discards it and `D` defers it (the Keys table below).
2. **Underway**: one row per live agent, in the main home and in every delegate home, with the task's title and what the agent is doing in WHAT, firstmate's state (`working`, `blocked`, `paused`, `failed`, `awaiting merge` when a done agent's pull request waits for your merge, `repairing PR` when an agent is fixing a pull request it once called done) beside herdr's pane state in HERDR. A delegate home with two or more live agents draws a group row over them (`working 2 live`, expanding to the agents); a home with one live agent draws that agent directly with HOME naming the home; a home with none draws nothing here. Holds and decisions are never rows in this pane: an agent whose task is also waiting on you carries `!` in front of its id, and its hold is in Captain's Call or Charted Next. Finished work appears only in Recently Landed.
3. **My PRs**: every open pull request your GitHub login authored, in any repository, plus the pull requests recorded on unfinished firstmate tasks whoever opened them, plus either kind that merged or closed in the last 12 hours; the columns are CHECKS (`passing`, `pending` or `failing`, judged from the newest run of each check on the head commit, so a run that a re-run superseded does not count), STATUS, ID, TITLE, BASE (the branch it targets) and AGE.
   With the config file's `prs.source` set to `firstmate`, or without gh on `PATH`, the pane lists what firstmate's own `fm-bearings-snapshot.sh` reports instead; [config.json](configuration.md#configjson) says what that shows and leaves out.
4. **Teammates' PRs**: the open pull requests where you are a requested reviewer, directly or through a team, and not the author, in the repositories firstmate works in plus the ones the config file names, filtered by the config file's label rules, with the same columns plus AUTHOR.
5. **Charted Next**: queued and gated work with the reason it waits, from every home: queued items (`queued`, or `blocked` with `by <blocker>` in WHY when another task must finish first), the holds you set that are not live (`dated` with `until MM-DD`, `blocked` with its blocker, `aged` with `held Nd`), and an in-flight item held from outside (a vendor, a dependency) whose agent is not working (`queued`, with the hold reason in WHAT), each once, newest filed first, with the filed date in FILED. Warnings come first and are not counted in the title: a delegate home whose state firstmate cannot read, an agent whose current state is unavailable, a pane that is gone, or a main inventory that does not add up. `enter` on a queued or held row shows its card, and `a`, `d` and `D` act on a held row as in Captain's Call; a warning has nothing to open.
6. **Recently Landed**: finished work and reports, newest first: merged pull requests, done tasks and reported scouts from every home, with the pull request URL or report path in WHAT; the holds you accepted or discarded here, and those answered elsewhere, with VERB `answered`, so your own words stay one `enter` away; and every report an agent wrote whose task has no completion row, with VERB `report` and the file's date.

A refresh is two independent cycles.
The fleet snapshot runs first and the four panes built from it, Captain's Call, Underway, Charted Next and Recently Landed, repaint the moment it lands; the GitHub fetch then starts on its own and the two pull request panes repaint when it returns, keeping their previous rows with `(updating)` in their titles meanwhile.
A slow or failed GitHub call never delays the fleet panes, the countdown or the next snapshot.
The title line names the main home and the number of homes, counts down to the next snapshot (`next refresh in 18s`), reads `refreshing...` while the snapshot runs, and after a failed snapshot or GitHub fetch reads `refresh failed 40s ago, retrying in 20s` in red until both are clean again, while the pane whose data failed carries `(stale)` in its title.
Each pane title carries its key and its row count, as in `[1] Captain's Call (3)`; Charted Next names its warnings apart, as in `[5] Charted Next (43, 2 warnings)`.
The selected row is drawn inverse, in your theme's own colours, and the focused pane's border is amber (palette colour 214 on a 256-colour terminal, your terminal's yellow on one with fewer colours); the other panes keep their blue border.
In the HERDR column, `pane lost` in red means herdr no longer has that agent's pane, and `unknown` in grey means herdr is disconnected so the board cannot tell.
The bottom line lists the keys, and `?` shows them all.
`f` searches every pane at once, the way quick open works in an editor: type a few letters in any order and any case, even letters apart (`mdm gap` finds `portal-mdm-gap-analysis`), and the grid gives way to one list of the matching rows, best first, with the pane each row belongs to in its first column; hidden rows, rows below a pane's `+N more` foot and the children of a collapsed Underway group are all searched.
`enter` jumps to the selected match in its pane, showing the pane, expanding the group or switching hidden rows on for the session when that is what it takes, so the next `enter` acts on the row as usual; `esc` closes the search and leaves the selection where it was.

## Keys and gestures

| Key or gesture | Action |
| --- | --- |
| `j` / `k`, arrows | move the selection |
| `tab` / `shift-tab` | next / previous pane |
| `enter`, or a double-click | act on the row: open its pull request in your browser; on a Captain's Call hold, decision or blocked row, on a Charted Next queued or held row, or on an Underway or Recently Landed row whose task is a captain hold, show its card in the terminal viewer; on an Underway group expand or collapse it; on an agent row focus its herdr pane; on a Recently Landed row without a pull request show its report, else focus its pane |
| `f` | search every pane: the footer takes the query (printable keys and space type, `backspace` deletes), the frame lists the matches ranked with the pane name first, `up` / `down`, `pageup` / `pagedown` and `tab` move through them, `enter` jumps to the selected match in its pane and `esc` closes; a hidden row is listed greyed and marked `(hidden)`, and jumping to it turns `H` on for the session; a query with no match reads `no matches` |
| `F` | focus the selected row's herdr pane, whatever the pane; a row without one says so (`f` through 0.6.6) |
| `a` | accept the selected hold: the grid gives way to the hold's card, so the full reason is in view, and the footer takes your answer. When the reason lists options, the card lists them and a lower-case letter that names one picks it (`backspace` unpicks); any other printable key starts a typed answer, after which every printable key types, `backspace` deletes, and `up` / `down`, `pageup` / `pagedown` and the wheel scroll the card. What counts as options: the text after the first `Options:` (any case) in the reason, split at markers of one letter followed by `.` or `)` and a space (`a.`, `a)`, `A.`, `A)`) whose letters run a, b, c... from a; an option's text ends at the next marker or the end of the reason, less a trailing `;` or `,`, as in `Options: a. keep it; b. drop it`. `enter` records the answer through firstmate's `fm-captain-hold.sh answer` in the hold's home as `Accepted by <your GitHub login> from firstmate-tui on <date>: option <letter> <option text>` or `Accepted by <your GitHub login> from firstmate-tui on <date>: <your line>`, with `--release` when the held task is a work item, so the hold lifts and firstmate dispatches the work on its next pass, and without it when it is a question, so the task closes; a work item is any record whose kind is not `captain`, the kind `fm-captain-hold.sh hold` gives a call it creates with no work item behind it. The row leaves the board at once, as after `d`, and the footer reads `<id>: answer recorded; firstmate dispatches` or `<id>: answer recorded; closed`; the board never says work started. An empty answer and the exact word `reconcile`, which `fm-captain-hold.sh` reserves, are refused with the prompt left open; a record without a kind is refused before the prompt opens, because the board never guesses between releasing and closing; a hold in a delegate home is accepted only when that home's full record is readable here; `esc` cancels. On a Captain's Call `review` row accepting would mean merging the pull request, which the board does not do: the footer says so and `enter` opens the pull request. The key is `a` because it was free; `y` was not used because it is already the confirmation inside the `d` prompt and would read as a second confirm |
| `d` | discard the selected hold: the footer asks `y to discard, esc to cancel`, then firstmate's `fm-captain-hold.sh answer` closes the task in its home with the decision `Discarded by <your GitHub login> from firstmate-tui on <date>: no action; closed as not wanted.`; the task's rows leave the board at once, the cursor moves to the next row and a refresh follows so firstmate's own state catches up; a refusal from the command shows in red and changes nothing |
| `D` | defer the selected hold: the footer takes a date (`YYYY-MM-DD`, prefilled with today plus 14 days; digits and dashes edit it, `enter` defers, `esc` cancels), then `fm-captain-hold.sh hold --until <date>` records it in the hold's home with the hold's own reason and the row leaves Captain's Call at once, as after `d`, to reappear in Charted Next as `dated` on the next refresh; a hold in a delegate home is deferred only when that home's full reason is readable here |
| `l` / `right`, `h` / `left` | expand / collapse the selected Underway group |
| `x`, `X`, `H` | hide the selected row; unhide every row in the pane; show hidden rows greyed and marked `(hidden)` |
| `1` to `6`, `0` | show or hide that pane; show every pane (with all six hidden the board lists these keys, and `r`, `.`, `?` and `q`) |
| `r` | refresh now: the fleet snapshot, drawn as soon as it lands, then the GitHub fetch behind it |
| `.` | the Settings page ([Upgrade and betas](upgrade.md)) |
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

## Commands

| Command | Meaning |
| --- | --- |
| `firstmate-tui [flags]`, `firstmate-tui open [flags]` | run the board in this terminal |
| `firstmate-tui open --detached [flags]` | open the board in its own herdr pane and print the pane id |
| `firstmate-tui focus` | bring that detached pane forward |
| `firstmate-tui upgrade [--stable \| --pre \| --version <v>]` | replace the install with another release |
| `firstmate-tui version` | print the installed version and whether it is a stable release or a beta (also `-V`, `--version`) |
| `firstmate-tui help` | the usage page (also `-h`, `--help`); an unknown subcommand prints it and exits 2 |

## Launch flags

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
| `--config <path>`, `--view-state <path>`, `--cache <path>` | where the board's three files live ([Configuration](configuration.md)); a path inside `FM_HOME` is refused |
| `--cache-max-age <seconds>` | ignore a state cache whose data is older than this and start with the spinners instead, default 3600 |
| `--no-cache` | never read the state cache, so every launch starts with the spinners; the file is still written for the next launch |
| `--opener-cmd <argv>` | the command that opens a URL, default `open` on macOS and `xdg-open` on Linux; the URL is appended as one argument |
| `--viewer-cmd <argv>` | the command that shows a report or a hold card, default `glow -p`, else `$EDITOR`, else `vim`, else `less`; the path is appended |
| `--snapshot-timeout <seconds>` | kill a snapshot run after this long, default 60 |
| `--herdr-cmd <argv>`, `--herdr-socket <path>` | how to reach herdr when `HERDR_BIN_PATH`, `HERDR_SOCKET_PATH` and `herdr status` do not apply |
| `--render-once`, `--fixture`, `--cols`, `--rows`, `--keys`, `--mouse`, `--expand`, `--tags`, `--headless`, `--curl-cmd`, `--install-root` | test mode: print one frame, or run the schedule without a terminal. `bin/firstmate-tui/lib/args.mjs` documents each one |
