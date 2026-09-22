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
scout report at `docs/scout-report-2026-09-16.md` is the design record of
the first releases: its section 1 table was the pane-to-data mapping through
0.6.x (since 0.4.0 its Ready for review row is two panes, My PRs and
Teammates' PRs, both over the identity in the board's config file), and its
section 7 table is the milestone plan. Since 0.7.0 the four fleet panes
follow the four sections of firstmate's bearings digest (Captain's Call,
Underway, Charted Next, Recently Landed; the chat-response contract in
firstmate's `.agents/skills/bearings/SKILL.md`), and the README's Using the
board section is the current pane-to-data mapping, which
`bin/firstmate-tui/lib/model.mjs` implements row for row. Check the plan
before widening scope: of its M2 actions, discarding and deferring a hold are
here since 0.6.0 (`d` and `D`, through `fm-captain-hold.sh`) and accepting
one with an option letter or a typed line is here too (`a`, the same
command's `answer`, `--release` for a work item); `fm-send --resolve-key`
routing, notes through `fm-inbox`, opening PRs, toasts and the unread-report
marker belong to later milestones.

## Hard rules

- The board reads firstmate homes and never edits a file under `FM_HOME`, a
  project or a `state/` directory; its three writes are `fm-captain-hold.sh
  answer` (`a` with the captain's own answer, `--release` for a work item;
  `d` with the fixed discard text) and `hold` (`D`), run in the home that
  owns the hold (`lib/hold.mjs`), so firstmate's own guards decide and the
  board never touches `backlog.md` or a status file. Its files are the pane record under
  `${XDG_STATE_HOME:-~/.local/state}/fm-board/` (or `HERDR_PLUGIN_STATE_DIR`),
  `view-state.json` (hidden rows and panes, and since 0.5.0 the selection:
  focused pane, row by hide key with its index as the fallback, expanded
  groups, scroll; `lib/viewstate.mjs` names the location chain and refuses a
  path inside `FM_HOME`), `config.json` beside
  it (`lib/config.mjs`, the same chain, passed by the launcher as `--config`
  the way `--view-state` is): the GitHub login the two PR panes are built
  around, the Teammates' PRs label rules and `prs.source` (`board`, the
  default, or `firstmate`, the opt-in to firstmate's script; the parsed
  config's `prs.configured` says whether the file set it), and `state-cache.json` beside
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
  showing a hold card (enter on a Captain's Call hold, decide or blocked row,
  on a Charted Next queued or held row, on a delegate's decision row, or on
  an Underway or Recently Landed row whose task is a captain hold;
  `lib/card.mjs` builds it, pure, from the backlog record and
  the files `lib/sources.mjs` reads under `data/<id>/` and `state/<id>.status`,
  and `lib/hold.mjs` writes it to a mkdtemp directory the same viewer path
  shows and then removes; a delegate home's record comes from that home's own
  `fm-fleet-snapshot.sh --json`, never from a backlog parser of the board's,
  and a remote or unreadable home gets the ledger's fields under a partial
  notice), discarding a hold (`d`, after `y`: `fm-captain-hold.sh answer <id>
  --decision-file <tmp>` in the owning home, the decision text fixed in
  `lib/card.mjs` with the resolved GitHub login or else the OS user) and
  deferring one (`D`, a footer date prompt prefilled with today plus 14 days:
  `fm-captain-hold.sh hold <id> --reason <the record's full hold_reason>
  --until <date>`; a delegate hold's full reason is read from its home first
  and the defer is refused rather than passing the ledger's 160-character
  cut), both argv spawns of `bash <home>/bin/fm-captain-hold.sh` with
  `FM_HOME=<home>` and cwd there, a success dropping every row of that task
  from the frame at once (`view.dismissed`, a session-only set beside
  `view.hidden` that `applyDismissed` in `lib/model.mjs` reads; never view
  state, never shown by `H`; an entry is cleared only by a clean refresh
  whose facts no longer list the task as a live hold, `pruneDismissed`) and
  starting a refresh, and a failure showing the command's stderr verbatim in
  red and changing nothing;
  a remote home's hold gets a notice and no prompt;
  accepting a hold (`a`: the row's card and full record are loaded first,
  `loadHoldCard` in `lib/hold.mjs`, a delegate home's through its own
  `fm-fleet-snapshot.sh`, and the accept is refused when that read fails, as
  `D` refuses; then `openAcceptPrompt` in `lib/controller.mjs` draws the card
  in the frame, `renderAccept` in `lib/render.mjs`, while the footer takes
  the answer, `view.prompt` kind `accept` in `lib/card.mjs`: the reason's
  lettered options from `parseOptions`, whose exact grammar the README key
  table states, a letter picks one, any other printable key types a line;
  enter runs `fm-captain-hold.sh answer <id> --decision-file <tmp>` in the
  owning home with the text `acceptDecision` fixes, plus `--release` when
  `acceptRelease` says the record is a work item: its `kind` is anything but
  `captain`, the kind `fm-captain-hold.sh hold` gives a question it creates;
  a record without a kind is refused by `acceptProblem` and never guessed;
  an empty answer and the reserved word `reconcile` are refused with the
  prompt open, `checkAcceptAnswer`; a success dismisses the task's rows and
  refreshes as `d` does and the footer reads `<id>: answer recorded;
  firstmate dispatches` or `closed`, never that work started; `a` on a
  Captain's Call `review` row is a notice, since the board has no merge
  path, and enter opens the PR);
  refreshing its own data (`r`: the snapshot, drawn when it lands, then the
  live PR fetch behind it unless `--no-prs`; that fetch is the board's own
  read-only GitHub search through `gh api graphql` in `lib/sources.mjs`: at
  most four searches per tick, My PRs open and tail by `author:<login>`,
  Teammates' PRs open and tail by
  `review-requested:<login> -author:<login>` over the candidate repositories
  plus the config file's, each `first: 50`, plus one aliased lookup of the
  recorded task PRs the author searches missed; `gh search prs --json` cannot
  replace it, it carries no review decision, checks or base branch, and
  `user-review-requested:` must not replace `review-requested:`, it drops the
  team requests. The candidate rule copies `fm-bearings-snapshot.sh`, which
  stays the My PRs fallback when gh is not on PATH and is the PR source
  outright when the config file's `prs.source` is `firstmate`
  (`prSourceInEffect` in `lib/config.mjs` is the one rule; `fetchPrs` hands
  the source it used back for the Settings page's PR source line, and
  Teammates' PRs is `unavailable` with `GH_MISSING` or `SCRIPT_CONFIGURED`
  from `lib/model.mjs` as the reason); the checks rule
  (`checksState`) judges only the newest run of each check on the head
  commit, which that script does not, so a cancelled run a re-run superseded
  never reads failing here. The script's rows go through `projectScriptPr`,
  so a row that ever carries its check runs is judged by the same rule, and
  a row with only the script's `checks` word keeps the word; do not
  recompute the word from nothing or copy the script into this repository),
  and upgrading itself from the Settings page (`.`): only after a
  `y` confirmation, only by running the installed launcher's own
  `firstmate-tui upgrade --version <v>` / `--stable` (`lib/upgrade.mjs`, argv
  spawn of `bash <prefix>/bin/firstmate-tui.sh upgrade ...`), so the record checks
  and the swap stay in `bin/firstmate-tui.sh` and `bin/install.sh`; the relaunch is
  exit 75, which `run_board` in the launcher answers by starting the same path
  again. It never moves or closes a herdr
  pane; the captain splits panes himself, so do not bring back an `f` pane
  toggle or a `pane move` action (`F` focuses the selected row's herdr pane
  in any pane, `focusProblem` with `any`, and nothing more; it was `f` from
  0.6.0 through 0.6.6, and `f` is the search since: a footer prompt,
  `view.prompt` kind `search` in `lib/card.mjs`, whose results list replaces
  the grid, `renderSearch` in `lib/render.mjs`, ranked by the pure
  `lib/search.mjs` over `model.search`, the index `buildModel` fills from
  every pane's full row list: dismissed rows out, hidden rows marked, every
  Underway group open, hidden panes included. Enter jumps: the row's pane
  shown if hidden, its group expanded, `H` on for the session if the row is
  hidden, the row selected by hide key. The query and cursor are session
  state, never view state. `j` and `k` type into the query, so only the
  arrows, the page keys, tab and the wheel move through the matches).
  `enter` is the one key that opens a PR; do not
  bring back the separate `o` key the scout report's M2 row still lists.
  Free-text answers, merges and dispatch stay with firstmate's own owners.
- The four fleet panes keep the bearings digest's placement rules, and
  every rule reads structured fields, never prose: a captain hold sits in
  exactly one pane by the canonical snapshot's `hold_bucket` (live in
  Captain's Call, blocked, dated or aged in Charted Next with its structured
  reason, `chartedRows` in `lib/model.mjs`); a queued item and an
  action-free warning are Charted Next's and never Captain's Call's
  (warnings first, left out of the count); a delegate home is never a row of
  work; a report is a completion in Recently Landed (VERB `reported` or
  `report`), never a pane of its own; Recently Landed admits a Done row by
  the port of firstmate's `bin/fm-landed-lib.sh` (`landedRecord`, keep it in
  step with that file) plus the answered calls as VERB `answered`. A
  delegate's hold appears once: its ledger is the authority and the copy
  the parent channel relayed into the delegate's task record (key
  `captain-hold-<task>-<n>`, `relayedTaskId`) is drawn only when the ledger
  does not carry the task (`relayedDecisionRows`).
