# Docker release and distribution

The canonical Docker Hub image is `gratedevs/grate`. GitHub remains
`grate-devs/grate`. Buildx produces one OCI archive; the organization OIDC
identity publishes that verified archive to `gratedevs/grate`. During the
transition, `erikbra/grate` receives the exact same
immutable digest through a Skopeo copy using the retained personal credential.
There is no second application build. Login identity does not choose the repository.

`release_tags.ps1` selects exact version tags for both names. Stable releases also
select `latest` on both; SemVer prereleases and releases explicitly marked as
prereleases never select `latest`. Optional `v` prefixes are removed. Build
metadata (`+...`) is rejected because it is not legal in a Docker tag; silently
dropping it could collide with another release. The local helper asks GitVersion
for metadata-free `SemVer`, falls back to `1.0.0-local`, and never pushes.

## Integrated release workflow

All artifact jobs use the immutable workflow event SHA, and selected release
tags must match the event ref and commit.
`resolve_release_context.ps1` accepts only strict metadata-free SemVer;
publishing requires a published non-draft release event, or explicit manual
publishing against an existing non-draft GitHub release. Ordinary push/PR events
and the default manual `publish=false` cannot enable publication.

`build-docker-image` runs without registry publishing credentials or an OIDC
permission. It builds amd64/arm64 into an OCI archive with `push: false`, verifies
its raw manifest digest, and retains that exact archive as an Actions artifact.
When publishing is requested, its read-only preflight also rejects an existing
canonical version with a conflicting digest before any GitHub asset upload.

The read-only `release-ready` gate requires all packaging and policy prerequisites
to succeed; it rejects failures, cancellations and unexpected skips. It validates
the 68-file release asset contract and generates checksums/manifest. The separate
application test job and normal required CI checks supply test evidence; the
packaging gate does not claim to include those database tests.

A release-only `publish-github-release` job uploads the validated assets.
`publish-docker` waits for that job and the gate, downloads the OCI archive and
uses `publish_docker_archive.ps1` to promote it without rebuilding. The canonical
job uses password-free login with username `gratedevs`, environment
`docker-hub`, its `DOCKERHUB_OIDC_CONNECTIONID` variable and `id-token: write`.
Its 3600-second credential outlives the bounded 45-minute publication job.
Compatibility then copies the same immutable digest using the personal token.

All five slim profiles have their own dual-architecture OCI build and retained
verification report. `publish_slim_docker_archive.ps1` checks the profile,
version, event SHA and archive digest again before canonical OIDC publication.
It preflights immutable `sqlite-<version>`, `sqlserver-<version>`,
`mariadb-<version>`, `postgresql-<version>` and `oracle-<version>` tags before
the release gate. Stable releases also update their corresponding profile alias;
prereleases update only the immutable tag. Prefixes keep these names distinct
from valid All SemVer prereleases. Slim variants use only `gratedevs/grate`;
the existing All compatibility-image contract remains unchanged.

Version and stable-only `latest` policies come from `release_tags.ps1`, using the
validated `is-prerelease` output for both release events and manual recovery.
Per-tag verification, publication serialization (`cancel-in-progress: false`),
credential isolation, and redacted partial-outcome reports remain in place.

For partial publication, check current tag ownership as described below, then
rerun failed publishing jobs in the **original tagged release run** when
appropriate so its verified artifact and digest are reused. A fresh build may have different
provenance even at the same source commit; preflight blocks a conflicting
published version before GitHub assets can be replaced. Never rebuild blindly.

## Verification and partial publication

The publishing action's digest is compared with the actual manifest body read
back for every selected tag, using the checked-in read-only Registry client.
Equality of an index digest binds its platform and attestation descriptors.
`docker-publication.json` and the job summary record each result. Verification
continues across inaccessible or mismatched tags and fails overall.

Before retrying an older stable publication, inspect version tags and `latest`
on both repositories against the original run's version/digest. A newer stable
release may already own `latest`. Both stable publishing helpers can overwrite
that mutable tag, so an original-job rerun is appropriate only while the original
release should still own it. Otherwise preserve the newer `latest` and prepare a
version-only repair from the retained verified digest within the authorized
recovery scope. A conflict-free immutable version does not make an older stable
job safe to replay against `latest`.

Canonical publication and compatibility copying are not atomic. The copy helper
preflights canonical references against the built digest and rejects an existing
legacy version with a conflicting digest. It verifies the version's complete
manifest graph and blobs before copying legacy `latest`; matching existing
versions are verified without recopying. Temporary legacy authfiles use mode
0600 and are removed on success or failure. Tool responses and authentication
exceptions are not printed. `docker-compatibility.json` journals partial outcomes.

