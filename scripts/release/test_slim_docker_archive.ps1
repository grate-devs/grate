#!/usr/bin/env pwsh
. "$PSScriptRoot/publish_slim_docker_archive.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
. "$PSScriptRoot/docker_publication_test_fixture.ps1"
$savedEnvironment = @{}
foreach ($name in @('DOCKER_HUB_USER', 'DOCKER_HUB_TOKEN')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, '')
}

function New-SlimArguments {
    $verification = Join-Path $script:Directory 'verification.json'
    $parameters = @{
        Distribution = 'SQLite'
        Version = '2.3.4'
        SourceCommit = 'a' * 40
        ExpectedDigest = $script:Digest
        Archive = $script:ArchivePath
        Report = $verification
        Mode = 'Verify'
    }
    $null = Invoke-SlimDockerArchive @parameters
    $parameters.Report = $script:ReportPath
    $parameters.VerificationReport = $verification
    $parameters.Authfile = $script:AuthPath
    $parameters.Mode = 'Publish'
    $script:Commands.Clear()
    $parameters
}

try {
    Invoke-Test 'all five profiles have disjoint version/alias tags and bounded lengths' {
        foreach ($profile in @('SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')) {
            $alias = $profile.ToLowerInvariant()
            Assert-Equal @("$alias-2.3.4", $alias) @(Get-SlimDockerTags $profile '2.3.4')
            Assert-Equal @("$alias-2.3.4-rc.1") @(Get-SlimDockerTags $profile '2.3.4-rc.1')
            Assert-Equal @("$alias-2.3.4") @(Get-SlimDockerTags $profile '2.3.4' $true)
            Assert-Throws { Get-SlimDockerTags $profile ('1.2.3-' + ('a' * 120)) } '*length*'
        }
        Assert-Throws { Get-SlimDockerTags All '2.3.4' }
        Assert-Throws { Get-SlimDockerTags SQLite '2.3.4;injected' }
        # A legitimate All prerelease tag stays distinct from the slim version.
        Assert-Equal '2.3.4-sqlite' (Get-NormalizedDockerVersion '2.3.4-sqlite')
    }

    Invoke-PublicationCase 'slim archive publishes immutable tag before its alias using canonical credentials' 'canonical' {
        $parameters = New-SlimArguments
        $script:AfterCopy = {
            param($Tag)
            if ($Tag -ceq 'sqlite') {
                Assert-Equal 'verified' (Get-PublicationReport).tags['sqlite-2.3.4'].status
            }
        }
        $result = Invoke-SlimDockerArchive @parameters
        Assert-Equal 'verified' $result.status
        Assert-Equal @('sqlite-2.3.4', 'sqlite') @(Get-PublicationCopies | ForEach-Object { $_[-1].Split(':')[-1] })
        Assert-Equal @('gratedevs/grate') @($script:RegistryCalls)
        Assert-True (!$result.tags.ContainsKey('latest'))
        Assert-Equal $script:OtherDigest $script:Destination.Tags.latest
    }

    Invoke-PublicationCase 'cross-profile version source or digest substitution fails before any tool or registry access' 'canonical' {
        $original = New-SlimArguments
        foreach ($name in @('Distribution', 'Version', 'SourceCommit', 'ExpectedDigest')) {
            $parameters = $original.Clone()
            $parameters[$name] = switch ($name) {
                Distribution { 'Oracle' }
                Version { '2.3.5' }
                SourceCommit { 'b' * 40 }
                ExpectedDigest { $script:OtherDigest }
            }
            Assert-Throws { Invoke-SlimDockerArchive @parameters } '*does not match*'
            Assert-Equal 0 $script:Commands.Count
            Assert-Equal 0 $script:RegistryCalls.Count
        }
    }

    Invoke-PublicationCase 'immutable conflict prevents every copy including mutable alias' 'canonical' {
        $parameters = New-SlimArguments
        $script:Destination.Tags['sqlite-2.3.4'] = $script:OtherDigest
        Assert-Throws { Invoke-SlimDockerArchive @parameters } '*conflicting*'
        Assert-Equal 0 @(Get-PublicationCopies).Count
    }

    Invoke-PublicationCase 'matching immutable tag permits alias refresh without overwrite' 'canonical' {
        $parameters = New-SlimArguments
        $script:Destination.Tags['sqlite-2.3.4'] = $script:Digest
        $script:Destination.Tags.sqlite = $script:OtherDigest
        $null = Invoke-SlimDockerArchive @parameters
        Assert-Equal @('sqlite') @(Get-PublicationCopies | ForEach-Object { $_[-1].Split(':')[-1] })
    }

    Invoke-PublicationCase 'archive mismatch fails before registry inspection or writes' 'canonical' {
        $parameters = New-SlimArguments
        $script:ArchiveRaw = [Text.Encoding]::UTF8.GetBytes('different profile archive')
        Assert-Throws { Invoke-SlimDockerArchive @parameters } '*archive differs*'
        Assert-Equal 0 $script:RegistryCalls.Count
        Assert-Equal 0 @(Get-PublicationCopies).Count
    }

    Invoke-PublicationCase 'prerelease writes its immutable tag without stable alias' 'canonical' {
        $parameters = New-SlimArguments
        $parameters.Mode = 'Preflight'
        $parameters.Version = '2.3.4-rc.1'
        $parameters.Report = $parameters.VerificationReport
        $null = Invoke-SlimDockerArchive @parameters
        $parameters.Mode = 'Publish'
        $parameters.Report = $script:ReportPath
        $null = Invoke-SlimDockerArchive @parameters
        Assert-Equal @('sqlite-2.3.4-rc.1') @(Get-PublicationCopies | ForEach-Object { $_[-1].Split(':')[-1] })
    }

    Invoke-PublicationCase 'failed immutable readback stops before alias and records a partial failure' 'canonical' {
        $parameters = New-SlimArguments
        $script:AfterCopy = {
            param($Tag)
            $script:Destination.Tags[$Tag] = $script:OtherDigest
        }
        Assert-Throws { Invoke-SlimDockerArchive @parameters } '*differs*'
        Assert-Equal @('sqlite-2.3.4') @(Get-PublicationCopies | ForEach-Object { $_[-1].Split(':')[-1] })
        Assert-Equal 'failed' (Get-PublicationReport).status
    }

    Invoke-PublicationCase 'compatibility secrets cannot reach canonical publication' 'canonical' {
        $parameters = New-SlimArguments
        $env:DOCKER_HUB_TOKEN = 'LEGACY_SECRET'
        try {
            Assert-Throws { Invoke-SlimDockerArchive @parameters } '*compatibility credentials*'
            Assert-Equal 0 $script:Commands.Count
        } finally {
            $env:DOCKER_HUB_TOKEN = ''
        }
    }

    if (!$IsWindows) {
        Invoke-PublicationCase 'CLI preserves archive report and profile arguments across imported scripts' 'canonical' {
            $pwsh = (Get-Process -Id $PID).Path
            $toolPath = Join-Path $script:Directory 'skopeo'
            $shim = "#!$pwsh`n[Console]::Write('{`"schemaVersion`":2,`"manifests`":[]}')`n"
            Set-Content -LiteralPath $toolPath -Value $shim -NoNewline -Encoding utf8NoBOM
            [IO.File]::SetUnixFileMode($toolPath,
                [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
            $savedPath = $env:PATH
            try {
                $env:PATH = $script:Directory + [IO.Path]::PathSeparator + $savedPath
                $arguments = @(
                    '-NoProfile', '-File', "$PSScriptRoot/publish_slim_docker_archive.ps1",
                    '-Distribution', 'Oracle', '-Version', '2.3.4', '-SourceCommit', ('a' * 40),
                    '-ExpectedDigest', $script:Digest, '-Archive', $script:ArchivePath,
                    '-Report', $script:ReportPath, '-Mode', 'Verify'
                )
                $output = & $pwsh @arguments 2>&1 | Out-String
                Assert-Equal 0 $LASTEXITCODE $output
                $result = Get-PublicationReport
                Assert-Equal 'Oracle' $result.distribution
                Assert-Equal '2.3.4' $result.version
                Assert-Equal 'Verify' $result.mode
                Assert-Equal 'verified' $result.status
                Assert-Equal $script:Digest $result.digest
            } finally {
                $env:PATH = $savedPath
            }
        }
    }
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
}
Write-Host "PASS: $script:TestCount slim Docker archive policy scenarios."
