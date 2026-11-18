function Get-DistributionSourceRevision {
    $revision = (git rev-parse HEAD).Trim()
    if ($revision -cnotmatch '^[a-f0-9]{40}$') {
        throw 'Expected an immutable source revision for distribution artifacts.'
    }
    return $revision
}

function Get-DistributionFrameworks {
    return @((dotnet msbuild src/grate/grate.csproj -nologo -getProperty:TargetFrameworks).Trim() -split ';')
}

function Get-DistributionPayloadFiles {
    param(
        [string]$Directory
    )

    return @(Get-ChildItem -LiteralPath $Directory -Recurse -Force -File |
        Where-Object { $_.FullName -cne (Join-Path $Directory 'manifest.json') } |
        ForEach-Object {
            [pscustomobject]@{
                Path = [IO.Path]::GetRelativePath($Directory, $_.FullName).Replace('\', '/')
                Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        } | Sort-Object Path)
}

function Write-DistributionPayloadManifest {
    param(
        [string]$Directory,
        [hashtable]$Identity
    )

    $files = @(Get-DistributionPayloadFiles -Directory $Directory)
    if ($files.Count -eq 0) {
        throw 'Cannot prepare an empty distribution payload.'
    }
    $manifest = @{
        Schema = 1
        Identity = $Identity
        Files = $files
    }
    $manifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $Directory 'manifest.json') -Encoding utf8NoBOM
}

function Read-DistributionPayloadManifest {
    param(
        [string]$Directory,
        [hashtable]$ExpectedIdentity
    )

    $manifestPath = Join-Path $Directory 'manifest.json'
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Missing prepared payload manifest: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.Schema -ne 1 -or $manifest.Identity -isnot [System.Collections.IDictionary]) {
        throw 'Unsupported prepared payload manifest.'
    }
    foreach ($key in $ExpectedIdentity.Keys) {
        $expected = ConvertTo-Json -InputObject $ExpectedIdentity[$key] -Compress
        $actual = ConvertTo-Json -InputObject $manifest.Identity[$key] -Compress
        if ($actual -cne $expected) {
            throw "Prepared payload identity mismatch for $key."
        }
    }
    if (@($manifest.Files).Count -eq 0) {
        throw 'Prepared payload has no recorded files.'
    }
    $recorded = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($file in $manifest.Files) {
        $relative = [string]$file.Path
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains('\') -or
            @($relative -split '/' | Where-Object { $_ -cin @('', '.', '..') }).Count -gt 0 -or
            $relative -ceq 'manifest.json' -or $recorded.ContainsKey($relative) -or
            [string]$file.Sha256 -cnotmatch '^[A-F0-9]{64}$') {
            throw 'Invalid prepared payload file inventory.'
        }
        $recorded.Add($relative, [string]$file.Sha256)
    }
    $actualFiles = @(Get-DistributionPayloadFiles -Directory $Directory)
    if ($actualFiles.Count -ne $recorded.Count) {
        throw 'Prepared payload file inventory does not match its contents.'
    }
    foreach ($file in $actualFiles) {
        if (!$recorded.ContainsKey($file.Path) -or $recorded[$file.Path] -cne $file.Sha256) {
            throw "Prepared payload integrity mismatch: $($file.Path)"
        }
    }
    return $manifest.Identity
}

function Get-DistributionPayloadIdentity {
    param(
        [string]$Kind,
        [string]$RuntimeIdentifier,
        [string[]]$Frameworks
    )

    return @{
        Kind = $Kind
        SourceRevision = Get-DistributionSourceRevision
        RunId = [string]$env:GITHUB_RUN_ID
        RuntimeIdentifier = $RuntimeIdentifier
        Framework = $Frameworks[-1]
        Frameworks = $Frameworks
        Configuration = 'Release'
    }
}

function Copy-DistributionPayload {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse
}
