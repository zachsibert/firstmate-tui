# firstmate-tui: agent notes

Project-intrinsic knowledge for anyone working on `firstmate-tui`. Read the
README first; this file records only what the code does not say on its own.

## What this is

A read-only terminal board over the firstmate fleet, hosted in herdr. The
command is `firstmate-tui` (bare, or `open`, runs the board in the current
pane; `focus`, `upgrade`, `version`, `help`; `run` is a hidden synonym of the
default); `fm-board`, the name up to 0.1.0, is written by the installer as an
alias for the 0.2.x release only. The release asset `fm-board-<tag>.tar.gz`,
the default prefix `~/.local/share/fm-board`, and `bin/fm-board.sh` and
`bin/fm-board/` inside the tarball are frozen under the old name because a
0.1.0 install upgrades by running its own `bin/install.sh`, which downloads
and checks exactly those; the launcher then writes `firstmate-tui` beside
`fm-board` (`ensure_new_command`). Rename them only once no 0.1.0 install
remains, and keep `tests/install.test.sh`'s 0.1.0 upgrade walk (built from
the `v0.1.0` tag) green until then. The herdr plugin id `firstmate.board`
stays for the same reason: linked plugins and the view-state directory are
keyed by it. The
scout report at `docs/scout-report-2026-09-16.md` is the design record: its
section 1 table is the pane-to-data mapping that `bin/fm-board/lib/model.mjs`
implements row for row, and its section 7 table is the milestone plan. Check
the plan before widening scope: answering decisions, opening PRs, toasts and
the findings watermark belong to later milestones.

## Hard rules

- The board reads firstmate homes and never writes into `FM_HOME`, a project
  or a `state/` directory. Its files are the pane record under
  `${XDG_STATE_HOME:-~/.local/state}/fm-board/` (or `HERDR_PLUGIN_STATE_DIR`)
  and `view-state.json` (hidden rows and panes; `lib/viewstate.mjs` names the
  location chain and refuses a path inside `FM_HOME`). Hiding is view state
  because firstmate retires Done rows itself; never turn it into a firstmate
  write.
- The board owns no authority. Its actions are `herdr agent focus`, opening a
  PR URL in the browser (`lib/opener.mjs`: an argv spawn of `open` /
  `xdg-open` / `--opener-cmd`, never a shell string, http(s) only), showing a
  report in a terminal viewer (`lib/viewer.mjs`, argv spawn, path appended)
  and refreshing its own data (`r`: the snapshot, then the live PR fetch
  unless `--no-prs`; that fetch is the board's own read-only `gh pr list` per
  candidate repository in `lib/sources.mjs`, copying `fm-bearings-snapshot.sh`'s
  candidate and checks rules, with that script as the fallback when gh is not
  on PATH). It never moves or closes a herdr pane; the captain splits
  panes himself, so do not bring back an `f` toggle or a `pane move` action.
  `enter` is the one key that opens a PR; do not bring back the separate `o`
  key the scout report's M2 row still lists. Answers, merges and dispatch stay
  with firstmate's own owners.
- In flight groups secondmate work by home, not by delegated item, because
  the ledger carries no per-child parent field (the comment above
  `inflightRows` in `lib/model.mjs` lists the fields that exist). Read it
  before changing the grouping.
- `FM_HOME` is explicit, never inferred from the current directory. The
  launcher's FM_HOME error may name a home it finds above the working
  directory as the command to run, but it never adopts one (`die_no_home`
  in `bin/fm-board.sh`); the plugin `fm-home` file is the one automatic
  fallback.
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
  is tested through `--render-once --keys <list>` (and `--expand`,
  `--view-state`, `--tags`); a PR open must go to `--opener-cmd bash
  tests/fake-opener.sh` and a report view to `--viewer-cmd bash
  tests/fake-viewer.sh`, never a real browser or editor (a one-shot render
  without `--viewer-cmd` only reports the resolved viewer for that reason).
  The `r` key is tested against a stand-in home whose snapshot scripts only
  log that they ran, with `tests/fake-gh.sh` first on PATH as `gh` (see
  `render_live` in the test): every live render must put that fake first on
  PATH, because the board's own fetch otherwise calls the real GitHub CLI.
  The refresh schedule (the snapshot, then the gh calls, per tick; a tick
  that lands mid-refresh skipped) is tested by running the app with
  `--headless` against a stand-in whose snapshot sleeps and stopping it with
  a signal, so `--headless` must never load `neo-blessed`. Nothing in the
  suite may call a real herdr or a real gh: if a test ever needs herdr, fake
  it and point `HERDR_BIN_PATH` at the fake as well as PATH, because herdr
  sets `HERDR_BIN_PATH` inside its panes and PATH alone still reaches the
  captain's live server.
- Bash (`bin/*.sh`, `scripts/*.sh`, `tests/*.sh`) must pass ShellCheck
  0.11.0, the same pin firstmate uses (`npx --yes shellcheck@4.1.0 --norc bin/fm-board.sh bin/install.sh scripts/package.sh tests/fm-board.test.sh tests/install.test.sh tests/fake-curl.sh`
  when no local binary is installed). Every `rm` on a variable path takes
  the `${VAR:?}` guard so an empty variable fails instead of widening.
- Distribution is GitHub Releases (README "Install" and "Releasing"). The
  one version source is `version` in `bin/fm-board/package.json`, and
  `.github/workflows/release.yml` is the only release path: a push to `main`
  releases `v<version>` once, any other push publishes the prerelease
  `v<version>-<sha7>`; nobody tags by hand, and no test creates a tag or a
  release. `scripts/package.sh` is the one place that builds the tarball
  (the workflow and `tests/install.test.sh` both run it), so a new file that
  must ship, and the tag-equals-version check, are changes there.
  `bin/install.sh` must stay runnable through `curl | bash`: everything
  inside `main()`, no `BASH_SOURCE`, only curl, tar and sha256sum or shasum
  (grep and sed parse the releases API), and it writes only under `--prefix`
  and `--bin-dir`; it ships in the tarball because `firstmate-tui upgrade` execs
  the installed copy, so download, verify and swap have one implementation.
  Tests reach GitHub through `tests/fake-curl.sh` on PATH, never the network.
  Lint the workflow with `actionlint` after changing it.
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
