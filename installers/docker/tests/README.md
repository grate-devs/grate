# Docker checks

Run the automated checks from the repository root:

```sh
pwsh -File scripts/release/Run-Tests.ps1 -Path installers/docker/tests
```

| File | Purpose |
| --- | --- |
| `test_release_tags.ps1` | Checks stable/prerelease tag selection and CLI outputs |
| `test_local_build.ps1` | Exercises `build-docker-local.ps1` with fake Docker/GitVersion commands, including invocation outside the checkout |
| `check_local_registry.ps1` | Optional real Buildx check using synthetic images and a temporary loopback registry |

The unit tests use temporary fixtures and PowerShell command shims and do not need a Docker daemon.
`pwsh -File installers/docker/tests/check_local_registry.ps1` requires Docker and
Buildx, creates local registry/builder/network resources and removes them on
exit. It does not authenticate to or publish to Docker Hub.
See the [verification guide](../VERIFICATION.md) for application-image checks.
