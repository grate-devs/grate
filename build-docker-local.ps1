#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$Platform = 'linux/amd64,linux/arm64',
    [switch]$Amd64,
    [switch]$Arm64,
    [switch]$Load
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if (($Amd64 -and $Arm64) -or (($Amd64 -or $Arm64) -and $PSBoundParameters.ContainsKey('Platform'))) {
    throw 'Choose -Platform, -Amd64 or -Arm64.'
}
$loadImage = $Load -or $Amd64 -or $Arm64 -or $PSBoundParameters.ContainsKey('Platform')
if ($Amd64) { $Platform = 'linux/amd64' }
if ($Arm64) { $Platform = 'linux/arm64' }
if ($Platform.StartsWith('-')) { throw '-Platform requires a value.' }
if ($loadImage -and $Platform.Contains(',')) { throw '-Load requires a single platform; use -Amd64 or -Arm64.' }

function Invoke-BuildDocker([string[]]$Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker failed with exit code $LASTEXITCODE." }
}
Push-Location $PSScriptRoot
try {
    $version = '1.0.0-local'
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        Write-Host 'Attempting to get version using GitVersion...'
        try {
            $tools = & dotnet tool list -g 2>$null
            if ($LASTEXITCODE -eq 0 -and ($tools -join "`n") -match 'gitversion\.tool') {
                $candidate = & dotnet gitversion /showvariable SemVer 2>$null
                if ($LASTEXITCODE -eq 0) { $version = ($candidate -join "`n").Trim() }
            }
        } catch { Write-Host 'GitVersion unavailable. Using default version.' }
    }
    Write-Host "Building Docker image with version: $version"
    Write-Host "Platform(s): $Platform"
    $tags = @(& "$PSScriptRoot/installers/docker/release_tags.ps1" -Version $version)
    $builders = Invoke-BuildDocker @('buildx','ls')
    if (($builders -join "`n") -notmatch 'multiarch-builder') {
        Invoke-BuildDocker @('buildx','create','--name','multiarch-builder','--use')
    } else { Invoke-BuildDocker @('buildx','use','multiarch-builder') }
    $buildArguments = @('buildx','build','--pull','--file','./installers/docker/Dockerfile','--platform',$Platform,'--build-arg',"VERSION=$version")
    foreach ($tag in $tags) { $buildArguments += @('--tag',$tag) }
    if ($loadImage) { $buildArguments += '--load' }
    Invoke-BuildDocker ($buildArguments + '.')
    Write-Host 'Build completed successfully!'
    foreach ($tag in $tags) { Write-Host "  - $tag" }
    if ($loadImage) { Write-Host "Test: docker run --rm --platform $Platform --entrypoint ./grate $($tags[0]) --help" }
    else { Write-Host 'Rebuild with -Amd64 or -Arm64 to load and run the image locally.' }
} finally { Pop-Location }
