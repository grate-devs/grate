#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('grate-cask-' + [guid]::NewGuid().ToString('N'))
$pwsh = (Get-Process -Id $PID).Path

try {
    $output = Join-Path $temporary 'nested/grate.rb'
    $arm64Checksum = 'A' * 64
    $x64Checksum = 'b' * 64
    $caskArguments = @{
        Version = '2.3.4'
        Arm64Sha256 = $arm64Checksum
        X64Sha256 = $x64Checksum
        Output = $output
    }

    & $pwsh -NoLogo -NoProfile -File "$PSScriptRoot/update_homebrew_cask.ps1" @caskArguments
    if ($LASTEXITCODE -ne 0) {
        throw 'Cask generation failed.'
    }

    $content = Get-Content -LiteralPath $output -Raw
    $expectedFragments = @(
        'version "2.3.4"'
        ('sha256 arm:   "' + ('a' * 64) + '"')
        ('intel: "' + $x64Checksum + '"')
        'releases/download/#{version}/grate-osx-#{arch}-self-contained-#{version}.zip'
        'binary "grate"'
    )
    foreach ($expected in $expectedFragments) {
        if (!$content.Contains($expected)) {
            throw "Cask missing expected release value: $expected"
        }
    }

    $bytes = [IO.File]::ReadAllBytes($output)
    if ($content.Contains("`r") -or $bytes[0] -ne [byte][char]'c' -or !$content.EndsWith("end`n")) {
        throw 'Cask must be UTF-8 without BOM and use LF newlines.'
    }

    foreach ($version in @('2.3.4-rc.1', 'v2.3.4', '2.3.4+build')) {
        $caskArguments.Version = $version
        & $pwsh -NoLogo -NoProfile -File "$PSScriptRoot/update_homebrew_cask.ps1" @caskArguments *> $null
        if ($LASTEXITCODE -eq 0 -or (Get-Content -LiteralPath $output -Raw) -cne $content) {
            throw "Invalid version '$version' must fail without overwriting the cask."
        }
    }

    $caskArguments.Version = '2.3.4'
    foreach ($checksum in @('bad', ('g' * 64), ('a' * 63))) {
        $caskArguments.Arm64Sha256 = $checksum
        & $pwsh -NoLogo -NoProfile -File "$PSScriptRoot/update_homebrew_cask.ps1" @caskArguments *> $null
        if ($LASTEXITCODE -eq 0 -or (Get-Content -LiteralPath $output -Raw) -cne $content) {
            throw 'Invalid checksum must fail without overwriting the cask.'
        }
    }
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: Homebrew CLI version/hash validation, rendered release values and file encoding.'
