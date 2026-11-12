# CI and release workflow layout

The event entry points keep dependency order, release eligibility and aggregate
results visible. Same-revision reusable workflows contain the implementation of
each phase. Each child has one leaf job, with its own matrix where applicable;
inputs carry version/context explicitly and outputs expose values such as the
built Docker digest.

## CI

[`ci.yml`](ci.yml) orchestrates preflight, build/isolated tests, the parallel
verification phases, and the existing `PR validation` / `CI result` gates.

| Reusable phase | Responsibility |
| --- | --- |
| [ci-build.yml](ci-build.yml) | Source restore/build |
| [ci-fast-tests.yml](ci-fast-tests.yml) | Isolated suites on Linux/Windows |
| [ci-security-analysis.yml](ci-security-analysis.yml) | CodeQL analysis, including the main/scheduled baseline |
| [ci-database-tests.yml](ci-database-tests.yml) | Provider/runtime suites |
| [ci-cli-distributions.yml](ci-cli-distributions.yml) | Matching All/slim CLI and installed-tool suites |
| [ci-packages.yml](ci-packages.yml) | NuGet consumer/package verification |
| [ci-standalone.yml](ci-standalone.yml) | Native profile/RID checks and MSI/Debian lifecycle tests |
| [ci-docker.yml](ci-docker.yml) | Native Alpine profile/architecture checks |
| [ci-report.yml](ci-report.yml) | Diagnostic report aggregation |

`PR validation` still checks every expected producer and applicable correctness
step through the Actions API. Reusable jobs add caller prefixes to displayed job
names; the validator recognizes only the explicitly mapped caller/leaf paths.
Missing, duplicate, failed, cancelled or unexpectedly skipped producers remain
failures. A successful report is not a substitute for a successful test phase.

## Release

[`build.yml`](build.yml) resolves the event's version/source, calls producers,
waits for the complete release contract, uploads GitHub assets and then enables
the eligible registry/package-manager handoffs.

| Reusable phase | Responsibility |
| --- | --- |
| [release-tools.yml](release-tools.yml) / [release-libraries.yml](release-libraries.yml) | NuGet candidates |
| [release-cli.yml](release-cli.yml) | Self-contained profile/RID archives; separate calls select the existing runner/RID sets |
| [release-msi.yml](release-msi.yml) / [release-debian.yml](release-debian.yml) / [release-chocolatey.yml](release-chocolatey.yml) | Wrap the matching verified CLI artifacts |
| [release-docker-build.yml](release-docker-build.yml) / [release-docker-slim-build.yml](release-docker-slim-build.yml) | Retained All/slim OCI archives and provenance checks |
| [release-validate.yml](release-validate.yml) | Complete prerequisite results, package inventory, checksums and manifest |
| [release-github.yml](release-github.yml) | Upload validated assets to the existing release |
| [release-docker-publish.yml](release-docker-publish.yml) / [release-docker-slim-publish.yml](release-docker-slim-publish.yml) | Promote exact verified image digests |
| [release-winget.yml](release-winget.yml) | Stable WinGet candidates without submission |
| [release-homebrew.yml](release-homebrew.yml) | Stable cask updates and source-formula candidates |
| [release-tests.yml](release-tests.yml) | Existing non-publication application suites |

NuGet publication intentionally stays in the entry point: its trusted-publisher
policy identifies `build.yml` through `job_workflow_ref`. Moving that credential
job would require a separate external policy change. Docker and Homebrew retain
their leaf-job environments; environment credentials are resolved there.

## Change and verify a phase

Keep caller dependency/eligibility decisions explicit. Pass required inputs and
outputs by name; a caller's workflow environment does not propagate into a
reusable workflow. Preserve immutable event-SHA checkout, token permission caps,
environment associations, credential separation and artifact names. Publication
phases also constrain their caller and release inputs.

The shared preflight checks effective leaf behavior and the raw call boundaries.
Its resolver fails on unsupported shapes rather than guessing their behavior.
When changing a phase, update its forwarding/output/permission tests as well as
the corresponding behavior checks. Relevant local entry points include
`scripts/release/test_distribution_profiles.ps1`, workflow-policy fixtures and
`scripts/ci/Test-PRValidation.ps1`; `actionlint` validates all workflow files.
These checks do not execute publication or establish hosted-runner execution.

The generated [distribution catalog](../../docs/distribution-catalog.md) expands
the package/platform inventory. Refresh it with
`scripts/distributions/Update-DistributionCatalog.ps1`; preflight rejects stale
content. Workflow badges describe whole-workflow status, with per-variant results
available in the linked run's matrix jobs and artifacts.
