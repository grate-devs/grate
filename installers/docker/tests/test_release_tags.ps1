#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../release_tags.ps1"
function Assert-Tags($Actual, $Expected) {
    if (($Actual -join "`n") -cne ($Expected -join "`n")) { throw "Incorrect image tags: $Actual" }
}
Assert-Tags @(Get-ImageTags '2.3.4') @('gratedevs/grate:2.3.4','gratedevs/grate:latest','erikbra/grate:2.3.4','erikbra/grate:latest')
Assert-Tags @(Get-ImageTags 'v2.3.4') @(Get-ImageTags '2.3.4')
foreach ($version in @('2.3.4-alpha','v2.3.4-rc.1','2.3.4-0','2.3.4-01a')) {
    $normalized = $version -creplace '^v',''
    Assert-Tags @(Get-ImageTags $version) @("gratedevs/grate:$normalized","erikbra/grate:$normalized")
}
Assert-Tags @(Get-ImageTags '2.3.4' $true) @('gratedevs/grate:2.3.4','erikbra/grate:2.3.4')
foreach ($version in @('', 'latest', 'V2.3.4', '2.3', '02.3.4', '2.03.4', '2.3.04', '2.3.4-01', '2.3.4-rc.01', '2.3.4-', '2.3.4-rc..1', '2.3.4+build.1', '2.3.4-rc.1+build.2', ' 2.3.4', '2.3.4 ', "2.3.4`nlatest", "2.3.4`ntags<<EOF`nother/repository:latest`nEOF", '2.3.4;echo injected', '$(echo 2.3.4)', '2.3.4/other', '2.3.4-æ', ('2.3.4-' + ('a' * 123)))) {
    $rejected = $false
    try { $null = Get-ImageTags $version } catch { $rejected = $true }
    if (!$rejected) { throw "Accepted invalid version: $version" }
}
if ((Get-NormalizedDockerVersion ('2.3.4-' + ('a' * 122))).Length -ne 128) { throw 'Rejecting valid maximum-length Docker tag.' }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('grate-tag-tests-' + [guid]::NewGuid().ToString('N'))
$pwsh = (Get-Process -Id $PID).Path
try {
    $null = New-Item -ItemType Directory -Path $temporary
    $output = "$temporary/github-output"
    [IO.File]::WriteAllText($output, "existing=retained`n")
    $tags = & $pwsh -NoLogo -NoProfile -File "$PSScriptRoot/../release_tags.ps1" -Version v2.3.4 -Prerelease -GithubOutput $output
    if ($LASTEXITCODE -ne 0) { throw 'Prerelease CLI failed.' }
    Assert-Tags $tags @('gratedevs/grate:2.3.4','erikbra/grate:2.3.4')
    $expected = @'
existing=retained
version=2.3.4
is-prerelease=true
tags<<GRATE_DOCKER_TAGS
gratedevs/grate:2.3.4
erikbra/grate:2.3.4
GRATE_DOCKER_TAGS
canonical-tags<<GRATE_DOCKER_TAGS
gratedevs/grate:2.3.4
GRATE_DOCKER_TAGS
compatibility-tags<<GRATE_DOCKER_TAGS
erikbra/grate:2.3.4
GRATE_DOCKER_TAGS
'@
    if ([IO.File]::ReadAllText($output) -cne ($expected.Replace("`r`n","`n") + "`n")) { throw 'Incorrect appended GitHub multiline outputs.' }
    Remove-Item -LiteralPath $output
    $tags = & $pwsh -NoLogo -NoProfile -File "$PSScriptRoot/../release_tags.ps1" -Version 2.3.4 -GithubOutput $output
    if ($LASTEXITCODE -ne 0) { throw 'Stable CLI failed.' }
    $content = [IO.File]::ReadAllText($output)
    foreach ($repository in @('gratedevs/grate','erikbra/grate')) {
        if (!$content.Contains("${repository}:2.3.4`n${repository}:latest`nGRATE_DOCKER_TAGS`n")) { throw 'Stable outputs lost latest or mixed publishing identities.' }
    }
    Remove-Item -LiteralPath $output
    $invalidOutput = & $pwsh -NoLogo -NoProfile -File "$PSScriptRoot/../release_tags.ps1" -Version latest -GithubOutput $output 2>$null
    if ($LASTEXITCODE -eq 0 -or $invalidOutput -or (Test-Path -LiteralPath $output)) { throw 'Invalid version must fail without stdout or outputs.' }
} finally { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'PASS: Docker tag versions, prerelease boundaries, length limits and CLI GitHub outputs.'
