# fm-board scout: a live herdr-hosted TUI over the firstmate fleet

Scout task `fm-board-tui-scout`, 2026-09-16. Read-only investigation; no code changed anywhere.
Every claim is tagged OBSERVED (command run or file:line) or INFERRED.
Firstmate repo at commit af1f2ea3 (this worktree); the live home `/Users/zachsibert/matthews/firstmate` is at b84e0e36. Herdr 0.8.2 / protocol 20 installed. yimbot cloned at 9d0e56a.

## 0. Bottom line

- Firstmate already owns every fact the board needs except three: herdr agent state per task, a "how old" number for events and reports, and PR detail (draft, labels, age). The first two are cheap board-side joins; the third is a small change to the `--include-prs` query.
- Herdr is a better host than tmux for this: it has a documented plugin system that opens a long-lived pane in the captain's workspace without splitting anything, a newline-JSON socket with `events.subscribe` so the board can react to agent state changes instead of polling, `agent focus` for jump-to-worker, and `notification show` for toasts. All verified live on 0.8.2.
- yimbot's board code is a good pattern library (layout, pane focus, column alignment, key gating) but its data model, actions, and jump mechanism are tmux and Linear specific. It ships no license, so copying code needs the author's permission; re-implementing the patterns is fine.
- Recommended stack: Node (already a required firstmate tool) plus neo-blessed (MIT), as an ESM `.mjs` module launched by a bash wrapper `bin/fm-board.sh`, packaged as a herdr plugin. Not Go (new toolchain), not bash/gum (wrong tool for a persistent multi-pane dashboard).
- Effort: about 9 to 12 worker-days across four milestones. Main risks: snapshot cost (5 s per refresh here), herdr version drift (CI pins 0.7.4, installed 0.8.2, docs describe 0.9.0), and the unlicensed yimbot source.

## 1. Summary table: panes x data sources x gaps

| Pane | Fields available today | Source | Gap | Where the gap closes |
| --- | --- | --- | --- | --- |
| Needs you | Live captain holds: `backlog.records[]` with `hold_kind=captain`, `hold_bucket=live`, `captain_actionable=true`, plus `title, repo, hold_reason, hold_until, hold_age_days, since`. Keyed worker decisions: `tasks[].hints.open_decisions[{key,verb,summary}]`, `hints.blocked_event`. Secondmate calls: `secondmate_current.records[].decisions_open[{id,key,verb,summary,reason,hold_bucket,hold_age_days}]`. Green-unmerged PR: `tasks[]` where `current_state.state=done` and `pr.url` set and backlog row not Done. | `fm-fleet-snapshot.sh --json` | PR age; green proof is only the worker's own done line, no check state; no event age. | Age: board-side (mtime of `paths.status_log.path`, or gh). Checks: join with `--include-prs` output. |
| Ready for review | `candidate_prs[{num,repo,task,url,review,mergeable,checks}]` | `fm-bearings-snapshot.sh --json --include-prs` (live gh) | No `isDraft`, `labels`, `createdAt`, author; `title` fetched but dropped; bounded to 10 repos x 20 PRs; repos discovered only from task `pr=` URLs and live worktree origins; secondmate-home PRs not enumerated; costs ~8 s. | Snapshot change: add fields to the gh `--json` list and jq projection (bin/fm-bearings-snapshot.sh:295-311). Cross-home: add recorded PRs to the home-summary ledger (snapshot change). |
| In flight | `tasks[]{id,kind,project,current_state{state,source,detail,observed_at},endpoint.target,hints.last_event_text,paths.status_log.last_event}`; secondmate `active_children[{id,kind,state,repo,name,source,doing}]` and `endpoints[{id,state,source,endpoint.target}]` | fleet snapshot + `home-summary.json` | Herdr `agent_status` absent (`endpoint.status` is always `unknown`, `agent_alive` `not_checked` for ordinary tasks). No event age (status log lines carry no timestamp). | Board-side join: `herdr agent list` keyed by pane id (4 ms). Age: board-side `stat` of the status file. |
| Findings | `scout_reports[{id,path,kind}]`; Done rows with `report_path` and `completion{verb,date}`; `hints.scout_report_present` | fleet snapshot | No report timestamp; no watermark. | Board-side: file mtime plus a board-owned `state/.board-seen` watermark. Optional snapshot change to add `mtime`. |
| Landed | `backlog.records[state=done]{id,title,pr_url,report_path,completion{verb,date}}`; `secondmate_landed.records[]` with `home,home_id` | fleet snapshot | Day granularity only; bounded by Done retention. | None needed. |

## 2. DATA

### 2.1 What the canonical snapshot exposes

OBSERVED `bin/fm-fleet-snapshot.sh --help` and bin/fm-fleet-snapshot.sh:284-286: the canonical script accepts only `--json`, `--secondmate-home-summary`, and `--contribution-input`. There is no `--include-prs` or `--all-*` on it.
OBSERVED bin/fm-bearings-snapshot.sh:79-90 and :186-200: the reveal flags (`--include-prs`, `--all-decisions`, `--all-in-flight`, `--all-landed`, `--all-reports`, `--all-queued`, `--all-recorded-prs`, `--all-unhealthy`, `--all-pr-repos`, `--fields bodies,paths,actions,endpoints`) live on the bearings projection, which shells out to the canonical snapshot and drops fields (header lines 4-11).

