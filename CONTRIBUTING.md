# Contributing

This repository treats ordinary PRs and releases differently.

Ordinary PRs change code, tests, or internal docs and do not create tags, GitHub Releases, or installer history entries. Releases are only for changes that are meant to be published to users, including public runtime scripts and any material change to install, update, recovery, or safety commands.

## What counts as a release

Use `scripts/release.sh` as the tag and GitHub Release gate. It will only create a release when all of these are true:

- the working tree is clean
- the branch is `public-clean`
- local `HEAD` matches `origin/main`
- the latest GitHub Actions `Verify scripts` run for that `HEAD` succeeded
- `CHANGELOG.md` has a section for the release version
- public metadata has no private device identifiers
- the tag and GitHub Release do not already exist

`scripts/verify-scripts.sh` is the release verification contract. It checks bash syntax, ShellCheck when installed, `--version` support on the installer and updater family, version consistency across `VERSION` and every public `SCRIPT_VERSION`, unsafe heredoc wrappers, and installer safety invariants.

Publishing commits and creating a release are separate steps. `scripts/publish-public.sh` pushes local `public-clean` to `origin/main`; after the resulting `Verify scripts` run succeeds, `scripts/release.sh` creates the version tag and GitHub Release.

If a change would make users fetch or reset `main` to get it, it is effectively publication. That includes merging public runtime scripts and materially changing published install, update, recovery, or shutdown commands. Prepare the release metadata before publishing those changes to `main`.

## What does not count as a release

These are ordinary PRs, not releases:

- tests only, including `tests/test-system-package-updater.sh`
- CI-only changes
- internal developer docs, including this file
- non-user-facing maintenance code that does not change published commands or shipped behavior

Issue #14 is the test-only example here. Its fix touches only `tests/test-system-package-updater.sh`, so it needs no version bump.

## Release decision table

| Change type | Release? | Bump | Notes |
| --- | --- | --- | --- |
| Test-only fix | No | None | Example: issue #14, tests only, no shipped behavior changes |
| CI-only change | No | None | Workflow, lint, or verification plumbing only |
| Internal docs, including CONTRIBUTING | No | None | Developer-facing only |
| Public README safety or command guidance | Usually yes | PATCH or MINOR | If it changes what users are told to run, treat it like published guidance |
| Public runtime script behavior | Yes | PATCH or MINOR while pre-1.0 | Comments and internal refactors alone do not trigger a release |
| Installer, updater, recovery, or shutdown command behavior | Yes | PATCH or MINOR while pre-1.0 | If users fetch `main` to get the fix, it is publication |
| Migration or installed-state change | Yes | PATCH or MINOR while pre-1.0 | Include linear updater history and any state recording needed on installed hosts |
| Release tooling changes, including `scripts/release.sh` or `scripts/verify-scripts.sh` | No | None | Usually ordinary PR work unless the tooling change itself alters published behavior |

## Version policy for this 0.x project

This repository is pre-1.0, so compatibility is narrower than a stable `1.x` line.

- `PATCH`, such as `0.5.26` to `0.5.27`, means a backward-compatible bug fix, hardening change, or published documentation correction.
- `MINOR`, such as `0.5.x` to `0.6.0`, means a new user-facing capability or a deliberate contract change during the pre-1.0 period. Breaking command, migration, or installed-state changes require explicit release notes and an upgrade path.
- `MAJOR`, meaning `1.0.0`, is reserved for declaring a stable public contract. Do not use it merely because a pre-1.0 change is incompatible.

For 0.x, be strict about what counts as compatible. Prefer `PATCH` when existing commands and installed hosts continue to work unchanged. Use `MINOR` when users or installed hosts must follow a new contract, and document the transition before merge.

## Release obligations

Before a release, update and verify all of these together:

1. `VERSION`
2. every public `SCRIPT_VERSION` value that `scripts/verify-scripts.sh` expects to match that version
3. the matching `## <version>` section in `CHANGELOG.md`
4. any linear updater history or installed-state migration needed for hosts already on disk
5. tests and the `Verify scripts` CI run for the release commit
6. the public metadata scrub and all gates enforced by `scripts/release.sh`

The release commit should make `scripts/verify-scripts.sh` pass. Then publish `public-clean` to `origin/main` with `scripts/publish-public.sh`, wait for the `Verify scripts` workflow to pass on that commit, and run `scripts/release.sh` to create the tag and GitHub Release.

## Practical rule of thumb

If the change affects what users run, what users see in the public README, or what an installed ODROID M1S stores and replays later, assume it needs a release. If it only helps contributors develop, test, or review the project, keep it as an ordinary PR.
