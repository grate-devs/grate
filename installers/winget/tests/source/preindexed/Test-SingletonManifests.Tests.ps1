#!/usr/bin/env pwsh
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$temp=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $locale=@{PackageLocale='en-US'; Publisher='erikbra'; PackageName='grate'; License='MIT'; ShortDescription='Test'}
    $legacy=@{Architecture='x64'; InstallerType='wix'; ProductCode='{E281998A-D8A2-4926-AAA3-066EFA4B2E74}'; AppsAndFeaturesEntries=@(@{UpgradeCode='{11111111-1111-1111-1111-111111111111}'}); InstallerUrl='https://127.0.0.1:8765/assets/grate-2.0.0.msi'; InstallerSha256=('A'*64)}
    $current=@{Architecture='x64'; InstallerType='wix'; ProductCode='{D60BDC2B-3F3B-53BA-AE6C-92F66776699B}'; AppsAndFeaturesEntries=@(@{UpgradeCode='{74CFECA2-37A1-5F6C-8739-E5ACA5116FC1}'}); InstallerUrl='https://127.0.0.1:8765/assets/grate-2.1.7.msi'; InstallerSha256=('B'*64)}
    $catalog=@{SourceIdentifier='ignored-by-preindexed-native-family';Packages=@(
        @{PackageIdentifier='erikbra.grate';Versions=@(@{PackageVersion='2.0.0';DefaultLocale=$locale;Installers=@($legacy)},@{PackageVersion='2.1.6';DefaultLocale=$locale;Installers=@($legacy)})},
        @{PackageIdentifier='grate-devs.grate';Versions=@(@{PackageVersion='2.1.7';DefaultLocale=@{PackageLocale='en-US';Publisher='grate-devs';PackageName='grate';License='MIT';ShortDescription='Test'};Installers=@($current)})}
    )}
    $catalogPath=Join-Path $temp 'catalog.json'
    $catalog | ConvertTo-Json -Depth 15 | Set-Content $catalogPath
    $files=@(& "$PSScriptRoot/New-SingletonManifests.ps1" -Catalog $catalogPath -OutputDirectory "$temp/manifests")
    if ($files.Count -ne 3) { throw 'All versions of both IDs must remain indexed.' }
    $old=Get-Content "$temp/manifests/erikbra.grate-2.0.0.yaml" -Raw | ConvertFrom-Json
    $new=Get-Content "$temp/manifests/grate-devs.grate-2.1.7.yaml" -Raw | ConvertFrom-Json
    if ($old.PackageIdentifier -cne 'erikbra.grate' -or $old.Publisher -cne 'erikbra' -or $old.Installers[0].ProductCode -cne '{E281998A-D8A2-4926-AAA3-066EFA4B2E74}') { throw 'Legacy identity was rewritten.' }
    if ($new.PackageIdentifier -cne 'grate-devs.grate' -or $new.Publisher -cne 'grate-devs' -or $new.Installers[0].ProductCode -cne '{D60BDC2B-3F3B-53BA-AE6C-92F66776699B}' -or $new.Installers[0].AppsAndFeaturesEntries[0].UpgradeCode -cne '{74CFECA2-37A1-5F6C-8739-E5ACA5116FC1}') { throw 'New identity/code references were changed.' }
    if ($new.ManifestType -cne 'singleton' -or $new.ManifestVersion -cne '1.12.0' -or $new.Installers[0].InstallerSha256 -cne ('B'*64)) { throw 'Downloadable singleton contract failed.' }
    $catalog.Packages=@($catalog.Packages[1])
    $catalog | ConvertTo-Json -Depth 15 | Set-Content $catalogPath
    $only=@(& "$PSScriptRoot/New-SingletonManifests.ps1" -Catalog $catalogPath -OutputDirectory "$temp/new-only")
    if ($only.Count -ne 1) { throw 'Public-origin catalog must not add an old ID absent from its input.' }
    $catalog.Packages[0].Versions+=@($catalog.Packages[0].Versions[0])
    $catalog | ConvertTo-Json -Depth 15 | Set-Content $catalogPath
    $rejected=$false
    try { & "$PSScriptRoot/New-SingletonManifests.ps1" -Catalog $catalogPath -OutputDirectory "$temp/duplicate" | Out-Null } catch { $rejected=$_.Exception.Message -like 'Duplicate manifest identity*' }
    if (!$rejected) { throw 'Duplicate package/version was silently overwritten.' }
    Write-Host 'Preindexed singleton conversion: all five contract checks passed.'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
