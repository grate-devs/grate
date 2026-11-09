# Native MSI upgrade action

| File | Purpose |
| --- | --- |
| `LegacyUpgradeActions.cpp` | Verifies existing products, architecture and numeric-version compatibility before adding the current user's legacy product to the transactional upgrade. |
| `Build-UpgradeActions.ps1` | Reads `../identity-contract.json`, generates the identity header, selects Visual Studio's target compiler, and builds `GrateUpgradeActions.dll` into the requested output directory. |
| `Get-UpgradeActionContract.ps1` | Generates the twelve known profile/architecture families and the current profile identity; only All enables legacy migration. |

The main `Create-Installer.ps1` calls this build script. Building the Windows DLL
requires Visual Studio C++ build tools and the Windows SDK. The C++ source also
contains portable policy assertions enabled with `GRATE_POLICY_TESTS`; these
exercise policy rules without Windows Installer.
