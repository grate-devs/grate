function Get-LicenseSourceRelativePath {
    param (
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$PackageKey,
        [Parameter(Mandatory)] [ValidatePattern('^[a-fA-F0-9]{64}$')] [string]$Sha256,
        [Parameter(Mandatory)] [string]$SourceDirectory
    )

    if ($Url -match '^https://raw\.githubusercontent\.com/([a-zA-Z0-9_.-]+)/([a-zA-Z0-9_.-]+)/[^/]+/([^/]+)$') {
        $owner = $Matches[1].ToLowerInvariant()
        $repository = $Matches[2].ToLowerInvariant()
        if ($owner -in @('.', '..') -or $repository -in @('.', '..')) {
            throw "Invalid upstream repository path: $Url"
        }
        $name = [IO.Path]::GetFileNameWithoutExtension($Matches[3]).ToLowerInvariant()
        if ($name -notmatch '^[a-zA-Z0-9_-]+$') {
            throw "Invalid upstream license filename: $Url"
        }
        $directory = "text/$owner/$repository"
    }
    elseif ($Url -ceq 'https://www.apache.org/licenses/LICENSE-2.0.txt') {
        $directory = 'text/apache'
        $name = 'license-2.0'
    }
    else {
        throw "No reviewed license-text path convention for: $Url"
    }

    $relative = "$directory/$name.txt"
    $path = Join-Path $SourceDirectory $relative
    if ((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path).Hash -ine $Sha256) {
        # Keep different historical texts; never overwrite a retained notice.
        $variant = ($PackageKey -replace '[^a-zA-Z0-9_.-]', '-').ToLowerInvariant()
        $relative = "$directory/$name-$variant.txt"
        $path = Join-Path $SourceDirectory $relative
        if ((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path).Hash -ine $Sha256) {
            throw "License text path collision: $relative"
        }
    }
    return $relative
}