Before image publication, `check_docker_access.ps1` requests repository grants
for each identity. It requires canonical OIDC pull/push and legacy-token
pull/push, and rejects OIDC push access to the legacy repository. A login alone
does not establish those grants. Final public manifest read-back deliberately
uses no legacy credential for the canonical repository.

If canonical push fails, the verifier
still observes each selected tag. Without a build digest it records
`observed_without_build_digest` and fails; these observations cannot establish
that this run published those tags. Failure before tag selection or verification
is explicitly reported in the summary. Never rebuild or blindly retry a partially
published version: inspect both repositories and the original build record, then
repair from the original immutable digest under the release recovery procedure.

## Publication configuration

The release jobs need two separate identities:

| Destination | Configuration | Required access |
| --- | --- | --- |
| Canonical `gratedevs/grate` | `docker-hub` environment and `DOCKERHUB_OIDC_CONNECTIONID` variable | Organization OIDC pull/push for this repository only |
| Compatibility `erikbra/grate` | `DOCKER_HUB_USER` and `DOCKER_HUB_TOKEN` repository secrets | Pull/push to the compatibility repository |

Record credential ownership, expiry, renewal and recovery responsibility in the
maintainer's operational records. Keep secret values out of logs and reports.
Recheck access when releasing; a saved template does not establish live grants.

### GitHub environment

[github-environment.json](config/github-environment.json) and
[github-environment-policies.json](config/github-environment-policies.json) are reusable
setup templates for the `docker-hub` environment: no wait timer or required
reviewer, with allowed refs `main` and tags matching `*`. Inspect the actual
repository policy before changing it; these files are desired configuration,
not observations of the live environment.

The release-only `publish-docker` job references `environment: docker-hub`;
ordinary build/test jobs do not. The manual access check uses the same environment
to verify the identity without publishing. Environment ref policies do not
allowlist job IDs, and an environment association does not restrict access to
existing repository-scoped secrets by itself.

Tagged recovery must use the selected tag as the workflow ref
(`--ref TAG -f release_tag=TAG`), so executed source and cache/ref context match.
The release resolver and `release-ready` dependency enforce published-release
eligibility; a tag pattern is not SemVer or release validation. See the
[release recovery commands](../../docs/ReleaseProcess.md#6-recover-a-failed-or-partial-release),
[GitHub environment API](https://docs.github.com/en/rest/deployments/environments)
and [ref-policy API](https://docs.github.com/en/rest/deployments/branch-policies).

### Organization OIDC identity

[oidc-connection-request.json](config/oidc-connection-request.json) is the reusable
organization connection template. Its contract is:

- Organization `gratedevs`, connection name `grate-github-release`.
- Subject `repo:grate-devs/grate:environment:docker-hub`.
- Resource `gratedevs/grate`, scope `scope-image-push`, including pull.
- No delete, broad repository or Build Cloud grant.

Store the created connection ID in the `docker-hub` environment variable
`DOCKERHUB_OIDC_CONNECTIONID`. Keep the personal credential separate for
compatibility publication. See [Docker's OIDC setup](https://docs.docker.com/security/authentication/oidc-connections/create-manage/)
and [scope reference](https://docs.docker.com/security/access-tokens/reference/).

Use the manual access diagnostic to establish canonical OIDC pull/push,
legacy-token pull/push and identity separation without uploading images. Keep
sanitized reports in Actions artifacts or linked maintenance records, not git.

## Compatibility transition

Before ending dual publication, maintainers must agree a date or release-count
window, notification period and criteria for consumer migration. Verify canonical
stable/prerelease publication and representative migrations, update public
examples and known supported consumers to `gratedevs/grate`, and record the
transition-end decision. Retain old version tags for reproducibility; ending
updates does not authorize deleting them.

Docker Hub descriptions should identify `gratedevs/grate` as canonical and link
the project and installation guide. The compatibility repository should link the
canonical name and describe the agreed support window. After the transition,
record its last supported release and retain the migration link.

## Historical tag migrations

A normal release does not copy registry history. For a separately authorized
history migration, first generate a read-only snapshot with
`scripts/release/migrate_docker_tags.ps1`, review its immutable digests and plan
hash, then copy only that plan with `-Copy`. Keep plans and reports outside git
in CI artifacts or linked maintenance records. Preserve platform/attestation
manifests and referenced blobs, reject conflicting tags and verify the result
independently. Inspect current destinations before retrying any partial copy.

## Verification

Follow [the Docker verification guide](VERIFICATION.md) for repeatable policy,
archive, registry and application checks. Store run-specific output in Actions
artifacts or external PR/release records. The source tree keeps the checks and
configuration needed to repeat them.
