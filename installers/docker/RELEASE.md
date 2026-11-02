# Docker distribution handoff for #799

The canonical Docker Hub image is `gratedevs/grate`. GitHub remains
`grate-devs/grate`. Buildx produces one OCI archive; the organization OIDC
identity publishes that verified archive to `gratedevs/grate`. During the transition, `erikbra/grate` receives the exact same
immutable digest through a Skopeo copy using the retained personal credential.
There is no second application build. Login identity does not choose the repository.

`release_tags.py` selects exact version tags for both names. Stable releases also
select `latest` on both; SemVer prereleases and releases explicitly marked as
prereleases never select `latest`. Optional `v` prefixes are removed. Build
metadata (`+...`) is rejected because it is not legal in a Docker tag; silently
dropping it could collide with another release. The local helper asks GitVersion
for metadata-free `SemVer`, falls back to `1.0.0-local`, and never pushes.

## Integrated release workflow

The Docker changes are integrated with #804's release-event contract and current
main's .NET 11/security settings. All artifact jobs use the immutable workflow
event SHA, and selected release tags must match the event ref and commit.
`resolve_release_context.py` accepts only strict metadata-free SemVer;
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
the 13-file release asset contract and generates checksums/manifest. The separate
application test job and normal required CI checks supply test evidence; the
packaging gate does not claim to include those database tests.

A release-only `publish-github-release` job uploads the validated assets.
`publish-docker` waits for that job and the gate, downloads the OCI archive and
uses `publish_docker_archive.py` to promote it without rebuilding. The canonical
job uses password-free login with username `gratedevs`, environment
`docker-hub`, its `DOCKERHUB_OIDC_CONNECTIONID` variable and `id-token: write`.
Its 3600-second credential outlives the bounded 45-minute publication job.
Compatibility then copies the same immutable digest using the personal token.

Version and stable-only `latest` policies come from `release_tags.py`, using the
validated `is-prerelease` output for both release events and manual recovery.
Per-tag verification, publication serialization (`cancel-in-progress: false`),
credential isolation, and redacted partial-outcome reports remain in place.

For partial publication, rerun failed publishing jobs in the **original tagged release run** so
its verified artifact and digest are reused. A fresh build may have different
provenance even at the same source commit; preflight blocks a conflicting
published version before GitHub assets can be replaced. Never rebuild blindly.

## Verification and partial publication

The publishing action's digest is compared with the actual manifest body read
back for every selected tag, using the checked-in read-only Registry client.
Equality of an index digest binds its platform and attestation descriptors.
`docker-publication.json` and the job summary record each result. Verification
continues across inaccessible or mismatched tags and fails overall.

Canonical publication and compatibility copying are not atomic. The copy helper
preflights canonical references against the built digest and rejects an existing
legacy version with a conflicting digest. It verifies the version's complete
manifest graph and blobs before copying legacy `latest`; matching existing
versions are verified without recopying. Temporary legacy authfiles use mode
0600 and are removed on success or failure. Tool responses and authentication
exceptions are not printed. `docker-compatibility.json` journals partial outcomes.

