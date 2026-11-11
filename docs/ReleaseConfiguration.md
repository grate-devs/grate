---
title: "Release configuration"
parent: "Release process"
permalink: /release-process/configuration/
nav_order: 1
---

# Release configuration

Use this reference when setting up publication, rotating access, changing a
registry destination or investigating an authentication failure. The
[release runbook](ReleaseProcess.md) covers normal releases.

## Repository and channel ownership

| Destination | Name used by the workflow | Owner/access boundary |
| --- | --- | --- |
| Source, Actions and GitHub releases | `grate-devs/grate` | Repository permissions |
| NuGet | Six CLI tools and six `grate.*` libraries | NuGet package ownership and trusted publisher |
| Canonical Docker image | `gratedevs/grate` | Docker organization OIDC connection |
| Docker compatibility image | `erikbra/grate` | Retained legacy credential during transition |
| WinGet | Six `grate-devs.grate` profile identities; historical `erikbra.grate` unchanged | Manifest PRs to the community repository; Microsoft controls acceptance |
| Chocolatey | `grate` and five `grate-<database>` profile packages | Community repository maintainer account and moderation |
| Homebrew cask | Six profile casks in `erikbra/homebrew-cask` | Separate GitHub repository write access |

Moving the source repository does not move registry ownership or grant CI access.
Keep compatibility names during the agreed transition. The Homebrew formula/core
work and WinGet acceptance are separate from successful publication of the
underlying release files.

## Publication identities and configuration

Check names and access with the destination's owner; do not copy credential
values into documentation, issue comments or logs.

| Job/destination | Required configuration | What to check |
| --- | --- | --- |
| GitHub assets | Repository `GITHUB_TOKEN`; job `contents: write` | Can upload to the intended existing release |
| NuGet | `NUGET_USER` and NuGet trusted publishing | Policy matches this repository/workflow and its release execution context; package IDs are owned by the publisher |
| Canonical Docker | `docker-hub` environment; `DOCKERHUB_OIDC_CONNECTIONID` variable | OIDC connection permits canonical pull/push and the intended workflow refs |
| Compatibility Docker | `DOCKER_HUB_USER` / `DOCKER_HUB_TOKEN` | Pull/push to the legacy repository, valid lifetime and an owner for rotation |
| WinGet preparation | Read-only repository token | Can read public release metadata/templates; no submission PAT is used |
| WinGet submission | Repository secret `WINGET_GH_PAT` | Can write the `erikbra/winget-pkgs` fork and open PRs to `microsoft/winget-pkgs`; does not grant upstream approval or merge rights |
| Chocolatey submission | Repository secret `CHOCOLATEY_API_KEY` | Community account has publication rights for the intended IDs; push destination is `https://push.chocolatey.org/` |
| Homebrew cask | `homebrew-cask` environment; `HOMEBREW_TAP_TOKEN` | Contents write access to `erikbra/homebrew-cask`, including its applicable repository rules |

Keep ordinary build/test jobs free of publication credential references.
Environment association does not make a repository secret environment-scoped;
the release resolver and job conditions also enforce publication eligibility.
Inspect the actual environment rules rather than assuming a named environment
has an approval configured. Respect those rules when dispatching diagnostics.

Configure the Windows-channel credentials under **Settings → Secrets and
variables → Actions → Repository secrets** in `grate-devs/grate`. Retrieve the
Chocolatey API key from the signed-in [Chocolatey account page](https://community.chocolatey.org/account).
Keep its value out of chat, source files and command output. The separate
`publish-windows-channels.yml` workflow exposes these credentials only to the
corresponding submission jobs after verification; its Windows installation jobs
use read-only GitHub access. A maintainer does not need a Windows machine.

The NuGet job intentionally has no environment association. Adding one changes
its OIDC subject and requires a matching NuGet trusted-publisher change. Do not
change that association as an isolated cleanup.

The repository `GITHUB_TOKEN` does not grant write access to the separate
Homebrew tap. A missing `HOMEBREW_TAP_TOKEN` can leave the stable cask job failed
even though other destinations already succeeded. A syntax-valid generated cask
still needs a native installation check.

## Verify Docker access without publishing

The manual `.github/workflows/docker-access-check.yml` diagnostic uses the
reviewed code at its selected ref. Use a ref permitted by `docker-hub`; read the
[Docker identity/setup details](https://github.com/grate-devs/grate/blob/main/installers/docker/RELEASE.md) first.

A successful diagnostic must establish canonical OIDC pull/push, legacy-token
pull/push, and separation between the identities. Login success or HTTP 200 alone
is insufficient. The diagnostic requests grants and retains a sanitized report;
it does not upload an image. Do not weaken environment protections or run the
release publisher as an access probe.

`pwsh scripts/release/migrate_docker_tags.ps1 -Copy` performs real registry writes. It
is not an access diagnostic or part of an ordinary release. For an explicitly
requested history migration, first generate and review a fresh frozen plan,
preserving digests/platforms and independent verification. Store the plan and
reports outside git in CI artifacts or linked maintenance records.

## Operational decisions to keep current

Record who owns each identity, its expiry/rotation plan, and the transition-end
criteria before retiring old destinations. Keep `erikbra/grate` compatibility
publication until that decision is made; a source-repository rename is not a
reason to remove it. Verify current channel acceptance before replacing public
installation instructions.

Legacy documentation redirects belong to the owner of the old user-site domain.
Do not recreate an `erikbra/grate` repository to host a redirect: reusing that
name can remove GitHub's repository redirect. Redirect maintenance is separate
from the grate release procedure.

For actual workflow conditions and inputs, inspect
[`build.yml`](https://github.com/grate-devs/grate/blob/main/.github/workflows/build.yml)
at the release commit. This page describes the configuration contract, not proof
that any credential is currently valid.
