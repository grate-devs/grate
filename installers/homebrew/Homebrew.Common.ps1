function Get-HomebrewDistribution {
    param(
        [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
        [string]$Distribution = 'All'
    )

    $canonicalName = @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle') |
        Where-Object { $_ -eq $Distribution }
    $packageId = if ($canonicalName -eq 'All') {
        'grate'
    } else {
        'grate-' + $canonicalName.ToLowerInvariant()
    }
    $family = @('grate', 'grate-sqlite', 'grate-sqlserver', 'grate-mariadb', 'grate-postgresql', 'grate-oracle')
    $className = ($packageId.Split('-') | ForEach-Object {
        $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1)
    }) -join ''
    [pscustomobject]@{
        Name = $canonicalName
        PackageId = $packageId
        ClassName = $className
        Conflicts = @($family | Where-Object { $_ -cne $packageId })
        Description = if ($canonicalName -eq 'All') { 'SQL scripts migration runner' } else { "SQL scripts migration runner for $canonicalName" }
    }
}

function Write-HomebrewCask {
    param(
        [string]$Version,
        [string]$Arm64Sha256,
        [string]$X64Sha256,
        [string]$Output,
        [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
        [string]$Distribution = 'All',
        [string]$ReleaseTag = $Version
    )

    if ($Version -cnotmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z') {
        throw 'Homebrew only publishes stable SemVer versions.'
    }
    if ($ReleaseTag -cne $Version -and $ReleaseTag -cne "v$Version") {
        throw 'releaseTag must be the version or the version prefixed with v.'
    }
    $Arm64Sha256 = $Arm64Sha256.ToLowerInvariant()
    $X64Sha256 = $X64Sha256.ToLowerInvariant()
    if ($Arm64Sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $X64Sha256 -cnotmatch '\A[0-9a-f]{64}\z') {
        throw 'Invalid SHA-256.'
    }
    $profile = Get-HomebrewDistribution -Distribution $Distribution
    $conflicts = ($profile.Conflicts | ForEach-Object { "    `"$_`"," }) -join "`n"
    $content = @"
cask "$($profile.PackageId)" do
  arch arm: "arm64", intel: "x64"

  version "$Version"
  sha256 arm:   "$Arm64Sha256",
         intel: "$X64Sha256"

  url "https://github.com/grate-devs/grate/releases/download/$ReleaseTag/$($profile.PackageId)-osx-#{arch}-self-contained-#{version}.zip"
  name "$($profile.PackageId)"
  desc "$($profile.Description)"
  homepage "https://grate-devs.github.io/grate/"

  conflicts_with cask: [
$conflicts
  ]
  depends_on :macos

  binary "grate"
end
"@
    # Keep the default All release URL compatible with the existing cask.
    if ($ReleaseTag -ceq $Version) {
        $content = $content.Replace("/download/$ReleaseTag/", '/download/#{version}/')
    }
    $path = [IO.Path]::GetFullPath($Output)
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force | Out-Null
    Set-Content -LiteralPath $path -Value ($content + "`n") -NoNewline -Encoding utf8NoBOM
}
