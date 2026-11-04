# WinGet manifests

WinGet installs Grate from the ZIPs or MSIs attached to a published GitHub
release. This folder prepares the manifests that point to those files; it does
not build Grate or submit manifests to the community repository.

Run `Create-Installer.ps1` on Windows with a published stable version and
`wingetcreate` available. For the new package identity:

```powershell
./installers/winget/Create-Installer.ps1 -version VERSION -PrepareMigration -outputDirectory ./candidate
```

The script verifies the release assets and MSI identity before writing a
candidate. Review and install-test it before a separate upstream submission.
Default mode is restricted to historical `erikbra.grate` MSI identity; corrected
MSIs require `-PrepareMigration`. See [the migration guide](MIGRATION.md) for the
supported ID transition and public-acceptance checks.

| File or folder | Purpose |
| --- | --- |
| `Create-Installer.ps1` | Reads release metadata, verifies downloaded MSIs, runs `wingetcreate`, and writes manifests under `artifacts/` unless another output directory is supplied. |
| `helpers/` | Manifest identity policy and the checksum-pinned WinGet client setup used by release/verification workflows. |
| `tests/` | Preparation, correlation and real Windows lifecycle checks, with disposable source fixtures and shared test helpers. |
| `grate/manifests/` | Historical accepted manifests. Keep their identities and contents unchanged. |
| `MIGRATION.md` | MSI/portable transition rules, client limitations and verification procedure. |

The release workflow prepares and schema-validates a new-ID candidate after
uploading stable release assets. It retains the candidate as a CI artifact;
community submission and public acceptance remain separate steps. Keep generated
manifests and run-specific reports outside git.