- Underway groups secondmate work by home, not by delegated item, because
  the ledger carries no per-child parent field (the comment above
  `inflightRows` in `lib/model.mjs` lists the fields that exist). Read it
  before changing the grouping. A home's rows are its live workers only
  (`ledgerChildRows`: active children and live endpoints, never a done or
  unknown one, never a hold or decision); a group row is drawn only over two
  or more of them, one worker draws directly, none draws nothing
  (`ledgerEntry`, `groupState`); the delegate's own task record lends the
  group a pane and nothing else, because that record's state is the last
  verb of the delegate's own status log and reads done after any done relay.
  Do not rank or list it again.
- `FM_HOME` is explicit, never inferred from the current directory. The
  launcher's FM_HOME error may name a home it finds above the working
  directory as the command to run, but it never adopts one (`die_no_home`
  in `bin/firstmate-tui.sh`); the plugin `fm-home` file is the one automatic
  fallback.
- yimbot (github.com/YiminArava4508/yimbot) ships no license: it is a pattern
  reference only. Do not copy code from it.

## Working on the code

- Pure modules (`text`, `layout`, `model`, `render`, `settings`, `identity`,
  `card`, `search`) take data and return data; keep them that way so
  `--render-once --fixture` stays the test surface. I/O lives in `sources.mjs` (firstmate,
  the GitHub searches and the identity rungs, the GitHub releases fetch
  through `--curl-cmd`, and the reads behind a hold card: `readHoldMaterials`
  and a delegate home's record through `readHoldRecord`), `herdr.mjs`
  (herdr), `upgrade.mjs` (the install record and the upgrade child),
  `hold.mjs` (the card's text and temp file and the three `fm-captain-hold.sh` runs),
  `viewstate.mjs` and `config.mjs` (the board's two files; both hold their
  pure parse beside the read and write). A row's `card` and `hold` fields
  (`lib/model.mjs` header) say what enter, `a`, `d` and `D` may do with it; the
  prompt state is `view.prompt` (`lib/card.mjs`), the busy guard `view.busy`,
  so `--render-once --keys d,y`, `D,enter` and `a,<letter or typed keys>,enter`
  drive all three through the controller, and the one-shot driver waits for
  a hold effect before the next key while `view.busy` is set.
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
- Captain's Call's `review` row, Underway's `repairing PR` state and My PRs'
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
  events. It also owns the colours: `STYLE_TAGS` there is the one place a
  style name becomes tags; the cursor bar (`selected`) is the terminal's
  inverse video and the focused pane's border (`border-focus`) is bold amber,
  and a colour beyond the basic 16 is named by its palette index
  (`{214-fg}`, that border), never a hex value, because neo-blessed 0.2.0
  maps a hex tag to a basic colour; `accentStyle` reads the terminal's colour
  count and falls back to yellow below 256, since the library reduces 214 to
  red there (its header says how this was found). The library reports one Enter press as two keypress events
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
  example config into its `XDG_CONFIG_HOME`, which is how the example's
  placeholder rule (`example-corp/portal`) reaches the Teammates' PRs scope
  in those checks. Names in the README, `docs/`, the shipped example, code
  comments and the fixtures are placeholders (`example-corp/portal`,
  `acme/...`, the delegate home `delegate-a`): never name a real
  organisation, repository or product there; `docs/scout-report-*.md` is a
  historical record and is left as written. The identity chain is tested
  with a fake `git` that answers `config --get github.user` alone and hands
  every other call to the real one, because `candidateRepos` runs git too.
  `populated.json` and `pr-status.json` are 160x44, not 40: six panes need
  the room, and the mouse and line-number checks name lines on that frame.
  The hold checks render `holds.json` after rewriting its two placeholder
  homes to scratch directories the suite fills (the card's files under
  `data/<id>/` and `state/<id>.status`, a fake `fm-fleet-snapshot.sh` that
  prints the delegate's record and `tests/fake-captain-hold.sh` as
  `bin/fm-captain-hold.sh`, which logs `FM_HOME`, its cwd, its argv and the
  decision file to `FM_BOARD_TEST_HOLD_LOG` and refuses with a fixed stderr
  line under `FAKE_HOLD_FAIL`); the card's text is read back through the fake
  viewer's `FM_BOARD_TEST_VIEWER_COPY`, since the board removes the temp file
  as soon as the viewer exits. `d,y`, `D,enter` and `a,...,enter` in a
  one-shot render run the home's script for real, so a fixture's homes must
  never be real ones; the pty section types the `D` prompt (digits,
  backspace, enter) and the `a` prompt (a line with a space, enter) against
  the stand-in home's copy of the fake. The accept checks render
  `accept.json` over the same two scratch homes (`option-hold` carries the
  `Options:` grammar and kind `captain`, `work-hold` kind `ship`,
  `nokind-hold` no kind); its `card lines M-N of T` heading counts the
  wrapped card, so a change to `buildHoldCard` or to the wrap moves those
  regexes on purpose.
  The pane order is `PANES` in `lib/layout.mjs` (Captain's Call, Underway,
  My PRs, Teammates' PRs, Charted Next, Recently Landed since 0.7.0); the
  pane ids are older than the titles (`needs`, `inflight`, `mine`,
  `toreview`, `charted`, `landed`; `findings` is gone and
  `lib/viewstate.mjs` drops its entries on read); the 1-6 keys follow the
  order by position, the height priorities name panes by id, and view state
  is keyed by pane id, so a reorder moves the mouse and line-number checks
  and nothing else. The placement checks live in the `captain's call`,
  `underway`, `charted next` and `recently landed` sections of the suite
  over `relayed-hold.json` (one row for a hold the parent channel relayed)
  and `charted.json` (every Charted Next row type and the warning rule).
  The refresh is two cycles in `lib/app.mjs` (its header): the local cycle
  (`refresh`: the snapshot and the ledgers, drawn when they land; the next
  one armed on landing for the last start plus `--refresh`, so a slow
  snapshot is followed at once and never doubled; a tick that lands
  mid-snapshot skipped) asks for one GitHub cycle (`fetchCycle`: the
  identity, then the gh calls, drawn when they return; one in flight at a
  time, a request meanwhile kept as one follow-up) and never awaits it, so
  a slow gh holds back nothing local. Both are tested by running the app
  with `--headless` against a stand-in whose snapshot sleeps and against
  one whose gh sleeps (`FAKE_GH_SLEEP` in `tests/fake-gh.sh`;
  `FAKE_GH_GRAPHQL_FAIL` fails the searches), stopping it with a signal
  and reading the fetch log's order, so `--headless` must never load
  `neo-blessed`; the pty section drives the same two cycles on a real
  terminal against a stand-in whose second snapshot adds a row. The
  launcher runs node as a child, so that signal goes to the child first
  (`pkill -P`) and then to the launcher; a signal to the launcher alone
  leaves the board running and appending to the fetch log for the rest of
  the suite. The title line's countdown, `refreshing...` and failure label
  and the PR panes' `(updating)` marker render from a fixture `refresh`
  block (`index.mjs` documents it: `refreshing` is the local cycle,
  `fetching` the GitHub one) because a one-shot render has no schedule; the
  panes' loading spinner comes from the same block (`refreshing: true` with
  no snapshot or `prs` block, `loading_frame` for the glyph), and it counts
  ticks, never the clock, so keep it that way or one-shot frames stop being
  deterministic. The Settings page
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
