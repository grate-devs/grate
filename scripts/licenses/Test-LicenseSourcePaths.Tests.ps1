#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/SourceTextPaths.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-source-paths-' + [Guid]::NewGuid().ToString('N'))

function Require {
    param ([bool]$Condition, [string]$Message)
    if (!$Condition) {
        throw $Message
    }
}

function Expect-PathFailure {
    param ([scriptblock]$Action)
    $failed = $false
    try {
        & $Action
    }
    catch {
        $failed = $true
    }
    Require $failed 'Expected an unsafe or conflicting path to be rejected.'
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $first = [Text.Encoding]::UTF8.GetBytes("Original owner and terms.`r`n")
    $second = [Text.Encoding]::UTF8.GetBytes("Different original notice.`n")
    $firstHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($first))
    $secondHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($second))
    $url = 'https://raw.githubusercontent.com/Acme/Project/exact-commit/LICENSE.txt'
    $relative = Get-LicenseSourceRelativePath -Url $url -PackageKey 'Fixture/1.0.0' -Sha256 $firstHash -SourceDirectory $root
    Require ($relative -ceq 'text/acme/project/license.txt') 'Path should identify the upstream repository and document.'
    $path = Join-Path $root $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllBytes($path, $first)
    $reused = Get-LicenseSourceRelativePath -Url $url -PackageKey 'Fixture/2.0.0' -Sha256 $firstHash -SourceDirectory $root
    Require ($reused -ceq $relative) 'Identical original bytes should reuse the readable path.'

    $variant = Get-LicenseSourceRelativePath -Url $url -PackageKey 'Fixture/2.0.0' -Sha256 $secondHash -SourceDirectory $root
    Require ($variant -ceq 'text/acme/project/license-fixture-2.0.0.txt') 'Different text needs a readable package/version label.'
    Require ((Get-FileHash -LiteralPath $path).Hash -ceq $firstHash) 'Existing original bytes were changed.'
    [IO.File]::WriteAllBytes((Join-Path $root $variant), $first)
    Expect-PathFailure {
        Get-LicenseSourceRelativePath -Url $url -PackageKey 'Fixture/2.0.0' -Sha256 $secondHash -SourceDirectory $root
    }
    Expect-PathFailure {
        Get-LicenseSourceRelativePath -Url 'https://raw.githubusercontent.com/../Project/revision/LICENSE' -PackageKey 'Fixture/1.0.0' -Sha256 $firstHash -SourceDirectory $root
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Host 'PASS: 4 readable source-path, byte-retention and collision scenarios.'
