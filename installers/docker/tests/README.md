# Docker checks

Run the automated checks from the repository root:

```sh
python3 -m unittest discover -s installers/docker/tests -p 'test_*.py' -v
```

| File | Purpose |
| --- | --- |
| `test_release_tags.py` | Checks stable/prerelease tag selection and CLI outputs |
| `test_local_build.py` | Exercises `build-docker-local.sh` with fake Docker/GitVersion commands, including invocation outside the checkout |
| `check_local_registry.py` | Optional real Buildx check using synthetic images and a temporary loopback registry |

The unit tests use temporary fixtures and do not need a Docker daemon.
`python3 installers/docker/tests/check_local_registry.py` requires Docker and
Buildx, creates local registry/builder/network resources and removes them on
exit. It does not authenticate to or publish to Docker Hub.
See the [verification guide](../VERIFICATION.md) for application-image checks.
