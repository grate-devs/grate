#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$temporary = Join-Path ([IO.Path]::GetTempPath()) "grate-archive-matrix-$([Guid]::NewGuid().ToString('N'))"

function Assert-Condition {
    param (
        [bool]$Condition,
        [string]$Message
    )

    if (!$Condition) {
        throw $Message
    }
}

try {
    $root = Join-Path $temporary 'packages'
    foreach ($name in @('fixture.client', 'fixture.runtime')) {
        $directory = Join-Path $root "$name/1.2.3"
        New-Item -ItemType Directory -Path "$directory/runtimes/linux-arm64/native" -Force | Out-Null
        "<package><metadata><id>$name</id><version>1.2.3</version><license type='file'>LICENSE.txt</license><repository url='https://example.invalid/source' commit='source123'/></metadata></package>" |
            Set-Content -LiteralPath "$directory/$name.nuspec" -Encoding utf8NoBOM
        'Original copyright and license text.' | Set-Content -LiteralPath "$directory/LICENSE.txt" -Encoding utf8NoBOM
        'notice requiring preservation' | Set-Content -LiteralPath "$directory/THIRD-PARTY-NOTICES.txt" -Encoding utf8NoBOM
        'native payload' | Set-Content -LiteralPath "$directory/runtimes/linux-arm64/native/libfixture.so" -Encoding utf8NoBOM
        '{"source":"https://example.invalid/feed","contentHash":"hash123"}' |
            Set-Content -LiteralPath "$directory/.nupkg.metadata" -Encoding utf8NoBOM
    }
    $assets = @{
        libraries = @{
            'fixture.client/1.2.3' = @{ type = 'package'; path = 'fixture.client/1.2.3' }
        }
        targets = @{
            'net10.0/linux-arm64' = @{
                'fixture.client/1.2.3' = @{
                    native = @{ 'runtimes/linux-arm64/native/libfixture.so' = @{} }
                }
            }
        }
        packageFolders = @{ $root = @{} }
        project = @{
            restore = @{ projectName = 'fixture' }
            frameworks = @{
                'net10.0' = @{
                    dependencies = @{ 'fixture.client' = @{ version = '[1.2.3, )' } }
                    downloadDependencies = @(@{ name = 'fixture.runtime'; version = '[1.2.3, 1.2.3]' })
                }
            }
        }
    }
    $assetsPath = Join-Path $temporary 'project.assets.json'
    $assets | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $assetsPath -Encoding utf8NoBOM
    $output = Join-Path $temporary 'output'
    & "$PSScriptRoot/Export-DependencyMatrix.ps1" -AssetsFile $assetsPath -OutputDirectory $output -Profile MariaDB -RuntimeIdentifier linux-arm64
    $matrix = @(Get-Content -LiteralPath "$output/dependency-matrix.json" -Raw | ConvertFrom-Json)
    Assert-Condition ($matrix.Count -eq 2) 'Runtime download dependency was omitted.'
    $client = $matrix | Where-Object id -EQ fixture.client
    $runtime = $matrix | Where-Object id -EQ fixture.runtime
    Assert-Condition ($client.directInProjects -contains 'fixture') 'Direct reference was not identified.'
    Assert-Condition $runtime.downloadDependency 'Runtime download was not distinguished from a normal reference.'
    Assert-Condition ($client.targetAssets[0].kind -eq 'native') 'Native selected-target evidence was omitted.'
    Assert-Condition ($runtime.packageNativeFiles.Count -eq 1) 'Native package contents were omitted for a runtime pack.'
    Assert-Condition ($client.sourceFeed -eq 'https://example.invalid/feed') 'Package feed provenance was lost.'
    Assert-Condition ($client.texts.Count -eq 2) 'License and NOTICE must both be preserved.'
    $csv = @(Import-Csv -LiteralPath "$output/dependency-matrix.csv")
    $csvClient = $csv | Where-Object id -EQ fixture.client
    Assert-Condition ($csv.Count -eq 2 -and $csvClient.version -eq '1.2.3' -and $csvClient.rid -eq 'linux-arm64' -and $csvClient.license -eq 'LICENSE.txt') 'CSV lost scalar package fields.'
    foreach ($text in $client.texts) {
        Assert-Condition ((Get-FileHash -LiteralPath (Join-Path $output $text.file) -Algorithm SHA256).Hash.ToLowerInvariant() -eq $text.sha256) 'Copied text hash does not match the original.'
    }
    $cache = Join-Path $temporary 'source-cache'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    @{ 'fixture.client/1.2.3' = @{ repositoryCommit = 'wrong'; texts = @() } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$cache/sources.json" -Encoding utf8NoBOM
    $rejected = $false
    try {
        & "$PSScriptRoot/Export-DependencyMatrix.ps1" -AssetsFile $assetsPath -OutputDirectory "$temporary/reject" -Profile MariaDB -RuntimeIdentifier linux-arm64 -LicenseSourceCacheDirectory $cache
    }
    catch {
        $rejected = $_.Exception.Message -like '*cache commit differs*'
    }
    Assert-Condition $rejected 'A license from a different source revision was accepted.'
    $sourceText = Join-Path $cache 'license.txt'
    'source license' | Set-Content -LiteralPath $sourceText -Encoding utf8NoBOM
    @{ 'fixture.client/1.2.3' = @{ repositoryCommit = 'source123'; texts = @(@{ file = 'license.txt'; sha256 = 'wrong'; url = 'https://example.invalid/license' }) } } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$cache/sources.json" -Encoding utf8NoBOM
    $rejected = $false
    try {
        & "$PSScriptRoot/Export-DependencyMatrix.ps1" -AssetsFile $assetsPath -OutputDirectory "$temporary/reject-hash" -Profile MariaDB -RuntimeIdentifier linux-arm64 -LicenseSourceCacheDirectory $cache
    }
    catch {
        $rejected = $_.Exception.Message -like '*cache hash mismatch*'
    }
    Assert-Condition $rejected 'Modified source license text was accepted.'
    Write-Host 'Dependency matrix checks passed: download packs, native assets, direct references, provenance, license/NOTICE bytes, and mismatched-source rejection.'
}
finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}
