# Releasing

How a release happens: the workflow that publishes it, the one version source, betas and their cleanup, and the rule every pushed commit message must keep.

Releases are GitHub Releases, published by `.github/workflows/release.yml`; nobody tags by hand.
Every merge to `main` is a release.
The one version source is `version` in `bin/firstmate-tui/package.json`, and `scripts/next-version.sh` decides what the next release is called: package.json's version when the tag `v<version>` does not exist yet, else the next free patch number.
When the picked version differs from package.json, the workflow writes it into package.json and the lockfile, commits that bump to `main` as `github-actions[bot]` with the skip-ci marker in the message, and releases at that commit; otherwise it releases at the merge commit itself.
Every push to any other branch publishes a beta, a prerelease named `v<next>-<sha7>` and built with `scripts/package.sh --commit <sha>`, so a beta carries the version the next merge will release.
When a pull request closes, merged or not, the workflow deletes the betas of its commits; after each new beta it also prunes betas beyond the newest 30, oldest first.
Stable releases are never deleted.

Nothing needs a version bump to be released, so never open a pull request only to bump the version.
To move the minor or major number, change it in the pull request that earns it:

```sh
(cd bin/firstmate-tui && npm version 0.5.0 --no-git-tag-version)   # sets package.json and the lockfile
git commit -am "Rework the panes; firstmate-tui 0.5.0"
```

One rule for every commit you push: its message must never contain the literal skip-ci marker, the bracketed words the bot's bump commit uses, because GitHub then skips the pull request's own checks and its beta.
The workflow's bump commit is the only place that marker belongs; in prose, spell it out as "the skip-ci marker".
`scripts/package.sh` is the one place that builds the tarball, for the workflow and for the tests alike, and it refuses a release tag that is not `v` plus the source version.
`.github/workflows/test.yml` runs both test suites, ShellCheck and actionlint on every pull request and on every push to a branch other than `main`.
After editing a workflow, lint it with `actionlint` and run `tests/install.test.sh`, which pins the workflow lines the installer and these docs depend on.
