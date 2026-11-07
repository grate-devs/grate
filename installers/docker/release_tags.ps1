#!/usr/bin/env pwsh
[CmdletBinding()]
param([Parameter(Position=0)][string]$Version, [switch]$Prerelease, [string]$GithubOutput)
. "$PSScriptRoot/../../scripts/release/release_common.ps1"

function Get-NormalizedDockerVersion([string]$Value) {
    if ($Value -cnotmatch "\Av?($script:SemVerPattern)\z") { throw "Version must be SemVer without build metadata (optional 'v' prefix)." }
    $normalized = $Matches[1]
    if ($normalized.Length -gt 128) { throw "Version exceeds Docker's 128-character tag limit." }
    $normalized
}
function Get-ImageTags([string]$Value, [bool]$IsPrerelease = $false) {
    $normalized = Get-NormalizedDockerVersion $Value
    $tags = if ($IsPrerelease -or $normalized.Contains('-')) { @($normalized) } else { @($normalized, 'latest') }
    foreach ($repository in @('gratedevs/grate','erikbra/grate')) { foreach ($tag in $tags) { "${repository}:$tag" } }
}
function Invoke-ReleaseTags([string]$Value, [bool]$IsPrerelease, [string]$OutputPath) {
    $normalized = Get-NormalizedDockerVersion $Value
    $IsPrerelease = $IsPrerelease -or $normalized.Contains('-')
    $tags = @(Get-ImageTags $normalized $IsPrerelease)
    if ($OutputPath) {
        $content = "version=$normalized`nis-prerelease=$($IsPrerelease.ToString().ToLowerInvariant())`n"
        $content += "tags<<GRATE_DOCKER_TAGS`n$($tags -join "`n")`nGRATE_DOCKER_TAGS`n"
        foreach ($entry in @(@('canonical-tags','gratedevs/grate'),@('compatibility-tags','erikbra/grate'))) {
            $selected = @($tags | Where-Object { $_.StartsWith($entry[1] + ':', [StringComparison]::Ordinal) })
            $content += "$($entry[0])<<GRATE_DOCKER_TAGS`n$($selected -join "`n")`nGRATE_DOCKER_TAGS`n"
        }
        [IO.File]::AppendAllText($OutputPath, $content, [Text.UTF8Encoding]::new($false))
    }
    $tags
}
if ($MyInvocation.InvocationName -ne '.') { Invoke-ReleaseTags $Version $Prerelease.IsPresent $GithubOutput }
