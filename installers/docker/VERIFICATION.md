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
the exact settings. Legacy credential lifecycle, Hub description edits and the transition end
condition remain as
listed in [RELEASE.md](RELEASE.md). At that checkpoint, the build.yml part still required integration with the
common release-event workflow. The later combined-workflow record below supersedes
that integration limitation. Product image execution here covers linux/arm64. Multi-platform
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

## Organization OIDC implementation and no-publication check

The maintainer subsequently authorized creating organization OIDC, retaining the
personal token for compatibility, and testing without image publication.
Connection `grate-github-release` was created after the requested action-time
confirmation, then re-opened to verify its saved exact environment subject,
repository `grate` and `scope-image-push` (includes pull). The connection ID is
`4ef78952-1444-428f-bbfc-61624a97b196` and is stored in the `docker-hub`
environment's `DOCKERHUB_OIDC_CONNECTIONID` variable. The legacy secrets' update
timestamps were checked and remain unchanged.

The new workflow separates credential-free nonrelease builds from a release-only
OIDC publishing job. Only canonical tags are passed to Buildx. Compatibility uses
Skopeo `--all --preserve-digests` from the built immutable canonical digest, with
separate source OIDC and temporary legacy destination credentials. Existing legacy
version conflicts fail before compatibility writes; legacy latest is copied only
after successful version graph/blob verification. Final read-back is public.

Local checks for this update:

- `python3 -W error::ResourceWarning -m unittest discover -s eng -p 'test_*docker*.py'`:
  34 passed, including 14 new copy-path tests and 6 new identity-check tests.
- `python3 -m unittest discover -s installers/docker -p 'test_*.py'`:
  14 passed, including separated canonical/compatibility outputs.
- Actionlint passed for the access and policy workflows, and for `build.yml` with
  only the unchanged Debian `set-output` deprecation ignored. Diff checks passed.
- An independent review confirmed the separate identity boundaries; an isolated
  mutation reusing the legacy authfile for source access failed the intended
  assertion. A token expiry finding was corrected: the release login requests
  3600 seconds, exceeding the publishing job's 45-minute limit. The reviewer
  rechecked the correction with no remaining substantiated findings.
- Real Skopeo 1.13.3 copied synthetic OCI layouts entirely between local files,
  preserving amd64, arm64, an attestation, every blob, and root digest
  `sha256:87a03172faffe11619c03924662174ee7c5b8e0089eb34312a510af8553a9df2`.
  It ran in a disposable container from the existing pinned Ubuntu 24.04 image,
  installing Skopeo/Python from Ubuntu's signed package repositories. It did not
  build an image, contact a registry for the copy, or publish any image. The
  [offline result](oidc-evidence-2026-11-01/offline-copy.json) is retained.

The real [GitHub run 41355646304](https://github.com/grate-devs/grate/actions/runs/41355646304)
passed at isolated commit `164b874424baca2dd42a3e31fbabcd25eec8f7b6`:

| Identity / repository boundary | Observed result |
| --- | --- |
| Organization OIDC → gratedevs/grate | Pull and push granted |
| Organization OIDC → erikbra/grate | Authorization denied, satisfying the negative push boundary |
| Retained erikbra credential → erikbra/grate | Pull and push granted |

The diagnostic tree contained only a manual workflow, the access helper and its
six tests. It did not contain or execute application builds, registry upload/copy
steps, or release jobs. The short-lived OIDC exchange used Docker's login action;
repository-grant probes made only GET requests to Docker's auth endpoint.
No JWT, password, authfile or secret value is included in retained evidence.
The [sanitized report](oidc-evidence-2026-11-01/docker-oidc-access-41355646304-1/docker-access.json),
[run metadata](oidc-evidence-2026-11-01/run.json) and
[provenance](oidc-evidence-2026-11-01/provenance.json) are checked in.

A temporary exact environment branch allowance permitted the reviewed diagnostic.
It was removed afterward, and the temporary branch was deleted only after checking
its head still matched the diagnostic commit. API read-back confirmed the original
allowed refs (`main` branch, `*` tags) were restored. The production workflow was
not dispatched and no images were published to any registry for this update.
A live end-to-end image push/copy remains intentionally untested; at that checkpoint the common
release workflow integration was still pending; the later combined-workflow
record below supersedes that limitation. Product
code and Dockerfile were unchanged, so earlier application test results were not
rerun or represented as new OIDC test results.

## Combined #804 workflow validation

Docker distribution is now integrated with #804's published-release contract,
preserving current main's .NET 11/security baseline, Dockerfile and MSI scripts.
The successful [combined run 41357832522](https://github.com/grate-devs/grate/actions/runs/41357832522)
used source `afcc8f4b88314fe12710949713bc5ad79d29222d`, manual `publish=false`
and an empty release tag. Thirty jobs succeeded and all five external publication
jobs were skipped: GitHub assets, NuGet, Docker, Homebrew and WinGet. No image or
release was published during this validation.

The run built the tool/provider packages, nine standalone targets, two MSI and
two Debian packages. Independent download checks verified all 13 release assets'
sizes and SHA-256 values against the generated manifest. Test reports use a
separate artifact prefix and are excluded from the release asset contract.

| Test project | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Basic_tests | 1,752 | 8 | 0 |
| PostgreSQL | 740 | 0 | 0 |
| SqlServer | 1,076 | 0 | 0 |
| MariaDB | 700 | 0 | 0 |
| Sqlite | 812 | 12 | 0 |
| Oracle | 1,264 | 4 | 0 |
| Total | 6,344 | 24 | 0 |

Every project executed on net8.0, net9.0, net10.0 and net11.0. Existing skipped
tests remain skips. The initial integrated run exposed .NET 11 MTP resolving
relative project paths twice; absolute `.csproj` paths fixed it. Matrix
fail-fast is disabled so one provider failure cannot hide the other results.

The Docker build produced one OCI archive with linux/amd64 and linux/arm64 plus
two attestations, digest
`sha256:6dba7f9e914c5e8dda7f4eed3fb0c8d6c77a7598bd64dc7cdf48ad36fa7392a9`.
Independent local inspection verified all 26 OCI blob hashes. The archive was
retained without registry publication. Its publisher's real read-only preflight
accepted an absent prerelease tag and rejected the conflicting existing `2.1.6`
version without credentials or registry writes. The disposable Ubuntu check
required `ca-certificates` in addition to Python/Skopeo; no product change was
needed.

All 96 focused Python/policy tests and actionlint for the three changed workflows
passed. Eight checks of the actual gate expression accepted complete success and
rejected failure, cancellation, skip, missing/unknown results and empty input.
Independent critical review rechecked artifact promotion, publication conditions,
credential isolation and recovery preflight; no substantiated findings remain.
The packaging gate does not depend on database tests; those tests and normal CI
provide separate evidence, and all six completed successfully here.

The Docker policy workflow now uses offline OCI copies on PRs; loopback-registry
publication requires explicit manual opt-in and was not exercised here. The final
evidence/documentation commit leaves production `build.yml` byte-identical to the
tested source. Live external publish/copy execution remains intentionally
untested. The earlier no-push OIDC grant check remains the identity evidence.

The [evidence directory](integration-evidence-2026-11-01/) contains run and artifact
metadata, per-framework test totals with raw-log hashes, the asset manifest and
checksums, independent OCI/asset checks, gate cases, read-only preflight reports
and invocation provenance. It contains no credentials or large build binaries.
