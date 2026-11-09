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
executable, its required `THIRD-PARTY-NOTICES.txt` companion, and generates
`tools/VERIFICATION.txt` there.

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
    -not (Test-Path -LiteralPath (Join-Path $inspection 'tools/LICENSE.txt') -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $inspection 'tools/THIRD-PARTY-NOTICES.txt') -PathType Leaf)) {
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

Check the exact version page and the maintainer for the existing
[`grate` package][package]. If that version already exists, read its moderation
state before attempting another push.

Use a Chocolatey API key belonging to a maintainer of `grate`. On a trusted
Windows machine, follow the [Chocolatey API key instructions][api-key] and push
the tested package with the configured key. Keep the key out of scripts, logs
and Git.

```powershell
choco push $package --source=https://push.chocolatey.org/
if ($LASTEXITCODE -ne 0) { throw 'Chocolatey submission failed.' }
```

For a one-off GitHub Actions submission, have the maintainer save the key as
`CHOCOLATEY_API_KEY` in [Actions secrets][actions-secrets]. Use a reviewed
workflow on a dedicated branch scoped to the intended version. Give the job
`actions: read` to download the tested artifact with `gh run download`, and
compare its SHA256 with the digest recorded by the Windows test before pushing.
Pass the secret as an environment variable only to the Chocolatey upload step.
Keep raw push output out of the log. Record the submission run and the package
SHA256.

Track the version on its Chocolatey page under **Version History**. If the
page still shows a cached 404 just after the push, retry with a fresh query
string and check the version history before retrying submission.

| Milestone | Evidence |
| --- | --- |
| Submitted | The push succeeds and the version appears on the package page. The exact-version download can already work during [moderation][moderation]. Compare the downloaded `.nupkg` SHA256 with the tested package. |
| Ready for review | Automated checks completed and Chocolatey queued the version for a reviewer. Read the check results and distinguish advisory scan notes from required changes. If the status says **Waiting for maintainer**, follow the review comments from the maintainer account. |
| Approved | Chocolatey marks the exact version approved on the version page. |
| Publicly available | After approval, normal search finds the version and a fresh install succeeds from the public feed on a clean Windows machine. |

```powershell
$feed = 'https://community.chocolatey.org/api/v2/'
$listed = choco search grate --exact --all-versions --source=$feed --limit-output
if ($LASTEXITCODE -ne 0 -or $listed -cnotcontains "grate|$version") {
    throw 'The exact version is missing from public Chocolatey search.'
}
choco install grate --version=$version --source=$feed --yes --no-progress
if ($LASTEXITCODE -ne 0) { throw 'Public Chocolatey installation failed.' }
grate.exe --help
if ($LASTEXITCODE -ne 0) { throw 'grate --help failed after public installation.' }
```

[package]: https://community.chocolatey.org/packages/grate
[api-key]: https://docs.chocolatey.org/en-us/choco/commands/apikey/
[actions-secrets]: https://github.com/grate-devs/grate/settings/secrets/actions
[moderation]: https://docs.chocolatey.org/en-us/community-repository/moderation/
