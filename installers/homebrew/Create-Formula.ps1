#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+\z')]
    [string]$version,
    [Parameter(Mandatory)]
    [string]$sourceArchive,
    [string]$releaseTag = $version,
    [string]$outputPath,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../../artifacts/homebrew/formula'),
    [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Distribution = 'All',
    [switch]$AllDistributions
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Homebrew.Common.ps1"
if ($releaseTag -cne $version -and $releaseTag -cne "v$version") {
    throw 'releaseTag must be the version or the version prefixed with v.'
}
if ($AllDistributions -and ($outputPath -or $Distribution -ne 'All')) {
    throw 'Use OutputDirectory and the default Distribution with AllDistributions.'
}
if (!(Test-Path -LiteralPath $sourceArchive -PathType Leaf)) {
    throw "Source archive does not exist: $sourceArchive"
}
if (![string]::Equals([IO.Path]::GetExtension($sourceArchive), '.gz', [StringComparison]::OrdinalIgnoreCase) -or
    ![string]::Equals([IO.Path]::GetExtension([IO.Path]::GetFileNameWithoutExtension($sourceArchive)), '.tar', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'sourceArchive must be the downloaded source .tar.gz archive.'
}

function Get-FormulaTest {
    param(
        [string]$Distribution
    )

    $test = if ($Distribution -in @('All', 'SQLite')) {
        @'
    scripts = testpath/"scripts/up"
    scripts.mkpath
    (scripts/"001_create_widgets.sql").write <<~SQL
      CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
      INSERT INTO widgets VALUES (1, 'grate');
      CREATE TEMP TABLE checked (value INTEGER CHECK(value = 1));
      INSERT INTO checked SELECT CASE WHEN COUNT(*) = 1 AND MIN(id) = 1 THEN 1 ELSE 0 END FROM widgets;
    SQL

    database = testpath/"grate-test.db"
    2.times do
      system bin/"grate",
             "--connectionstring", "Data Source=#{database}",
             "--databasetype", "sqlite",
             "--sqlfilesdirectory", testpath/"scripts",
             "--output", testpath/"output",
             "--version", version.to_s,
             "--silent"
    end
    assert_path_exists database
    assert_predicate database, :size?
'@
    } else {
        # Server-backed migrations run in provider CI. The portable Homebrew
        # test verifies compiled selection without requiring a database server.
        @'
    assert_match "This build supports @DISTRIBUTION@ only.", shell_output("#{bin}/grate --help")
    rejected = shell_output("#{bin}/grate --databasetype sqlite --connectionstring invalid --silent 2>&1", 1)
    assert_match "This build supports @DISTRIBUTION@ only.", rejected
'@
    }
    $test += @'

    system bin/"grate", "skills", "install", "--local", "--path", testpath/"skill"
    assert_path_exists testpath/"skill/.agents/skills/use-grate/SKILL.md"
'@
    $test.Replace('@DISTRIBUTION@', $Distribution)
}

# Hash the downloaded source archive shared by all source-built variants.
$sourceHash = (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'grate.rb.in') -Raw
$profiles = if ($AllDistributions) {
    @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')
} else {
    @($Distribution)
}
foreach ($name in $profiles) {
    $profile = Get-HomebrewDistribution -Distribution $name
    $conflicts = ($profile.Conflicts | ForEach-Object {
        "  conflicts_with `"$_`", because: `"both install the grate command`""
    }) -join "`n"
    $replacements = @{
        '@RELEASE_TAG@' = $releaseTag
        '@SOURCE_SHA256@' = $sourceHash
        '@FORMULA_CLASS@' = $profile.ClassName
        '@DESCRIPTION@' = $profile.Description
        '@DISTRIBUTION@' = $profile.Name
        '@CONFLICTS@' = $conflicts
        '@TEST_BODY@' = Get-FormulaTest -Distribution $profile.Name
    }
    $formula = $template
    foreach ($key in $replacements.Keys) {
        $formula = $formula.Replace($key, $replacements[$key])
    }
    if ($formula -match '@[A-Z_]+@') {
        throw 'The formula template contains unresolved placeholders.'
    }
    $destination = if ($outputPath) { $outputPath } else { Join-Path $OutputDirectory "$($profile.PackageId).rb" }
    $destination = [IO.Path]::GetFullPath($destination)
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
    Set-Content -LiteralPath $destination -Value $formula -NoNewline -Encoding utf8NoBOM
    Write-Host "Generated source-built formula: $destination"
}
