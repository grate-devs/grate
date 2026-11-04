# Homebrew packaging

## Distribution strategy

The goal is a formula in the official `Homebrew/homebrew-core` repository so users
can install grate with `brew install grate`. The formula builds from source and
uses Homebrew's shared .NET dependency rather than bundling a runtime. It is
intended for the applicable macOS and Linux hosts; verify each supported platform
before submission. Do not advertise core installation as available until the
formula has been accepted and published.

The existing cask in [`erikbra/homebrew-cask`](https://github.com/erikbra/homebrew-cask)
installs the self-contained macOS release binary, including its .NET runtime.
Update this cask to 2.2.0 after that release and its Arm64 and Intel archives are
published, so existing cask users can upgrade while the core formula is pursued.
The cask is a separate distribution, not a prerequisite for the formula.

Do not create a new organization-owned cask tap as part of this plan. If acceptance
in `homebrew/core` is unsuccessful, revisit moving the cask from `erikbra` to
`grate-devs` as a fallback under [#801](https://github.com/grate-devs/grate/issues/801).

Keep dated status reports, commit-specific CI results and artifact-verification
evidence in the relevant pull requests rather than this packaging guide.

## Generate reviewable updates after the stable release

Both generators accept a stable numeric version and either that tag or its
`v`-prefixed equivalent. They create local files and never publish them.

- `Create-Formula.ps1 -version 2.2.0 -sourceArchive <final-source.tar.gz>` hashes
  the source archive for the corresponding tag and renders `grate.rb.in` into
  `artifacts/homebrew/formula/grate.rb`.
- `Create-Cask.ps1 -version 2.2.0 -artifactDirectory <final-macos-zips>` hashes
  both published macOS ZIPs and writes `artifacts/homebrew/cask/grate.rb`.
  The input files must be named `grate-osx-arm64-self-contained-<version>.zip`
  and `grate-osx-x64-self-contained-<version>.zip`.
- Use `-releaseTag v2.2.0` only when that is the actual tag, and use the matching
  archives. The helpers do not verify the provenance of arbitrary local files;
  the release operator must download the exact URLs being rendered. Use
  `-outputPath` to override either helper's default destination.

The automated release workflow uses
[`scripts/release/update_homebrew_cask.py`](../../scripts/release/update_homebrew_cask.py)
to generate the cask update for `erikbra/homebrew-cask`; the PowerShell helper
supports manual preparation. The workflow publishes the cask only for stable
releases, after release validation and GitHub publication. Its separate
`homebrew-cask` environment requires `HOMEBREW_TAP_TOKEN` with write access to the
tap. Neither PowerShell generator needs credentials or rebuilds grate. See the
[release runbook](../../docs/ReleaseProcess.md) and
[release configuration](../../docs/ReleaseConfiguration.md) for publication and
verification steps. Formula submission to core remains separate.

Run `pwsh -NoProfile -File installers/homebrew/Test-PackageGenerators.ps1` for the
offline generator checks from the repository root. They use synthetic fixtures
and do not establish a working Homebrew installation.

## Validate and submit updates

Packaging preparation can be merged before a release; final checksums and package
verification require the published stable tag and artifacts. Core acceptance is
not a prerequisite for releasing grate.

For the formula, generate metadata from the final source archive, then run native
Homebrew source-build, functional test, linkage, audit and style checks on the
supported platforms before submitting an update to `Homebrew/homebrew-core`.
See [Packaging](../../docs/Packaging.md) for commands and local tap setup.

For manual cask updates, generate metadata from both final macOS ZIPs, verify clean
installation and upgrade from the previous cask on Arm64 and Intel, and submit
the generated manifest as `Casks/grate.rb` in `erikbra/homebrew-cask`. Check that
the installed command runs a real database migration. Generating a manifest does
not publish it or prove installation works; external repository changes require
review before merging.

## Transition from cask to formula

Once the formula is available in core, verify and document the transition before
recommending it to existing cask users. Both distributions install the command
`grate`, so the proposed manual sequence removes the cask first:

```sh
brew update
brew uninstall --cask erikbra/cask/grate
brew install --formula homebrew/core/grate
```

This is a validation plan, not an upgrade guarantee. Verify clean installation
and transition on both Mac architectures, record runtime selection and a successful
database migration, and check for stale Caskroom receipts or executable links.
Keep the existing tap and installation instructions available until users have a
tested transition and rollback path. Cask retirement or automatic migration is a
separate, reviewed change, not a side effect of core acceptance.
