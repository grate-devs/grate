# Docker verification

Use these checks when changing Docker packaging, release policy, identity
handling or compatibility copying. Run them against the intended source and
artifact, and record their outcomes and limits in the PR/release record. Store
logs, registry snapshots, digests and reports in CI artifacts or external records;
do not commit point-in-time evidence to git.

## Policy and local archive checks

Run from the repository root with PowerShell 7:

```sh
pwsh -File scripts/release/Run-Tests.ps1 -Path installers/docker/tests
pwsh -File scripts/release/Run-Tests.ps1 -Filter 'test_*docker*.ps1'
bash -n build-docker-local.sh
shellcheck build-docker-local.sh
pwsh -File scripts/release/check_docker_oci_copy.ps1
```

The last command requires Skopeo. It copies a synthetic OCI layout with amd64,
arm64 and attestation descriptors between local directories, verifying the exact
root digest and every blob without contacting a registry or publishing images.

`tests/check_local_registry.ps1` exercises stable/prerelease tags and compatibility
copying in a disposable loopback registry. It creates a temporary builder,
registry and network. Use it when local registry execution is in scope:

```sh
pwsh -File installers/docker/tests/check_local_registry.ps1
```

Neither synthetic check establishes that Grate executes successfully on the
image's advertised architectures.

## Application images

Build the selected source on each architecture being claimed, using
`installers/docker/Dockerfile` or `build-docker-local.sh`. Record the resulting
image digest. Verify `--help`, a representative database migration, an unchanged
rerun and bundled skill installation. The matching Docker integration suites
exercise database effects and migration history; follow
[the test/artifact map](../../docs/agents/testing.md) for project selection.

`grate --version` sets a database migration version and is not an executable
version probe. Use image labels and package metadata for source/version identity.
A successful cross-build is not native execution evidence, and a passing SQLite
check does not establish other providers' behavior.

## Access and publication checks

The manual `.github/workflows/docker-access-check.yml` diagnostic checks
canonical OIDC grants, retained-token compatibility grants and identity
separation without image publication. Use a reviewed ref allowed by the
`docker-hub` environment; do not weaken its protections to run the diagnostic.
Login success alone does not establish push permission.

After an authorized release, compare every selected public tag on both
repository names with the original build digest. Verify both runnable platforms,
attestations and referenced blobs. Stable releases should update `latest`;
prereleases should preserve the prior stable pointer. Check partial publication
before any retry, retaining a newer stable pointer when applicable. Follow
[release recovery](../../docs/ReleaseProcess.md#6-recover-a-failed-or-partial-release)
and [the Docker publication contract](RELEASE.md).
