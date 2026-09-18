# firstmate-tui: agent notes

Project-intrinsic knowledge for anyone working on `firstmate-tui`. Read the
README first; this file records only what the code does not say on its own.

## What this is

A read-only terminal board over the firstmate fleet, hosted in herdr. The
command is `firstmate-tui` (bare, or `open`, runs the board in the current
pane; `focus`, `upgrade`, `version`, `help`; `run` is a hidden synonym of the
default); `fm-board`, the name up to 0.1.0, is written by the installer as an
alias through 0.3.x and goes in the next release (drop the second
`write_command` call in `bin/install.sh`, `OLD_NAME` in both scripts,
`ensure_new_command`, and the alias checks in `tests/install.test.sh`). The
rename of the asset (`firstmate-tui-<tag>.tar.gz`) and of the paths inside
it (`bin/firstmate-tui.sh`, `bin/firstmate-tui/`) is done as of 0.3.0; only
the default prefix `~/.local/share/fm-board`, the pane-record and view-state
directories named `fm-board` and the view-state schema keep the old word, so
an upgrade moves nothing. Because an install upgrades by running the
`bin/install.sh` that shipped in its own tarball, `bin/install.sh` still
knows both asset names: it reads the release's asset list
(`/releases/tags/<tag>`) and downloads `firstmate-tui-<tag>.tar.gz` when the
release has it, else `fm-board-<tag>.tar.gz`; when that read fails it tries
the two names in that order and moves on from the first on any curl
failure, never on one exit status (GitHub's redirected 404 reached the
0.2.5 installer as exit 56, not the 22 it waited for, so a 0.2.5 install's
own `firstmate-tui upgrade` is not reliable and the README documents one
reinstall through the current installer). It accepts either layout inside
the tarball (never a mix), so a 0.2.x release can be installed again;
installs older than 0.2.5 reach 0.3.0 only through 0.2.5 (the last release
under the old name, and the first installer that knows both).
`tests/install.test.sh` walks both chains with the real installers from the
`v0.1.0` and `v0.2.5` tags and the exit-56 shape (`tests/fake-curl.sh`,
`FAKE_CURL_FAIL`). The herdr plugin id `firstmate.board` stays: linked
plugins and the view-state directory are keyed by it; a plugin linked at
the old `bin/fm-board` path is relinked once. The
scout report at `docs/scout-report-2026-09-16.md` is the design record: its
section 1 table is the pane-to-data mapping that `bin/firstmate-tui/lib/model.mjs`
implements row for row (since 0.4.0 its Ready for review row is two panes, My
PRs and Teammates' PRs, both over the identity in the board's config file; the
README's Using the board section is the current mapping), and its section 7 table is
the milestone plan. Check the plan before widening scope: answering
decisions, opening PRs, toasts and the findings watermark belong to later
milestones.

## Hard rules

- The board reads firstmate homes and never writes into `FM_HOME`, a project
  or a `state/` directory. Its files are the pane record under
  `${XDG_STATE_HOME:-~/.local/state}/fm-board/` (or `HERDR_PLUGIN_STATE_DIR`),
  `view-state.json` (hidden rows and panes, and since 0.5.0 the selection:
  focused pane, row by hide key with its index as the fallback, expanded
  groups, scroll; `lib/viewstate.mjs` names the location chain and refuses a
  path inside `FM_HOME`), `config.json` beside
  it (`lib/config.mjs`, the same chain, passed by the launcher as `--config`
  the way `--view-state` is): the GitHub login the two PR panes are built
  around and the Teammates' PRs label rules, and `state-cache.json` beside
  both (`lib/cache.mjs`: the last facts drawn, written after a clean refresh
  and on quit, drawn at once on the next launch with `(cached Nm ago)` on
  every pane title until that pane's live source lands; `facts.cached` in
  `lib/model.mjs` carries the per-source flags and `lib/app.mjs` clears
  them). The cache holds only what came from outside (snapshot, ledgers, PR
  data with its identity, herdr agents), never view state or the refresh
  bookkeeping, and a failed refresh never overwrites it. The board writes `config.json` once,
  from `EXAMPLE_CONFIG`, when no file is there, and never again; the test
  suite pins that constant byte for byte to `docs/config.example.json`, so
  change both together. Hiding is view state because firstmate retires Done
  rows itself; never turn it into a firstmate write.
- The identity (`lib/identity.mjs`) is the config file's `github_login`, else
  `gh api user` (once per session, again on `r` only while unknown), else
  `git config --get github.user`, never `user.name` or `user.email`: those
  are not GitHub logins. With `--no-prs` gh is not asked at all.
- The board owns no authority. Its actions are `herdr agent focus`, opening a
  PR URL in the browser (`lib/opener.mjs`: an argv spawn of `open` /
  `xdg-open` / `--opener-cmd`, never a shell string, http(s) only), showing a
  report in a terminal viewer (`lib/viewer.mjs`, argv spawn, path appended),
  refreshing its own data (`r`: the snapshot, then the live PR fetch
  unless `--no-prs`; that fetch is the board's own read-only GitHub search
  through `gh api graphql` in `lib/sources.mjs`: at most four searches per
  tick, My PRs open and tail by `author:<login>`, Teammates' PRs open and tail by
  `review-requested:<login> -author:<login>` over the candidate repositories
  plus the config file's, each `first: 50`, plus one aliased lookup of the
  recorded task PRs the author searches missed; `gh search prs --json` cannot
  replace it, it carries no review decision, checks or base branch, and
  `user-review-requested:` must not replace `review-requested:`, it drops the
  team requests. The candidate rule copies `fm-bearings-snapshot.sh`, which
  stays the My PRs fallback when gh is not on PATH; the checks rule
  (`checksState`) judges only the newest run of each check on the head
  commit, which that script does not, so a cancelled run a re-run superseded
  never reads failing here), and upgrading itself from the Settings page (`.`): only after a
  `y` confirmation, only by running the installed launcher's own
  `firstmate-tui upgrade --version <v>` / `--stable` (`lib/upgrade.mjs`, argv
  spawn of `bash <prefix>/bin/firstmate-tui.sh upgrade ...`), so the record checks
  and the swap stay in `bin/firstmate-tui.sh` and `bin/install.sh`; the relaunch is
  exit 75, which `run_board` in the launcher answers by starting the same path
  again. It never moves or closes a herdr
  pane; the captain splits panes himself, so do not bring back an `f` toggle
  or a `pane move` action. `enter` is the one key that opens a PR; do not
  bring back the separate `o` key the scout report's M2 row still lists.
  Answers, merges and dispatch stay with firstmate's own owners.
- In flight groups secondmate work by home, not by delegated item, because
  the ledger carries no per-child parent field (the comment above
  `inflightRows` in `lib/model.mjs` lists the fields that exist). Read it
  before changing the grouping.
- `FM_HOME` is explicit, never inferred from the current directory. The
  launcher's FM_HOME error may name a home it finds above the working
  directory as the command to run, but it never adopts one (`die_no_home`
  in `bin/firstmate-tui.sh`); the plugin `fm-home` file is the one automatic
  fallback.
- yimbot (github.com/YiminArava4508/yimbot) ships no license: it is a pattern
  reference only. Do not copy code from it.

## Working on the code

- Pure modules (`text`, `layout`, `model`, `render`, `settings`, `identity`)
  take data and return data; keep them that way so `--render-once --fixture`
  stays the test surface. I/O lives in `sources.mjs` (firstmate, the GitHub
  searches and the identity rungs, and the GitHub releases fetch through
  `--curl-cmd`), `herdr.mjs` (herdr), `upgrade.mjs` (the install record and
  the upgrade child), `viewstate.mjs` and `config.mjs` (the board's two
  files; both hold their pure parse beside the read and write).
- The two PR panes share one candidate list; a row's `pane` (`mine` or
  `toreview`, absent means `mine`) says where it draws, and `facts.prs.mine`
  and `facts.prs.toreview` carry each pane's own fetch state so one pane can
  be stale while the other is fresh (`mergePrs` in `lib/model.mjs` is the one
  place that folds a fetch into the previous facts). The identity has three
  states (`lib/identity.mjs`): `null` is unresolved (the app before its first
  refresh has asked the rungs, and again while `r` asks for an unknown one),
  a login is known, and `{ login: null, source: 'unknown' }` is resolved
  unknown; the PR panes spin on the first (`resolving GitHub identity`) and
  show their identity row only for the last, and a fetch with the identity
  unknown is `skipped`, leaving both panes unfetched. A fixture's
  `prs.identity` absent stands for a known login, `null` for unresolved, and
  an object without a login for resolved unknown.
