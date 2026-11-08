#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceDirectory,
    [Parameter(Mandatory)]
    [string]$UbuntuFeedDirectory,
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    [ValidateSet('Upstream', 'Archive')]
    [string]$Mode = 'Archive',
    [ValidateSet('arm64', 'amd64')]
    [string]$Architecture = 'arm64',
    [string]$BuilderImage = 'grate-ubuntu-source:26.04'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$revision = 'eb47546a408bbf6c178bda4f04dc205bc51ffbfe'
$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$feed = (Resolve-Path -LiteralPath $UbuntuFeedDirectory).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) {
    throw 'Use a new OutputDirectory; existing evidence is never replaced.'
}
if ((& git -C $source rev-parse HEAD).Trim() -cne $revision) {
    throw "Expected Dapper 2.1.89 source revision $revision."
}
New-Item -ItemType Directory -Path $output | Out-Null
$tarball = Join-Path $output 'source.tar'
& git -C $source archive --format=tar "--output=$tarball" $revision
$build = Join-Path $output 'source'
New-Item -ItemType Directory -Path $build | Out-Null
& tar -xf $tarball -C $build
$modifiedFiles = @()

# Only packaging XML changes; committed runtime sources are exported verbatim.
if ($Mode -eq 'Archive') {
    $removals = [ordered]@{
        'Directory.Build.props' = @('Microsoft.NETFramework.ReferenceAssemblies', 'Microsoft.SourceLink.GitHub', 'Nerdbank.GitVersioning')
        'Directory.Packages.props' = @('ReferenceTrimmer')
        'Dapper/Dapper.csproj' = @('Microsoft.CodeAnalysis.PublicApiAnalyzers')
    }
    foreach ($relative in $removals.Keys) {
        $file = Join-Path $build $relative
        $original = Join-Path $output "original/$relative"
        New-Item -ItemType Directory -Path (Split-Path -Parent $original) -Force | Out-Null
        Copy-Item -LiteralPath $file -Destination $original
        $document = [xml]::new()
        $document.PreserveWhitespace = $true
        $document.Load($file)
        foreach ($name in $removals[$relative]) {
            $nodes = @($document.SelectNodes("//PackageReference[@Include='$name'] | //GlobalPackageReference[@Include='$name']"))
            if ($nodes.Count -ne 1) {
                throw "Expected exactly one build-only reference $name in $relative."
            }
            [void]$nodes[0].ParentNode.RemoveChild($nodes[0])
        }
        if ($relative -eq 'Dapper/Dapper.csproj') {
            $group = $document.CreateElement('ItemGroup')
            $license = $document.CreateElement('None')
            $license.SetAttribute('Include', '../License.txt')
            $license.SetAttribute('Pack', 'true')
            $license.SetAttribute('PackagePath', '/')
            [void]$group.AppendChild($license)
            [void]$document.Project.AppendChild($group)
        }
        $document.Save($file)
        $modifiedFiles += $relative
        $PSNativeCommandUseErrorActionPreference = $false
        & git diff --no-index -- $original $file |
            Add-Content -LiteralPath (Join-Path $output 'packaging-changes.patch') -Encoding utf8
        $diffExit = $LASTEXITCODE
        $PSNativeCommandUseErrorActionPreference = $true
        if ($diffExit -gt 1) {
            throw "Could not record packaging changes to $relative."
        }
    }
}

'<configuration><packageSources><clear/><add key="ubuntu" value="/ubuntu-feed"/></packageSources></configuration>' |
    Set-Content -LiteralPath (Join-Path $output 'NuGet.Config') -Encoding utf8
& docker image inspect --platform "linux/$Architecture" $BuilderImage |
    Set-Content -LiteralPath (Join-Path $output 'builder-image.json') -Encoding utf8
[ordered]@{
    dependency = 'Dapper'
    version = '2.1.89'
    sourceRepository = 'https://github.com/DapperLib/Dapper'
    sourceRevision = $revision
    sourceArchiveSha256 = (Get-FileHash -LiteralPath $tarball -Algorithm SHA256).Hash.ToLowerInvariant()
    mode = $Mode
    modifiedPackagingFiles = $modifiedFiles
    targetFramework = 'net10.0'
    assemblyVersion = '2.0.0.0'
    architecture = $Architecture
    inputFeed = 'Read-only Ubuntu SDK source-built artifacts'
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'source-origin.json') -Encoding utf8
$command = @'
set -eu
cd /
test "$(dotnet --version)" = '10.0.114'
dotnet --info
dpkg-query -W -f='${binary:Package}\t${Version}\n'
dotnet restore /work/Dapper/Dapper.csproj -p:TargetFrameworks=net10.0 -p:NuGetAudit=false --packages /evidence/nuget-packages --configfile /evidence/NuGet.Config
dotnet build /work/Dapper/Dapper.csproj --no-restore -c Release -p:TargetFrameworks=net10.0 -p:Version=2.1.89 -p:AssemblyVersion=2.0.0.0 -p:FileVersion=2.1.89.0 -p:RepositoryCommit=eb47546a408bbf6c178bda4f04dc205bc51ffbfe
dotnet pack /work/Dapper/Dapper.csproj --no-build --no-restore -c Release -p:TargetFrameworks=net10.0 -p:Version=2.1.89 -p:AssemblyVersion=2.0.0.0 -p:FileVersion=2.1.89.0 -p:RepositoryCommit=eb47546a408bbf6c178bda4f04dc205bc51ffbfe -o /evidence/packages-built
'@
$arguments = @(
    'run', '--rm', '--pull=never', '--network=none', '--platform', "linux/$Architecture",
    '--mount', "type=bind,src=$build,dst=/work",
    '--mount', "type=bind,src=$output,dst=/evidence",
    '--mount', "type=bind,src=$feed,dst=/ubuntu-feed,readonly",
    '--env', 'DOTNET_CLI_HOME=/evidence/dotnet-home',
    '--env', 'NUGET_PACKAGES=/evidence/nuget-packages',
    '--env', 'NUGET_HTTP_CACHE_PATH=/evidence/http-cache',
    '--env', 'NUGET_PLUGINS_CACHE_PATH=/evidence/plugins-cache',
    '--env', 'DOTNET_CLI_TELEMETRY_OPTOUT=1',
    '--env', 'DOTNET_GENERATE_ASPNET_CERTIFICATE=false',
    $BuilderImage, 'sh', '-ec', $command
)
$arguments | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'docker-arguments.json') -Encoding utf8
$PSNativeCommandUseErrorActionPreference = $false
& docker @arguments 2>&1 | Tee-Object -FilePath (Join-Path $output 'build.log') | Out-Host
$buildExit = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $true
[ordered]@{
    exitCode = $buildExit
    packageProduced = Test-Path -LiteralPath (Join-Path $output 'packages-built/Dapper.2.1.89.nupkg')
    scope = 'net10.0 packaging adaptation; not an upstream release reproduction or archive approval'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding utf8
if ($buildExit -ne 0) {
    throw "Dapper $Mode source build failed (exit $buildExit); see $output/build.log."
}
