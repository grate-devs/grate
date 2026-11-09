#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('grate-cask-' + [guid]::NewGuid().ToString('N'))
$pwsh = (Get-Process -Id $PID).Path

function Invoke-TestCask {
    param(
        [hashtable]$Arguments,
        [string]$ExpectedError
    )

    $commandOutput = & $pwsh -NoLogo -NoProfile -File "$PSScriptRoot/update_homebrew_cask.ps1" @Arguments 2>&1 | Out-String
    if ($ExpectedError) {
        if ($LASTEXITCODE -eq 0 -or $commandOutput -notlike $ExpectedError) {
            throw "Expected failure '$ExpectedError'; exit $LASTEXITCODE returned: $commandOutput"
        }
    } elseif ($LASTEXITCODE -ne 0) {
        throw "Cask generation failed: $commandOutput"
    }
}

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

    Invoke-TestCask -Arguments $caskArguments

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
        Invoke-TestCask -Arguments $caskArguments -ExpectedError '*Homebrew only publishes stable SemVer versions.*'
        if ((Get-Content -LiteralPath $output -Raw) -cne $content) {
            throw "Invalid version '$version' must fail without overwriting the cask."
        }
    }

    $caskArguments.Version = '2.3.4'
    foreach ($architecture in @('Arm64Sha256', 'X64Sha256')) {
        foreach ($checksum in @('bad', ('g' * 64), ('a' * 63))) {
            $invalidArguments = $caskArguments.Clone()
            $invalidArguments[$architecture] = $checksum
            Invoke-TestCask -Arguments $invalidArguments -ExpectedError '*Invalid SHA-256.*'
            if ((Get-Content -LiteralPath $output -Raw) -cne $content) {
                throw 'Invalid checksum must fail without overwriting the cask.'
            }
        }
    }

    foreach ($tag in @('v2.3.5', '../../2.3.4', "v2.3.4`n", '2.3.4"; system("injected")')) {
        $invalidArguments = $caskArguments.Clone()
        $invalidArguments.ReleaseTag = $tag
        Invoke-TestCask -Arguments $invalidArguments -ExpectedError '*releaseTag must be the version or the version prefixed with v.*'
        if ((Get-Content -LiteralPath $output -Raw) -cne $content) {
            throw 'Invalid release tag overwrote the cask.'
        }
    }

    $profiles = [ordered]@{
        All = 'grate'
        SQLite = 'grate-sqlite'
        SQLServer = 'grate-sqlserver'
        MariaDB = 'grate-mariadb'
        PostgreSQL = 'grate-postgresql'
        Oracle = 'grate-oracle'
    }
    foreach ($profile in $profiles.Keys) {
        $id = $profiles[$profile]
        $caskArguments.Distribution = $profile
        $caskArguments.ReleaseTag = 'v2.3.4'
        $caskArguments.Output = "$temporary/variants/$id.rb"
        Invoke-TestCask -Arguments $caskArguments
        $variant = Get-Content -LiteralPath $caskArguments.Output -Raw
        foreach ($expected in @("cask `"$id`" do", "/download/v2.3.4/$id-osx-#{arch}-self-contained-#{version}.zip", 'binary "grate"')) {
            if (!$variant.Contains($expected)) {
                throw "Missing $profile cask value: $expected"
            }
        }
        foreach ($other in @($profiles.Values | Where-Object { $_ -cne $id })) {
            if (!$variant.Contains("`"$other`",")) {
                throw "Missing $other conflict in $profile cask."
            }
        }
    }

    $archiveDirectory = "$temporary/archives"
    New-Item -ItemType Directory -Path $archiveDirectory | Out-Null
    foreach ($id in $profiles.Values) {
        [IO.File]::WriteAllText("$archiveDirectory/$id-osx-arm64-self-contained-2.3.4.zip", 'abc', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText("$archiveDirectory/$id-osx-x64-self-contained-2.3.4.zip", 'hello', [Text.UTF8Encoding]::new($false))
    }
    $allArguments = @{
        Version = '2.3.4'
        ReleaseTag = 'v2.3.4'
        AllDistributions = $true
        ArtifactDirectory = $archiveDirectory
        OutputDirectory = "$temporary/all-casks"
    }
    Invoke-TestCask -Arguments $allArguments
    $allCasks = @(Get-ChildItem -LiteralPath $allArguments.OutputDirectory -Filter '*.rb' -File)
    if ($allCasks.Count -ne 6) {
        throw 'The wrapper must generate all six casks.'
    }
    $allHashes = @{}
    foreach ($id in $profiles.Values) {
        $path = "$($allArguments.OutputDirectory)/$id.rb"
        $allCask = Get-Content -LiteralPath $path -Raw
        foreach ($fragment in @(
            "cask `"$id`" do"
            "/download/v2.3.4/$id-osx-#{arch}-self-contained-#{version}.zip"
            'sha256 arm:   "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"'
            'intel: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"'
        )) {
            if (!$allCask.Contains($fragment)) {
                throw "Missing wrapper output for ${id}: $fragment"
            }
        }
        $allHashes[$path] = (Get-FileHash -LiteralPath $path).Hash
    }

    # Each mutually exclusive per-cask option and both required directories have
    # independent fixtures, so one guard cannot mask another missing guard.
    foreach ($option in @('Distribution', 'Output', 'Arm64Sha256', 'X64Sha256', 'ArtifactDirectory', 'OutputDirectory')) {
        $invalidArguments = $allArguments.Clone()
        switch ($option) {
            'Distribution' { $invalidArguments.Distribution = 'SQLite' }
            'Output' { $invalidArguments.Output = $output }
            'Arm64Sha256' { $invalidArguments.Arm64Sha256 = $arm64Checksum }
            'X64Sha256' { $invalidArguments.X64Sha256 = $x64Checksum }
            default { $invalidArguments.Remove($option) }
        }
        Invoke-TestCask -Arguments $invalidArguments -ExpectedError '*AllDistributions requires ArtifactDirectory*OutputDirectory*per-cask hashes/output.*'
    }
    if ((Get-Content -LiteralPath $output -Raw) -cne $content) {
        throw 'Rejected AllDistributions options overwrote a valid single cask.'
    }
    foreach ($path in $allHashes.Keys) {
        if ((Get-FileHash -LiteralPath $path).Hash -cne $allHashes[$path]) {
            throw "Rejected AllDistributions options overwrote $path."
        }
    }

    $missingArchive = "$archiveDirectory/grate-oracle-osx-x64-self-contained-2.3.4.zip"
    Move-Item -LiteralPath $missingArchive -Destination "$missingArchive.wrong-name"
    $missingArguments = $allArguments.Clone()
    $missingArguments.OutputDirectory = "$temporary/missing-archive-output"
    Invoke-TestCask -Arguments $missingArguments -ExpectedError '*find*grate-oracle-osx-x64-self-contained-2.3.4.zip*'
    if (Test-Path -LiteralPath $missingArguments.OutputDirectory) {
        throw 'The wrapper wrote a partial cask set before discovering a missing archive.'
    }
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: Homebrew CLI six-profile output, version/hash/tag errors, all six AllDistributions guards, atomic missing-input failure and file encoding.'
