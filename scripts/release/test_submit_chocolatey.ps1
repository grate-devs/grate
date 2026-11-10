#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/submit_chocolatey.ps1" -FunctionsOnly
$script:ActualPublicVersions = (Get-Command Get-ChocolateyPublicVersions).ScriptBlock

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('grate-choco-submit-' + [guid]::NewGuid().ToString('N'))
$version = '2.3.4'
$source = 'a' * 40
$apiKey = 'test-only-api-key-must-never-be-echoed'
$profiles = [ordered]@{
    All = 'grate'
    SQLite = 'grate-sqlite'
    SQLServer = 'grate-sqlserver'
    MariaDB = 'grate-mariadb'
    PostgreSQL = 'grate-postgresql'
    Oracle = 'grate-oracle'
}
$previousEnvironment = @{}
foreach ($name in @('GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT', 'GITHUB_RUN_ID', 'CHOCOLATEY_API_KEY')) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$script:Pushes = [Collections.Generic.List[string]]::new()
$script:FeedReads = [Collections.Generic.List[string]]::new()
$script:FeedMode = 'fresh'
$script:FailPushAt = 0
$script:ResolvedSource = $source
$script:PageReads = [Collections.Generic.List[string]]::new()

function New-ChocolateyFeedFixture {
    param(
        [string]$Id,
        [string]$PackageVersion,
        [string[]]$NextLinks = @()
    )

    $links = @($NextLinks | ForEach-Object { '<link rel="next" href="' + [Security.SecurityElement]::Escape($_) + '"/>' }) -join ''
    '<feed xmlns="http://www.w3.org/2005/Atom" xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices" xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata"><entry><title>' + $Id + '</title><m:properties><d:Version>' + $PackageVersion + '</d:Version></m:properties></entry>' + $links + '</feed>'
}

function Assert-SubmissionFailure {
    param(
        [scriptblock]$Action,
        [string]$Expected
    )

    $rejected = $false
    $captured = [Text.StringBuilder]::new()
    try {
        & $Action *>&1 | ForEach-Object {
            [void]$captured.AppendLine([string]$_)
        }
    } catch {
        $rejected = $true
        if ($_.Exception.Message -notlike $Expected) {
            throw "Unexpected rejection: $($_.Exception.Message); expected $Expected."
        }
        if ($_.Exception.Message.Contains($apiKey)) {
            throw 'A failure exposed the API key.'
        }
    }
    if (!$rejected) {
        throw "Expected rejection: $Expected."
    }
    if ($captured.ToString().Contains($apiKey)) {
        throw 'Captured native output exposed the API key.'
    }
}

# Exercise the actual production guard before replacing only this host boundary
# for offline orchestration tests. No publication bypass flag exists in the CLI.
$env:GITHUB_ACTIONS = 'false'
Assert-SubmissionFailure { Assert-ChocolateyPublicationHost } '*isolated GitHub-hosted Windows*'

function Assert-ChocolateyPublicationHost {
    if ([string]::IsNullOrWhiteSpace($env:CHOCOLATEY_API_KEY)) {
        throw 'The repository secret CHOCOLATEY_API_KEY is not configured.'
    }
}

function Get-WindowsChannelReleaseContext {
    param(
        [string]$Version,
        [string]$ReleaseRunId
    )

    return @{ SourceCommit = $script:ResolvedSource; ExpectedSQLiteVersion = '3.53.4' }
}

