#!/usr/bin/env pwsh

$ErrorActionPreference = 'Stop'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('grate-homebrew-' + [Guid]::NewGuid().ToString('N'))
$fixtureScripts = Join-Path $fixtureRoot 'installers/homebrew'
$formulaOutput = Join-Path $fixtureRoot 'artifacts/homebrew/formula/grate.rb'
$caskOutput = Join-Path $fixtureRoot 'artifacts/homebrew/cask/grate.rb'
$sourceArchive = Join-Path $fixtureRoot '2.2.0.tar.gz'
$abcHash = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
$helloHash = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'

function Assert-Contains([string]$Actual, [string]$Expected) {
    if (!$Actual.Contains($Expected)) { throw "Missing expected output: $Expected" }
}

function Assert-Rejected([scriptblock]$Action, [string]$Output = $formulaOutput, [string]$Expected = $script:publishedFormula, [string]$ExpectedErrorId = '') {
    $rejected = $false
    try { & $Action } catch {
        if ($ExpectedErrorId -and $_.FullyQualifiedErrorId -notlike $ExpectedErrorId) {
            throw "Expected $ExpectedErrorId, got $($_.FullyQualifiedErrorId)."
        }
        $rejected = $true
    }
    if (!$rejected) { throw 'Expected invalid input to be rejected.' }
    if ((Get-Content -LiteralPath $Output -Raw) -cne $Expected) {
        throw 'Rejected input changed the existing output.'
    }
}

try {
    $null = New-Item -ItemType Directory -Path $fixtureScripts -Force
    foreach ($name in @('Create-Formula.ps1', 'Create-Cask.ps1', 'grate.rb.in')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $fixtureScripts
    }
    $generator = Join-Path $fixtureScripts 'Create-Formula.ps1'
    $caskGenerator = Join-Path $fixtureScripts 'Create-Cask.ps1'
    # Known byte strings isolate checksum/rendering checks from network access.
    # These fixtures do not claim to be valid Grate release archives.
    [IO.File]::WriteAllText($sourceArchive, 'abc', [Text.UTF8Encoding]::new($false))
    & $generator -version '2.2.0' -sourceArchive $sourceArchive
    $script:publishedFormula = Get-Content -LiteralPath $formulaOutput -Raw
    Assert-Contains $publishedFormula 'url "https://github.com/grate-devs/grate/archive/refs/tags/2.2.0.tar.gz"'
    Assert-Contains $publishedFormula "sha256 `"$abcHash`""
    Assert-Contains $publishedFormula 'depends_on "dotnet"'
    Assert-Contains $publishedFormula '--no-self-contained'
    Assert-Contains $publishedFormula 'bin.install_symlink libexec/"grate"'
    if ($publishedFormula -match '@[A-Z_]+@|2\.1\.6') { throw 'Generated formula contains stale metadata or placeholders.' }

    & $generator -version '2.2.0' -sourceArchive $sourceArchive
    if ((Get-Content -LiteralPath $formulaOutput -Raw) -cne $publishedFormula) {
        throw 'Identical inputs produced different formula output.'
    }
    $prefixedOutput = Join-Path $fixtureRoot 'custom/grate.rb'
    & $generator -version '2.2.0' -sourceArchive $sourceArchive -releaseTag 'v2.2.0' -outputPath $prefixedOutput
    Assert-Contains (Get-Content -LiteralPath $prefixedOutput -Raw) '/tags/v2.2.0.tar.gz'

    Assert-Rejected { & $generator -version '2.2.0-rc.1' -sourceArchive $sourceArchive } -ExpectedErrorId 'ParameterArgumentValidationError*'
    Assert-Rejected { & $generator -version "2.2.0`n" -sourceArchive $sourceArchive } -ExpectedErrorId 'ParameterArgumentValidationError*'
    Assert-Rejected { & $generator -version '2.2.0' -sourceArchive (Join-Path $fixtureRoot 'missing.tar.gz') }
    Assert-Rejected { & $generator -version '2.2.0' -sourceArchive $sourceArchive -releaseTag 'v2.3.0' }
    Assert-Rejected { & $generator -version '2.2.0' -sourceArchive $sourceArchive -releaseTag '2.2.0"; puts "bad' }
    $wrongArchive = Join-Path $fixtureRoot 'wrong.zip'
    [IO.File]::WriteAllText($wrongArchive, 'abc')
    Assert-Rejected { & $generator -version '2.2.0' -sourceArchive $wrongArchive }

    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'grate-osx-arm64-self-contained-2.2.0.zip'), 'abc', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'grate-osx-x64-self-contained-2.2.0.zip'), 'hello', [Text.UTF8Encoding]::new($false))
    & $caskGenerator -version '2.2.0' -artifactDirectory $fixtureRoot
    $cask = Get-Content -LiteralPath $caskOutput -Raw
    Assert-Contains $cask 'cask "grate" do'
    Assert-Contains $cask 'depends_on :macos'
    Assert-Contains $cask "sha256 `"$abcHash`""
    Assert-Contains $cask "sha256 `"$helloHash`""
    Assert-Contains $cask '/releases/download/2.2.0/grate-osx-arm64-self-contained-#{version}.zip'
    Assert-Contains $cask '/releases/download/2.2.0/grate-osx-x64-self-contained-#{version}.zip'
    $prefixedCask = Join-Path $fixtureRoot 'custom-cask/grate.rb'
    & $caskGenerator -version '2.2.0' -artifactDirectory $fixtureRoot -releaseTag 'v2.2.0' -outputPath $prefixedCask
    Assert-Contains (Get-Content -LiteralPath $prefixedCask -Raw) '/releases/download/v2.2.0/grate-osx-arm64-self-contained-#{version}.zip'
    Assert-Rejected { & $caskGenerator -version '2.2.0-rc.1' -artifactDirectory $fixtureRoot } -Output $caskOutput -Expected $cask -ExpectedErrorId 'ParameterArgumentValidationError*'
    Assert-Rejected { & $caskGenerator -version "2.2.0`n" -artifactDirectory $fixtureRoot } -Output $caskOutput -Expected $cask -ExpectedErrorId 'ParameterArgumentValidationError*'
    Assert-Rejected { & $caskGenerator -version '2.2.0' -releaseTag 'v2.3.0' -artifactDirectory $fixtureRoot } -Output $caskOutput -Expected $cask
    Assert-Rejected { & $caskGenerator -version '2.2.0' -releaseTag '2.2.0"; puts "bad' -artifactDirectory $fixtureRoot } -Output $caskOutput -Expected $cask
    if ((Get-Content -LiteralPath $formulaOutput -Raw) -cne $publishedFormula) {
        throw 'Cask generation overwrote the source-built formula.'
    }
    if ((Get-Content -LiteralPath (Join-Path $fixtureScripts 'grate.rb.in') -Raw) -cne
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'grate.rb.in') -Raw)) {
        throw 'Generation changed the tracked formula template.'
    }
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
    Remove-Variable -Name publishedFormula -Scope Script -ErrorAction SilentlyContinue
}

Write-Host 'PASS: formula checksums, source URLs, validation, determinism and separate cask/formula outputs.'
