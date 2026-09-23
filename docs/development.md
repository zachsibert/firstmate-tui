# Development

Running the board from a checkout, the two test suites and what they need, ShellCheck, and where the code notes and the design report live.

```sh
git clone https://github.com/zachsibert/firstmate-tui.git
cd firstmate-tui
(cd bin/firstmate-tui && npm ci)   # installs the one dependency, neo-blessed 0.2.0
bin/firstmate-tui.sh version       # from a checkout the command is bin/firstmate-tui.sh
```

The tests:

```sh
env -u FORCE_COLOR bash tests/fm-board.test.sh    # the board: renders fixtures and asserts on the frames
env -u FORCE_COLOR bash tests/install.test.sh     # the installer, the upgrade paths and the release workflow
```

The board suite renders fixtures under `tests/fixtures/` through `--render-once` and asserts on the printed frame; it needs Node, and its last section needs python3 and the installed `node_modules`, and is skipped with a note without them.
One check compares node's plain output, so `FORCE_COLOR` must be unset.
The narrow-layout checks match the box-drawing dashes in a section header, so the shell needs a UTF-8 locale (`LANG=en_US.UTF-8`); under a bare environment with no locale two of them fail on that alone.
The install suite builds the release tarball, installs it into a scratch prefix and walks the upgrade chains against a fake GitHub; it needs npm and a full clone, because it builds the 0.1.0 and 0.2.5 tarballs from their tags.
Neither suite touches GitHub, a real herdr server or a browser.
ShellCheck 0.11.0 must pass on every shell script: `npx --yes shellcheck@4.1.0 --norc bin/*.sh scripts/*.sh tests/*.sh`.
[`AGENTS.md`](../AGENTS.md) describes the layout of the code, the rules the board keeps and how each part is tested.
The design report that grounds the board is [`docs/scout-report-2026-09-16.md`](scout-report-2026-09-16.md).
