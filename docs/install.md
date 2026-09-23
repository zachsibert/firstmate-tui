# Install

Everything about installing firstmate-tui: what the installer writes and where, other locations and uninstalling, linking the herdr plugin, the first run, how the board finds your GitHub login, and running it inside herdr. The README's Install section has the short version.

One command installs the latest stable release:

```sh
curl -fsSL https://raw.githubusercontent.com/zachsibert/firstmate-tui/main/bin/install.sh | bash
```

It asks GitHub for the latest release, downloads the release tarball `firstmate-tui-<tag>.tar.gz` and its `.sha256` file, verifies the checksum, unpacks the tarball and writes the command.
A failed download or a checksum mismatch stops it before anything is replaced.
It writes three things and nothing else: no shell profile, no herdr config.

| What | Where |
| --- | --- |
| The files | `~/.local/share/fm-board`, or `$XDG_DATA_HOME/fm-board` when that variable is set. This is the prefix. The directory keeps the board's former name, so an upgrade moves nothing |
| The command | `~/.local/bin/firstmate-tui`, a one-line script that runs the launcher inside the prefix. `~/.local/bin/fm-board` is written beside it as an alias, the command's former name, and goes away in the next release |
| The install record | `<prefix>/install-record`, a key=value file naming the prefix, the bin dir, the repository, the installed version and the tarball layout. `firstmate-tui upgrade` reads it |

When the bin dir is not on your `PATH`, the installer ends with this line:

```
install: note: /Users/you/.local/bin is not on your PATH; add it, or run /Users/you/.local/bin/firstmate-tui by its full path
```

Add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile yourself; the installer never edits it.
For other locations add the flags after `bash -s --`, for example `bash -s -- --prefix /opt/firstmate-tui --bin-dir /usr/local/bin`.
`bin/install.sh --help` lists every flag, including `--from-file <tarball>` for a tarball you already have.
To uninstall, delete the prefix directory and the `firstmate-tui` and `fm-board` commands in the bin dir.

## Link the herdr plugin (once)

Linking registers the board's plugin manifest with herdr.
After that herdr's command palette has two entries, one that opens the board in a tab pane and one that focuses it, and `firstmate-tui open --detached` places the board in a tab pane of the current workspace instead of a hidden workspace.
Linking is optional: without it `firstmate-tui` still runs in whatever terminal you type it in.
It is also user-global, so it affects every herdr session on the machine.

```sh
herdr plugin link ~/.local/share/fm-board/bin/firstmate-tui
echo "$FM_HOME" > "$(herdr plugin config-dir firstmate.board)/fm-home"
```

The second line matters because a palette action carries no environment: the plugin reads `FM_HOME` from that `fm-home` file.
To bind a key to the focus action, add this to `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+y"
type = "plugin_action"
command = "firstmate.board.focus"
```

A plugin linked before 0.3.0 points at `.../bin/fm-board`, a directory the upgrade removed.
Run `herdr plugin unlink firstmate.board` once and link the new path as above; the plugin id stays, so the config directory and the `fm-home` file are kept.

## First run

```sh
export FM_HOME=/path/to/your/firstmate/home
firstmate-tui
```

The launcher checks the home, Node and herdr, then the board fills the terminal with six bordered panes.
Each pane's body starts with a spinner line naming what it waits on (the fleet snapshot, then for the two pull request panes your GitHub identity, then the GitHub checks or the GitHub review requests) until that data first lands, about five seconds for the snapshot and a few more for GitHub.
From the second launch on, the board draws what it showed last time at once, each pane title marked `(cached 12m ago)` until that pane's live data lands, and puts the cursor back on the row you were on; [state-cache.json](configuration.md#state-cachejson) explains both.
The first launch also writes the board's config file from the shipped example, so you have a real file to edit; [Configuration](configuration.md) says where it lives and what is in it.
Press `?` inside the board for the keys, `.` for the Settings page and `q` to quit.

Without `FM_HOME` the launcher stops and prints two commands to copy: the `export` for a terminal launch and the `mkdir` plus `echo` that write the plugin's `fm-home` file.
When a firstmate home sits above the current directory the `export` names it, but the board never adopts one on its own.

The two pull request panes are built around one GitHub login, yours.
The board takes it from the config file's `identity.github_login` when set, else from the account gh is logged in as (`gh api user`, once per session), else from git's `github.user` setting.
While the board asks them, on the first refresh and again on `r` while the login is unknown, both panes show the spinner line `resolving GitHub identity`.
When none of the three answers, both panes show one row, `identity unknown: see Settings (.)`, and fetch nothing; [Troubleshooting](troubleshooting.md) has the fix.

Inside herdr, `firstmate-tui` runs in the pane you type it in.
To put the board beside firstmate, split the pane first (herdr's defaults are `ctrl+b` then `v` for a pane to the right and `ctrl+b` then `-` for one below), run `firstmate-tui` in the new pane, and close that pane yourself when done.
`firstmate-tui open --detached` opens the board away from your terminal instead, in its own herdr pane, and `firstmate-tui focus` brings that pane forward later.