OBSERVED (`FM_HOME=/Users/zachsibert/matthews/firstmate bin/fm-fleet-snapshot.sh --json | jq`): top-level keys `backlog, contributions, fm_home, generated, main_inventory, roots, schema, scout_reports, secondmate_current, secondmate_guidance, secondmate_landed, tasks`; schema `fm-fleet-snapshot.v1`; this home had 3 task records, 36 backlog rows (2 in flight, 24 queued, 10 done), 2 secondmate homes, 18 scout reports; output 220 KB.

OBSERVED `tasks[]` record keys: `actions, backend, backlog, current_state, endpoint, harness, hints, id, kind, mode, paths, pr, project, remote, secondmate_projects, spawn_gen, yolo`.
- `current_state = {state, source, detail, raw, observed_at, freshness}` parsed from `bin/fm-crew-state.sh` (bin/fm-fleet-snapshot.sh:57-59). Example: `{"state":"working","source":"pane","detail":"harness busy (claude-hook)"}`.
- `endpoint = {target, exists, agent_alive, status, observed_at, freshness}`. Example target `default:w2Y:p2`. For ordinary tasks `agent_alive` is `not_checked` and `status` is `unknown` by contract (bin/fm-fleet-snapshot.sh:66-67).
- `hints = {pending_decision, blocked_event, open_decisions[{key,verb,summary}], scout_report_present, last_event_text}`; `open_decisions` is the authoritative keyed fold from fm-classify-lib (bin/fm-fleet-snapshot.sh:62-65).
- `pr = {url, source, head}` where `source` is `absent`, `status_event`, or meta (recorded by `bin/fm-pr-check.sh`, which stores `pr=` and `pr_head=`; header lines 1-8).
- `paths.status_log = {path, present, kind:"event_history", last_event{state,note,raw}}`; the header calls this history, never current state (bin/fm-fleet-snapshot.sh:60-61).
- `actions = {steer, watch, return_channel_note}` command strings.

OBSERVED `backlog.records[]` key union: `blocked_by, blocked_by_ids, blocked_reason, body_excerpt, body_lines, captain_actionable, checked, completion{verb,date}, current_role, done, hold_age_days, hold_bucket, hold_kind, hold_reason, hold_set, hold_until, id, kind, links, local_note, merged, order, pr_url, priority, raw, repo, report_path, reported, requires_child_metadata, since, state, structured, title, unresolved_blocker_ids`. `hold_bucket` is total and exclusive (`blocked|dated|aged|live|null`) and `captain_actionable == (hold_bucket == "live")` (bin/fm-fleet-snapshot.sh:29-41).

OBSERVED `secondmate_current.records[]` keys: `active_children, contradiction, contributions, counts, current, decisions_open, endpoints, freshness, holds, home, host, id, invalidity, landed, omitted, parent_event, provenance, queued, reconcile_inventory, registered, remote, spawn_gen, terminal_evidence`.
- `provenance = {selected, structured_home, summary_source: local-ledger|remote-ledger|remote-ledger-cache, summary_valid, trust, parent_event_role}`; `freshness = {status, observed_at, age_seconds}` (example `age_seconds: 129`).
- `active_children[]` shape is `{id, kind, state, repo, name, source, doing}` (bin/fm-fleet-snapshot.sh:1038-1045). Only children whose `current_state.state == "working"` qualify, so a secondmate child that is `done` or `failed` appears only under `endpoints[]` and `invalidity`.
- `endpoints[] = {id, state, source, endpoint{target,exists,agent_alive,status,...}}`; observed 6 entries for the hyperion home including herdr targets like `default:w2M:p2` and one tmux target `0:fm-hyperion-nonprod-prod-readiness-plan`.
- `queued[]` is bounded (observed `omitted: [{surface:"queued",count:4}]`).

OBSERVED `scout_reports[]` is `{id, path}` from `find "$DATA" -mindepth 2 -maxdepth 2 -name report.md` plus a derived `kind` (bin/fm-fleet-snapshot.sh:1950-1957, :2056). No timestamp. Report mtimes on disk range from 2026-07-28 to 2026-09-08 (`stat -f '%Sm' data/*/report.md`), so a mtime-based watermark is viable board-side.

OBSERVED `secondmate_landed.records[] = {id, title, pr_url, report_path, local_note, completion{verb,date}, home, home_id}`.

### 2.2 The secondmate ledger (`state/home-summary.json`)

OBSERVED (`jq keys` on `/Users/zachsibert/.treehouse/firstmate-8bf1b0/1/firstmate/state/home-summary.json` and `.../2/firstmate/state/home-summary.json`): `active_children, counts, decisions_open, endpoints, generated, generated_epoch, hold_classifier_schema, holds, home, invalidity, landed, omitted, queued, reason, schema, state, valid`. Schema `fm-secondmate-home-summary.v1`, hold classifier `fm-captain-hold-buckets.v1`. `state` takes values like `unknown`, `no_active_work`, `active_child_work` (bin/fm-fleet-snapshot.sh:1082-1085).
- `decisions_open[]` keys: `hold_age_days, hold_bucket, hold_until, id, key, reason, source, summary, verb`.
- `queued[]` keys: `id, title, blocked_by, blocked_by_ids, unresolved_blocker_ids, blocked_reason, hold_reason, hold_kind, hold_until, hold_bucket, hold_age_days, captain_actionable, repo, kind`.
- `landed[]` keys: `id, title, pr_url, report_path, local_note, completion`.
- No PR list, no per-child pane freshness beyond `endpoints[].endpoint.observed_at`, no report paths for children.

