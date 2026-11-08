#!/usr/bin/env pwsh
# Called by Invoke-DependencyInventory inside its isolated SDK container.
param (
    [string]$LicenseSourceCacheDirectory
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path /evidence/source | Out-Null
& tar -xf /evidence/source.tar -C /evidence/source
if ($LASTEXITCODE -ne 0) {
    throw 'Cannot unpack source snapshot.'
}
Set-Location -LiteralPath /evidence/source
$expectedSdk = (Get-Content -LiteralPath global.json -Raw | ConvertFrom-Json).sdk.version
$actualSdk = & dotnet --version
if ($LASTEXITCODE -ne 0 -or $actualSdk -cne $expectedSdk) {
    throw "Expected pinned SDK $expectedSdk, found $actualSdk. Recheck archive SDK/runtime packs after GA."
}
& dotnet --info | Set-Content -LiteralPath /evidence/sdk-info.txt -Encoding utf8NoBOM
if ($LASTEXITCODE -ne 0) {
    throw 'Cannot record SDK information.'
}
'<configuration><packageSources><clear/><add key="discovery-only" value="https://api.nuget.org/v3/index.json"/></packageSources></configuration>' |
    Set-Content -LiteralPath /evidence/NuGet.Config -Encoding utf8NoBOM
$plans = @(
    @{ Profile = 'MariaDB'; Framework = 'net11.0'; Project = 'src/grate/grate.csproj' },
    @{ Profile = 'SQLite'; Framework = 'net11.0'; Project = 'src/grate/grate.csproj' },
    @{ Profile = 'SQLServer'; Framework = 'net11.0'; Project = 'src/grate/grate.csproj' },
    @{ Profile = 'All'; Framework = 'net11.0'; Project = 'src/grate/grate.csproj' },
    @{ Profile = 'PostgreSQL-library'; Framework = 'net11.0'; Project = 'src/grate.postgresql/grate.postgresql.csproj' },
    @{ Profile = 'MariaDB'; Framework = 'net10.0'; Project = 'src/grate/grate.csproj' }
)
foreach ($plan in $plans) {
    foreach ($rid in @('linux-arm64', 'linux-x64')) {
        $key = "$($plan.Profile)-$($plan.Framework)-$rid"
        $build = "/evidence/build/$key"
        $arguments = @(
            'restore', $plan.Project,
            '--artifacts-path', $build,
            "-p:TargetFrameworks=$($plan.Framework)",
            '-p:SelfContained=true',
            '-r', $rid,
            '--configfile', '/evidence/NuGet.Config',
            '-p:NuGetAudit=false'
        )
        if ($plan.Profile -ne 'PostgreSQL-library') {
            $arguments += "-p:GrateDistribution=$($plan.Profile)"
        }
        # Audit requests are disabled only to keep this graph/license inventory separate
        # from the security-advisory check; this does not waive that release check.
        & dotnet @arguments *> "/evidence/$key-restore.log"
        if ($LASTEXITCODE -ne 0) {
            throw "Restore failed: $key; see its log."
        }
        $assets = @(Get-ChildItem -LiteralPath "$build/obj" -Filter project.assets.json -File -Recurse | ForEach-Object FullName)
        $export = @{
            AssetsFile = $assets
            OutputDirectory = "/evidence/inventory/$key"
            Profile = $plan.Profile
            RuntimeIdentifier = $rid
            SdkRoot = '/usr/share/dotnet'
        }
        if ($LicenseSourceCacheDirectory) {
            $export.LicenseSourceCacheDirectory = $LicenseSourceCacheDirectory
        }
        & /automation/Export-DependencyMatrix.ps1 @export
    }
}

& /automation/Export-ProspectiveDependencyUnion.ps1 -InventoryDirectory /evidence
