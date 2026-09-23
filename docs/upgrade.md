# Upgrade and betas

How `firstmate-tui upgrade` works, what a beta is and how to try one, the Settings page's upgrade path, and how an install older than 0.3.0 reaches the current release.

`firstmate-tui version` prints what is installed and where:

```
firstmate-tui 0.4.2 (stable release)
installed at /Users/you/.local/share/fm-board (from release v0.4.2); firstmate-tui upgrade replaces it
```

A stable release is numbered `X.Y.Z`.
A beta is that number plus the short hash of the commit it was built from, such as `0.4.2-d8b290e`; every push to a branch other than `main` publishes one as a GitHub prerelease, so a beta names one exact commit you can install.
On a beta the first line reads `firstmate-tui 0.4.2-d8b290e (beta: 0.4.2 at commit d8b290e)`.
Betas are deleted when their pull request closes, and at most 30 are kept at a time, so a beta is for trying a branch, not for staying on.

```sh
firstmate-tui upgrade                            # to the latest stable release
firstmate-tui upgrade --pre                      # to the newest release, betas included
firstmate-tui upgrade --version 0.4.2-d8b290e    # to one exact version, beta or release (v0.4.2 works too)
firstmate-tui upgrade --stable                   # from a beta back to the latest stable release
```

`firstmate-tui upgrade` runs the installer that shipped inside your install against the prefix and bin dir in the install record.
It downloads and verifies the new tarball, unpacks it beside the install and swaps the whole directory in, so a failed download or checksum leaves what you have.
Versions are never compared, so going back is the same step as going forward.
Your config file and view state live outside the prefix and come through unchanged.
The same three flags work on the install command after `bash -s --`, which is how to start on a beta with nothing installed yet.
From a git checkout, `firstmate-tui upgrade` refuses and prints the `git pull` that updates a checkout instead.

**From inside the board.**
Press `.` for the Settings page.
It shows the running version, where it is installed and from which release, the latest stable release with its date and a verdict (`upgrade available`, `up to date`, or that you are on a beta), the launch flags in effect, and the identity, config file and PR source the pull request panes use.
From an install it offers `Upgrade to <version>`, a **Betas** submenu listing the prereleases newest first with their commit and date, and `Back to stable`.
Choosing one shows the exact command it stands for and asks `y to confirm, esc to cancel`; only `y` runs it, through the same `firstmate-tui upgrade` as the command line, with the installer's lines appearing on the page.
On success the page reads `restart to use <version>` and `R` restarts the board on the new copy.
A failure leaves the installer's output on the page and the current install untouched.
`r` fetches the release list again; `.`, `esc` or `q` returns to the board.
Release data is fetched only when the page opens and on `r`, never on the refresh tick.

**Older installs.**
Since 0.3.0 the tarball is `firstmate-tui-<tag>.tar.gz`; up to 0.2.x it was `fm-board-<tag>.tar.gz` with `bin/fm-board.sh` and `bin/fm-board/` inside.
The current installer knows both names and both layouts, so `firstmate-tui upgrade --version 0.2.6` still goes back to a 0.2.x release.
An install at 0.2.5 or 0.2.6 should run the install command in [Install](install.md) once more, because the installers that shipped in those two versions stop on a missing asset instead of trying the other name; after that reinstall `firstmate-tui upgrade` works as usual.
An install older than 0.2.5 first runs its own `fm-board upgrade --version 0.2.5`, the last release under the old asset name, and then reinstalls the same way.
