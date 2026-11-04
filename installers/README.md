# Installers and distribution packages

These folders wrap Grate's published CLI or build its Docker image. Start with
the [release process](../docs/ReleaseProcess.md) for a complete release, or the
[packaging guide](../docs/Packaging.md) for supported platforms and runtimes.

| Folder | What it produces |
| --- | --- |
| [msi](msi/README.md) | Per-user Windows x64/ARM64 installers, with stable upgrade identities |
| [winget](winget/README.md) | WinGet manifests referring to the final Windows release assets |
| [deb](deb/README.md) | Debian packages containing the Linux standalone executable |
| [chocolatey](chocolatey/README.md) | A Chocolatey package embedding the Windows x64 executable |
| [homebrew](homebrew/README.md) | A cask referring to the final macOS release archives |
| [docker](docker/README.md) | A multi-architecture Alpine image built from source |

Build entrypoints remain at the top of each installer folder. Larger folders
separate reusable helpers, native code, configuration and tests. The release
workflows call these entrypoints; [scripts/release](../scripts/release/README.md)
contains the shared release and registry automation.

Keep generated packages, downloaded tools and execution reports out of git.
Read each folder's README for prerequisites and output locations.
