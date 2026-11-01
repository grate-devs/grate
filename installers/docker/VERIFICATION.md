# Docker #799 verification record — 1 November 2026

Base: `origin/main` at `e67e518ed03059fce631409dc51edc6646384b6d`.
The branch starts with the preserved history tooling at
`4d9fca392283746aa63b4c2bb36bc7902d1fa334`.
This record covers the new Docker distribution change. Earlier Hub history-copy
and grant-check evidence is referenced in [the release handoff](RELEASE.md).

## Local checks

- `python3 -m unittest discover -s installers/docker -p 'test_*.py' -v`:
  13 passed (tag policy and real shell-helper subprocesses with stub tools).
- `python3 -m unittest discover -s eng -p 'test_*docker*.py' -v`:
  14 passed (9 historical-copy tests, 5 release-verification tests).
- `bash -n build-docker-local.sh`, `shellcheck build-docker-local.sh`, and
  `git diff --check`: passed.
- `actionlint .github/workflows/docker-distribution.yml .github/workflows/docker-access-check.yml .github/workflows/docker-migrate-tags.yml`:
  passed. Full `build.yml` reports its pre-existing Debian `set-output`
  deprecation; with only that diagnostic ignored, it passes. No new expression
  or workflow diagnostics remain.
- Independent read-only review completed. An isolated always-tag-latest mutation
  caused 6 intended assertion failures in the tag policy suite; the original
  suite passed again. The reviewer rechecked the local SemVer correction,
  partial publication reporting, SQLite adapter correction, and integration notes.

## Real local registry

`python3 installers/docker/check_local_registry.py` passed with Docker 29.9.2 /
Buildx 0.38.1. Both indexes include linux/amd64 and linux/arm64 plus attestations.

| Locally published tags | Manifest/index digest |
| --- | --- |
| Both repository names, `3.0.0` and `latest` | `sha256:5b77aebda8714666072031a829aad21493eea45bf8bded8a57175f50927ecefe` |
| Both repository names, `3.1.0-rc.1` | `sha256:7d69305be4d5360c243ca1c76527bfdc357f2d193749a56f6277cc90658a5f9b` |

The different prerelease build left both `latest` tags at the stable digest.
The check used a temporary registry on an isolated Docker network, exposed only
on loopback. Its builder, registry container, anonymous volumes and network were
removed. An initial attempt through Docker Desktop's default builder could not
reach the loopback registry; the committed check explicitly creates the isolated
builder/network and passed. No Docker Hub image was pushed.

## Application artifact and migration checks

A real ARM64 build from the current source passed:

```sh
docker buildx build --builder desktop-linux --pull \
  --file installers/docker/Dockerfile --platform linux/arm64 \
  --build-arg VERSION=1.0.0-local \
  --tag gratedevs/grate:1.0.0-local --tag erikbra/grate:1.0.0-local --load .
```

Both local names resolve to
`sha256:561be0dde957d8542b6ab5f59eb2b2bdd504c079c9d05f29f1b58d56a257881a`.
The build uses the unchanged pinned .NET 11 RC3 Dockerfile and entrypoint.
Its existing `NETSDK1244` single-file extraction warning remains.
`docker run --rm --entrypoint ./grate gratedevs/grate:1.0.0-local --help` passed.
A `--version` probe is not valid for this CLI: that option takes the migration's
schema version and still requires a connection string.

The host has .NET SDK 10.0.401, not the pinned RC3 SDK. From `/tmp`, using absolute
project paths, both `Basic_tests` and `Docker.Sqlite` built with
`-c Release -p:TargetFrameworks=net10.0` (the latter also with
`-p:GrateBuildLocalDockerImage=false`), with zero warnings/errors.
Direct `dotnet <test-assembly.dll>` runs then selected these scopes:

- Basic Docker image selection, lazy image builds and MSBuild plans:
  `--filter-class Basic_tests.Infrastructure.DockerGrateMigrator_ Basic_tests.Infrastructure.LocalDockerImage_ Basic_tests.Infrastructure.LocalDockerImageBuild_ --minimum-expected-tests 22`:
  22 passed, zero skipped.
- Compatibility local name via
  `GrateTestConfig__ApplicationDockerImage=erikbra/grate:1.0.0-local` and
  `--filter-class Docker.Sqlite.Running_MigrationScripts.One_time_scripts --minimum-expected-tests 1`:
  4 passed, zero skipped, against the same current application image.

The first complete canonical-image SQLite run selected 75 tests: 68 passed,
3 failed, 4 skipped. All 3 failures came from the unchanged recovery fixtures
supplying no admin connection string: the Docker adapter attempted to insert a
null bind-mount path before starting the container. The adapter now skips absent
optional admin strings. The same complete suite reran without exclusions: 71 passed, zero failed,
4 existing skips (database-creation capability and three unavailable CLI error-detail
checks). The initial rerun's `--minimum-expected-tests 75` counted executed tests,
so its runner returned exit 9 despite these passing results; the correct minimum
for the 71 executable cases was used for the final run: exit 0, 71 passed,
zero failed and the same 4 skips. No tests were explicitly excluded.

A representative historical pull, `docker pull gratedevs/grate:2.1.6`, passed at
`sha256:3c19c167f5860374bb1268b10b3dd9db7345eca699ada46d6e3ecdeeba2eb2be`;
its `--entrypoint ./grate ... --help` check also passed. Historical source tags
were not modified, and no further history-copy operation was run.

## Evidence limits

No release or Docker Hub publication workflow was run. After the maintainer
selected the environment policy, `docker-hub` was created without reviewers or a
wait timer, permitting branch `main` and tag pattern `*`; API read-back confirmed
the exact settings. Credential lifecycle, the pending organization-identity
migration, Hub description edits and the transition end condition remain as
listed in [RELEASE.md](RELEASE.md). The build.yml part still requires
integration with the common release-event workflow; it is not a separate release
mechanism. Product image execution here covers linux/arm64. Multi-platform
manifest publication was tested with scratch fixtures, not both grate binaries.
Host tests cover net10.0; net8.0/net9.0/net11.0 host suites and other database
providers were not run for this bounded distribution change.

## Maintainer clarification and environment follow-up

The maintainer confirmed that the existing CI token is owned by Docker ID
`erikbra` and selected organization-managed access under `gratedevs` as the target.
The requested GitHub `docker-hub` environment was created with no required
reviewers or wait timer. API read-back verified custom ref policies exactly:
branch `main`, tag `*`. These refs support normal tag releases and manual recovery
from the current workflow; the workflow must still restrict usage to its
release-only publishing job. The configuration and observed API evidence are
stored alongside [RELEASE.md](RELEASE.md).

The maintainer then provided an authenticated Edge window. Read-only inspection
of `https://app.docker.com/billing/gratedevs` confirmed Docker-Sponsored Open Source
with all Team features, renewal 1 January 2027. The authenticated OIDC overview
showed no connections; the unsaved create form exposed repository-scoped rules
including `grate`. Returning to the overview still showed no connections. No
Docker authentication or billing settings were saved. The initial in-app-browser
session had been signed out; that limitation was resolved by using the window
provided by the maintainer.
