# Debian package

`Create-Package.ps1` packages an already published Linux executable. It copies
the payload into `/usr/bin`, adds the Debian metadata, manual and documentation,
then builds the package with `dpkg-deb --root-owner-group`. Run it on Linux with
PowerShell, `dpkg-deb` with `--root-owner-group` support, `gzip` and the usual Unix
file utilities installed.

From the repository root, pass the executable, Grate version and Debian
architecture (`amd64` or `arm64`) to `Create-Package.ps1` using `-grateExe`,
`-version` and `-arch`. The script uses a temporary staging directory and writes
`grate_<version>-1_<arch>.deb` beside itself by default. Pass `-OutputDirectory`
to select another destination. The release workflow gives the uploaded asset its
public filename.

`-Distribution` accepts `All` (the default), `SQLite`, `SQLServer`, `MariaDB`,
`PostgreSQL` and `Oracle`. The slim packages use the names `grate-sqlite`,
`grate-sqlserver`, `grate-mariadb`, `grate-postgresql` and `grate-oracle`.
Each installs `/usr/bin/grate` and conflicts with the other
variants because they share that command path. Select the matching executable
when building a package.

| File or folder | Purpose |
| --- | --- |
| `Create-Package.ps1` | Stages files, fills in version/architecture and builds the `.deb` |
| `Test-PackageVersion.Tests.ps1` | Builds temporary fixture packages and checks metadata, filenames and Debian version ordering |
| `template/DEBIAN/control` | Package metadata, dependencies and version/architecture placeholders |
| `template/DEBIAN/postinst`, `prerm` | Maintainer hooks for the legacy `/usr/doc/grate` documentation link |
| `template/usr/share/doc/grate/` | Copyright and changelog installed with the package |
| `template/usr/share/man/man1/grate.1` | The packaged command manual |

Prerelease metadata uses Debian's `~` ordering, for example
`2.2.0~rc.1-1 < 2.2.0-1`; filenames retain the Grate SemVer. Run the regression
check with `pwsh installers/deb/Test-PackageVersion.Tests.ps1 -Architecture amd64`
or `arm64`. Its package builds are isolated in a temporary directory.
