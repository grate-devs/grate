# Homebrew cask

`Create-Cask.ps1` generates a cask from the final macOS x64 and ARM64 release
ZIPs. It calculates their SHA256 hashes and points Homebrew at their GitHub
release URLs; it does not rebuild Grate or publish to a tap.

| File | Purpose |
| --- | --- |
| `Create-Cask.ps1` | Reads both archives and generates the architecture-specific cask |
| `grate.rb` (generated) | The cask to review, test and copy to the maintained tap |

Pass `-version` and `-artifactDirectory`, whose files must use the release names
`grate-osx-arm64-self-contained-<version>.zip` and
`grate-osx-x64-self-contained-<version>.zip`. Optional `-releaseTag` selects a
different GitHub tag; `-outputPath` changes the default `grate.rb` destination.

The automated release workflow uses
[`scripts/release/update_homebrew_cask.py`](../../scripts/release/update_homebrew_cask.py)
to update `erikbra/homebrew-cask`. This PowerShell helper supports manual
preparation. Validate the final cask and install it on the applicable macOS
architectures before submission; see the [packaging guide](../../docs/Packaging.md).
