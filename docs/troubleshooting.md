# Troubleshooting

Six things that go wrong, each with its symptom, cause, check and fix. The README lists the three most common in one line each.

**The title line reads `refresh failed ... ago, retrying in ...` in red and the pull request panes say `(stale)`.**
Symptom: the title line turns red with a line such as `refresh failed 40s ago, retrying in 20s`, both pull request panes carry `(stale)` in their titles and keep their old rows, a footer notice starting `PR fetch: My PRs:` names the error once, and a recorded pull request in My PRs reads `checks: fetch failed`.
Cause: the board's GitHub fetch failed, most often because the machine cannot reach or resolve `github.com` (a dropped network, a VPN that is not up, a DNS outage).
Confirm: run `gh api user` in a terminal.
It prints your GitHub account as JSON when GitHub is reachable, and a connection error when it is not.
Fix: restore the network.
The board retries on every tick and `r` retries at once; the red text clears on the first clean refresh.

**Both pull request panes show one row, `identity unknown: see Settings (.)`.**
Symptom: My PRs and Teammates' PRs each show that single row and fetch nothing, the footer shows once `GitHub identity unknown (<what was tried>); set identity.github_login in <config path> or run gh auth login`, and the Settings page's Identity line reads `identity unknown: set identity.github_login in <config path>, or run gh auth login`.
A spinner line reading `resolving GitHub identity` in both panes for a few seconds after a start is not this: it is the board asking the three sources, and the row appears only once all three have failed.
Cause: the board could not learn your GitHub login: the config file's `identity.github_login` is `null`, gh is not logged in (or not installed, or the board runs with `--no-prs`), and git has no `github.user` setting.
Fix: either write your login into the config file's `identity.github_login`, or run `gh auth login` once.
Then press `r`; while the identity is unknown a refresh asks again, so no restart is needed.
Check: the Settings page's Identity line reads your login followed by `(from config)` or `(from gh api user)`.

**My PRs reads `failing` for a pull request whose checks are green on GitHub, and the Settings page's PR source line starts with `firstmate`.**
Symptom: a pull request whose check was cancelled once and then re-run to success reads `failing` under CHECKS; its row has `-` under BASE and a `~` after its age, and the footer said once `PR data from fm-bearings-snapshot.sh (...)`.
Cause: the pull request data comes from firstmate's script, either because the config file's `prs.source` is `firstmate` or because gh is not on `PATH`, and that script reads any cancelled run as failing ([config.json](configuration.md#configjson) says why the board cannot regroup those rows).
Fix: set `prs.source` to `board` (or remove the key) and make sure gh is on `PATH`; then press `r`.
Check: the Settings page's PR source line reads `board: the board's own GitHub fetch`.

**The footer reads `state cache ignored: <path>: <reason>` once, and the panes start with spinners.**
Symptom: right after launch the footer names the state cache file with `bad JSON`, `not an object`, `unexpected schema` or `written for another home`, and the board starts as if it had no cache.
Cause: the file at that path is damaged, was written by another version of the board, or belongs to a board that runs against a different `FM_HOME`; the board never draws data it cannot trust.
Fix: nothing, unless the notice repeats on every launch: the next refresh that lands cleanly writes a fresh cache over the file, and `--no-cache` skips the read for good if you want a spinner start every time.

**`a`, `d` or `D` ends with a red line in the footer and the hold is still there.**
Symptom: after `enter` on the accept prompt, `y` on the discard prompt, or `enter` on the defer prompt, the footer shows a red line such as `fm-captain-hold: task <id> is not held for the captain; hold it first or name the right task`, and the row stays.
Cause: the board ran firstmate's `fm-captain-hold.sh` in the hold's home and the command refused; the line is the command's own words, and nothing was changed.
Check: run the same command in that home (`FM_HOME=<home> <home>/bin/fm-captain-hold.sh open <id>` shows what firstmate knows about the hold).
Fix: whatever the message asks for; a hold whose home is on another machine cannot be changed from here at all, and the board says so before it prompts.

**The title line reads `herdr disconnected (<reason>)` in red.**
Symptom: the title line carries that warning, and the HERDR column in Underway reads `unknown` in grey instead of a live pane state.
Cause: the board cannot hold its subscription to herdr's socket.
The reason in the parentheses says why: `--no-herdr` means you started it that way; `connecting` means it has not connected yet; a socket error such as `ECONNREFUSED` or `ENOENT` means herdr's server is not running or its socket has moved; `herdr status did not report a socket path` means the board found a `herdr` command but that command could not name a server.
Check: run `herdr status`.
It reports the running server, or fails when there is none.
Fix: start herdr, or run the board from inside a herdr pane, where the socket is known through the environment; the board reconnects on its own and the warning goes as soon as the subscription is back.
Outside herdr on purpose, start with `--no-herdr` and read the warning as a reminder rather than a fault.
