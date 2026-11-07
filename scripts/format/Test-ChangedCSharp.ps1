#!/usr/bin/env pwsh
# Integration checks using a disposable Git repository and the real formatter.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('grate format fixture-' + [Guid]::NewGuid().ToString('N'))
$utf8Bom = [Text.UTF8Encoding]::new($true)
$checkCount = 0

function Invoke-FixtureGit {
    & git @args | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Fixture git failed: $args" }
}

function Assert-Check {
    param([int] $ExpectedExitCode, [string] $ExpectedOutput, [string[]] $CheckArguments = @('-BaseRef', 'main'))
    $output = (& pwsh -NoProfile -File './scripts/format/Check-ChangedCSharp.ps1' @CheckArguments 2>&1) -join "`n"
    if ($LASTEXITCODE -ne $ExpectedExitCode -or $output -notmatch $ExpectedOutput) {
        throw "Expected exit $ExpectedExitCode and '$ExpectedOutput', got exit ${LASTEXITCODE}:`n$output"
    }
    $script:checkCount++
}

try {
    New-Item -ItemType Directory -Path "$fixtureRoot/scripts/format", "$fixtureRoot/src" -Force | Out-Null
    Copy-Item "$PSScriptRoot/Check-ChangedCSharp.ps1" "$fixtureRoot/scripts/format/"
    Copy-Item "$repositoryRoot/.editorconfig", "$repositoryRoot/global.json" $fixtureRoot
    [IO.File]::WriteAllText("$fixtureRoot/src/Legacy.cs", 'public class Legacy {public int Value=>1;}', $utf8Bom)
    [IO.File]::WriteAllText("$fixtureRoot/src/Good.cs", "public class Good`n{`n}`n", $utf8Bom)
    Push-Location $fixtureRoot
    try {
        Invoke-FixtureGit init -b main
        Invoke-FixtureGit config user.name 'Formatter fixture'
        Invoke-FixtureGit config user.email 'formatter@example.invalid'
        Invoke-FixtureGit add .
        Invoke-FixtureGit commit -m baseline

        # Existing debt is outside the changed-file check.
        Assert-Check 0 'No changed C# files'
        [IO.File]::AppendAllText("$fixtureRoot/src/Legacy.cs", "`n")
        Assert-Check 2 'WHITESPACE'
        Invoke-FixtureGit restore src/Legacy.cs

        [IO.File]::AppendAllText("$fixtureRoot/src/Good.cs", "// A staged change.`n")
        Invoke-FixtureGit add src/Good.cs
        Assert-Check 0 'Checking whitespace and encoding in 1 C# files'

        # An untracked name with spaces and Unicode must remain one argument.
        [IO.File]::WriteAllText("$fixtureRoot/src/New file æ.cs", 'public class New {public int Value=>1;}')
        Assert-Check 2 'CHARSET'
        Remove-Item -LiteralPath "$fixtureRoot/src/New file æ.cs"

        # Deleted files must never reach the formatter.
        Remove-Item "$fixtureRoot/src/Legacy.cs"
        Assert-Check 0 'Checking whitespace and encoding in 1 C# files'
        Invoke-FixtureGit restore src/Legacy.cs

        Invoke-FixtureGit mv src/Good.cs 'src/Good renamed æ.cs'
        Assert-Check 0 'Checking whitespace and encoding in 1 C# files'
        Assert-Check 2 'WHITESPACE' @('-All')

        [IO.File]::AppendAllText("$fixtureRoot/.editorconfig", "`n# Configuration changed.`n")
        Assert-Check 2 'checking all tracked C# files'
        Assert-Check 1 'Cannot find merge base' @('-BaseRef', 'missing-base')
    }
    finally { Pop-Location }
    Write-Host "Passed $checkCount formatter integration checks."
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
