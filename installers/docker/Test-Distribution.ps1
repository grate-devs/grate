#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [string]$Image,
    [Parameter(Mandatory)]
    [ValidateSet('SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Distribution,
    [Parameter(Mandatory)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) {
    throw 'Use a fresh profile verification directory.'
}
New-Item -ItemType Directory -Path $output | Out-Null
$help = docker run --rm --entrypoint /app/grate $Image --help | Out-String
if (!$help.Contains("This build supports $Distribution only.")) {
    throw "Image is not the selected $Distribution distribution."
}
$other = if ($Distribution -eq 'SQLite') { 'postgresql' } else { 'sqlite' }
try {
    $PSNativeCommandUseErrorActionPreference = $false
    $rejection = docker run --rm --entrypoint /app/grate $Image --databasetype $other --connectionstring invalid --silent 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or !$rejection.Contains("This build supports $Distribution only.")) {
        throw "Image did not reject unsupported provider $other."
    }
} finally {
    $PSNativeCommandUseErrorActionPreference = $true
}
$arguments = @(
    'run', '--rm', '-v', "${output}:/verification", '--entrypoint', '/app/grate',
    $Image, 'skills', 'install', '--local', '--path', '/verification'
)
docker @arguments
if (!(Test-Path -LiteralPath "$output/.agents/skills/use-grate/SKILL.md")) {
    throw 'Image did not install its bundled skill.'
}
Write-Host "PASS: native $Distribution image help, unsupported-provider rejection and bundled skill."
