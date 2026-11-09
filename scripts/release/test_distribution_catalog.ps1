#!/usr/bin/env pwsh
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
. "$PSScriptRoot/distribution_profiles.ps1"
$repository = Split-Path (Split-Path $PSScriptRoot)
$generator = "$repository/scripts/distributions/Update-DistributionCatalog.ps1"
$directory = New-TestDirectory
$page = Join-Path $directory 'catalog.md'

try {
    Invoke-Test 'checked-in catalog is fresh and generated content is reproducible' {
        & $generator -Check
        & $generator -OutputPath $page
        & $generator -Check -OutputPath $page
        $expected = (Get-Content -LiteralPath "$repository/docs/distribution-catalog.md" -Raw).Replace("`r`n", "`n")
        Assert-Equal $expected (Get-Content -LiteralPath $page -Raw)
    }
    Invoke-Test 'catalog lists every primary asset and distinguishes channel permutations' {
        $text = Get-Content -LiteralPath $page -Raw
        $primary = ($text -split '## NuGet tools')[0]
        foreach ($asset in Get-GrateReleaseAssets -Version '<version>') {
            Assert-Equal 1 ([regex]::Matches($primary, [regex]::Escape($asset))).Count "Primary asset: $asset"
        }
        foreach ($title in @(
            'ZIP (54 release files)', 'MSI (12 release files)', 'Debian (12 release files)',
            'NuGet tools (6 package identities)', 'Docker (6 images, 12 platform variants)',
            'WinGet (6 candidate identities, 30 installer selections)', 'Chocolatey (6 package candidates)',
            'Homebrew casks (6 recipes, 12 architecture selections)', 'Homebrew source formulas (6 candidates)',
            'NuGet libraries (6 existing APIs plus symbol packages)'
        )) {
            Assert-True $text.Contains("## $title") "Missing channel/count: $title"
        }
        Assert-True $text.Contains('main workflow') 'Workflow status must not impersonate per-package status.'
        Assert-True $text.Contains('require publication or channel acceptance') 'Candidate availability must be explicit.'
    }
    Invoke-Test 'missing or stale catalog content fails instead of silently regenerating' {
        Assert-Throws { & $generator -Check -OutputPath "$directory/missing.md" } '*stale*'
        $text = Get-Content -LiteralPath $page -Raw
        $mutated = $text.Replace('grate-oracle-msi-win-arm64-<version>.msi', 'missing-package.msi')
        Set-Content -LiteralPath $page -Value $mutated -NoNewline -Encoding utf8NoBOM
        Assert-Throws { & $generator -Check -OutputPath $page } '*stale*'
        Assert-True (Get-Content -LiteralPath $page -Raw).Contains('missing-package.msi') 'Check must not rewrite the stale page.'
        & $generator -OutputPath $page
    }
    Invoke-Test 'framework changes in the build inputs invalidate the catalog' {
        $fixture = Join-Path $directory 'repo'
        New-Item -ItemType Directory -Path "$fixture/scripts/distributions", "$fixture/scripts/release" | Out-Null
        Copy-Item -LiteralPath $generator -Destination "$fixture/scripts/distributions/Update-DistributionCatalog.ps1"
        Copy-Item -LiteralPath "$PSScriptRoot/distribution_profiles.ps1" -Destination "$fixture/scripts/release/distribution_profiles.ps1"
        '<Project><PropertyGroup><TargetFrameworks>net11.0</TargetFrameworks></PropertyGroup></Project>' |
            Set-Content -LiteralPath "$fixture/Directory.Build.props" -Encoding utf8NoBOM
        $fixtureGenerator = "$fixture/scripts/distributions/Update-DistributionCatalog.ps1"
        Assert-Throws { & $fixtureGenerator -Check -OutputPath $page } '*stale*'
        & $fixtureGenerator -OutputPath "$directory/net11.md"
        Assert-True (!(Get-Content -LiteralPath "$directory/net11.md" -Raw).Contains('net8.0')) 'Framework lists must come from build properties.'
    }
    Invoke-Test 'checkout line endings do not create false freshness failures' {
        $text = (Get-Content -LiteralPath $page -Raw).Replace("`r`n", "`n").Replace("`n", "`r`n")
        Set-Content -LiteralPath $page -Value $text -NoNewline -Encoding utf8NoBOM
        & $generator -Check -OutputPath $page
    }
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
Write-Host "PASS: $script:TestCount distribution catalog scenarios."