OBSERVED cadence: the watcher republishes the ledger when it is older than `FM_HOME_SUMMARY_INTERVAL` (default 300 s; bin/fm-watch.sh:225, :2063) and `bin/fm-home-summary-refresh.sh` writes it atomically by rename, also called at session start, spawn, and teardown (its header). The parent snapshot reads the ledger live for local homes and uses a cached copy for remote homes under `FM_SNAPSHOT_BUDGET` (default 5 s) (`--help`).

### 2.3 PR data

OBSERVED: the canonical snapshot performs no GitHub call; it only surfaces recorded `pr=` URLs (bin/fm-bearings-snapshot.sh:14-20). The merge poll (`bin/fm-pr-poll.sh` header) emits only a merged line and is silent otherwise, so no local record says "green and unmerged"; that signal exists only as the worker's `done: PR <url> checks green` status line, which `fm-crew-state.sh` maps to `done`.
OBSERVED `--include-prs` (bin/fm-bearings-snapshot.sh:270-311): candidate repos come from `tasks[].pr.url` plus `git remote get-url origin` of each live non-secondmate worktree; per repo it runs `gh pr list --repo <slug> --state open --limit 21 --json number,title,url,headRefName,reviewDecision,mergeable,statusCheckRollup` and projects `{num, repo, task, url, review, mergeable, checks:"none|failing|pending|passing"}`. `task` is derived from a `fm/` branch prefix. Live run here: `"checked (3 repos; 22 shown, at least 23 open; capped in 1 repo(s))"`, sample row `{"num":"306","repo":"MatthewsREIS/hyperion-ai","url":"https://github.com/MatthewsREIS/hyperion-ai/pull/306","review":"REVIEW_REQUIRED","mergeable":"MERGEABLE","checks":"passing"}`.
Gaps for a Ready-for-review pane: `isDraft`, `labels`, `createdAt`/`updatedAt`, `author`, and `title` (fetched, then dropped). Each is a one-line addition to the gh field list and jq projection: a snapshot change, not a board join. Cross-home PR enumeration is also a snapshot change (add recorded PRs to the home-summary ledger).

### 2.4 Which gaps are snapshot changes versus board-side joins

Board-side joins (no firstmate change):
- Herdr agent state per in-flight task: split `endpoint.target` on the first colon (docs/herdr-backend.md:214) and look the pane id up in `herdr agent list` (OBSERVED 4.2 ms).
- Event age: `stat` mtime of `paths.status_log.path` for main-home tasks; for local secondmate children, `<home>/state/<id>.status` where `home` comes from `secondmate_current.records[].home`.
- Findings watermark: report mtime versus a board-owned seen file.
- Green-unmerged PR: derive from `current_state.state == done` plus `pr.url` plus backlog row not Done.

Snapshot changes (small PRs to this repo):
- PR detail fields in `--include-prs` (draft, labels, created/updated, author, title).
- Report `mtime` on `scout_reports[]`.
- Recorded PRs in the home-summary ledger for cross-home review lists.
- Optionally a `last_event_epoch` on `paths.status_log` derived from file mtime so remote homes get an age too.

### 2.5 Cost measurements (this home, 2026-09-16)

OBSERVED with `/usr/bin/time -p` and `FM_HOME=/Users/zachsibert/matthews/firstmate`:

| Command | real | user | sys |
| --- | --- | --- | --- |
| `bin/fm-fleet-snapshot.sh --json` (3 runs) | 5.32 / 4.68 / 5.13 s | ~1.3 s | ~2.4 s |
| `bin/fm-bearings-snapshot.sh --json` with every `--all-*` and `--fields` | 6.00 s | 1.45 s | 2.88 s |
| `bin/fm-bearings-snapshot.sh --json --include-prs --all-pr-repos` | 8.38 s | 1.56 s | 2.85 s |
| `bin/fm-fleet-snapshot.sh --secondmate-home-summary` (local only) | 3.81 s | 1.00 s | 1.91 s |
| `bin/fm-fleet-snapshot.sh --contribution-input` | 0.19 s | | |
| `bin/fm-crew-state.sh fm-board-tui-scout` | 0.08 s | | |
| `bin/fm-crew-state.sh hyperion` | 0.54 s | | |
| `herdr agent list` / `herdr api snapshot` / `herdr pane list` | 4.2 / 4.6 / 4.1 ms | | |

INFERRED: sys time dominates, consistent with many `jq` subprocess forks per record; the cost scales with backlog rows plus tasks, not with wall-clock. At a 10-15 s cadence a 5 s snapshot is a 33-50% duty cycle and each run also rewrites the parent-side remote-summary cache (its only mutation, bin/fm-fleet-snapshot.sh:6-9). Section 6 recommends 30 s plus event-triggered refreshes.

## 3. HERDR

