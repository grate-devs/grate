# Chocolatey package

`Create-Package.ps1` embeds an already published self-contained Windows x64
executable, records its SHA256 and calls `choco pack`. It requires PowerShell and
Chocolatey. Pass the extracted executable with `-grateExe` and the release version
with `-version`; the resulting `.nupkg` is written to this folder.

| File or folder | Purpose |
| --- | --- |
| `Create-Package.ps1` | Copies the executable, updates verification details and builds the package |
| `grate/grate.nuspec` | Package identity, descriptive metadata and the `tools/**` file inclusion rule |
| `grate/tools/LICENSE.txt` | License shipped with the embedded executable |
| `grate/tools/VERIFICATION.txt` | Verification template replaced with the actual payload hash during packaging |
| `grate/tools/grate.exe` (generated) | The embedded release executable |

The script updates the local package staging files. Check the resulting package
and install it from a local source before a separate Chocolatey submission.
The release workflow does not automatically publish this channel. See the
[packaging guide](../../docs/Packaging.md#package-manager-updates-after-a-release).