function Get-ChocolateyPublicVersions {
    param(
        [string]$Id
    )

    $script:FeedReads.Add($Id)
    if ($script:FeedMode.StartsWith('paged-', [StringComparison]::Ordinal)) {
        $firstUri = "https://community.chocolatey.org/api/v2/FindPackagesById()?id=%27$Id%27"
        $nextUri = "https://community.chocolatey.org/api/v2/FindPackagesById?id=%27$Id%27&`$skip=1"
        $laterVersion = if ($script:FeedMode -eq 'paged-existing' -or ($script:FeedMode -eq 'paged-different' -and $Id -eq 'grate-oracle')) {
            $version
        } elseif ($script:FeedMode -eq 'paged-newer' -and $Id -eq 'grate-oracle') {
            '2.3.5'
        } else {
            '2.2.1'
        }
        $firstPage = New-ChocolateyFeedFixture -Id $Id -PackageVersion '2.2.0' -NextLinks @($nextUri)
        $secondPage = New-ChocolateyFeedFixture -Id $Id -PackageVersion $laterVersion
        $pageReads = $script:PageReads
        $readPage = {
            param(
                $uri
            )
            $pageReads.Add($uri)
            if ($uri -ceq $firstUri) { return $firstPage }
            if ($uri -ceq $nextUri) { return $secondPage }
            throw 'Unexpected destination page requested.'
        }.GetNewClosure()
        return @(& $script:ActualPublicVersions -Id $Id -ReadFeed $readPage)
    }
    switch ($script:FeedMode) {
        'existing' { return @('2.2.0', $version) }
        'different' {
            if ($Id -ceq 'grate-oracle') {
                return @($version)
            }
            return @('2.2.0')
        }
        'newer' {
            if ($Id -ceq 'grate-oracle') {
                return @('2.2.0', '2.3.5')
            }
            return @('2.2.0')
        }
        default { return @('2.2.0') }
    }
}

function Save-ChocolateyPublicPackage {
    param(
        [string]$Id,
        [string]$Version,
        [string]$Path
    )

    if ($script:FeedMode -cin @('different', 'paged-different')) {
        [IO.File]::WriteAllText($Path, 'different bytes already accepted by feed')
    } else {
        Copy-Item -LiteralPath "$temporary/candidates/$Id.$Version.nupkg" -Destination $Path
    }
}

function Invoke-ReleaseProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds
    )

    if ($FilePath -cne 'choco' -or $Arguments[0] -cne 'push' -or $TimeoutSeconds -ne 600 -or
        $Arguments -cnotcontains '--source=https://push.chocolatey.org/' -or $Arguments -cnotcontains "--api-key=$apiKey") {
        throw 'Unexpected publishing process invocation.'
    }
    if ($script:FeedReads.Count -ne 6) {
        throw 'A push was attempted before every destination had been inventoried.'
    }
    $script:Pushes.Add([IO.Path]::GetFileName($Arguments[1]))
    return @{
        ExitCode = if ($script:FailPushAt -eq $script:Pushes.Count) { 1 } else { 0 }
        # Deliberately emulate an external tool/server echoing credentials.
        Text = "native stdout unexpectedly echoed $apiKey"
        ErrorText = "native stderr unexpectedly echoed $apiKey"
    }
}

function Reset-SubmissionScenario {
    param(
        [string]$Mode = 'fresh'
    )

    $script:FeedMode = $Mode
    $script:FailPushAt = 0
    $script:Pushes.Clear()
    $script:FeedReads.Clear()
    $script:PageReads.Clear()
    $env:CHOCOLATEY_API_KEY = $apiKey
    if (Test-Path -LiteralPath "$temporary/output") {
        Remove-Item -LiteralPath "$temporary/output" -Recurse -Force
    }
}

