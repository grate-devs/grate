# Docker distribution handoff for #799

The canonical Docker Hub image is `gratedevs/grate`. GitHub remains
`grate-devs/grate`. During the transition, `erikbra/grate` receives the same image
from the same Buildx build/export. Login identity does not choose the repository.

`release_tags.py` selects exact version tags for both names. Stable releases also
select `latest` on both; SemVer prereleases and releases explicitly marked as
prereleases never select `latest`. Optional `v` prefixes are removed. Build
metadata (`+...`) is rejected because it is not legal in a Docker tag; silently
dropping it could collide with another release. The local helper asks GitVersion
for metadata-free `SemVer`, falls back to `1.0.0-local`, and never pushes.

## Integration with the common release workflow

The `.github/workflows/build.yml` change on this branch is a **Docker-only
integration part**, based on current main. The common release/documentation owner
must integrate these steps into #804's `publish-docker` job rather than replace
its job contract with the main-shaped `build-docker-image` job:

- Preserve the `release-ready` dependency, release-only job condition,
  `environment: docker-hub`, and checkout at the selected `checkout-ref`.
- Use the common job's validated `semVer` and `is-prerelease` outputs, including
  manual recovery of a GitHub release marked prerelease with a stable-looking tag.
  Set the tag-selection step's `PRERELEASE` environment variable to
  `${{ needs.set-version-number.outputs.is-prerelease }}` in that integration.
  Current main has no such output; this branch uses the release event flag plus
  the helper's SemVer prerelease detection.
- Keep one publishing build/export with all selected tags. Preserve QEMU,
  `--pull`, current pinned SDK/runtime base images, entrypoint, bundled skill,
  and current source. The old #804 Dockerfile/SDK is not the integration baseline.
- Retain the separate nonpublishing Docker build for ordinary checks and point
  its metadata at `gratedevs/grate`. Run Docker policy tests in PR CI; the new
  `docker-distribution.yml` has no Docker Hub credentials or external publishing.
- Keep the publication concurrency group with `cancel-in-progress: false` and
  the digest verification/report steps. Check final workflow YAML with actionlint.

The main-shaped `versionSourceDistance` release detection is deliberately outside
this channel's ownership. Do not merge that integration part as an alternative
to the agreed published-release contract.

## Verification and partial publication

The publishing action's digest is compared with the actual manifest body read
back for every selected tag, using the checked-in read-only Registry client.
Equality of an index digest binds its platform and attestation descriptors.
`docker-publication.json` and the job summary record each result. Verification
continues across inaccessible or mismatched tags and fails overall.

Buildx publication across repositories is not atomic. If push fails, the verifier
still observes each selected tag. Without a build digest it records
`observed_without_build_digest` and fails; these observations cannot establish
that this run published those tags. Failure before tag selection or verification
is explicitly reported in the summary. Never rebuild or blindly retry a partially
published version: inspect both repositories and the original build record, then
repair from the original immutable digest under the release recovery procedure.