- Needs you's `review` row, In flight's `repairing PR` state and My PRs'
  `READY` / `REPAIRING` words are one set of definitions in `lib/model.mjs`
  (`parkedForCaptain`, `isRepairing`, `prReadiness`, `fleetPrTasks`); change
  them together. Two facts they need are not in the fleet snapshot: whether a
  working task once said done (the board reads the status log's verbs through
  `facts.statusVerbs`, the one place it reads a log's lines; a fixture's
  `status_logs` map stands in) and a secondmate child's PR (the ledger's
  `contributions.captain[]`, from firstmate's `fm-contributions.sh`; its
  `active_children` and `endpoints` carry no PR field). GitHub's
  `mergeStateStatus` is fetched as `merge_state`; `ready` means mergeable and
  not DIRTY, so BLOCKED (a required review missing) counts as ready.
- `lib/tui-blessed.mjs` is the only importer of `neo-blessed`. Anything the
  terminal library must do goes through the screen contract at the top of
  that file. That includes the mouse: adding the screen's mouse listener is
  what switches terminal mouse reporting on, and the adapter only translates
  events. The library reports one Enter press as two keypress events
  (`enter`, then `return`); `normalizeKey` keeps the first and drops the
  second, so the controller hears one key per press. `--render-once --keys`
  feeds the controller directly and never loads the library, so a change to
  how input reaches the app must also be checked on a real pseudo-terminal:
  a private `tmux -L <name>` server with `send-keys` and `capture-pane`
  (never the captain's session) shows the actual screen. What a click means
  is decided in `lib/controller.mjs`
  (`mouseAction`, `handleMouse`; on the Settings page `settingsMouseAction`
  in `lib/settings.mjs`, over that page's own `kind: 'settings'` zones)
  against the `zones` the renderer returns with every frame, so gestures are
  tested through `--render-once --mouse <list>` (event tokens and key names
  in order) and never a real pointer. The column drag takes the same path:
  the column-header line's zone carries the drawn columns (`header`),
  `boundaryAt` in `lib/layout.mjs` reads it, the controller's
  `drag-start` / `drag-move` / `drag-end` and `reset-column` actions apply
  it, and the harness drives it with `drag:X1,Y->X2`, `move:X,Y` and
  `release:X,Y`. The adapter turns a motion report with a button held into
  a `drag` event (the library labels it a press); mode 1002 is already among
  the modes `enableMouse` switches on. That harness never loads neo-blessed,
  so a change to the adapter is also checked by running the interactive
  board on a pseudo-terminal (`tests/pty-keys.py`, Python `pty.fork`; macOS
  `script` refuses piped stdio; the suite's last section drives it for the
  Enter key and the identity spinner; the driver sees only the cells the
  library repaints, so a phrase drawn over other text can reach a `wait:`
  with its unchanged letters missing: wait for text that lands on blank
  cells or after a full redraw, and `absent:` checks what must not have been
  drawn yet) with `--opener-cmd bash tests/fake-opener.sh` and the raw
  reports a terminal sends (X10 `ESC [ M`, button+32, col+33, line+33:
  press 32, release 35, drag 64; SGR `ESC [ < b;col+1;line+1 M` or `m`),
  counting opener lines. Inside herdr the same check runs in a lab session
  (firstmate's `bin/fm-herdr-lab.sh`: provision, `viewer start` for a
  120x40 client, `workspace create`, `pane run` the board with `--no-herdr
  --no-prs --view-state <scratch file>` so it makes no herdr call of its own,
  `pane send-text` with the raw report bytes, `pane read`, teardown); it
  proves the parse and the adapter inside a herdr pane, not herdr's routing
  of a real pointer. neo-blessed 0.2.0 parses one report per chunk,
  labels a drag as `mousedown left` and emits two keypress events for one
  carriage return; the adapter's comments say how each is handled.
- Column widths are computed, never fixed: `columns()` in `lib/layout.mjs`
  sizes each fixed column to the widest value it shows in that pane (between
  its label and a cap), applies the captain's dragged widths from view state,
  and gives the one flexible column the rest, with a two-cell gutter. The
  tests pin a header as `LABEL {W}NEXT` where W is the column's width (its
  padding plus the gutter), so a fixture change that widens a value, or a key
  that hides the widest row, moves those regexes on purpose; write new ones
  with `+` unless the width is the point of the check.
- Run `tests/fm-board.test.sh` after any change; it needs Node, plus
  python3 and the board's `node_modules` for its last section, which runs
  the interactive board on a pseudo-terminal (`tests/pty-keys.py`) and is
  skipped with a note without them. Add a fixture under `tests/fixtures/` when a new data shape appears,
  and name in the test comment what would make the check fail. Key behavior
  is tested through `--render-once --keys <list>` (and `--expand`,
  `--view-state`, `--tags`, `--cache`: a one-shot render restores a saved
  selection and never records one, so scripted key lists start from a known
  place and renders sharing a view-state file stay independent; it reads a
  state cache only with `--cache <file>` and writes that file only when
  nothing in the frame came from it, which is how the suite builds a cache
  from `populated.json` and restores it over `cold-start.json`); a PR open must go to `--opener-cmd bash
  tests/fake-opener.sh` and a report view to `--viewer-cmd bash
  tests/fake-viewer.sh`, never a real browser or editor (a one-shot render
  without `--viewer-cmd` only reports the resolved viewer for that reason).
  The `r` key is tested against a stand-in home whose snapshot scripts only
  log that they ran, with `tests/fake-gh.sh` first on PATH as `gh` (see
  `render_live` in the test): every live render must put that fake first on
  PATH, because the board's own fetch and its `gh api user` identity call
  otherwise reach the real GitHub CLI. The fake answers `api user` and `api
  graphql` (dispatching on the search string's `author:`,
  `review-requested:`, `is:open` and `closed:>=`, or on the lookup's
  `repository(` aliases; its header names every canned PR and what each
  proves) and fails on `pr list`, so the old per-repository fetch cannot come
  back unnoticed; it logs a search with the `closed:>=` stamp replaced by
  `<since>` so the suite compares whole logs. A live render also writes the
  example config into its `XDG_CONFIG_HOME`, which is how the gemini rule
  reaches the Teammates' PRs scope in those checks. The identity chain is tested
  with a fake `git` that answers `config --get github.user` alone and hands
  every other call to the real one, because `candidateRepos` runs git too.
  `populated.json` and `pr-status.json` are 160x44, not 40: six panes need
  the room, and the mouse and line-number checks name lines on that frame.
  The pane order is `PANES` in `lib/layout.mjs` (Needs you, My PRs,
  Teammates' PRs, In flight, Findings, Landed); the 1-6 keys follow it by
  position, the height priorities name panes by id, and view state is keyed
  by pane id, so a reorder moves the mouse and line-number checks and
  nothing else.
  The refresh schedule (the snapshot, then the gh calls; the next refresh
  armed on completion for the last start plus `--refresh`, so a slow refresh
  is followed at once and never doubled; a tick that lands mid-refresh
  skipped) is tested by running the app with `--headless` against a stand-in
  whose snapshot sleeps and stopping it with a signal, so `--headless` must
  never load `neo-blessed`. The launcher runs node as a child, so that
  signal goes to the child first (`pkill -P`) and then to the launcher; a
  signal to the launcher alone leaves the board running and appending to the
  fetch log for the rest of the suite. The title line's countdown, `refreshing...` and
  failure label render from a fixture `refresh` block (`index.mjs` documents
  it) because a one-shot render has no schedule; the panes' loading spinner
  comes from the same block (`refreshing: true` with no snapshot or `prs`
  block, `loading_frame` for the glyph), and it counts ticks, never the
  clock, so keep it that way or one-shot frames stop being deterministic. The Settings page
  is tested with `--install-root` at a fake prefix whose `bin/firstmate-tui.sh` is
  `tests/fake-upgrade.sh` and with `--curl-cmd bash tests/fake-curl.sh` over
  `tests/fixtures/releases/api`; a one-shot render without `--curl-cmd`
  fetches nothing by design, and the launcher's relaunch loop runs against
  `tests/fake-node.sh` on PATH. Nothing in the suite may call a real herdr or
  a real gh: if a test ever needs herdr, fake it and point `HERDR_BIN_PATH`
  at the fake as well as PATH, because herdr sets `HERDR_BIN_PATH` inside its
  panes and PATH alone still reaches the captain's live server.
- Bash (`bin/*.sh`, `scripts/*.sh`, `tests/*.sh`) must pass ShellCheck
  0.11.0, the same pin firstmate uses (`npx --yes shellcheck@4.1.0 --norc bin/*.sh scripts/*.sh tests/*.sh`
  when no local binary is installed). Every `rm` on a variable path takes
  the `${VAR:?}` guard so an empty variable fails instead of widening.
- Distribution is GitHub Releases (README "Install" and "Releasing"). The
  one version source is `version` in `bin/firstmate-tui/package.json`, and
  `.github/workflows/release.yml` is the only release path. Every push to
  `main` is a release: `scripts/next-version.sh` picks package.json's
  version when its tag is free, else the next free patch, and the workflow
  commits that bump to `main` as `github-actions[bot]` (`Release <v> [skip
  ci]`) before building at it; any other push publishes the prerelease
  `v<next>-<sha7>`, named against the coming release. Nobody tags by hand,
  nobody opens a PR only to bump the version (bump minor or major in the PR
  that earns it), and no test creates a tag or a release. A commit message
  you push must never contain the literal skip-ci marker (the bracketed
  words the bot's bump commit uses): GitHub then skips the PR's own checks
  and its beta; the workflow's bump commit is the only place it belongs, and
  prose spells it out as "the skip-ci marker". `scripts/package.sh`
  is the one place that builds the tarball (the workflow and
  `tests/install.test.sh` both run it), so a new file that must ship, and the
  tag-equals-version check, are changes there. `.github/workflows/test.yml`
  runs both suites, ShellCheck and actionlint on every pull request and on
  every push to a branch other than `main`.
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
