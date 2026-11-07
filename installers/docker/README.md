# Docker image

The Dockerfile builds Grate from the repository source and embeds a
self-contained executable in an Alpine image with ICU. Buildx supplies the
target architecture, selecting the matching musl runtime. From the repository
root, a local build is:

```sh
docker build -f installers/docker/Dockerfile -t grate-local:tests .
```

| File or folder | Purpose |
| --- | --- |
| `Dockerfile` | Pinned SDK build stage and runtime-dependencies image |
| `Dockerfile.dockerignore` | Keeps the build context to the files the Dockerfile needs |
| `entrypoint.sh` | Maps connection/version/environment variables to CLI arguments and forwards extra arguments |
| `release_tags.ps1` | Selects version tags and stable-only `latest` for canonical and compatibility image names |
| [config/](config/README.md) | Reusable GitHub environment and Docker OIDC setup templates |
| [tests/](tests/README.md) | Tag-policy and local-build tests, plus an optional loopback-registry check |
| [RELEASE.md](RELEASE.md) | Publication identities, digest-preserving promotion and recovery |
| [VERIFICATION.md](VERIFICATION.md) | Repeatable image and release verification procedures |

`entrypoint.sh` remains a small POSIX shell runtime launcher: the application
image does not include PowerShell. Host-side build and verification scripts use
PowerShell 7, including `build-docker-local.ps1` in the repository root. Use
`-Amd64`, `-Arm64`, or `-Platform linux/amd64` to load a single-platform image;
the default builds both platforms without loading or publishing.

The normal entrypoint needs `APP_CONNSTRING`, reads scripts from `/db` and writes
output to `/output`. To check help without connecting to a database, use
`docker run --rm --entrypoint /app/grate grate-local:tests --help`.
The canonical public image is `gratedevs/grate`; `erikbra/grate` remains the
compatibility name. Release publication promotes one verified OCI archive.