try {
    $env:GITHUB_RUN_ID = '67890'
    New-Item -ItemType Directory -Path "$temporary/candidates" -Force | Out-Null
    $packageHashes = @{}
    $payloadHashes = @{}
    foreach ($profile in $profiles.Keys) {
        $id = $profiles[$profile]
        $unpacked = "$temporary/unpacked/$id"
        New-Item -ItemType Directory -Path "$unpacked/tools" -Force | Out-Null
        "<package><metadata><id>$id</id><version>$version</version></metadata></package>" |
            Set-Content -LiteralPath "$unpacked/$id.nuspec" -Encoding utf8NoBOM
        [IO.File]::WriteAllBytes("$unpacked/tools/grate.exe", [Text.Encoding]::UTF8.GetBytes("unique executable fixture for $id"))
        $package = "$temporary/candidates/$id.$version.nupkg"
        [IO.Compression.ZipFile]::CreateFromDirectory($unpacked, $package)
        $packageHashes[$id] = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
        $payloadHashes[$id] = (Get-FileHash -LiteralPath "$unpacked/tools/grate.exe" -Algorithm SHA256).Hash
    }
    $records = @(foreach ($profile in $profiles.Keys) {
        $id = $profiles[$profile]
        foreach ($case in @('zip/x86', 'zip/x64', 'zip/arm64', 'wix/x64', 'wix/arm64', 'chocolatey/x64')) {
            $parts = $case.Split('/')
            $channel = if ($parts[0] -ceq 'chocolatey') { 'chocolatey' } else { 'winget' }
            [pscustomobject]@{
                Channel = $channel
                InstallerType = if ($channel -ceq 'chocolatey') { 'zip' } else { $parts[0] }
                Architecture = $parts[1]
                Distribution = $profile
                PackageId = $id
                Version = $version
                ReleaseRunId = '12345'
                SourceCommit = $source
                ValidationRunId = '67890'
                ExpectedSQLiteVersion = '3.53.4'
                Status = 'passed'
                PackageSha256 = $packageHashes[$id]
                PublicExecutableSha256 = $payloadHashes[$id]
                ChocolateyAllUpgrade = if ($channel -ceq 'chocolatey' -and $profile -ceq 'All') { 'passed' } else { 'not applicable' }
                LegacyMigration = if ($profile -ceq 'All') { 'passed; actual public 2.0.0 to final release through private PreIndexed source' } else { 'not applicable; separate slim identity' }
            }
        }
    })
    $gate = "$temporary/verified.json"
    $records | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $gate -Encoding utf8NoBOM
    $arguments = @{ Version = $version; ReleaseRunId = '12345'; SourceCommit = $source; CandidateDirectory = "$temporary/candidates"; EvidencePath = $gate; OutputDirectory = "$temporary/output" }

    Reset-SubmissionScenario
    $output = Invoke-ChocolateySubmission @arguments *>&1 | Out-String
    $journal = @(Get-Content -LiteralPath "$temporary/output/chocolatey-submissions.json" -Raw | ConvertFrom-Json)
    if ($script:Pushes.Count -ne 6 -or $journal.Count -ne 6 -or
        @($journal | Where-Object Status -CNE 'submitted_pending_validation_or_moderation').Count -or $output.Contains($apiKey)) {
        throw 'The complete matching set must push all six exact packages without exposing credentials.'
    }

    Reset-SubmissionScenario -Mode existing
    Invoke-ChocolateySubmission @arguments | Out-Null
    $journal = @(Get-Content -LiteralPath "$temporary/output/chocolatey-submissions.json" -Raw | ConvertFrom-Json)
    if ($script:Pushes.Count -ne 0 -or $journal.Count -ne 6 -or
        @($journal | Where-Object Status -CNE 'already_available_exact_bytes').Count) {
        throw 'Already-public exact packages must be reused without another push.'
    }

    foreach ($mode in @('different', 'newer')) {
        Reset-SubmissionScenario -Mode $mode
        $expected = if ($mode -ceq 'different') { '*Existing Chocolatey version has different bytes*' } else { '*newer stable Chocolatey version exists*' }
        Assert-SubmissionFailure { Invoke-ChocolateySubmission @arguments } $expected
        if ($script:Pushes.Count -ne 0 -or (Test-Path -LiteralPath "$temporary/output/chocolatey-submissions.json")) {
            throw 'An invalid final destination must reject the whole plan before the first write.'
        }
    }

    Reset-SubmissionScenario -Mode paged-existing
    Invoke-ChocolateySubmission @arguments | Out-Null
    if ($script:Pushes.Count -ne 0 -or $script:PageReads.Count -ne 12) {
        throw 'Exact existing versions on later pages must be found for every profile without another push.'
    }
    foreach ($mode in @('paged-different', 'paged-newer')) {
        Reset-SubmissionScenario -Mode $mode
        $expected = if ($mode -ceq 'paged-different') { '*Existing Chocolatey version has different bytes*' } else { '*newer stable Chocolatey version exists*' }
        Assert-SubmissionFailure { Invoke-ChocolateySubmission @arguments } $expected
        if ($script:Pushes.Count -ne 0 -or $script:PageReads.Count -ne 12 -or (Test-Path -LiteralPath "$temporary/output/chocolatey-submissions.json")) {
            throw 'A conflicting or newer sixth-profile version on a later page must block all publication writes.'
        }
    }

    $initialUri = 'https://community.chocolatey.org/api/v2/FindPackagesById()?id=%27grate%27'
    foreach ($links in @(
        @($initialUri),
        @($initialUri, $initialUri),
        @('https://outside.invalid/api/v2/FindPackagesById?id=%27grate%27'),
        @('http://community.chocolatey.org/api/v2/FindPackagesById?id=%27grate%27'),
        @('https://community.chocolatey.org:444/api/v2/FindPackagesById?id=%27grate%27'),
        @('https://community.chocolatey.org/api/v2/FindPackagesById?id=%27other%27'),
        @('https://community.chocolatey.org/api/v2/FindPackagesById?id=%27grate%27&id=%27grate%27')
    )) {
        $feed = New-ChocolateyFeedFixture -Id grate -PackageVersion '2.2.0' -NextLinks $links
        $readPage = {
            param(
                $uri
            )
            $feed
        }.GetNewClosure()
        Assert-SubmissionFailure { & $script:ActualPublicVersions -Id grate -ReadFeed $readPage | Out-Null } '*pagination*'
    }
    $pageCount = [Collections.Generic.List[string]]::new()
    $readMany = {
        param(
            $uri
        )
        $pageCount.Add($uri)
        $next = 'https://community.chocolatey.org/api/v2/FindPackagesById?id=%27grate%27&$skip=' + $pageCount.Count
        New-ChocolateyFeedFixture -Id grate -PackageVersion '2.2.0' -NextLinks @($next)
    }.GetNewClosure()
    Assert-SubmissionFailure { & $script:ActualPublicVersions -Id grate -ReadFeed $readMany | Out-Null } '*excessive or cyclic*'
    if ($pageCount.Count -ne 100) {
        throw 'Destination feed pagination did not stop at its bounded page limit.'
    }

    Reset-SubmissionScenario
    $oracle = "$temporary/candidates/grate-oracle.$version.nupkg"
    $originalBytes = [IO.File]::ReadAllBytes($oracle)
    [IO.File]::AppendAllText($oracle, 'changed after Windows verification')
    Assert-SubmissionFailure { Invoke-ChocolateySubmission @arguments } '*Candidate does not match the exact Windows-tested package*'
    if ($script:Pushes.Count -ne 0) {
        throw 'A changed sixth package must block all earlier pushes.'
    }
    [IO.File]::WriteAllBytes($oracle, $originalBytes)

    foreach ($field in @('SourceCommit', 'Status', 'ValidationRunId', 'PackageSha256', 'PublicExecutableSha256', 'ExpectedSQLiteVersion')) {
        Reset-SubmissionScenario
        $changed = $records | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $changed[-1].$field = 'wrong'
        $changed | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $gate
        Assert-SubmissionFailure { Invoke-ChocolateySubmission @arguments } '*'
        if ($script:Pushes.Count -ne 0) {
            throw "Misbound native evidence must block every push: $field"
        }
    }
    Reset-SubmissionScenario
    $changed = $records | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $changed[5].ChocolateyAllUpgrade = 'not performed'
    $changed | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $gate
    Assert-SubmissionFailure { Invoke-ChocolateySubmission @arguments } '*Duplicate, incorrect-source or non-passing*'
    if ($script:Pushes.Count -ne 0) {
        throw 'An unexecuted All upgrade must block Chocolatey publication.'
    }
    $records | Select-Object -Skip 1 | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $gate
    Reset-SubmissionScenario
    Assert-SubmissionFailure { Invoke-ChocolateySubmission @arguments } '*36 native channel records*'
    $records | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $gate

    Reset-SubmissionScenario
    $script:FailPushAt = 3
    Assert-SubmissionFailure { Invoke-ChocolateySubmission @arguments } '*Chocolatey submission failed*'
    $journalText = Get-Content -LiteralPath "$temporary/output/chocolatey-submissions.json" -Raw
    $journal = @($journalText | ConvertFrom-Json)
    if ($script:Pushes.Count -ne 3 -or $journal.Count -ne 3 -or
        $journal[0].Status -cne 'submitted_pending_validation_or_moderation' -or
        $journal[1].Status -cne 'submitted_pending_validation_or_moderation' -or
        $journal[2].Id -cne 'grate-sqlserver' -or $journal[2].Status -cne 'submission_failed_or_unknown' -or
        $journalText.Contains($apiKey)) {
        throw 'A failed push must stop later uploads and retain safe partial/uncertain publication evidence.'
    }
    Write-Output 'PASS: guarded Chocolatey promotion, six-package/native-evidence preflight, exact-existing reuse, divergent/newer refusal, late-package refusal, and redacted partial failure journal.'
} finally {
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name])
    }
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