Before image publication, `check_docker_access.py` requests repository grants
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
| Repository grants | [OIDC diagnostic 41355646304](https://github.com/grate-devs/grate/actions/runs/41355646304) verified OIDC canonical pull/push, denied OIDC legacy push, and verified retained-token legacy pull/push without image publication. The earlier history copy separately exercised writes with the old shared identity. |
| `docker-hub` environment | Created and read back through the GitHub API after the maintainer selected release-job-only use without manual approval. No reviewer or wait timer; allowed refs are branch `main` and tags matching `*`. See the configuration below. |
| Long-term identity | Maintainer selected a move to organization-managed access under Docker organization `gratedevs` (GitHub organization remains `grate-devs`). The personal repository still needs a compatibility credential. Preserve working credentials during the transition. |

### Configured GitHub environment

The requested environment body is in [github-environment.json](github-environment.json)
and the allowed-ref rules are in
[github-environment-policies.json](github-environment-policies.json).
[github-environment-observed.json](github-environment-observed.json) records the
actual API read-back. No secret was created, moved, read or rotated.

The common workflow's release-only `publish-docker` job references
`environment: docker-hub`; ordinary build/test jobs do not. The manual access
check explicitly uses the same environment to verify that identity without
publishing. It is not part of ordinary CI. GitHub environment ref
policies do not allowlist job IDs. The environment permits `main` and tag refs;
other branches are not allowed.
The release workflow requires tagged recovery to be dispatched on the selected
tag (`--ref TAG -f release_tag=TAG`), so the executed source and cache/ref context
match. A dispatch on `main` cannot select another release tag. See the
[release recovery commands](../../docs/ReleaseProcess.md#workflow-layout).
The common release resolver and `release-ready` dependency must still enforce
published-release eligibility; an environment tag pattern is not SemVer or
release validation. See the
[GitHub environment API](https://docs.github.com/en/rest/deployments/environments)
and [ref-policy API](https://docs.github.com/en/rest/deployments/branch-policies).
The repository-scoped Docker secrets still exist; this environment alone does
not restrict which jobs can read those existing repository secrets.

### Configured organization identity

The maintainer authorized organization OIDC while retaining the personal token
for compatibility. Docker-Sponsored Open Source with all Team features and renewal
on 1 January 2027 was confirmed in the authenticated organization window.

[Connection grate-github-release](https://app.docker.com/accounts/gratedevs/admin/oidc-connections/4ef78952-1444-428f-bbfc-61624a97b196)
was created and its saved rule re-opened and checked:

- Connection ID: `4ef78952-1444-428f-bbfc-61624a97b196`.
- Subject: `repo:grate-devs/grate:environment:docker-hub`.
- Resource: only `gratedevs/grate`, scope `scope-image-push`, which includes pull.
  No delete, broad repository or Build Cloud grant was selected.
- GitHub environment variable `DOCKERHUB_OIDC_CONNECTIONID` in `docker-hub`
  stores the connection ID. It is not a secret.
- Existing repository secrets `DOCKER_HUB_USER` and `DOCKER_HUB_TOKEN` remain
  unchanged and are used only for legacy grants and destination copying.
  Their API update timestamps remain 20:51:05Z and 20:50:49Z on 1 November 2026.

The GitHub OIDC customization API reports `use_default: true`,
`use_immutable_subject: false`, and prefix `repo:grate-devs/grate`, confirming the
subject format for this repository. See the checked-in
[connection request](oidc-connection-request.json) and
[observed configuration](oidc-connection-observed.json), plus
[Docker's OIDC setup](https://docs.docker.com/security/authentication/oidc-connections/create-manage/)
and [scope reference](https://docs.docker.com/security/access-tokens/reference/).

The real [Actions access check](https://github.com/grate-devs/grate/actions/runs/41355646304)
passed at isolated commit `164b874424baca2dd42a3e31fbabcd25eec8f7b6`.
Its tree contained only the manual diagnostic at the registered `build.yml` path,
the grant-check helper and its six unit tests; there were no product build,
release or image publication steps. A temporary exact branch allowance let this
reviewed diagnostic use `docker-hub`; both that allowance and the temporary branch
were removed afterward. The final environment allows only branch `main` and tag
pattern `*`, as before. Sanitized grants and provenance are retained under
[oidc-evidence-2026-11-01](oidc-evidence-2026-11-01/).

No images or releases were published during OIDC setup. The common release-event
workflow integration is now implemented; its no-publication validation is recorded
in [VERIFICATION.md](VERIFICATION.md). The personal
token's expiration and renewal/recovery ownership remain unrecorded operational
metadata; retaining it does not authorize extending or changing its permissions.

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
python3 eng/check_docker_oci_copy.py # requires skopeo; local files only
```

Recorded local outcomes and evidence limits are in [VERIFICATION.md](VERIFICATION.md).

The last command copies a tiny synthetic OCI layout with amd64, arm64 and an
attestation between local directories with real Skopeo. It verifies the exact
root digest and every blob without contacting a registry or publishing images.
The separate `check_local_registry.py` remains available for explicitly authorized
loopback-registry checks; it was not run for the no-publication OIDC setup.
Application behavior requires the Docker integration suites against a matching
locally built application image separately; application sources did not change
for this authentication update.
