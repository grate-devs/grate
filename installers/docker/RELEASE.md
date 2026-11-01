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

Read-only GitHub inventory on 1 November 2026 confirmed:

| Item | Evidence / remaining action |
| --- | --- |
| `DOCKER_HUB_USER` | Repository secret updated `2026-11-01T20:51:05Z`; value intentionally unreadable through the secrets API. Exact Docker ID/identity owner still needs a maintainer record. |
| `DOCKER_HUB_TOKEN` | Repository secret updated `2026-11-01T20:50:49Z`; token type, expiration, renewal owner and recovery owner are not discoverable from GitHub secret metadata. Record metadata only, never the token. |
| Repository grants | [Diagnostic attempt 2](https://github.com/grate-devs/grate/actions/runs/40603935117/attempts/2) confirmed pull/push for both names; the completed history copy exercised writes. Neither establishes expiration or future access. |
| `docker-hub` environment | Absent. The common release owner must configure the intended branch/tag policy and approval policy before publication. Merely naming an environment in YAML does not establish protections. |
| Long-term identity | Choose organization-managed access for the canonical repository and an explicit compatibility credential strategy for the personal repository. Preserve working credentials during the transition. |

[Docker's token guidance](https://docs.docker.com/security/access-tokens/)
distinguishes account-owned PATs, organization-owned tokens and GitHub OIDC
connections. Select the future identity against actual subscription/support and
access to **both** repositories; do not assume an organization credential can
publish into a personal namespace. No token rotation or account changes are part
of this branch.

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
