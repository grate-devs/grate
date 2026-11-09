#!/usr/bin/env pwsh
# Keep stdout attached to the runner for groups, progress and annotations.
param(
    [Parameter(Mandatory, Position = 0)][string]$Grate,
    [Parameter(ValueFromRemainingArguments)][string[]]$CommandArguments
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('grate-ci-logging-' + [guid]::NewGuid().ToString('N'))

try {
    $null = New-Item -ItemType Directory -Path "$scratch/sql/up" -Force
    $null = New-Item -ItemType Directory -Path "$scratch/sql/views" -Force
    $options = @(
        '--databasetype=sqlite'
        "--connectionstring=Data Source=$scratch/example.db"
        "--files=$scratch/sql"
        "--output=$scratch/output"
        '--silent'
    )

    Set-Content -LiteralPath "$scratch/sql/up/01-create.sql" -Value "CREATE TABLE example (id INTEGER);`n" -Encoding utf8NoBOM -NoNewline
    Set-Content -LiteralPath "$scratch/sql/views/example_view.sql" -Value "CREATE VIEW example_view AS SELECT id FROM example;`n" -Encoding utf8NoBOM -NoNewline
    & $Grate @CommandArguments @options --transaction
    if ($LASTEXITCODE -ne 0) {
        throw "Initial SQLite migration failed with exit code $LASTEXITCODE."
    }

    # The failed folder must close its group and progress without reporting success.
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
