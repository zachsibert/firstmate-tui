# firstmate-tui: agent notes

Project-intrinsic knowledge for anyone working on `fm-board`. Read the README
first; this file records only what the code does not say on its own.

## What this is

A read-only terminal board over the firstmate fleet, hosted in herdr. The
scout report at `docs/scout-report-2026-09-16.md` is the design record: its
section 1 table is the pane-to-data mapping that `bin/fm-board/lib/model.mjs`
implements row for row, and its section 7 table is the milestone plan. Check
the plan before widening scope: answering decisions, opening PRs, toasts and
the findings watermark belong to later milestones.

## Hard rules

- The board reads firstmate homes and never writes into `FM_HOME`, a project
  or a `state/` directory. Its only file is the pane record under
  `${XDG_STATE_HOME:-~/.local/state}/fm-board/` (or `HERDR_PLUGIN_STATE_DIR`).
- The board owns no authority. Its actions are `herdr agent focus` and
  opening a PR URL in the browser (`lib/opener.mjs`: an argv spawn of `open`
  / `xdg-open` / `--opener-cmd`, never a shell string, http(s) only). Answers,
  merges and dispatch stay with firstmate's own owners.
- In flight groups secondmate work by home, not by delegated item, because
  the ledger carries no per-child parent field (the comment above
  `inflightRows` in `lib/model.mjs` lists the fields that exist). Read it
  before changing the grouping.
- `FM_HOME` is explicit, never inferred from the current directory.
- yimbot (github.com/YiminArava4508/yimbot) ships no license: it is a pattern
  reference only. Do not copy code from it.

## Working on the code

- Pure modules (`text`, `layout`, `model`, `render`) take data and return
  data; keep them that way so `--render-once --fixture` stays the test
  surface. I/O lives in `sources.mjs` (firstmate) and `herdr.mjs` (herdr).
- `lib/tui-blessed.mjs` is the only importer of `neo-blessed`. Anything the
  terminal library must do goes through the screen contract at the top of
  that file.
- Run `tests/fm-board.test.sh` after any change; it needs Node and nothing
  else. Add a fixture under `tests/fixtures/` when a new data shape appears,
  and name in the test comment what would make the check fail. Key behavior
  is tested through `--render-once --keys <list>` (and `--expand`); a PR open
  must go to `--opener-cmd bash tests/fake-opener.sh`, never a real browser.
- Bash (`bin/fm-board.sh`, `tests/*.sh`) must pass ShellCheck 0.11.0, the
  same pin firstmate uses (`npx --yes shellcheck@4.1.0 --norc bin/fm-board.sh tests/fm-board.test.sh`
  when no local binary is installed).
- Live herdr behavior is verified only in an isolated named session through
  firstmate's `bin/fm-herdr-lab.sh` (provision, run, teardown). Never drive
  the captain's `default` session from a test. Verified on herdr 0.8.2,
  protocol 20: `status --json` reports the socket at `.server.socket`, the
  event envelope uses underscore names (`pane_updated`), and a subscription
  naming a pane the server does not know is rejected as a whole.
- `herdr plugin link` is user-global (it affects every session), so linking
  the manifest is the captain's step, not a test step.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