All observed against herdr 0.8.2, protocol 20, server running at `/Users/zachsibert/.config/herdr/herdr.sock` (`herdr status`). This scout runs inside herdr: `HERDR_ENV=1`, `HERDR_PANE_ID=w2Y:p2`, `HERDR_TAB_ID=w2Y:t2`, `HERDR_WORKSPACE_ID=w2Y`, `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH` are injected (`env | grep HERDR_`).

### 3.1 `herdr agent list` / `get`

OBSERVED live `herdr agent list` returns `{"result":{"type":"agent_list","agents":[...]}}`; each agent carries `agent, agent_session{agent,kind,source,value}, agent_status, cwd, focused, foreground_cwd, pane_id, revision, state_change_seq, tab_id, terminal_id, terminal_title, terminal_title_stripped, workspace_id`. Example: the primary firstmate is `pane_id w1M:p1`, `agent_status idle`, title `✳ First mate`; this scout is `w2Y:p2`, `working`, title `◐ Firstmate board TUI with herdr integration`.
OBSERVED schema (`herdr api schema --json`, `success_response.$defs.AgentInfo`) adds optional `name, display_agent, title, tokens, state_labels, interactive_ready, launch_pending, screen_detection_skipped`.
OBSERVED `AgentStatus` enum: `idle, working, blocked, done, unknown`. Semantics from `herdr --skill`: `done` is idle after unseen background work; focusing the tab or an `agent focus` marks it seen, CLI reads do not; `blocked` means an approval or question UI was recognized.
OBSERVED `herdr agent get <pane_id>` returns the same record as `agent_info`.
Relevance: `agent_status` is exactly the per-worker state the In-flight pane wants beside firstmate's `current_state`, and `blocked` is a strong Needs-you signal that firstmate already consumes through its push path (docs/herdr-backend.md:304-313).

### 3.2 Focus, panes, notification

OBSERVED `herdr agent focus <target>` where target is a unique agent name or a pane id currently hosting an agent (`herdr agent` group listing). Firstmate records `herdr_pane_id` in every herdr task's meta (docs/herdr-backend.md:205-212), so jump-to-worker is `herdr agent focus <pane>` with no lookup. Raw methods `tab.focus` and `workspace.focus` also exist for non-agent panes (`herdr api schema` request list).
OBSERVED `herdr pane` commands: `list, current, get, layout, process-info, neighbor, edges, focus --direction, resize, zoom, rename, read, input, split, swap, move, close, send-text, send-keys, wait-output, report-agent, report-agent-session, release-agent, report-metadata, run`. `pane focus` is direction-only; use `agent focus` or `plugin pane focus` for a specific pane.
OBSERVED `herdr notification show <title> [--body TEXT] [--position ...] [--sound none|done|request]`; title trimmed to 80 chars, body to 240; delivery follows `ui.toast.delivery` (`off|herdr|terminal|system`) (socket-api.mdx:371, `herdr --default-config` `[ui.toast]`).
OBSERVED `pane report-metadata` lets a source attach `--title`, `--state-label STATUS=TEXT`, and `--token NAME=VALUE` (with TTL) to a pane; tokens render as `$name` in configurable sidebar rows `[ui.sidebar.agents] rows = [...]` (default config lines 258-269).

### 3.3 Socket API and event stream

OBSERVED `herdr api schema --json`: protocol 20, 91 request methods including `events.subscribe`, `events.wait`, `session.snapshot`, `agent.list/get/focus/wait`, `notification.show`, `agent.view.set/clear`, `plugin.*`, `pane.report_metadata`. Event types: 26 lifecycle events (`workspace_*`, `worktree_*`, `tab_*`, `pane_created/closed/updated/focused/moved/output_changed/exited/agent_detected/agent_status_changed`, `layout_updated`).
OBSERVED transport (socket-api.mdx:652-668): newline-delimited JSON over the Unix socket; a subscription keeps the connection open; lifecycle subscriptions do not replay history, so subscribe first, then `session.snapshot` (socket-api.mdx:117-127, :813-814).
OBSERVED live test (python, 6 s): sending `{"id":"sub1","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.agent_status_changed","pane_id":"w2Y:p2"},{"type":"pane.updated"},{"type":"workspace.updated"}]}}` returned `{"id":"sub1","result":{"type":"subscription_started"}}` and then three `pane.updated` events within the window, each carrying a full pane record (`agent_status`, `cwd`, `foreground_cwd`, `pane_id`, `terminal_title`, ...).
OBSERVED firstmate already has this exact client: `bin/backends/herdr-eventwait.py` subscribes to `pane.agent_status_changed` and documents the wire format in its docstring; the watcher uses it as a latency shortcut with polling as permanent fallback (docs/herdr-backend.md:306-313).
OBSERVED `herdr api snapshot` prints `session.snapshot`: `agents, panes, workspaces, tabs, layouts, focused_*` (4 agents, 11 panes, 11 workspaces here).
Consequence: a board can bootstrap from `herdr api snapshot`, subscribe to `pane.agent_status_changed` for the panes it knows plus `pane.updated`, and redraw on push; it never needs to poll herdr.

### 3.4 Agent view (a zero-TUI alternative worth knowing)

