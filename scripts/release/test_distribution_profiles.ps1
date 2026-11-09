#!/usr/bin/env pwsh
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
. "$PSScriptRoot/distribution_profiles.ps1"
. "$PSScriptRoot/workflow_test_helpers.ps1"

$directory = New-TestDirectory
$profiles = @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')
$rids = @('win-x64', 'win-x86', 'win-arm64', 'linux-x64', 'linux-arm64', 'linux-musl-x64', 'linux-musl-arm64', 'osx-x64', 'osx-arm64')
$toolIds = @('grate', 'grate-sqlite', 'grate-sqlserver', 'grate-mariadb', 'grate-postgresql', 'grate-oracle')
$libraryIds = @('grate.core', 'grate.sqlite', 'grate.sqlserver', 'grate.mariadb', 'grate.postgresql', 'grate.oracle')

function New-PackageFixture {
    param(
        [string]$Path,
        [string]$Id,
        [string]$Version
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path
    }
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry('fixture.nuspec')
        $writer = [IO.StreamWriter]::new($entry.Open())
        try {
            $writer.Write("<package><metadata><id>$Id</id><version>$Version</version></metadata></package>")
        } finally {
            $writer.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

try {
    Invoke-Test 'release and native CLI matrices require every profile on the supported platforms' {
        $release = Read-Workflow 'build.yml'
        foreach ($job in @('build-netcore-tool', 'build-standalone', 'build-standalone-mac-arm64', 'build-deb', 'build-msi')) {
            Assert-Equal @($profiles | Sort-Object) @($release.jobs[$job].strategy.matrix.distribution | Sort-Object) $job
        }
        $releaseRids = @($release.jobs['build-standalone'].strategy.matrix.arch) + @($release.jobs['build-standalone-mac-arm64'].strategy.matrix.arch)
        Assert-Equal @($rids | Sort-Object) @($releaseRids | Sort-Object)
        foreach ($producer in @('build-standalone', 'build-standalone-mac-arm64')) {
            $commands = $release.jobs[$producer].steps.run -join "`n"
            Assert-True $commands.Contains("-StandaloneVersion '`${{ needs.set-version-number.outputs.semVer }}'") 'Full prerelease version must reach the executable metadata.'
        }
        Assert-Equal @('linux-arm64', 'linux-x64') @($release.jobs['build-deb'].strategy.matrix.arch | Sort-Object)
        $ci = (Read-Workflow 'ci.yml').jobs.standalone
        Assert-Equal @($profiles | Sort-Object) @($ci.strategy.matrix.distribution | Sort-Object)
        Assert-Equal @($rids | Sort-Object) @($ci.strategy.matrix.rid | Sort-Object)
        Assert-Equal @($rids | Sort-Object) @($ci.strategy.matrix.include.rid | Sort-Object)
        $verify = $ci.steps | Where-Object name -CEQ 'Verify self-contained runtime and execution'
        Assert-True $verify.run.Contains("-Distribution '`${{ matrix.distribution }}'")
        foreach ($step in $ci.steps | Where-Object { $_.name -match 'Debian' }) {
            Assert-True ([string]$step.if).Contains("matrix.distribution == 'All'") 'Installer identities remain scoped to the All fixture.'
        }
    }

    Invoke-Test 'release inventory contains 54 ZIPs, twelve Debian packages and twelve profile MSIs' {
        $assets = @(Get-GrateReleaseAssets -Version '2.3.4-rc.1')
        Assert-Equal 78 $assets.Count
        Assert-Equal 78 @($assets | Select-Object -Unique).Count
        Assert-Equal 54 @($assets | Where-Object { $_.EndsWith('.zip') }).Count
        Assert-Equal 12 @($assets | Where-Object { $_.EndsWith('.deb') }).Count
        $msis = @($assets | Where-Object { $_.EndsWith('.msi') })
        Assert-Equal 12 $msis.Count
        foreach ($id in $toolIds) {
            foreach ($architecture in @('x64', 'arm64')) {
                Assert-True ($msis -ccontains "$id-msi-win-$architecture-2.3.4-rc.1.msi")
            }
            foreach ($rid in $rids) {
                Assert-True ($assets -ccontains "$id-$rid-self-contained-2.3.4-rc.1.zip")
            }
        }
    }

    Invoke-Test 'all package-manager candidates use every profile and retain publication boundaries' {
        $workflow = Read-Workflow 'build.yml'
        foreach ($name in @('build-chocolatey', 'prepare-winget')) {
            $job = $workflow.jobs[$name]
            Assert-Equal @($profiles | Sort-Object) @($job.strategy.matrix.distribution | Sort-Object) $name
            Assert-True (!$job.'continue-on-error') "$name failures must remain visible."
        }
        Assert-True ($workflow.jobs['release-ready'].needs -ccontains 'build-chocolatey')
        $chocolatey = $workflow.jobs['build-chocolatey']
        Assert-True ($chocolatey.needs -ccontains 'build-standalone')
        $chocolateyCommands = $chocolatey.steps.run -join "`n"
        Assert-True $chocolateyCommands.Contains("-Distribution '`${{ matrix.distribution }}'")
        Assert-True $chocolateyCommands.Contains('-ReleaseTag $tag') 'Retain the exact release tag in embedded verification URLs.'
        $packStep = $chocolatey.steps | Where-Object name -CEQ 'Check and build the profile package'
        Assert-Equal '${{ needs.set-version-number.outputs.release-tag }}' $packStep.env.RELEASE_TAG
        Assert-True (!$chocolateyCommands.Contains('choco push')) 'Feed publication remains a separate step.'
        $winget = $workflow.jobs['prepare-winget']
        $homebrew = $workflow.jobs['publish-homebrew']
        foreach ($job in @($winget, $homebrew)) {
            Assert-True ($job.needs -ccontains 'publish-github-release') 'Use final published artifacts.'
            Assert-True ([string]$job.if).Contains("is-prerelease != 'true'") 'These candidates require a stable release.'
        }
        Assert-True (($winget.steps.run -join "`n").Contains('-PrepareMigration'))
        $casks = $homebrew.steps | Where-Object name -CEQ 'Update and validate cask'
        foreach ($profile in $profiles) {
            Assert-True $casks.run.Contains("'$profile'") "Missing cask $profile."
        }
        Assert-True $casks.run.Contains('ReleaseTag = $env:RELEASE_TAG')
        $formulas = $homebrew.steps | Where-Object name -CEQ 'Generate all source formula candidates from the final tagged archive'
        Assert-True $formulas.run.Contains('-AllDistributions')
        Assert-Equal 2 ([regex]::Matches($formulas.run, 'Assert-GrateSourceTag -Tag').Count) 'Check the source tag before and after download.'
        Assert-Equal '${{ github.sha }}' $formulas.env.SOURCE_COMMIT
        $publish = $homebrew.steps | Where-Object name -CEQ 'Publish cask update'
        foreach ($id in $toolIds) {
            Assert-True $publish.run.Contains("'$id'") "Missing staged cask $id."
        }
        Assert-True ($publish.run.IndexOf('git add -- @paths') -lt $publish.run.IndexOf('git diff --cached')) 'Stage new identities before checking the tap diff.'
    }

    Invoke-Test 'manifest requires the complete exact inventory and records candidate bytes' {
        $assetsRoot = Join-Path $directory 'assets'
        New-Item -ItemType Directory -Path $assetsRoot | Out-Null
        $expected = @(Get-GrateReleaseAssets -Version '2.3.4')
        foreach ($name in $expected) {
            Set-Content -LiteralPath (Join-Path $assetsRoot $name) -Value 'fixture' -NoNewline -Encoding utf8NoBOM
        }
        $removed = Join-Path $assetsRoot $expected[0]
        Remove-Item -LiteralPath $removed
        Assert-Throws { Write-GrateReleaseManifest -Directory $assetsRoot -Version '2.3.4' -Tag '2.3.4' -Repository 'grate-devs/grate' } '*inventory*'
        Assert-True (!(Test-Path -LiteralPath "$assetsRoot/checksums.sha256"))
        Set-Content -LiteralPath $removed -Value 'fixture' -NoNewline -Encoding utf8NoBOM
        Set-Content -LiteralPath "$assetsRoot/unexpected.zip" -Value 'fixture'
        Assert-Throws { Write-GrateReleaseManifest -Directory $assetsRoot -Version '2.3.4' -Tag '2.3.4' -Repository 'grate-devs/grate' } '*inventory*'
        Remove-Item -LiteralPath "$assetsRoot/unexpected.zip"
        Write-GrateReleaseManifest -Directory $assetsRoot -Version '2.3.4' -Tag '2.3.4' -Repository 'grate-devs/grate'
        $manifest = Get-Content -LiteralPath "$assetsRoot/release-manifest.json" -Raw | ConvertFrom-Json
        Assert-Equal 78 $manifest.assets.Count
        Assert-Equal 'grate-devs/grate' $manifest.repository
        Assert-Equal '2.3.4' $manifest.version
        $fixtureDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('fixture'))).ToLowerInvariant()
        foreach ($asset in $manifest.assets) {
            Assert-Equal 7 $asset.size
            Assert-Equal $fixtureDigest $asset.sha256
        }
        Assert-Equal 78 @(Get-Content -LiteralPath "$assetsRoot/checksums.sha256").Count
        Remove-Item -LiteralPath "$assetsRoot/checksums.sha256", "$assetsRoot/release-manifest.json"
        Write-GrateReleaseManifest -Directory $assetsRoot -Version '2.3.4' -Tag $null -Repository 'grate-devs/grate'
        $dryRun = Get-Content -LiteralPath "$assetsRoot/release-manifest.json" -Raw | ConvertFrom-Json
        Assert-Equal '' $dryRun.tag 'Ordinary build runs have no release tag.'
    }

    Invoke-Test 'NuGet selection validates all twelve IDs and versions before returning any candidate' {
        $feed = Join-Path $directory 'nuget'
        New-Item -ItemType Directory -Path $feed | Out-Null
        foreach ($id in @($toolIds) + @($libraryIds)) {
            New-PackageFixture -Path "$feed/$id.nupkg" -Id $id -Version '2.3.4'
        }
        Assert-Equal 12 @(Get-GrateReleaseNugetPackages -Directory $feed -Version '2.3.4').Count
        New-PackageFixture -Path "$feed/grate-oracle.nupkg" -Id 'grate-oracle' -Version '2.3.3'
        Assert-Throws { Get-GrateReleaseNugetPackages -Directory $feed -Version '2.3.4' } '*version*'
        New-PackageFixture -Path "$feed/grate-oracle.nupkg" -Id 'grate' -Version '2.3.4'
        Assert-Throws { Get-GrateReleaseNugetPackages -Directory $feed -Version '2.3.4' } '*duplicate*'
        New-PackageFixture -Path "$feed/grate-oracle.nupkg" -Id 'unexpected' -Version '2.3.4'
        Assert-Throws { Get-GrateReleaseNugetPackages -Directory $feed -Version '2.3.4' } '*Unexpected*'
        Remove-Item -LiteralPath "$feed/grate-oracle.nupkg"
        Assert-Throws { Get-GrateReleaseNugetPackages -Directory $feed -Version '2.3.4' } '*exactly 12*'
    }
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
Write-Host "PASS: $script:TestCount distribution release contracts."
