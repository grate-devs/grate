# Release tooling

These PowerShell 7 scripts support the release workflows in `.github/workflows/`.
They resolve release versions and publishing intent, check Docker access, publish
and verify the retained Docker archive, and generate the Homebrew cask update.
Production scripts use PowerShell and .NET without additional modules.
The scripts keep this logic testable outside GitHub Actions.

Run the automated checks from the repository root:

```sh
pwsh -File scripts/release/Install-TestDependencies.ps1
pwsh -File scripts/release/Run-Tests.ps1
pwsh -File scripts/release/Run-Tests.ps1 -Path installers/docker/tests
```

`Install-TestDependencies.ps1` installs the pinned `powershell-yaml` 0.4.12
module used only by workflow-policy tests. The test suites use synthetic fixtures and mocked registry requests; they do not
publish releases or images. The optional `check_docker_oci_copy.ps1` check uses
Skopeo with temporary local OCI layouts and also performs no registry writes.

Publication scripts and `migrate_docker_tags.ps1 -Copy` write to external
registries. Follow the [release process](../../docs/ReleaseProcess.md) and inspect
the command's inputs before running them. Historical tag migration is separate
from an ordinary release and requires a fresh, reviewed plan.

Keep generated plans, logs, reports, and observed configuration outside git, using
CI artifacts or a temporary directory. Commit reusable scripts, tests, desired
configuration, and instructions.