OBSERVED `agent.view.set` (socket-api.mdx:418-490): a declarative filter (`all/any/not/eq/in/exists` over `status, workspace_id, tab_id, pane_id, agent, seen, state_change_seq` or `{token:name}`) and sort (`attention, state_change_seq, ...`) applied to herdr's built-in Agents sidebar. Combined with `pane report-metadata --token`, firstmate could label every worker pane with task id, PR state, and decision flag and let herdr's own sidebar sort blocked and done workers to the top. INFERRED: this covers the In-flight pane only; captain holds, PR lists, findings, and landed work have no pane and cannot be rendered there.

### 3.5 Hosting a long-lived pane without splitting the captain pane

OBSERVED plugin system (`herdr plugin` group; plugins.mdx): a directory with `herdr-plugin.toml` declaring `[[panes]]` (placement `overlay|popup|split|tab|zoomed`, `width`, `height`, `command` argv), `[[actions]]`, `[[events]]` (`on = "<event name>"`), `[[startup]]`, `[[link_handlers]]`. `herdr plugin link <path>` registers a local plugin; `herdr plugin pane open --plugin ID --entrypoint ID [--placement ...] [--workspace ID] [--target-pane PANE] [--direction right|down] [--cwd] [--env K=V] [--focus|--no-focus]`; `herdr plugin pane focus|close <pane_id>`. Runtime env includes `HERDR_SOCKET_PATH, HERDR_BIN_PATH, HERDR_ENV=1, HERDR_PLUGIN_ID, HERDR_PLUGIN_ROOT, HERDR_PLUGIN_CONFIG_DIR, HERDR_PLUGIN_STATE_DIR, HERDR_PLUGIN_CONTEXT_JSON`. No plugin SDK; the CLI is the plugin API. `herdr plugin list` here: "No plugins installed."
Three hosting shapes:
1. Plugin pane, `placement = "tab"` in the captain's own workspace: `herdr plugin pane open --plugin firstmate.board --entrypoint board --placement tab --workspace "$HERDR_WORKSPACE_ID" --no-focus`. Becomes a normal herdr pane with a pane id (plugins.mdx "Panes"); never touches the active tab.
2. Dedicated background workspace, no plugin needed: `herdr workspace create --cwd <home> --label <label> --no-focus` then `herdr pane run <root_pane> <cmd>`. OBSERVED this is precisely how firstmate already hosts the away-mode daemon (bin/fm-afk-launch.sh:470-520; docs/herdr-backend.md:326-327 "never splits the captain's active tab").
3. On-demand modal popup bound to a key: `[[keys.command]] key = "prefix+y" type = "popup" command = "..." width = "90%" height = "90%"` (configuration.mdx:186-221; default config lines 128-135). A popup is session-modal, has no pane id, and closes when the command exits.
Recommendation: shape 1 for the always-on board (herdr present, plugin API present), shape 2 as the fallback when the plugin API is missing, shape 3 as the "peek" binding.

### 3.6 Mapping yimbot's tmux `prefix+Y` onto herdr

OBSERVED yimbot: `tmux bind-key -T prefix Y switch-client -t <board pane>` at start, `unbind-key` at quit (src/watcher.ts:1189-1191, :1206-1220; README.md:367-383).
OBSERVED herdr has no runtime keybinding API ("Runtime action registration ... not part of plugin v1", plugins.mdx); bindings live in `~/.config/herdr/config.toml` and take effect on `herdr server reload-config`. Options:
- `[[keys.command]] key = "prefix+y" type = "plugin_action" command = "firstmate.board.focus"` where the action's command runs `herdr plugin pane focus <recorded pane id>` (plugins.mdx "Keybindings"). One-time captain config; the board records its pane id under `state/.board-pane` so the action can read it.
- Or `type = "popup"` opening a transient board (section 3.5 shape 3), which is closer to "glance and return" since Esc returns focus.
- Built-ins already useful without any board: `open_notification_target = "prefix+o"` jumps to the agent that raised the latest notification; `focus_agent = "prefix+alt+1..9"`; `next_agent`/`previous_agent` (default config lines 72-90).

### 3.7 Version drift

OBSERVED: installed 0.8.2 / protocol 20; `https://herdr.dev/llms.txt` says current stable is 0.9.0 and its docs are for v0.9.0; CI pins exact 0.7.4 with protocol floor 16 (.github/workflows/ci.yml, "Assert Herdr pin and protocol floor"); firstmate's documented floor is protocol 14 with 0.8.0 for presentation spaces (docs/herdr-backend.md:4-5). INFERRED: the plugin API exists at 0.7.3 or later (plugins.mdx mentions plugins installed on 0.7.3 needing re-registration), so it should be present at the CI pin, but `agent.view.*` and the exact `plugin.pane.open` parameters are unverified below 0.8.2. The board must read `herdr api schema --json` (or `herdr status --json`) at start and feature-gate.

## 4. YIMBOT REUSE

OBSERVED stack (package.json): `neo-blessed ^0.2.0`, `node-pty ^1.1.0`, `@xterm/headless ^6.0.0`, `@clack/prompts`, `cli-highlight`, `tsx`, TypeScript 5, tests with `node --test`. npm metadata (`npm view`): neo-blessed 0.2.0 MIT, last modified 2022-05-10 (a fork of blessed 0.1.81, itself last modified 2024-10-22); node-pty 1.1.0 MIT; @xterm/headless 6.0.0 MIT.
OBSERVED license: no `LICENSE*` file and no `license` field in package.json. INFERRED consequence: default copyright, so copying source needs the author's permission; re-implementing the same patterns from scratch does not.

