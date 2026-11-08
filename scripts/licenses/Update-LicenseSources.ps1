#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)] [string]$InventoryFile
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/SourceTextPaths.ps1"
$verifiedSources = Get-Content -LiteralPath "$PSScriptRoot/verified-sources.json" -Raw | ConvertFrom-Json -AsHashtable
$inventory = Get-Content -LiteralPath $InventoryFile -Raw | ConvertFrom-Json -AsHashtable
$cachePath = Join-Path $PSScriptRoot 'sources.json'
$cache = [Collections.Generic.SortedDictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $cachePath) {
    $old = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($entry in $old.GetEnumerator()) {
        $cache[$entry.Key] = $entry.Value
    }
}
$requests = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$failures = @()
$directory = Join-Path $PSScriptRoot 'text'
New-Item -ItemType Directory -Path $directory -Force | Out-Null

function Get-SourceText {
    param (
        [string]$Url,
        [string]$PackageKey
    )

    if (!$requests.ContainsKey($Url)) {
        $response = Invoke-WebRequest -Uri $Url -SkipHttpErrorCheck
        if ($response.StatusCode -eq 404) {
            $requests[$Url] = $null
        }
        elseif ($response.StatusCode -ne 200) {
            throw "License source returned HTTP $($response.StatusCode): $Url"
        }
        else {
            $content = [string]$response.Content
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($content))).ToLowerInvariant()
            $path = Get-LicenseSourceRelativePath -Url $Url -PackageKey $PackageKey -Sha256 $hash -SourceDirectory $PSScriptRoot
            New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $PSScriptRoot $path)) -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $PSScriptRoot $path), $content, [Text.UTF8Encoding]::new($false))
            $requests[$Url] = [ordered]@{
                url = $Url
                file = $path
                sha256 = $hash
            }
        }
    }
    return $requests[$Url]
}

foreach ($package in $inventory) {
    if ($package.evidence -ne 'missing-source') {
        continue
    }
    $key = "$($package.id)/$($package.version)"
    if ($cache.ContainsKey($key) -and $cache[$key].repositoryCommit -ceq $package.repositoryCommit) {
        continue
    }
    $repository = $package.repository -replace '\.git$', ''
    $revision = $package.repositoryCommit
    # Some active dependencies predate source-revision metadata. Their verified
    # revisions, provenance and product/test/example roles live in reviewed data.
    if ($verifiedSources.ContainsKey($key)) {
        $verified = $verifiedSources[$key]
        if ($verified.repository) {
            $repository = $verified.repository
        }
        $revision = $verified.revision
    }
    if ($repository -notmatch '^https://github.com/([^/]+/[^/]+)/?$' -or !$revision) {
        $failures += $key
        Write-Warning "No exact upstream source revision for $key."
        continue
    }
    $base = "https://raw.githubusercontent.com/$($Matches[1])/$revision"
    $texts = @()
    foreach ($name in @('LICENSE.TXT', 'LICENSE', 'LICENSE.txt', 'License.txt', 'license.txt', 'LICENSE.md', 'License.md', 'LICENSE-MIT')) {
        $found = Get-SourceText -Url "$base/$name" -PackageKey $key
        if ($found) {
            $texts += $found
            break
        }
    }
    if (!$texts.Count) {
        $failures += $key
        Write-Warning "No upstream license found for $key at $revision."
        continue
    }
    foreach ($name in @('NOTICE', 'NOTICE.txt', 'NOTICE.TXT')) {
        $found = Get-SourceText -Url "$base/$name" -PackageKey $key
        if ($found) {
            $texts += $found
        }
    }
    if ($package.license -eq 'Apache-2.0') {
        # Some upstream files identify Apache-2.0 by link; reproduce its full terms too.
        $texts += Get-SourceText -Url 'https://www.apache.org/licenses/LICENSE-2.0.txt' -PackageKey $key
    }
    $cache[$key] = [ordered]@{
        repositoryCommit = $package.repositoryCommit
        sourceRevision = $revision
        texts = $texts
    }
    Write-Host "Cached original license/notice sources for $key."
}
[IO.File]::WriteAllText($cachePath, (ConvertTo-Json -InputObject $cache -Depth 10) + "`n", [Text.UTF8Encoding]::new($false))
if ($failures.Count) {
    throw "Original license evidence still missing for: $($failures -join ', ')"
}
