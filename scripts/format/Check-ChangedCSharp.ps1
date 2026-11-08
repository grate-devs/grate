#!/usr/bin/env pwsh
<#
.SYNOPSIS
Checks whitespace and encoding of changed C# files with the repository SDK.
.DESCRIPTION
Compares the working tree to the merge base of BaseRef and HEAD, including staged,
unstaged and untracked files under src/ and unittests/. Deleted and ignored files
are excluded. All checks every tracked C# file in those directories instead.
Changes to .editorconfig or global.json also select all tracked C# files.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $BaseRef = 'origin/main',
    [switch] $All
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest

function Invoke-GitPaths {
    param(
        [string[]] $GitArguments
    )
    # NUL delimiters preserve spaces, Unicode and newlines in file names.
    $output = (& git @GitArguments) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "git failed with exit code $LASTEXITCODE."
    }
    $output -split "`0" | Where-Object { $_.Length -gt 0 }
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Push-Location $repositoryRoot
try {
    if (!$All) {
        $mergeBase = & git merge-base $BaseRef HEAD
        if ($LASTEXITCODE -ne 0) {
            throw "Cannot find merge base for '$BaseRef'. Fetch the base branch before checking formatting."
        }
        $configurationChanges = @(Invoke-GitPaths -GitArguments @('diff', '--name-only', '-z', $mergeBase, '--', '.editorconfig', 'global.json'))
        if ($configurationChanges.Count -gt 0) {
            Write-Host 'Formatter configuration or SDK changed; checking all tracked C# files.'
            $All = $true
        }
    }
    if ($All) {
        $paths = @(Invoke-GitPaths -GitArguments @('ls-files', '-z', '--', 'src/', 'unittests/'))
    }
    else {
        $paths = @(Invoke-GitPaths -GitArguments @('diff', '--name-only', '--diff-filter=ACMR', '-z', $mergeBase, '--', 'src/', 'unittests/'))
    }
    $paths += @(Invoke-GitPaths -GitArguments @('ls-files', '--others', '--exclude-standard', '-z', '--', 'src/', 'unittests/'))
    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $files = @($paths | Where-Object {
        $_.EndsWith('.cs', [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $_ -PathType Leaf) -and
        $seenPaths.Add($_)
    })

    if ($files.Count -eq 0) {
        Write-Host 'No changed C# files to check.'
        exit 0
    }

    Write-Host "Checking whitespace and encoding in $($files.Count) C# files."
    & dotnet format whitespace --folder --include @files --verify-no-changes
    $formatExitCode = $LASTEXITCODE
    if ($formatExitCode -ne 0) {
        Write-Host 'Run dotnet format whitespace --folder --include <reported files> to fix formatting.'
    }
    exit $formatExitCode
}
finally {
    Pop-Location
}
