---
name: release-grate
description: "Prepare, publish, verify, or recover grate project releases using the repository workflows and distribution handoffs. Use for maintainer release work; not for database migrations in projects that consume grate."
---

# Release grate

Read [the release guide](../../../docs/ReleaseProcess.md), then inspect
`.github/workflows/build.yml`, `scripts/release/resolve_release_context.ps1` and `GitVersion.yml`
at the intended release commit. Resolve repository-relative paths with
`git rev-parse --show-toplevel`. The guide is the human procedure; this skill
coordinates the same workflows. If the implementation differs, report the gap
before choosing a trigger. Keep this maintainer skill in `.agents/skills`;
the consumer skill in `docs/skills/use-grate` is bundled in the CLI separately.

## Prepare

Resolve the version, stable/prerelease designation and exact source SHA. Check
working-tree changes, GitHub releases, CI for that commit, available artifacts and
existing destination versions using connected tools or `gh`. A missing or
inaccessible response is an evidence gap, not proof that a release does not exist.

Confirm these implementation contracts before planning publication:

- A published, non-draft GitHub release triggers `build.yml`. Versions use strict
  SemVer without a `v` prefix or build metadata; its suffix must agree with the
  GitHub prerelease flag. Default manual runs have `publish=false`.
- Every source checkout uses the immutable event SHA. A tagged manual dispatch
  requires `refs/tags/TAG` as its workflow ref and that tag's commit must equal
  the event SHA. Selecting another tag from a `main` dispatch is rejected.
- The packaging gate requires successful artifact/policy jobs and validates
  78 release files (54 CLI ZIPs, 12 MSIs, 12 Debian packages), then generates
  checksums/manifest. The Docker OCI archive is verified before that gate;
  NuGet publication validates twelve package IDs/versions. A file count alone
  does not validate every binary's embedded version.
- Release and publishing-recovery runs skip application tests. Confirm separate
  CI/test evidence for the intended commit, including runtime/native dependency
  servicing and relevant native package checks. A policy-permitted skip is not
  an executed passing test.

For channel-specific prerequisites, read [Docker release details](../../../installers/docker/RELEASE.md),
[WinGet migration guidance](../../../installers/winget/MIGRATION.md) or
[package guidance](../../../docs/Packaging.md) as relevant. Verify destination
access without exposing credentials. Preparing a release does not authorize
publishing it or submitting external manifests; retain any authorization already
given in the session instead of asking again.

Return a concrete plan: version/SHA, release notes, stable/prerelease flag, exact
trigger/ref/inputs, artifact inventory, channel identities, evidence links and
remaining prerequisites. Distinguish source checks from observations of the
actual published packages. Do not merge unrelated packaging PRs as a side effect.

## Publish and verify

When publication of the version and commit is authorized, use the agreed tag and
publish its GitHub release. This starts the workflow; do not also dispatch a
second publishing run. Follow the original run and inspect resolved version,
source, packaging gate and per-channel outcomes.

Use the publication policy at the selected commit:

- GitHub assets and NuGet support stable and prerelease versions. Check the
  release manifest/checksums, uploaded assets and all twelve NuGet IDs/versions.
- Docker builds six amd64/arm64 OCI archives before publication. The publishing
  jobs promote the verified profiles with organization OIDC to `gratedevs/grate`.
  The All profile's immutable digest is also copied to compatibility
  `erikbra/grate` with the retained token. Only stable releases update `latest`
  on the two All image names and the corresponding slim profile aliases.
  Record per-tag digest/platform verification and any partial copy outcome.
- Stable WinGet preparation generates and schema-validates six profile candidates
  from the final uploaded files. The separate `publish-windows-channels.yml`
  pipeline checks the original release run/tag, public assets and Windows
  installations before submitting manifest PRs and the retained Chocolatey
  packages. Reuse matching published versions/PRs and preserve other work.
  Leave historical `erikbra.grate` manifests unchanged. Acceptance and public
  new-ID installation checks remain separate steps. Use the migration guide's
  distinct MSI and portable transition commands; preserve full SemVer MSI
  identities and the explicit uninstall/reinstall rule for same-core releases.
- The current stable Homebrew job updates all six casks in `erikbra/cask`. Recheck the
  workflow and package guidance if the separate formula/core work has landed;
  a proposed formula or namespace is not evidence of public availability.

Respect configured environments and credential boundaries. Record tag/SHA,
run/attempt, asset checksums, image digests, package-manager status, native smoke
checks and coverage limits. A successful workflow or submitted manifest PR alone
does not establish availability through every package manager.

## Recover

Inventory completed publication before retrying: GitHub assets, NuGet packages,
Docker version/latest tags, compatibility copies and cask changes. Some writes
are irreversible or non-atomic. Preserve a newer Homebrew cask as well:
replaying an older stable `publish-homebrew` job can replace its current version. GitHub asset replacement and NuGet duplicate
skipping do not make the entire workflow idempotent.

Before a Docker retry, compare the original version/digest with the current
version tags and `latest` on both repositories. If a newer stable release now
owns either `latest`, preserve it: a stable publishing-job rerun writes `latest`
again. The normal workflow has no version-only recovery input; prepare a separate
bounded repair within the authorized scope instead of replaying that older job.

When the original version should still own the selected tags, rerun failed
publishing jobs in the **original tagged release run** to reuse its retained OCI
archive/digest. A fresh build may have different bytes/provenance even at the same
source commit; conflicting canonical versions are rejected before GitHub assets
can be replaced.

For an in-scope validation of an existing tag containing these controls:

```sh
gh workflow run build.yml --repo grate-devs/grate --ref "$RELEASE_TAG" -f release_tag="$RELEASE_TAG" -f publish=false
```

For authorized recovery against an existing published release, the same command
with `publish=true` enables external publication. Check the workflow stored at
the tag first. Old tags cannot borrow current `main` tooling, and rerunning an
old manual `main` run retains its old workflow/security context. Never move a
historical tag or change the ref/input to bypass validation. Stop a retry that
repeats the same failure without new evidence; use a new version when source or
immutable-package contents need correcting.

## Distribution diagnostics and migrations

For Docker access diagnostics, read `.github/workflows/docker-access-check.yml`
and use a reviewed ref allowed by the `docker-hub` environment. It checks
canonical OIDC grants, legacy-token grants and identity separation without
uploading. Login success or HTTP 200 alone does not establish push permission.
Do not weaken environment protections or extract secret values to test access.

A specifically requested historical Docker tag migration uses the read-only
snapshot mode of `scripts/release/migrate_docker_tags.ps1` first, then a reviewed
frozen plan and `-Copy` only within that authorization. The copy command performs
real registry writes; it is not an access test. Keep its plan and reports outside
git, using CI artifacts or linked maintenance records. Preserve digests, all
platforms, attestations and referenced blobs,
refuse conflicting tags and retain independent verification reports. Do not
repeat a history copy during an ordinary release or retire the legacy name
without an agreed transition-end decision.

When updating distribution documentation, migrate channels independently and
retain supported old names during the transition. Inspect current channel code
and live acceptance state before changing installation commands. Keep historical
references and CI evidence in external PR/release records or CI artifacts. Do
not commit point-in-time logs, reports, API snapshots or migration plans.