Reusable as patterns (all pure functions, covered by 79 tests in src/tui.test.ts):
- Layout: three equal-height stacked panes with a 4-row floor and an optional left column that hides below 80 columns (src/tui.ts:119-150).
- Pane membership decided by an upstream label, not by status (src/tui.ts:82-97). For firstmate the label is `hold_bucket` / `current_state` / backlog state, already computed.
- Focus model: skip empty panes, sync with mouse focus, restore focus after an overlay (src/tui.ts:180-236).
- Shared column grid across panes via `alignTables` using blessed's own width measurement (src/tui.ts:430-456).
- Row rendering: one header, time, duration, status, id, PR, repo, title, flag, reason (src/tui.ts:387-428). `fmtDuration` (377-385).
- Key handling gated on "an overlay is open" (src/tui.ts:458-547) and a `?` help overlay (52-80, 755-780).
- Transient status-bar notice with TTL and red service warnings for unreachable dependencies (src/tui.ts:320-349, src/reach.ts).
- Wall-clock repaint timer to catch up after sleep, plus event-driven repaint (src/tui.ts:16-24, :731-736).
- TERM fix for multiplexers (src/tui.ts:30-41).

Coupled to yimbot's daemon or tmux (not reusable):
- Data: `events.jsonl` reducer, `BoardRow`, `section_*` events, `bus` (src/events.ts:190-202, :335-352, :435-449).
- Heavy-queue pane (src/heavy-queue.ts), AI review ordering via `claude -p` (src/review-order.ts), supervised/autonomous `Mode`, refine chip.
- Actions: `r` adds a GitHub label and queues a merge, `f` flags, `m` toggles autopilot mode (src/tui.ts:351-369, :815-828). Firstmate must not merge or dispatch from a board (section 5).
- Jump: `tmux switch-client -t =<session>` and `TMUX_PANE` (src/watcher.ts:1173-1220).
- `src/tui-review.ts` (849 lines): PR diff review overlay embedding a live claude via node-pty and @xterm/headless; `ReviewDeps` needs gh diff, grouping model, session switching (src/tui-review.ts:247-290).
- `src/tui-settings.ts` (467 lines): Linear settings editor (`SettingsDeps` at :58-65).
INFERRED: node-pty and @xterm/headless are only needed for the embedded-terminal review overlay; a firstmate board that jumps to the real worker pane via herdr needs neither.

## 5. ACTIONS

The board needs exactly two writes and one launch, each already owned:

1. Answer a decision.
   - Keyed worker decision (`needs-decision:` or `blocked:` in the status log, surfaced as `hints.open_decisions[].key`): `FM_HOME=<home> bin/fm-send.sh <task-id> --resolve-key <key> '<captain words>'`. OBSERVED bin/fm-send.sh:154-175: fm-send itself appends the closing `resolved [key=...]` line at enqueue time for every target kind, refuses when it cannot produce an acceptable close, and fails loudly if the key is still open afterwards. `FM_HOME` must be explicit (AGENTS.md section 2).
   - Captain-held backlog task (`hold_kind=captain`): `bin/fm-captain-hold.sh answers --source <provenance>` with `<task-id>\t<answer>\t<label>[\t<mode>]` on stdin, or `answer <task-id> --decision-file <path> [--release]`. OBSERVED `bin/fm-captain-hold.sh --help`: this is the one keyed-answer intake every channel feeds; the value `reconcile` is reserved and closes nothing; a captured source can be pre-bound with `bind <source-id>`.
   - Precedent: the Lavish `/bearings` board already does exactly this through a bound procevent source that feeds `answers` (.agents/skills/bearings/SKILL.md:122-127; bin/fm-bearings-board.sh header). A free-text captain note that is not a decision goes through `bin/fm-inbox.sh note`, which appends one `check` wake (header).
   - Firstmate learns about a board-written answer without any board-to-firstmate channel: the status-file append is a wake event, and the next drain prints the resolution under `UNREAD STATUS` (AGENTS.md section 3 step 3).
2. Jump to a worker: `herdr agent focus <pane id>` (section 3.2). Not possible for a remote secondmate's children (their panes live on another host; `fm-peek.sh` header) or for tmux-backed tasks when the board runs in herdr.
3. Open a PR URL: `open <url>` on macOS or `gh pr view --web`; the URL is copied verbatim from `tasks[].pr.url`, `backlog.pr_url`, or `candidate_prs[].url` (AGENTS.md section 9 forbids assembling URLs from memory).

No authority of its own: the board never calls `bin/fm-pr-merge.sh`, `bin/fm-merge-local.sh`, `bin/fm-spawn.sh`, `bin/fm-teardown.sh`, `bin/fm-control.sh`, or any `no-mistakes` command, and never takes the session lock (the snapshot does not need it, bin/fm-fleet-snapshot.sh:6-7). It writes only through the two intake owners above plus its own `state/.board-*` files.
How the hard rules apply: rule 1 (never write to a project) holds because the board reads `data/`, `state/`, and herdr only. Rule 2 (never merge) holds because merge stays with firstmate, unlike yimbot's `r`. Rule 3 (never tear down) is untouched. Rule 4 (crewmates never address the captain) is preserved in spirit: the board is the captain's own tool, and its answers land as durable records that firstmate reconciles, matching AGENTS.md rule 4's "treat direct captain intervention ... as authoritative and reconcile it at the next supervision review". Rule 5 is why the board must show `freshness`, `observed_at`, `provenance.trust`, and `invalidity` rather than hiding them.

