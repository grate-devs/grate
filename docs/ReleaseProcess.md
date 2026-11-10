---
title: "Release process"
permalink: /release-process/
nav_order: 12
has_children: true
---

# Release process

Use this runbook to ship a grate release and check that users can obtain it.
The normal route is to select a tested commit, draft a GitHub release, publish
it once, follow the release build, and verify each distribution channel.

The examples use `2.2.0`; replace it with your intended version. The repository
at the release commit must contain the release-event workflow described here.
For first-time setup or a changed credential, start with
[Release configuration](ReleaseConfiguration.md). For SDK details, supported
platforms and manual package recipes, see [Building and releasing packages](Packaging.md).

You need GitHub permission to create releases and tags in `grate-devs/grate`.
The CLI examples assume a local checkout, Git and an authenticated GitHub CLI
(`gh auth status`; use `gh auth login` if needed). Run them from the checkout.
Local package smoke checks also need the applicable .NET, Docker or native
installer tools; the GitHub publication steps can be done in the web interface.
Shell examples use macOS/Linux syntax. Windows maintainers can use the same
web steps and the corresponding PowerShell commands for local verification.

In this guide:

1. [Choose the version and commit](#1-choose-the-version-and-commit).
2. [Optionally validate before publication](#2-optionally-validate-before-publication).
3. [Draft and publish the GitHub release](#3-draft-and-publish-the-github-release).
4. [Follow the release run](#4-follow-the-release-run).
5. [Verify what users receive](#5-verify-what-users-receive).
6. [Recover a failed or partial release](#6-recover-a-failed-or-partial-release).
7. [Leave a release record](#7-leave-a-release-record).

## 1. Choose the version and commit

Choose a commit on `main` that contains the intended fixes and packaging changes.
Use its full SHA throughout preparation; `main` can move while you work.
These optional GitHub CLI commands collect the starting information:

```sh
git fetch origin --tags
RELEASE_TAG=2.2.0
RELEASE_COMMIT=$(git rev-parse origin/main)
git show --no-patch --format=fuller "$RELEASE_COMMIT"
gh run list --repo grate-devs/grate --commit "$RELEASE_COMMIT"
gh release list --repo grate-devs/grate
```

Before creating the release:

- Check the actual CI, integration and native-package results for the selected
  commit. Record skipped or unavailable coverage. A successful packaging job
  does not establish that database or installation tests passed.
- Check that the version is unused on GitHub and in the channels you will publish
  to. Investigate an existing version before proceeding; do not overwrite it as
  part of preparing a new release.
- Review the SDK/runtime and native dependency requirements in the package guide.
  Self-contained binaries and Docker images must be rebuilt to pick up bundled
  runtime fixes; updating the build machine alone does not patch old packages.
- Write release notes covering the changes, compatibility implications and any
  channel still pending. Include relevant upgrade instructions, such as MSI
  prerelease transitions described below.
- Confirm the [publication identities and configuration](ReleaseConfiguration.md)
  are ready. A green PR build does not test registry publication credentials.

**Version syntax:** use bare SemVer such as `2.2.0` or `2.2.0-rc.1`. The workflow
rejects `v2.2.0`, build metadata such as `2.2.0+build.1`, and a prerelease flag
that disagrees with the suffix. Do not edit version numbers in project files;
the release tag supplies the package version.

### Decide which channels this release will update

| Destination | Stable, for example `2.2.0` | Prerelease, for example `2.2.0-rc.1` |
| --- | --- | --- |
| GitHub release files | Upload packages, checksums and manifest | Same |
| Six NuGet tools and six libraries | Publish exact version | Publish exact version including suffix |
| Docker `gratedevs/grate` | Version tag and `latest` | Version tag only |
| Docker compatibility `erikbra/grate` | Same version digest and `latest` | Same version digest only |
| WinGet | Prepare six candidates; the post-release Windows pipeline validates and opens manifest PRs | Skip |
| Homebrew `erikbra/cask` | Update six casks; retain six source-formula candidates | Skip |
| Chocolatey | Retain six x64 packages; the post-release Windows pipeline validates and submits them | Retain candidates; no automatic publication |

GitHub is `grate-devs/grate`; the Docker organization is **`gratedevs`** without a
hyphen. A repository move does not rename packages in other registries.

## 2. Optionally validate before publication

To exercise the build and tests at the current workflow ref without publishing:

```sh
gh workflow run build.yml --repo grate-devs/grate --ref main -f publish=false
```

This uses GitVersion at that commit, which may differ from your planned release
version. Check the run's event SHA: `main` may have advanced since you recorded
`RELEASE_COMMIT`. It uploads Actions artifacts and consumes runner time, but does not
upload GitHub release files or publish to registries.

For an exact-version rehearsal, first create the intended tag at the agreed
commit, if it does not already exist. This changes the remote tag, so check the
version and commit first:

```sh
git tag "$RELEASE_TAG" "$RELEASE_COMMIT"
git push origin "refs/tags/$RELEASE_TAG"
```

A tag push alone is not a publication trigger in `build.yml`. Then dispatch the
workflow **from that same tag**:

```sh
gh workflow run build.yml --repo grate-devs/grate --ref "$RELEASE_TAG" \
  -f release_tag="$RELEASE_TAG" -f publish=false
```

The tag must contain this workflow. Entering a release tag while selecting
`main` as the workflow ref is rejected, even with `publish=false`. The workflow
checks that its event ref and immutable event SHA identify the selected tag.
Older tags run their older workflow; they cannot borrow current `main` tooling.
Do not move a historical release tag to make this command work.

Check the resolved version, source SHA, build results and artifacts in Actions.
All publication jobs and WinGet preparation should be skipped. Application tests
run separately in a validation dispatch; the packaging gate does not depend on
their results, so inspect those results too.

## 3. Draft and publish the GitHub release

1. Open [grate Releases](https://github.com/grate-devs/grate/releases) and choose
   **Draft a new release**.
2. Select the existing tag from validation, or create the intended tag against
   the exact commit chosen in step 1. Do not rely on `main` still pointing at
   that commit. If an existing tag points elsewhere, stop and resolve that
   discrepancy before publishing.
3. Use the version as the release title and add the prepared release notes.
4. For a suffixed version such as `2.2.0-rc.1`, select **Set as a pre-release**.
   For `2.2.0`, leave that option clear.
5. Save the draft if it still needs review. Drafting is preparation; the release
   build starts when you publish the release.
6. After the version, commit, notes and test evidence are checked, choose
   **Publish release** once.

If you prefer to save the draft through the CLI, prepare `release-notes.md` and use:

```sh
gh release create "$RELEASE_TAG" --repo grate-devs/grate \
  --target "$RELEASE_COMMIT" --title "$RELEASE_TAG" \
  --notes-file release-notes.md --draft
```

Add `--prerelease` when drafting an RC. `--target` controls automatic tag creation;
if the tag already exists, verify its commit independently. Complete the review
and publication in the GitHub release editor.

Publishing makes the release page visible before all its files are available.
The workflow will build and upload them. **Do not start a second manual
publishing run** to hurry this along.

## 4. Follow the release run

Open [the release workflow](https://github.com/grate-devs/grate/actions/workflows/build.yml)
and find the run triggered by the published release, checking its tag and SHA.
You can also locate and follow it with the CLI:

```sh
gh run list --repo grate-devs/grate --workflow build.yml \
  --event release --commit "$RELEASE_COMMIT"
# Set RUN_ID to the numeric ID of that release run.
gh run watch "$RUN_ID" --repo grate-devs/grate --exit-status
```

| Stage | What to look for |
| --- | --- |
| Resolve release context | Correct tag, source SHA, version and prerelease setting |
| Build and validate | CLI archives, MSI, Debian, NuGet and Docker OCI archive succeed |
| Release contract ready | Every required packaging/policy job succeeds; all 78 payload files exist |
| GitHub and NuGet publication | Files attached to the release; exact NuGet versions published in a separate job |
| Docker, Homebrew and WinGet handoff | Six Docker digest promotions; six stable cask updates; six formula and WinGet candidates retained |

Each Docker profile is built once per run into an amd64/arm64 OCI archive and
verified before publication. Publication promotes that profile's retained
archive, bound to its version, source and digest. All also copies its digest to
the compatibility repository. Publishing does not rebuild an image or promote
an archive from an earlier PR run.

The application-test job is intentionally skipped in a release or publishing
recovery run. Use the separate test evidence collected before publication.
A green release run is packaging/publication evidence, not a fresh database test.

The destinations progress independently. One failed channel does not mean that
nothing was published elsewhere. If any job fails, record the successful and
failed stages and use the recovery section before retrying.

## 5. Verify what users receive

Record a separate outcome for each channel: **available**, **prepared/pending**,
**failed**, or **not applicable**. Registry indexing can lag behind a successful
upload. Do not announce that every channel is updated until it is observable.

### GitHub files and checksums

Expect **80 uploaded files**: 54 CLI ZIPs, twelve MSIs, twelve Debian packages,
`checksums.sha256` and `release-manifest.json`. GitHub's automatically generated
source ZIP/tarball are additional downloads, outside this count.

The release ZIPs cover `win-x86`, `win-x64`, `win-arm64`, `linux-x64`, `linux-arm64`,
`linux-musl-x64`, `linux-musl-arm64`, `osx-x64` and `osx-arm64`. MSI supports Windows
x64/ARM64; Debian supports amd64/arm64. NuGet packages and the Docker OCI archive
are distributed separately, not attached as extra release files.

On macOS or Linux, download the actual published files and verify their hashes:

```sh
RELEASE_DIR="$PWD/release-check/$RELEASE_TAG"
mkdir -p "$RELEASE_DIR"
gh release download "$RELEASE_TAG" --repo grate-devs/grate --dir "$RELEASE_DIR"
(cd "$RELEASE_DIR" && shasum -a 256 --check checksums.sha256)
```

Use a fresh directory for each inspection. All 78 payload files should report
`OK`. Check the manifest's `version`, `tag` and asset names/sizes as well. On
Windows, use `Get-FileHash -Algorithm SHA256` to compare downloaded files with
the checksum list or manifest. Matching filenames alone are not verification.

### NuGet and native package smoke checks

Check the exact version on NuGet for the six tools (`grate`, `grate-sqlite`,
`grate-sqlserver`, `grate-mariadb`, `grate-postgresql`, `grate-oracle`) and the
six libraries (`grate.core`, `grate.mariadb`, `grate.oracle`, `grate.postgresql`,
`grate.sqlite`, `grate.sqlserver`).
The tool can be installed into a fresh local path to avoid replacing your normal
installation:

```sh
dotnet tool install grate --version "$RELEASE_TAG" --tool-path "$RELEASE_DIR/tool"
"$RELEASE_DIR/tool/grate" --help
```

Also extract the relevant self-contained ZIP and exercise that executable on its
native platform. Follow [Getting started](GettingStarted.md) with a disposable
database, then repeat the migration to check its one-time behavior. Check the
bundled skill with `grate skills install --local --path <temporary-directory>`.
Record which platforms/installers you actually ran, including MSI and Debian
where applicable; cross-building is not native execution evidence.

**Do not use `grate --version` as an executable-version probe.** In grate that
option sets the database migration version. Use package/release metadata and
actual executable/package checks instead.

For MSI packages, full SemVer gives each prerelease a distinct ProductCode,
while Windows Installer's ProductVersion remains numeric. Switching between
`2.2.0-rc.1`, `2.2.0-rc.2` and `2.2.0` requires explicit uninstall/reinstall.
Higher numeric-version upgrades use the tested major-upgrade path. Include this
in prerelease notes; do not claim that an RC automatically upgrades to its final
version with the same numeric core.

### Docker

Inspect the public version tags on both names and compare their root manifest
digests with the verified digest recorded in the release run:

```sh
docker buildx imagetools inspect "gratedevs/grate:$RELEASE_TAG"
docker buildx imagetools inspect "erikbra/grate:$RELEASE_TAG"
```

Both must identify the intended digest and provide runnable `linux/amd64` and
`linux/arm64` manifests. Attestation descriptors may also appear. For a stable
release, check `latest` on both names as well. For a prerelease, confirm that
`latest` still identifies the preceding intended stable release.

For a help smoke check, bypass the normal database-oriented entrypoint:

```sh
docker run --rm --entrypoint /app/grate "gratedevs/grate:$RELEASE_TAG" --help
```

The normal entrypoint requires `APP_CONNSTRING`, even when extra arguments are
supplied. Use the [Docker guide](https://github.com/grate-devs/grate/blob/main/installers/docker/RELEASE.md) for connection,
identity, digest and compatibility details, and exercise representative migrations
on the architectures being claimed.

### WinGet, Homebrew and Chocolatey

The separate `publish-windows-channels.yml` pipeline follows a successful stable
release workflow. It verifies that the original run, immutable tag and public
release agree, then downloads that run's existing WinGet and Chocolatey candidates.
It checks the actual published GitHub files before installing the packages on
disposable Windows runners. SQLite probes use the selected release commit's
native dependency policy. Chocolatey All also upgrades a real earlier approved
public package, preserving migration data and history before cleanup.
It does not rebuild the application or rerun the
GitHub/NuGet/Docker/Homebrew publishers. Publication credentials are confined to
the submission jobs after the Windows checks pass.

Use its manual dispatch for an already published release or a bounded retry.
Select the original release run and stable version; keep publication disabled
when only verifying. Inspect existing public packages and manifest PRs before
retrying. Successful submission is distinct from upstream acceptance and public
installation. Record each channel's actual outcome and pending moderation.
See [credential configuration](ReleaseConfiguration.md#publication-identities-and-configuration).

For a verification-only run from macOS, Linux or Windows with GitHub CLI:

```sh
gh workflow run publish-windows-channels.yml --repo grate-devs/grate --ref main \
  -f version="$RELEASE_TAG" -f release_run_id="$RELEASE_RUN_ID" -f publish=false
```

`RELEASE_RUN_ID` is the original successful release-event build, not this
channel workflow or a PR validation run. Set `publish=true` only for an intended
submission. Expired original artifacts stop promotion; rebuilding the application
is not an implicit recovery step.

- **WinGet:** for a stable release, download the
  `winget-migration-candidate-VERSION` and five `winget-PROFILE-candidate-VERSION`
  Actions artifacts. They contain `grate-devs.grate` and
  `grate-devs.grate.{SQLite,SQLServer,MariaDB,PostgreSQL,Oracle}` candidates,
  schema results and provenance. The post-release pipeline validates and
  install-tests those final files before submitting one package/version per PR
  to `microsoft/winget-pkgs`. Existing matching submissions are reused.
  Discovery searches PR titles for the package identifier, then checks the
  changed manifest paths and contents. A discovered submission for a different
  version stops for explicit reconciliation. Before submission, also inspect
  open upstream PRs for grate in their title or description and check their
  manifest paths; a competing PR with an unrelated title can escape automatic
  discovery.
  A generated candidate is not an accepted/public package. After acceptance,
  verify the new ID through the public `winget` source. Follow the
  [MSI and portable transition instructions](https://github.com/grate-devs/grate/blob/main/installers/winget/MIGRATION.md);
  keep public installation commands on the accepted identity until then.
- **Homebrew:** confirm `erikbra/homebrew-cask` contains all six profile casks with
  the new version, both architecture hashes and canonical GitHub download URLs. The workflow checks
  Ruby syntax; it does not prove native installation. Install/smoke-test the
  casks on available macOS architectures. The `homebrew-candidates-VERSION`
  artifact retains six casks and six source formulas. Formula source-tag lookup
  must match the release commit before and after downloading the archive.
  Formula/core submission is separate; check acceptance before announcing
  public formula installation. Uninstall an existing variant before switching.
- **Chocolatey:** download all six `chocolatey-PACKAGEID-VERSION` artifacts.
  The release build retains candidates; the post-release Windows pipeline
  install-tests and submits the same `.nupkg` files to the community feed.
  Inspect an existing version instead of overwriting it. Verify moderation,
  package availability and installation separately from upload acceptance.

## 6. Recover a failed or partial release

First inspect the original run and the public destinations. Keep the release
tag, commit, run/attempt, retained artifacts and error logs together. Diagnose
the failing step before retrying; a full rerun can replace already published
files, skip existing NuGet packages and move mutable channel pointers.

| Symptom | Next action |
| --- | --- |
| Invalid version, flag or tag/ref mismatch | Correct the release metadata or dispatch ref as appropriate. Source checkouts remain pinned to the event SHA. Do not move a historical tag to bypass validation. |
| Build or packaging failure before publication | Keep the release pending. Fix the cause and retry only a valid candidate; use a new version when source or immutable package contents must change. |
| Missing credentials or denied grants | Check the relevant identity/configuration with the maintainer who owns it. Do not extract secret values or publish an image as an access test. |
| GitHub files or NuGet partly published | Inventory existing files/packages and their contents before retrying. GitHub upload uses replacement semantics; NuGet `--skip-duplicate` does not compare existing bytes. |
| Canonical Docker succeeded, compatibility failed | Resolve the copy failure, then reuse the original verified digest/artifact. Check current `latest` ownership before retrying that publishing job. |
| A newer stable release has appeared | Preserve its Docker `latest` tags and Homebrew cask. An older stable-job replay can move those channels backwards. Prepare a bounded repair instead of replaying the whole old release. |
| WinGet candidate exists but new ID is unavailable | This is an outstanding submission/acceptance step, not a reason to rerun asset or image publication. |

For Docker partial publication, prefer rerunning only the failed publishing job
in the **original tagged release run**, provided its retained archive is available
and its selected mutable tags should still belong to that release. The job reuses
the original digest. A fresh build can produce a different digest even at the
same source SHA and will be refused if that immutable version already exists.

If a newer stable release owns either `latest`, preserve it. The normal workflow
has no version-only recovery input; a version-only repair needs a separate,
reviewed plan within the recovery scope. Likewise, do not overwrite a newer
Homebrew cask by rerunning an older `publish-homebrew` job. If the original
artifact is no longer available, report that gap rather than blindly rebuilding
or overwriting the existing version.

When a full publishing recovery is actually appropriate for an existing
published release, it uses the matching tag and explicitly enables writes:

```sh
gh workflow run build.yml --repo grate-devs/grate --ref "$RELEASE_TAG" \
  -f release_tag="$RELEASE_TAG" -f publish=true
```

This is a publication command, not a validation command. Do not use it to repair
a partial Docker release when a fresh build would conflict with the existing
version. Inspect the workflow at the tag first. Rerunning an old manual run on
`main` retains its old workflow/security context; it does not adopt newer fixes.
Stop repeating a failed action without new evidence.

## 7. Leave a release record

Keep a short record with the release notes or linked maintenance work. Store
run-specific reports and logs in CI artifacts or those external records, outside
the source repository:

```text
Version/tag and stable/prerelease flag:
Source SHA:
GitHub release URL:
Workflow run URL and attempt:
Test evidence for that source (including skipped/unavailable scope):
Release files, checksums and manifest:
NuGet versions:
Docker digest, compatibility result and latest ownership:
Homebrew version/native smoke results:
WinGet candidate, submission and public acceptance:
Chocolatey status, if in scope:
Other native smoke checks and remaining work:
```

Report pending channels explicitly. A successful workflow, a package-manager PR
and public installation are different milestones.

## References

- [Release configuration and ownership](ReleaseConfiguration.md)
- [Build outputs, SDK requirements and manual packaging](Packaging.md)
- [Docker release and recovery details](https://github.com/grate-devs/grate/blob/main/installers/docker/RELEASE.md)
- [WinGet migration contract](https://github.com/grate-devs/grate/blob/main/installers/winget/MIGRATION.md)

For optional agent assistance, the repository-local `release-grate` skill follows
this runbook. Its entrypoint is `.agents/skills/release-grate/SKILL.md`; invoke
`$release-grate` from a checkout to prepare a plan or help follow an authorized release.
