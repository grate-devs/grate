# Chocolatey package

The `grate` package embeds the published self-contained Windows x64 CLI.
Chocolatey creates the `grate.exe` shim during installation. Use a clean,
disposable Windows x64 machine with PowerShell 7, Chocolatey 2 and GitHub CLI.
Run the commands from the repository root in an elevated PowerShell session.

## Download and verify the release

Set `$version` to the published stable GitHub release tag. The staging directory
is unique to this run.

```powershell
$ErrorActionPreference = 'Stop'
$version = '2.2.0'
$stage = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) "grate-chocolatey-$([guid]::NewGuid())")
$archive = "grate-win-x64-self-contained-$version.zip"
gh release download $version --repo grate-devs/grate --dir $stage.FullName --pattern $archive --pattern checksums.sha256 --pattern release-manifest.json
if ($LASTEXITCODE -ne 0) { throw 'Release download failed.' }

$archivePath = Join-Path $stage.FullName $archive
$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
$checksum = @(Get-Content (Join-Path $stage.FullName 'checksums.sha256') | Where-Object {
    $_ -match "^$archiveHash  $([regex]::Escape($archive))$"
})
$manifest = Get-Content (Join-Path $stage.FullName 'release-manifest.json') -Raw | ConvertFrom-Json
$asset = @($manifest.assets | Where-Object { $_.name -ceq $archive })
if ($checksum.Count -ne 1 -or $manifest.repository -cne 'grate-devs/grate' -or
    $manifest.tag -cne $version -or $manifest.version -cne $version -or
    $asset.Count -ne 1 -or $asset[0].sha256 -ne $archiveHash -or
    $asset[0].size -ne (Get-Item -LiteralPath $archivePath).Length) {
    throw 'Release archive does not match the checksums and manifest.'
}

$payload = Join-Path $stage.FullName 'payload'
Expand-Archive -LiteralPath $archivePath -DestinationPath $payload
$exe = Join-Path $payload 'grate.exe'
$payloadHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
```

## Build and inspect the package

Copy the recipe into the staging directory. `Create-Package.ps1` stages the
executable and generates `tools/VERIFICATION.txt` there.

```powershell
$recipe = (Resolve-Path -LiteralPath './installers/chocolatey').Path
Copy-Item -LiteralPath (Join-Path $recipe 'Create-Package.ps1') -Destination $stage.FullName
$tools = New-Item -ItemType Directory -Path (Join-Path $stage.FullName 'grate/tools') -Force
Copy-Item -LiteralPath (Join-Path $recipe 'grate/grate.nuspec') -Destination $tools.Parent.FullName
Copy-Item -LiteralPath (Join-Path $recipe 'grate/tools/LICENSE.txt') -Destination $tools.FullName
& (Join-Path $stage.FullName 'Create-Package.ps1') -grateExe $exe -version $version

$package = Join-Path $stage.FullName "grate.$version.nupkg"
$inspection = Join-Path $stage.FullName 'inspection'
[IO.Compression.ZipFile]::ExtractToDirectory($package, $inspection)
[xml]$nuspec = Get-Content (Join-Path $inspection 'grate.nuspec') -Raw
if ($nuspec.package.metadata.id -cne 'grate' -or $nuspec.package.metadata.version -cne $version) {
    throw 'Unexpected package ID or version.'
}
$embeddedHash = (Get-FileHash -LiteralPath (Join-Path $inspection 'tools/grate.exe') -Algorithm SHA256).Hash
$verification = Get-Content (Join-Path $inspection 'tools/VERIFICATION.txt') -Raw
if ($embeddedHash -ne $payloadHash -or $verification -notmatch $payloadHash -or
    -not (Test-Path -LiteralPath (Join-Path $inspection 'tools/LICENSE.txt') -PathType Leaf)) {
    throw 'Embedded executable, verification file or license failed inspection.'
}
Get-FileHash -LiteralPath $package -Algorithm SHA256
```

## Test the local package on Windows

Use only the staging directory as the source. Check that `grate.exe` on
`PATH` is the Chocolatey shim and that the installed payload still matches the
release. Keep the tested `.nupkg` and its SHA256 for submission.

```powershell
choco install grate --version=$version --source=$($stage.FullName) --yes --no-progress
if ($LASTEXITCODE -ne 0) { throw 'Local Chocolatey installation failed.' }

$shim = Join-Path $env:ChocolateyInstall 'bin/grate.exe'
$installed = Join-Path $env:ChocolateyInstall 'lib/grate/tools/grate.exe'
if ((Get-Command grate.exe -CommandType Application).Path -ne $shim -or
    (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -ne $payloadHash) {
    throw 'Unexpected Chocolatey shim or installed executable.'
}
grate.exe --help
if ($LASTEXITCODE -ne 0) { throw 'grate --help failed.' }

choco uninstall grate --version=$version --yes --no-progress
if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $shim) -or (Test-Path -LiteralPath $installed)) {
    throw 'Chocolatey uninstall did not remove the shim and payload.'
}
```

## Submit and follow moderation

Check the version history and maintainer for the existing [`grate` package][package].
Use a Chocolatey API key belonging to a maintainer of that ID. Configure it on
the maintainer's trusted Windows machine using the
[Chocolatey API key instructions][api-key]. Keep it out of scripts, logs and Git.
Run the push with the already configured key and the tested package path.

```powershell
choco push $package --source=https://push.chocolatey.org/
if ($LASTEXITCODE -ne 0) { throw 'Chocolatey submission failed.' }
```

A successful push records submission. Check the version page and respond to any
[moderation][moderation] requests from the maintainer account. After approval,
verify discovery and a fresh install from the public feed on a clean Windows
machine.

```powershell
$feed = 'https://community.chocolatey.org/api/v2/'
choco search grate --exact --all-versions --source=$feed
choco install grate --version=$version --source=$feed --yes --no-progress
grate.exe --help
```

[package]: https://community.chocolatey.org/packages/grate
[api-key]: https://docs.chocolatey.org/en-us/choco/commands/apikey/
[moderation]: https://docs.chocolatey.org/en-us/community-repository/moderation/
