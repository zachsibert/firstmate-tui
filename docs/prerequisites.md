# Prerequisites

What firstmate-tui needs on the machine before it runs: the two firstmate words these docs use, then each requirement with a check and an install command.

Two words these docs use that are firstmate's own:

- A **firstmate home** is a checkout of the firstmate repository that firstmate runs from, with its `bin/` scripts and the `state/` and `data/` directories it fills.
  The board reads one main home, the one `FM_HOME` points at.
- firstmate can hand part of its work to a second copy of itself running from another home.
  firstmate calls that copy a secondmate; these docs call it a **delegate home**.
  The board finds delegate homes through the main home's `data/secondmates.md` and lists their work too.

## Required

The launcher checks the firstmate home, Node and herdr before it starts and stops with a message when one is missing.
Nothing checks bash or jq up front.

**bash 3.2 or newer.**
The `firstmate-tui` command and the installer are bash scripts.
macOS ships bash 3.2 and Linux ships 5.x, so there is nothing to install.
Check: `bash --version` prints the version on its first line.

**A firstmate home, in `FM_HOME`.**
The board runs that home's `bin/fm-fleet-snapshot.sh` for its data on every refresh.
The launcher stops unless `FM_HOME` names a directory holding an executable `bin/fm-fleet-snapshot.sh`; it never guesses the path from where you started it.
Check: `ls "$FM_HOME/bin/fm-fleet-snapshot.sh"` prints the path instead of an error.
Get one: `git clone https://github.com/kunchenguid/firstmate.git ~/firstmate` (any path works), then put `export FM_HOME=$HOME/firstmate` in your shell profile so it is set in every terminal.

**herdr 0.8.2 or newer.**
herdr hosts the board's pane and tells it which agent panes are alive.
The launcher checks that a `herdr` command is on `PATH`.
The 0.8.2 minimum is the one the board's plugin manifest declares, and herdr enforces it when you link the plugin.
`--no-herdr` runs the board without herdr; the title line then says so.
Check: `herdr --version` prints `herdr 0.8.2` or higher.
Install: macOS `brew install herdr`.
Linux, or macOS without Homebrew: `curl -fsSL https://herdr.dev/install.sh | sh`.
herdr's install page, https://herdr.dev/install, covers the other routes and `herdr update`.

**Node 20 or newer.**
Node runs the board.
The launcher reads Node's major version and stops below 20.
npm is needed only for the [development install](development.md), because a release tarball already carries the one dependency.
Check: `node --version` prints `v20` or higher.
Install: macOS `brew install node`.
Debian and Ubuntu: `sudo apt install nodejs` when the packaged version is 20 or newer (Ubuntu 24.04 packages Node 18, which is too old), otherwise the packages and version managers at https://nodejs.org/en/download.

**jq 1.5 or newer.**
jq is a command that reads JSON.
`firstmate-tui open --detached` and `firstmate-tui focus` read herdr's answers with it; the board itself does not use it.
Nothing checks for it up front, so those two commands fail without it.
Check: `jq --version` prints `jq-1.5` or higher.
Install: macOS `brew install jq`.
Debian and Ubuntu: `sudo apt install jq`.
Other systems: https://jqlang.github.io/jq/download/.

**For the installer: curl, tar, and sha256sum or shasum.**
The installer downloads the release with curl, unpacks it with tar and verifies the checksum with sha256sum or, when that is missing, shasum.
It checks for all three before it downloads anything and names the missing one.
All of them ship with macOS and with every common Linux.
Check: `curl --version`, `tar --version` and `shasum --version` (or `sha256sum --version`) each print a version.
Install, Debian and Ubuntu, when one is missing: `sudo apt install curl tar coreutils`.

## Optional

**gh, the GitHub CLI, logged in.**
gh gives the two pull request panes their data.
After every fleet snapshot the board runs `gh api graphql` itself, at most four searches plus one lookup, without holding the rest of the board for the answer, and once per session `gh api user` for your GitHub login unless the [config file](configuration.md) names it.
Without gh on `PATH`, My PRs falls back to a firstmate script that needs gh as well, so in practice that pane reports a failed fetch, and Teammates' PRs reads `gh not on PATH: Teammates' PRs needs the GitHub CLI`.
The config file's `prs.source` can pick that script on purpose ([Configuration](configuration.md)); it needs gh just the same, so neither choice removes this prerequisite.
`--no-prs` runs the board without any GitHub call; the two panes then list only the pull request links firstmate recorded.
Check: `gh auth status` prints `Logged in to github.com`.
Install: macOS `brew install gh`.
Debian and Ubuntu: `sudo apt install gh`, or the packages at https://github.com/cli/cli/blob/trunk/docs/install_linux.md.
Then run `gh auth login` once.

**glow.**
glow renders a Markdown report, or a hold card, in the terminal when you press `enter` on a Recently Landed row with a report or on a held task.
Without it the board uses `$EDITOR`, then `vim`, then `less`.
Check: `glow --version`.
Install: macOS `brew install glow`.
Linux: the packages listed at https://github.com/charmbracelet/glow.

**python3, for the test suite only.**
The last section of `tests/fm-board.test.sh` drives the real board on a pseudo-terminal through a Python script.
Without python3 that section is skipped with a note.
Check: `python3 --version`.
Install: macOS `brew install python@3`.
Debian and Ubuntu: `sudo apt install python3`.
