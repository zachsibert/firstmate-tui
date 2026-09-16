# firstmate-tui

`fm-board`: a live, herdr-hosted terminal board over the [firstmate](https://github.com/kunchenguid/firstmate) fleet snapshot, so all parallel work is visible at a glance instead of buried in a scrolling chat thread.

Panes, top to bottom by urgency:

1. **Needs you** - open captain decisions, blockers, and green PRs waiting on a merge
2. **Ready for review** - one row per open PR with checks, draft state, labels, age
3. **In flight** - one row per worker across every home, with live herdr agent state
4. **Findings** - scout reports and discoveries since your last look
5. **Landed** - recently merged and cleaned up work

Data comes from `bin/fm-fleet-snapshot.sh --json` and each home's `state/home-summary.json`; agent state comes from herdr's socket API (`events.subscribe`), so the board reacts to changes instead of polling herdr. The board owns no authority of its own: answers route through `fm-captain-hold.sh` / `fm-send.sh --resolve-key`, jump-to-worker through `herdr agent focus`.

## Status

Design stage. The scout report that grounds the plan is in [`docs/scout-report-2026-09-16.md`](docs/scout-report-2026-09-16.md): data availability per pane, herdr capabilities, what is reusable from yimbot, stack choice, and a four-milestone plan (about 9 to 12 worker-days, M1 read-only board 3 to 4).

## Requirements

- firstmate home with `bin/fm-fleet-snapshot.sh`
- herdr 0.8.x or newer (socket API protocol 20)
- Node (already a firstmate dependency)