The frozen history plan remains unchanged, SHA-256
`044b46912aaa90f3fe352e80639b1feff6682ae36eb1eb59d7ed046fbf3f4c1e`.
All 37 historical tags were already copied and verified by
[run 41350802278](https://github.com/grate-devs/grate/actions/runs/41350802278).
Do not run another history copy for this change. `docker-migrate-tags.yml` is a
manual recovery tool, separate from release publication.

## Operations inventory and outstanding decisions

GitHub inventory and maintainer decisions recorded on 1 November 2026:

| Item | Evidence / remaining action |
| --- | --- |
| `DOCKER_HUB_USER` | Repository secret updated `2026-11-01T20:51:05Z`; value intentionally unreadable through the secrets API. The maintainer confirmed the current credential owner is Docker ID `erikbra`. |
| `DOCKER_HUB_TOKEN` | Repository secret updated `2026-11-01T20:50:49Z`; maintainer confirmed owner `erikbra`. Token type, expiration, renewal owner and recovery owner remain unrecorded. Record metadata only, never the token. |
| Repository grants | [Diagnostic attempt 2](https://github.com/grate-devs/grate/actions/runs/40603935117/attempts/2) confirmed pull/push for both names; the completed history copy exercised writes. Neither establishes expiration or future access. |
| `docker-hub` environment | Created and read back through the GitHub API after the maintainer selected release-job-only use without manual approval. No reviewer or wait timer; allowed refs are branch `main` and tags matching `*`. See the configuration below. |
| Long-term identity | Maintainer selected a move to organization-managed access under Docker organization `gratedevs` (GitHub organization remains `grate-devs`). The personal repository still needs a compatibility credential. Preserve working credentials during the transition. |

### Configured GitHub environment

The requested environment body is in [github-environment.json](github-environment.json)
and the allowed-ref rules are in
[github-environment-policies.json](github-environment-policies.json).
[github-environment-observed.json](github-environment-observed.json) records the
actual API read-back. No secret was created, moved, read or rotated.

Only the common workflow's release-only `publish-docker` job should reference
`environment: docker-hub`; build/test jobs should not. GitHub environment ref
policies do not allowlist job IDs. The environment permits `main` for manual
recovery using the current workflow plus a validated existing release tag, and
permits tag refs for normal release events. Other branches are not allowed.
The common release resolver and `release-ready` dependency must still enforce
published-release eligibility; an environment tag pattern is not SemVer or
release validation. See the
[GitHub environment API](https://docs.github.com/en/rest/deployments/environments)
and [ref-policy API](https://docs.github.com/en/rest/deployments/branch-policies).
The repository-scoped Docker secrets still exist; this environment alone does
not restrict which jobs can read those existing repository secrets.

### Organization identity migration

The target ownership decision is confirmed. After the maintainer opened the
organization in Edge, read-only inspection confirmed Docker-Sponsored Open Source
with all Docker Team features, renewal on 1 January 2027. The organization's
OIDC connections page is available and shows no existing connections. Its create
form exposes repository-scoped rules and lists the `grate` repository. No OIDC
connection was created; the form was left without saving and the overview still
showed no connections. Existing credentials remain in place. Token expiry and
renewal/recovery ownership are still unrecorded.

[Docker's token guidance](https://docs.docker.com/security/access-tokens/)
distinguishes account-owned PATs, organization-owned tokens and GitHub OIDC
connections. Use an organization OIDC connection as the target migration design, scoped to
`gratedevs/grate` pull/push and the GitHub environment subject
`repo:grate-devs/grate:environment:docker-hub`. The GitHub OIDC customization
API reports `use_default: true`, `use_immutable_subject: false`, and prefix
`repo:grate-devs/grate`, confirming that subject format for this repository. The login action already meets the
[documented OIDC minimum](https://docs.docker.com/security/authentication/oidc-connections/create-manage/).
If OIDC is unavailable but organization tokens are supported, use a scoped OAT
with an agreed expiration and renewal owner. Do not simply change
`DOCKER_HUB_USER` from `erikbra` to the organization while retaining the old token.

Organization resources cover repositories within that organization, per
[Docker's OIDC resource rules](https://docs.docker.com/security/authentication/oidc-connections/rulesets-claims/).
The compatibility repository `erikbra/grate` therefore needs a separate credential
strategy. Before switching the live workflow, develop and verify a two-identity
publication path: publish one immutable artifact to the canonical repository,
then copy that exact digest and all platform/attestation manifests to the legacy
repository under its own credential. Preserve stable-only `latest`, serialization,
per-tag evidence and partial-failure handling. Test the path locally before any
release publication; no rebuild is permitted between the two destinations.

Subscription and OIDC availability are confirmed. Record the organization owners
responsible for access recovery, existing-token expiry and renewal ownership. Then
configure organization trust or a new credential directly in Docker/GitHub,
verify grants for each identity independently without pushing, and only then
integrate the migration. This follow-up has not created or revoked Docker
credentials, changed Docker account settings, or published images.

Before ending dual publication, maintainers must agree a date or release-count
window, notification period, and evidence that supported consumers have migrated.
No end date has been selected. Proposed exit criteria: the documented window has
elapsed; canonical stable/prerelease publishing and representative migrations are
verified; public docs/examples and known supported consumers use `gratedevs/grate`;
and maintainers explicitly approve ending updates to the old name. Retain old
version tags for historical reproducibility; ending dual publication does not
authorize deleting them.

Docker Hub description changes remain a maintainer decision and are not applied:

- `gratedevs/grate`: identify it as the canonical image, link the GitHub project
  and installation guide, and describe version tags and stable-only `latest`.
- `erikbra/grate`: mark it moved to `gratedevs/grate`, link the new repository,
  and state that compatible updates continue during the agreed transition.
- After the transition: state the last compatible version/date and that new
  releases are available only from the canonical name. Keep the migration link.

## Checks for this change

```sh
python3 -m unittest discover -s installers/docker -p 'test_*.py' -v
python3 -m unittest discover -s eng -p 'test_*docker*.py' -v
bash -n build-docker-local.sh
shellcheck build-docker-local.sh
python3 installers/docker/check_local_registry.py
```

Recorded local outcomes and evidence limits are in [VERIFICATION.md](VERIFICATION.md).

The last command builds tiny scratch images against a disposable loopback-bound
registry on an isolated Docker network. It checks amd64/arm64 indexes, matching
digests for both names, and unchanged `latest` after a different prerelease build.
It removes its builder, registry container, anonymous volumes, network and build
files. It does not test grate behavior; run the Docker integration suites against
a matching locally built application image separately.