## 6. STACK AND SHAPE

### 6.1 Constraints from this repo

OBSERVED: `bin/` helper scripts are plain bash and `tests/` are plain bash (CONTRIBUTING.md:48-51); `bin/*.sh` and `bin/backends/*.sh` must pass the pinned shellcheck via `bin/fm-lint.sh` (.agents/skills/firstmate-coding-guidelines/SKILL.md:127-128); tests are `tests/<subject>.test.sh` run through `bin/fm-test-run.sh` and must exercise behavior through an executable interface (SKILL.md:130-131). No `package.json`, `go.mod`, or `tsconfig.json` at the root. The repo already ships non-bash executables: `bin/fm-extension.mjs` (Node ESM, node built-ins only), `bin/backends/herdr-eventwait.py`, `bin/fm-herdr-lab-viewer.py`, `bin/fm-voice-*.py`. Node is part of the essential universal toolchain every home must have (docs/configuration.md:464). CI has a required real-Herdr lane pinned to 0.7.4 (.github/workflows/ci.yml:229-300).

### 6.2 Options

| Option | For | Against |
| --- | --- | --- |
| TypeScript or JS + neo-blessed | Node already required; yimbot patterns transfer directly; listtable handles unicode widths, scrolling, mouse; 5-pane board in a few hundred lines | First npm dependency in the repo; neo-blessed unmaintained since 2022; TS needs a build or `tsx`; yimbot code itself cannot be copied without a license |
| Go + bubbletea | Single static binary; strong TUI ecosystem; easy CI | New toolchain for contributors and CI; cannot reuse yimbot; a compiled artifact must be built or downloaded per home |
| bash + gum (or raw ANSI) | Matches `bin/` conventions and lint; zero new runtime | gum is not in the toolchain either and is built for prompts, not a persistent multi-pane dashboard; a 5-pane in-place renderer with keyboard focus in bash means hand-rolled cursor math and a jq fork per repaint |

Recommendation: Node ESM (`.mjs`, following bin/fm-extension.mjs) with neo-blessed pinned in an isolated `bin/fm-board/package.json` plus lockfile, launched by a shellcheck-clean `bin/fm-board.sh`. Write the pure layout, partition, alignment, and key-gate functions fresh (they are small) and keep neo-blessed behind one thin adapter so it can be swapped if it rots. Skip node-pty and @xterm/headless entirely. INFERRED: plain `.mjs` with JSDoc avoids a build step while still running under the Node the home already has; TypeScript is fine if the team prefers it, at the cost of `tsx` or a build.

### 6.3 Where it lives and how it launches

- `bin/fm-board.sh` (bash, lint-covered): `open` verifies `HERDR_ENV=1` and the socket, runs `herdr plugin pane open ... --placement tab --workspace "$HERDR_WORKSPACE_ID" --no-focus` when the plugin is linked, else falls back to `workspace create --no-focus` + `pane run` (the fm-afk-launch pattern), records the pane id in `state/.board-pane`, and prints it; `focus` runs `herdr plugin pane focus` / `agent focus` on the recorded pane; `status` reports whether the board pane is alive; `render-once --cols N --rows N --snapshot <file>` prints one frame to stdout for tests.
- `bin/fm-board/` holds `index.mjs`, `package.json`, `package-lock.json`, and `herdr-plugin.toml` (`[[panes]] id="board" placement="tab" command=["bash","../fm-board.sh","run"]`, `[[actions]] id="focus" command=["bash","../fm-board.sh","focus"]`, `min_herdr_version` set to the lowest verified version). `herdr plugin link "$FM_ROOT/bin/fm-board"` is a one-time captain step that `/board` performs after consent.
- `.agents/skills/board/SKILL.md`, captain-invocable `/board`: loads, runs `bin/fm-board.sh open`, and tells the captain the pane exists plus the one-line `[[keys.command]]` snippet to bind `prefix+y`.
- The board process reads `FM_HOME` (explicit, never inferred) and runs the snapshot with `FM_HOME` set, exactly as this scout did.

### 6.4 Refresh cadence

- Fleet snapshot every 30 s (5 s wall here, about 17% duty), debounced to at most one in flight.
- Immediate re-render, and a snapshot refresh scheduled within 2 s, on any herdr `pane.agent_status_changed` push, on `fs.watch` of `state/*.status`, `state/.wake-queue`, `data/backlog.md`, and each local secondmate home's `state/home-summary.json`.
- PR enrichment (`--include-prs`, 8 s) every 120 s or on demand with a key, shown with its own age.
- Herdr overlay (`agent list`) is refreshed per event and costs nothing.
- Every pane header shows the age of its data source so a stale board is visibly stale.

### 6.5 Degradation

