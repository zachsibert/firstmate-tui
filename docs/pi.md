# The board in Pi (prototype)

`bin/firstmate-tui/pi/index.ts` is a Pi extension that puts the board inside a Pi 1.4.0 session. The standalone board is unchanged; the two share the same data sources, model, layout, render and controller code through `createApp` in `lib/app.mjs`.

## Try it

```
pi -e <absolute path to this repository>/bin/firstmate-tui/pi/index.ts
```

`FM_HOME` must point at a firstmate home (the directory holding `bin/fm-fleet-snapshot.sh`), the same rule as the standalone board; the herdr plugin's `fm-home` file is the fallback. Extra board flags go through `FM_BOARD_PI_ARGS`, for example `FM_BOARD_PI_ARGS="--no-herdr --refresh 60"`.

## What you get

- A footer status line with the fleet counts, refreshed every 5 s: `board 4 call | 2 underway | 6 my PRs | 2 to review`. The extension owns the timer and clears it on session shutdown.
- `/board` opens the whole board as a full-screen overlay with the board's own keys. `q` or escape closes back to the editor.
- Row actions prefill the chat box and send nothing. `a` on a hold row fills `Answer for <id>: `, `d` fills `Discard the hold on <id>: `, `D` fills `Defer <id> until <date>: ` with the default date, and `c` fills `About <row> in <pane>: ` for any row. The answer itself goes through the normal chat turn.
- The hold writes (`answer`, `discard`, `defer`) are off inside Pi: their effects are replaced with a notice. The same holds for the upgrade action on the Settings page.

## Files

The Pi front end keeps its own view state (`pi/view-state.json` beside the board's view-state file, or under the herdr plugin config directory) so it never overwrites the standalone board's selection. The config file and the state cache are the board's own, shared with the standalone board.

## Known gaps

- Mouse: the overlay takes keys only.
- The pager hand-off for a full report or card (`enter` inside the summary view) shows a notice; the summary view itself works.
- Summaries are off; rows show their raw text.
- The pinned widget, a model-callable tool and an MCP server are not built.
- The board lives and dies with its Pi session; `/reload`, `/new` and `/resume` restart it.
