#!/usr/bin/env pwsh
# Run from this example's directory, including when invoked elsewhere.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Push-Location $PSScriptRoot
try {
    & docker compose up --build
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose failed with exit code $LASTEXITCODE." }
    & docker compose down
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose cleanup failed with exit code $LASTEXITCODE." }
} finally { Pop-Location }
