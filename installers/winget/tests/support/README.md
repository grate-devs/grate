# WinGet lifecycle helpers

| File | Purpose |
| --- | --- |
| `Get-LifecycleAssets.ps1` | On a disposable Windows runner, combines digest-verified historical release assets with current-source test candidates and writes the lifecycle inventory. MSI metadata comes from the shared MSI helpers. |
| `New-LifecycleCatalog.ps1` | Builds an in-memory source catalog from an inventory, selecting old/new identities and optional diagnostic bridge cases. It performs no network requests or installations. |

The [lifecycle tests](../README.md) consume these helpers. Generated assets and
inventories belong in the runner's temporary output directory.
