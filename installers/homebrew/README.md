# Homebrew channels and transition

The source-built core formula and the existing cask are different distributions.
The formula uses Homebrew's shared .NET runtime and supports the applicable macOS
and Linux hosts. The cask installs the macOS self-contained release binary.

## Verified channel status — 2026-11-01

- [Grate PR #805](https://github.com/grate-devs/grate/pull/805) prepares the core
  formula template, generators and installation documentation. Its CI on
  `9ca2b6e` passed all 52 active checks; five explicitly disabled jobs were skipped.
- [Homebrew/core PR #296651](https://github.com/Homebrew/homebrew-core/pull/296651)
  is closed without merging. The shared-runtime correction is pushed on
  `grate-devs/homebrew-core:agent/grate-2.1.6`, but the closed PR still points to
  its older commit. GitHub rejected attempts to reopen it. Coordinate reopening
  or resubmission with maintainers; do not treat the pushed fork as core availability.
- Grate 2.2.0 is a draft release without a final tag. The source archive checksum
  and final tagged-package checks therefore remain pending.
- The live [personal-tap manifest](https://github.com/erikbra/homebrew-cask/blob/8fa031c82f472bb369500eae7ea42a086260ef25/Casks/grate.rb)
  still declares **1.8.0**, with the old `erikbra/grate` release URLs. Both archives
  downloaded successfully through those URLs and contained `grate` at the archive
  root. Their SHA256 values matched the manifest:

  | Archive | SHA256 |
  | --- | --- |
  | macOS Arm64 1.8.0 | `d0465592555c90207f7b48984c8b330bd055c618646172d4c7f15a48d254ea05` |
  | macOS x64 1.8.0 | `7e14283ee5a97c81e8104aca32367d5f817a1b072caef101e16f9af94cfcb37e` |

  This verifies artifact availability and integrity, not installation, execution,
  upgrade behavior or current runtime security. No historical binary was executed.
- A regenerated 1.8.0 cask loaded successfully through Homebrew's actual cask DSL
  on macOS Arm64 (`Homebrew/brew` commit `27af95f6`). Its metadata declared macOS
  support and did not declare Linux support. This was a metadata check, not an install.
- A `grate-devs/homebrew-cask` repository was not available through the authenticated
  GitHub account when checked. No organization cask has been published by this work.

## Generate reviewable updates after the stable release

Both generators accept a stable numeric version and either that tag or its
`v`-prefixed equivalent. They create local files and never publish them.

- `Create-Formula.ps1 -version 2.2.0 -sourceArchive <final-source.tar.gz>` hashes
  the source archive for the corresponding tag and renders `grate.rb.in` into
  `artifacts/homebrew/formula/grate.rb`.
- `Create-Cask.ps1 -version 2.2.0 -artifactDirectory <final-macos-zips>` hashes
  both published macOS ZIPs and writes `artifacts/homebrew/cask/grate.rb`.
- Use `-releaseTag v2.2.0` only when that is the actual tag, and use the matching
  archives. The helpers do not verify the provenance of arbitrary local files;
  the release operator must download the exact URLs being rendered.
- Stable-only publication must also be enforced by the release workflow:
  exclude draft/prerelease events, require the intended stable tag and preserve
  review before changes to external taps or core. Neither generator needs secrets.
  Cross-repository publication, if added later, needs separately scoped credentials.

Run `pwsh -NoProfile -File installers/homebrew/Test-PackageGenerators.ps1` for the
offline generator checks. They use synthetic fixtures and do not establish a
working 2.2.0 Homebrew installation.

## Transition decisions for #801

If core is accepted as the primary channel, moving the cask to a second tap is
not a prerequisite for `brew install grate`. The remaining choice is whether to
maintain a self-contained macOS cask as an alternative or retire that channel
after a verified transition. Keep the old installation instructions until a
replacement is actually available.

If the alternative cask is retained, #801 still needs an organization-owned tap,
reviewed cask updates, credentials and stable-release automation, plus native
Arm64/Intel install and upgrade checks. Do not advertise
`brew install --cask grate-devs/cask/grate` before that repository and cask exist
and the installation has been verified.

If the cask is retired in favor of core, verify both a clean formula installation
and the transition from an installed personal-tap cask. Both distributions install
the command `grate`, so explicitly remove the old cask before installing the formula
for the manual transition. After core acceptance, the proposed manual sequence is:

```sh
brew update
brew uninstall --cask erikbra/cask/grate
brew install --formula homebrew/core/grate
```

This sequence is a validation plan, not a tested upgrade guarantee. Record the
old/new versions, runtime selection and a successful migration on both Mac
architectures; check that no stale Caskroom receipt or executable link remains.
Keep the old tap available until users have a tested path and a documented
rollback option. Remove it from a particular machine only after checking that
no other installed casks use it.

Homebrew's [tap migration guide](https://docs.brew.sh/Migrating-A-Formula-To-A-Tap)
describes coordinated source/destination changes. The installed Homebrew source
also contains cask-to-formula handling in
[`migrate_tap_migration`](https://github.com/Homebrew/brew/blob/27af95f6a334817dfc67703582a4dae87cc7f614/Library/Homebrew/cmd/update_report/reporter.rb).
For the core transition, a `tap_migrations.json` entry such as
`{"grate":"homebrew/core"}` is only a candidate **after** the formula exists and
the coordinated deletion/migration is reviewed and tested. Destination trust,
old cask receipts and executable ownership must be exercised in an isolated
Homebrew environment. Do not publish migration metadata while keeping two
independently active `grate` definitions or pointing at a missing destination.

Core acceptance alone does not complete #801: its original acceptance criteria
describe an organization-owned cask, while a core transition requires a revised
scope and verified migration evidence.
