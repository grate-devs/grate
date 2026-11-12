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

## macOS Arm64 SDK setup

The native macOS release build uses `.github/actions/setup-dotnet-macos-arm64`.
It installs the SDK from `global.json` and the caller's additional SDK versions
with the existing pinned `actions/setup-dotnet`, then checks SDK selection,
host architecture, `PATH` and `DOTNET_ROOT` before building.

Hosted macOS runners can encounter transient filesystem errors during extraction
([upstream report](https://github.com/actions/runner-images/issues/15265)). The
action allows one retry after an installation failure, preserving the first error
and attempting filesystem diagnostics. Persistent installation failures still fail
the job. The action cannot classify the upstream action's unstructured errors, so
the single retry also applies to other installation failures.

Each attempt has separate fresh installation and temporary directories. This is
required because the pinned installer copies files even after extraction fails,
and later detects an installed SDK by its version directory's presence. Reusing
that partial tree could turn a failed extraction into a false successful setup.
This mitigation is independent of prerelease/GA versions; SDK version changes
remain in `global.json`.
