# Configuration

The three files the board owns, config.json, view-state.json and state-cache.json, plus the pane record: where they live, what is in each and what the board does with them.

The board owns three files and writes nowhere else: never into a firstmate home, a project or a `state/` directory (the `d` and `D` keys change a hold through firstmate's own command, not through a file the board edits).
All three live in the same directory: the one `herdr plugin config-dir firstmate.board` prints when herdr answers, else `$XDG_CONFIG_HOME/fm-board/`, else `~/.config/fm-board/`.
`--config`, `--view-state` and `--cache` override the three paths one at a time.

## config.json

The config file holds the three things about the pull request panes that are yours to set.
When no file exists at startup, the board writes this example, [`docs/config.example.json`](config.example.json), byte for byte, and never touches the file again:

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
| `prs.source` | where the pull request panes get their data. `board` (the default, and what a file without the key means) is the board's own GitHub fetch described under [Using the board](board.md), which still falls back to firstmate's script when gh is not on `PATH`. `firstmate` runs firstmate's own `FM_HOME/bin/fm-bearings-snapshot.sh --include-prs` on every refresh instead, whether or not gh is there. That script lists open pull requests only, in the repositories firstmate works in, without titles, base branches, creation times, authors or labels, so a row shows the recorded task's title or the URL, `-` under BASE and the task's status-log age marked `~` under AGE; its CHECKS word is the script's own verdict; and Teammates' PRs reads `config prs.source = firstmate: Teammates' PRs needs the board's own fetch`. The script calls gh itself, so this source needs gh on `PATH` and logged in exactly as the default does |

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

## view-state.json

The view state remembers what you hid and how you sized the columns: hidden rows (by pane, home and id, plus the completion date for Recently Landed, so an item that lands again reappears), hidden panes, and every column width you dragged.
The pane ids in the file are older than the pane titles (`needs` is Captain's Call, `inflight` is Underway, `landed` is Recently Landed, `charted` is Charted Next), so a file written before 0.7.0 keeps its meaning; its entries for the former Findings pane are dropped on read, and a report you had hidden there reappears once in Recently Landed.
firstmate retires done rows on its own, so hiding a row is the board's business and never a firstmate write.
A hold you accepted, discarded or deferred is not a hidden row: it leaves the board for the rest of the session because firstmate's own state now carries the answer, so it is not in this file and `H` does not show it.
`=` resets every column width, and the Settings page has a `Reset column widths` entry that does the same.
Since 0.5.0 the file also remembers where you were: the focused pane, the selected row, the expanded Underway groups and each pane's scroll offset.
The board saves them whenever it saves the file anyway, about 1.5 seconds after your last key or click, and when you quit.
At the next launch the cursor goes back to that row as soon as its pane has data; a row that is gone gives way to the row at the same position, and a board that quit before any data landed keeps the file's selection rather than recording an empty one.

## state-cache.json

The state cache holds the last data the board drew that came from outside: the fleet snapshot, the delegate homes' ledgers, the pull request data with the GitHub login it was fetched for, and the herdr pane states.
The board writes it when the fleet snapshot lands and again when the GitHub fetch lands, as long as neither has failed, and once more when you quit, and stamps it with the time the data landed; a snapshot or fetch that failed never overwrites it, and neither does a quit while that failure stands.
At the next launch, when the file is younger than `--cache-max-age` seconds (default 3600, one hour), the panes draw it at once and every pane title carries `(cached 12m ago)`, the age in the AGE column's shape.
The title line reads the refreshing label and the launch snapshot starts immediately, exactly as it would without a cache; nothing is skipped or delayed.
As each source lands live its panes drop the marker: the fleet snapshot clears Captain's Call, Underway, Charted Next and Recently Landed, and each pull request pane clears its own when its GitHub fetch answers.
A pane whose live fetch failed keeps its cached rows, its marker and the `(stale)` word.
Every cached row works as usual, and `enter` on a pull request row whose pane still shows cached data opens the pull request and says `opening PR from data cached 12m ago` in the footer, so you know what you are acting on; there is no prompt.
With no cache, a cache older than the limit or `--no-cache`, the first frame is the spinner-per-pane start described in [First run](install.md#first-run); `--no-cache` skips the read only, and the file is still written.
A cache that fails to parse, names another schema or was written for another firstmate home is ignored with a footer notice and replaced by the next clean refresh.

## The pane record

`firstmate-tui open --detached` records the pane it created under `~/.local/state/fm-board/` (or `$XDG_STATE_HOME/fm-board/`, or the directory herdr provides in `HERDR_PLUGIN_STATE_DIR`), so `firstmate-tui focus` can find it later.
