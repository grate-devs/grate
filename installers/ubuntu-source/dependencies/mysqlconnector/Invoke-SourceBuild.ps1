#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceDirectory,

    [Parameter(Mandatory)]
    [string]$UbuntuFeedDirectory,

    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [ValidateSet('Canonical', 'UbuntuNet10')]
    [string]$Mode = 'Canonical',

    [string]$BuilderImage = 'grate-ubuntu-source:26.04'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$sourceCommit = '775689bb3e1ab55d16171e0795264fa746e364c4'
$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$feed = (Resolve-Path -LiteralPath $UbuntuFeedDirectory).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) {
    throw 'OutputDirectory must not exist; every attempt requires fresh source and caches.'
}
$resolved = (& git -C $source rev-parse "$sourceCommit^{commit}").Trim()
if ($resolved -cne $sourceCommit) {
    throw 'The exact upstream source revision is unavailable.'
}
New-Item -ItemType Directory -Path $output | Out-Null
$staged = Join-Path $output 'source'
New-Item -ItemType Directory -Path $staged | Out-Null
$sourceArchive = Join-Path $output 'upstream-source.tar'
& git -C $source archive --format=tar "--output=$sourceArchive" $sourceCommit
& tar -xf $sourceArchive -C $staged
$adjustments = @()
if ($Mode -eq 'UbuntuNet10') {
    # Change packaging only in the exported source. Retain the original project,
    # signing, IVT, generators, AOT annotations and runtime implementation.
    $centralPath = Join-Path $staged 'Directory.Packages.props'
    [xml]$central = Get-Content -LiteralPath $centralPath -Raw
    foreach ($reference in @($central.SelectNodes('/Project/ItemGroup/GlobalPackageReference'))) {
        $reference.ParentNode.RemoveChild($reference) | Out-Null
    }
    foreach ($package in @($central.SelectNodes('/Project/ItemGroup/PackageVersion'))) {
        if ($package.Include -in @('Microsoft.Extensions.Logging.Abstractions', 'Microsoft.Extensions.DependencyInjection.Abstractions', 'System.Diagnostics.DiagnosticSource')) {
            $package.SetAttribute('Version', '10.0.14')
        }
    }
    $central.Save($centralPath)
    $adjustments = @(
        'Remove global MinVer7.0.0 and StyleCop.Analyzers1.2.0-beta.556 references.'
        'Select archive Logging.Abstractions/DependencyInjection.Abstractions/DiagnosticSource10.0.14 instead of upstream8.0.2/8.0.1.'
        'Build/pack net10.0 only; disable upstream package-baseline validation.'
        'Set package2.6.2, assembly2.0.0.0, file2.6.2.0 and exact repository revision explicitly.'
    )
}
Copy-Item -LiteralPath (Join-Path $staged 'Directory.Packages.props') -Destination (Join-Path $output 'Directory.Packages.props')
'<configuration><packageSources><clear/><add key="ubuntu-source-built" value="/ubuntu-feed"/></packageSources></configuration>' | Set-Content -LiteralPath (Join-Path $output 'NuGet.Config') -Encoding utf8
$inspection = & docker image inspect --platform linux/arm64 $BuilderImage
$inspection | Set-Content -LiteralPath (Join-Path $output 'builder-image.json') -Encoding utf8
$properties = '-p:NuGetAudit=false'
if ($Mode -eq 'UbuntuNet10') {
    $properties += ' -p:TargetFrameworks=net10.0 -p:EnablePackageValidation=false -p:Version=2.6.2 -p:PackageVersion=2.6.2 -p:AssemblyVersion=2.0.0.0 -p:FileVersion=2.6.2.0 -p:RepositoryCommit=' + $sourceCommit
}
$command = @'
set -eu
cd /work/source
printf '%s\n' '=== Archive SDK and installed packages ==='
dotnet --info
dpkg-query -W -f='${binary:Package}\t${Version}\n'
printf '%s\n' '=== Restore exact upstream source ==='
'@
$command += "`ndotnet restore src/MySqlConnector/MySqlConnector.csproj --configfile /work/NuGet.Config $properties`n"
$command += "dotnet pack src/MySqlConnector/MySqlConnector.csproj --no-restore -c Release --output /work/packages $properties`n"
$arguments = @(
    'run', '--rm', '--pull=never', '--network=none', '--platform=linux/arm64',
    '--mount', "type=bind,src=$output,dst=/work",
    '--mount', "type=bind,src=$feed,dst=/ubuntu-feed,readonly",
    '--env', 'DOTNET_CLI_HOME=/tmp/grate-dotnet-home',
    '--env', 'NUGET_PACKAGES=/work/nuget-packages',
    '--env', 'NUGET_HTTP_CACHE_PATH=/tmp/grate-nuget-http',
    '--env', 'NUGET_PLUGINS_CACHE_PATH=/tmp/grate-nuget-plugins',
    '--env', 'DOTNET_CLI_TELEMETRY_OPTOUT=1',
    '--env', 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1',
    $BuilderImage, 'sh', '-c', $command
)
$arguments | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'docker-arguments.json') -Encoding utf8
$PSNativeCommandUseErrorActionPreference = $false
& docker @arguments 2>&1 | Tee-Object -FilePath (Join-Path $output 'build.log') | Out-Host
$buildExitCode = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $true
$producedPackages = @(Get-ChildItem -LiteralPath $output -Recurse -Filter 'MySqlConnector.2.6.2.nupkg')
$packageArtifacts = @(
    foreach ($packageFile in $producedPackages) {
        [ordered]@{
            path = $packageFile.FullName
            sha256 = (Get-FileHash -LiteralPath $packageFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
)
[ordered]@{
    mode = $Mode
    sourceCommit = $sourceCommit
    sourceArchiveSha256 = (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    adjustments = $adjustments
    exitCode = $buildExitCode
    originalProjectSha256 = (Get-FileHash -LiteralPath (Join-Path $staged 'src/MySqlConnector/MySqlConnector.csproj') -Algorithm SHA256).Hash.ToLowerInvariant()
    adjustedCentralPropsSha256 = (Get-FileHash -LiteralPath (Join-Path $staged 'Directory.Packages.props') -Algorithm SHA256).Hash.ToLowerInvariant()
    packages = @($producedPackages | Select-Object -ExpandProperty FullName)
    packageArtifacts = $packageArtifacts
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding utf8
if ($buildExitCode -ne 0) {
    throw "Offline MySqlConnector $Mode attempt failed (exit $buildExitCode). See $output/build.log."
}