- Herdr absent (`HERDR_ENV` unset): the board runs in the current terminal; jump is `tmux select-window -t <meta window=>` when the task backend is tmux and disabled otherwise; no toasts; everything else works.
- Herdr present but plugin API missing (older server): fall back to the dedicated `--no-focus` workspace; `prefix+y` becomes a `type = "popup"` binding running `bin/fm-board.sh run --popup`.
- Snapshot failure or lock-free read errors: keep the last frame, mark it stale in red, and show the error text in the status line (yimbot's `reachWarnings` pattern).
- Read-only mode flag (`--read-only`) hides the answer keys entirely; useful when the captain wants a wall display.

## 7. PLAN

| Milestone | Scope | Effort |
| --- | --- | --- |
| M1 Read-only board | `bin/fm-board.sh`, `bin/fm-board/index.mjs`, five panes (Needs you, Ready for review, In flight, Findings, Landed) over `fm-fleet-snapshot.sh --json` and the local home-summary ledgers, herdr `agent list` overlay, socket subscription, resize, `j/k/tab/enter/?/q`, freshness headers, `/board` skill, plugin manifest and `workspace create` fallback, `render-once` test mode with fixture JSON and `tests/fm-board.test.sh` | 3 to 4 worker-days |
| M2 Actions | `a` answer: prompt, then route to `fm-captain-hold.sh answers` or `fm-send.sh --resolve-key` by record kind; `enter`/`g` jump via `herdr agent focus`; `o` open PR URL; `n` note via `fm-inbox.sh note`; confirmation and result notice; tests through a fake `herdr` and fake owners on `PATH` | 2 to 3 worker-days |
| M3 Polish | `herdr notification show` on new Needs-you rows with dedupe; findings watermark in `state/.board-seen`; filters by home and repo; PR enrichment toggle; optional `pane report-metadata` tokens so herdr's own sidebar shows task ids | 2 to 3 worker-days |
| M4 Upstream | Snapshot PRs: `isDraft`, `labels`, `createdAt`, `title` in `--include-prs`; report `mtime`; recorded PRs in the home-summary ledger. Docs classified in `docs/documentation-audiences.json`; CI lane running `tests/fm-board.test.sh` with Node; each through no-mistakes per AGENTS.md section 1 | 1 to 2 worker-days plus review cycles |

Total: about 9 to 12 worker-days. M1 alone delivers the captain's stated need (see all parallel work at a glance).

Risks:
- Snapshot cost. 5 s here with 3 tasks; each local task adds a bounded `fm-crew-state.sh` read (10 s cap, concurrency 8) and each remote home a ledger fetch under a shared 5 s budget (`--help`). A 10-15 s cadence would spend a third to half of wall time in the snapshot and rewrite the remote cache each time. Mitigation: 30 s plus event-triggered refresh, or a future `--board` projection that skips `contributions` and bounded terminal evidence.
- Remote homes. Only their cached ledger is readable, `freshness` says `cached`, and no jump or pane state is possible; the board must label those rows.
- Terminal size. Five bordered panes need roughly 20 rows minimum (header, two borders, one row each) plus title and footer; below 100 columns drop the REPO and AGE columns first; below 80 collapse to a single scrolling list with section headers.
- Herdr version drift. CI 0.7.4, installed 0.8.2, docs 0.9.0; feature-gate on the schema, keep `min_herdr_version` honest, and add the board to the real-Herdr CI lane so a pin bump is caught.
- Dependency health. neo-blessed last published 2022; keep it behind an adapter and pin it.
- License. yimbot has no license; treat it as a reference, not a source.

## 8. Commands run (reproducibility)

```
FM_HOME=/Users/zachsibert/matthews/firstmate bin/fm-fleet-snapshot.sh --help
FM_HOME=/Users/zachsibert/matthews/firstmate bin/fm-fleet-snapshot.sh --json            # x3, timed
FM_HOME=/Users/zachsibert/matthews/firstmate bin/fm-bearings-snapshot.sh --json --all-in-flight --all-decisions --all-secondmates --all-landed --all-reports --all-queued --all-recorded-prs --all-unhealthy --fields bodies,paths,actions,endpoints
FM_HOME=/Users/zachsibert/matthews/firstmate bin/fm-bearings-snapshot.sh --json --include-prs --all-pr-repos --all-recorded-prs
FM_HOME=/Users/zachsibert/matthews/firstmate bin/fm-fleet-snapshot.sh --secondmate-home-summary
FM_HOME=/Users/zachsibert/matthews/firstmate bin/fm-crew-state.sh fm-board-tui-scout ; ... hyperion
jq keys /Users/zachsibert/.treehouse/firstmate-8bf1b0/{1,2}/firstmate/state/home-summary.json
herdr --version ; herdr status ; herdr --skill ; herdr api schema --json ; herdr api snapshot
herdr agent ; herdr agent list ; herdr agent get w2Y:p2 ; herdr pane current --current
herdr pane ; herdr plugin ; herdr plugin pane ; herdr plugin list ; herdr notification ; herdr --default-config
python3 sub-test.py "$HERDR_SOCKET_PATH" "$HERDR_PANE_ID"   # events.subscribe wire test, 6 s
curl https://herdr.dev/llms.txt ; plugins.mdx ; socket-api.mdx ; configuration.mdx ; cli-reference.mdx (v0.9.0 docs)
git clone --depth 1 https://github.com/YiminArava4508/yimbot.git   # into the scratchpad
npm view neo-blessed|node-pty|@xterm/headless|blessed version license time.modified
```
