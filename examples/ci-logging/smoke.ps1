#!/usr/bin/env pwsh
# Keep stdout attached to the runner so it can interpret grate's annotations.
param(
    [Parameter(Mandatory, Position = 0)][string]$Grate,
    [Parameter(ValueFromRemainingArguments)][string[]]$CommandArguments
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('grate-ci-logging-' + [guid]::NewGuid().ToString('N'))

try {
    $null = New-Item -ItemType Directory -Path "$scratch/sql/up" -Force
    $options = @(
        '--databasetype=sqlite'
        "--connectionstring=Data Source=$scratch/example.db"
        "--files=$scratch/sql"
        "--output=$scratch/output"
        '--silent'
    )

    Set-Content -LiteralPath "$scratch/sql/up/01-create.sql" -Value "CREATE TABLE example (id INTEGER);`n" -Encoding utf8NoBOM -NoNewline
    & $Grate @CommandArguments @options --transaction
    if ($LASTEXITCODE -ne 0) {
        throw "Initial SQLite migration failed with exit code $LASTEXITCODE."
    }

    Set-Content -LiteralPath "$scratch/sql/up/02-failure.sql" -Value "SELECT * FROM missing_table;`n" -Encoding utf8NoBOM -NoNewline
    & $Grate @CommandArguments @options
    if ($LASTEXITCODE -ne 1) {
        throw "Expected exit code 1 from the failing SQLite migration, got $LASTEXITCODE."
    }

    # The intentional migration failure is the expected result of this check.
    $global:LASTEXITCODE = 0
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
