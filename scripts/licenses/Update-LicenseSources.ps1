#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)] [string]$InventoryFile
)

$ErrorActionPreference = 'Stop'
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
    param ([string]$Url)

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
            $path = "text/$hash.txt"
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
    # A tag can identify source for old packages whose nuspec predates SourceLink.
    if ($key -eq 'Mono.Cecil/0.11.6') {
        $repository = 'https://github.com/jbevain/cecil'
        $revision = '0.11.6'
    }
    elseif ($key -eq 'SQLitePCLRaw.bundle_e_sqlite3/3.0.5') {
        $revision = 'v3.0.5'
    }
    elseif ($key -eq 'Microsoft.SqlServer.Server/1.0.0') {
        # AssemblyInformationalVersion in the exact NuGet DLL identifies this commit.
        $revision = '54ab5aef2e1b74c0971a00711fecb003b624efdf'
    }
    elseif ($key -eq 'Microsoft.Data.SqlClient/5.1.5') {
        # Historical example dependency: exact DLL AssemblyInformationalVersion.
        $revision = '01a589e54afe43c85c7607aa05f8605fa6f13bb3'
    }
    elseif ($key -eq 'Microsoft.Data.SqlClient/5.2.2') {
        $revision = 'a98592718693168af42ec4af3eb974d58497373e'
    }
    if ($repository -notmatch '^https://github.com/([^/]+/[^/]+)/?$' -or !$revision) {
        $failures += $key
        Write-Warning "No exact upstream source revision for $key."
        continue
    }
    $base = "https://raw.githubusercontent.com/$($Matches[1])/$revision"
    $texts = @()
    foreach ($name in @('LICENSE.TXT', 'LICENSE', 'LICENSE.txt', 'License.txt', 'license.txt', 'LICENSE.md', 'License.md', 'LICENSE-MIT')) {
        $found = Get-SourceText "$base/$name"
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
        $found = Get-SourceText "$base/$name"
        if ($found) {
            $texts += $found
        }
    }
    if ($package.license -eq 'Apache-2.0') {
        # Some upstream files identify Apache-2.0 by link; reproduce its full terms too.
        $texts += Get-SourceText 'https://www.apache.org/licenses/LICENSE-2.0.txt'
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
