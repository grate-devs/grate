#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$ExpectedMessage
    )
    try {
        & $Action | Out-Null
    }
    catch {
        if ($_.Exception.Message -like $ExpectedMessage) {
            return
        }
        throw
    }
    throw "Expected failure matching '$ExpectedMessage'."
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('grate-source-tests-' + [Guid]::NewGuid().ToString('N'))
$fixture = Join-Path $temporaryRoot 'repository'
$recipe = Join-Path $fixture 'installers/ubuntu-source'
try {
    New-Item -ItemType Directory -Path $recipe, (Join-Path $fixture 'src/grate'), (Join-Path $fixture 'docs/skills') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Stage-Source.ps1'), (Join-Path $PSScriptRoot 'Invoke-OfflineBuild.ps1') -Destination $recipe
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'debian') -Destination $recipe -Recurse
    'committed source' | Set-Content -LiteralPath (Join-Path $fixture 'src/grate/Program.cs')
    'source license' | Set-Content -LiteralPath (Join-Path $fixture 'LICENSE')
    '<Project />' | Set-Content -LiteralPath (Join-Path $fixture 'Directory.Build.targets')
    & git -C $fixture init --quiet
    & git -C $fixture add .
    & git -C $fixture -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m fixture
    $revision = (& git -C $fixture rev-parse HEAD).Trim()

    # A recursive copy would contaminate the source with developer restore/build
    # state. This fixture ensures git archive excludes these actual files.
    New-Item -ItemType Directory -Path (Join-Path $fixture 'src/grate/bin'), (Join-Path $fixture 'src/grate/obj') | Out-Null
    'prebuilt' | Set-Content -LiteralPath (Join-Path $fixture 'src/grate/bin/grate.dll')
    'developer restore' | Set-Content -LiteralPath (Join-Path $fixture 'src/grate/obj/project.assets.json')
    $stage = Join-Path $temporaryRoot 'stage'
    $source = & (Join-Path $recipe 'Stage-Source.ps1') -OutputDirectory $stage
    if (Test-Path -LiteralPath (Join-Path $source 'src/grate/bin')) {
        throw 'Developer binary directory contaminated source staging.'
    }
    if (Test-Path -LiteralPath (Join-Path $source 'src/grate/obj')) {
        throw 'Developer restore cache contaminated source staging.'
    }
    $origin = Get-Content -LiteralPath (Join-Path $stage 'source-origin.json') -Raw | ConvertFrom-Json
    if ($origin.sourceRevision -cne $revision -or (Get-Content -LiteralPath (Join-Path $source 'debian/source-revision') -Raw).Trim() -cne $revision) {
        throw 'Source revision provenance does not match the committed source.'
    }
    if (!(Test-Path -LiteralPath (Join-Path $stage 'grate-mariadb_0.0.1.orig.tar.gz'))) {
        throw 'Original source tarball was not produced.'
    }
    if ((Get-Content -LiteralPath (Join-Path $source 'src/grate/Program.cs') -Raw).Trim() -cne 'committed source') {
        throw 'Staged source differs from the selected committed revision.'
    }
    if (Test-Path -LiteralPath (Join-Path $source 'debian/patches')) {
        throw 'The archive analyzer adaptation was enabled without an explicit switch.'
    }
    $upgradeStage = Join-Path $temporaryRoot 'upgrade-stage'
    $upgradeSource = & (Join-Path $recipe 'Stage-Source.ps1') -OutputDirectory $upgradeStage -Version '0.0.2' -UseUbuntuArchiveAnalyzer
    if ((Get-Content -LiteralPath (Join-Path $upgradeSource 'debian/grate-version') -Raw).Trim() -cne '0.0.2' -or !(Test-Path -LiteralPath (Join-Path $upgradeStage 'grate-mariadb_0.0.2.orig.tar.gz'))) {
        throw 'The requested upgrade version was not carried into the source package.'
    }
    if (!(Get-Content -LiteralPath (Join-Path $upgradeSource 'debian/changelog') -Raw).StartsWith('grate-mariadb (0.0.2-1~poc1)')) {
        throw 'The upgrade changelog has the wrong Debian version.'
    }
    if ((Get-Content -LiteralPath (Join-Path $upgradeSource 'debian/patches/series') -Raw).Trim() -cne 'use-ubuntu-archive-analyzers.patch') {
        throw 'The explicitly selected archive analyzer patch is missing.'
    }
    Assert-Throws -Action {
        & (Join-Path $recipe 'Invoke-OfflineBuild.ps1') -StagedDirectory $upgradeStage -EvidenceDirectory (Join-Path $temporaryRoot 'incomplete-inputs') -DapperPackage 'unused.nupkg'
    } -ExpectedMessage 'Supply both source-built dependency packages together*'
    $invalidPackage = Join-Path $temporaryRoot 'invalid-revision.nupkg'
    $archive = [IO.Compression.ZipFile]::Open($invalidPackage, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry('Dapper.nuspec')
        $writer = [IO.StreamWriter]::new($entry.Open())
        try {
            $writer.Write('<package><metadata><id>Dapper</id><version>2.1.89</version><repository commit="wrong-source-revision" /></metadata></package>')
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
    Assert-Throws -Action {
        & (Join-Path $recipe 'Invoke-OfflineBuild.ps1') -StagedDirectory $upgradeStage -EvidenceDirectory (Join-Path $temporaryRoot 'invalid-inputs') -DapperPackage $invalidPackage -MySqlConnectorPackage $invalidPackage
    } -ExpectedMessage 'Unexpected source-built package identity/revision for Dapper*'

    Assert-Throws -Action { & (Join-Path $recipe 'Stage-Source.ps1') -OutputDirectory $stage } -ExpectedMessage 'OutputDirectory must not exist*'
    Assert-Throws -Action { & (Join-Path $recipe 'Stage-Source.ps1') -OutputDirectory (Join-Path $fixture 'inside') } -ExpectedMessage 'Stage outside the checkout*'
    'uncommitted behavior' | Add-Content -LiteralPath (Join-Path $fixture 'src/grate/Program.cs')
    Assert-Throws -Action { & (Join-Path $recipe 'Stage-Source.ps1') -OutputDirectory (Join-Path $temporaryRoot 'dirty') } -ExpectedMessage 'Commit product changes*'
    & git -C $fixture restore src/grate/Program.cs
    '<!-- uncommitted build behavior -->' | Add-Content -LiteralPath (Join-Path $fixture 'Directory.Build.targets')
    Assert-Throws -Action { & (Join-Path $recipe 'Stage-Source.ps1') -OutputDirectory (Join-Path $temporaryRoot 'dirty-targets') } -ExpectedMessage 'Commit product changes*'
    & git -C $fixture restore Directory.Build.targets
    'tracked binary' | Set-Content -LiteralPath (Join-Path $fixture 'src/grate/runtime.dll')
    & git -C $fixture add src/grate/runtime.dll
    & git -C $fixture -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m binary
    Assert-Throws -Action { & (Join-Path $recipe 'Stage-Source.ps1') -OutputDirectory (Join-Path $temporaryRoot 'binary') } -ExpectedMessage 'The selected revision contains binary/build inputs*'

    New-Item -ItemType Directory -Path (Join-Path $source 'debian/.build') | Out-Null
    Assert-Throws -Action {
        & (Join-Path $recipe 'Invoke-OfflineBuild.ps1') -StagedDirectory $stage -EvidenceDirectory (Join-Path $temporaryRoot 'evidence')
    } -ExpectedMessage 'The source staging directory contains prior build/cache state*'
    Write-Output 'Passed: source/cache isolation, provenance, version/upgrade propagation, explicit analyzer adaptation, dependency-pair/source-revision validation, existing-output protection, checkout protection, dirty-source rejection, tracked-binary rejection, prior-build rejection.'
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
