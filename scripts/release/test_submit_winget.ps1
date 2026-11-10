#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/submit_winget.ps1" -FunctionsOnly

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('grate-winget-submit-' + [guid]::NewGuid().ToString('N'))
$previousToken = $env:GH_TOKEN
$previousGitHubEnvironment = @{}
foreach ($name in @('GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT', 'GITHUB_REPOSITORY', 'GITHUB_RUN_ID')) {
    $previousGitHubEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$version = '2.3.4'
$source = '1' * 40
$baseSha = '2' * 40
$profiles = [ordered]@{
    All = @('grate', 'grate-devs.grate')
    SQLite = @('grate-sqlite', 'grate-devs.grate.SQLite')
    SQLServer = @('grate-sqlserver', 'grate-devs.grate.SQLServer')
    MariaDB = @('grate-mariadb', 'grate-devs.grate.MariaDB')
    PostgreSQL = @('grate-postgresql', 'grate-devs.grate.PostgreSQL')
    Oracle = @('grate-oracle', 'grate-devs.grate.Oracle')
}
$script:FixtureManifest = @{ repository = 'grate-devs/grate'; tag = $version; version = $version; assets = @() }
$script:FixtureRelease = @{ tag_name = $version; draft = $false; prerelease = $false; published_at = '2026-11-10T20:00:00Z'; assets = @() }
$script:Requests = [Collections.Generic.List[object]]::new()
$script:References = @{}
$script:Trees = @{}
$script:Commits = @{}
$script:PullRequests = @{}
$script:FakeNumber = 100
$script:Public = $false
$script:Divergent = $false

function Assert-Failure {
    param(
        [scriptblock]$Action,
        [string]$Message
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notlike $Message) {
            throw "Unexpected failure: $($_.Exception.Message); expected $Message."
        }
        return
    }
    throw "Expected failure: $Message."
}

function Get-FakeContents {
    param(
        [string]$Path,
        [string]$Ref
    )

    if ($Ref -ceq $baseSha -and !$script:Public) {
        return $null
    }
    $contents = if ($Ref -ceq $baseSha) { $script:AllContents } else { $script:Commits[$Ref] }
    if ($contents.Contains($Path)) {
        $text = $contents[$Path]
        if ($script:Divergent) {
            $text += '# changed after validation'
        }
        return @{ encoding = 'base64'; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }
    }
    foreach ($key in $contents.Keys) {
        if ($key.StartsWith($Path + '/', [StringComparison]::Ordinal)) {
            @{ path = $key; type = 'file' }
        }
    }
}

function Invoke-WinGetGitHub {
    param(
        [string]$Endpoint,
        [string]$Method = 'GET',
        $Body,
        [switch]$AllowMissing
    )

    $script:Requests.Add(@{ Method = $Method; Endpoint = $Endpoint; Body = $Body })
    switch -Regex ($Endpoint) {
        '^repos/grate-devs/grate/releases/tags/' { return $script:FixtureRelease }
        '^repos/grate-devs/grate/actions/runs/' {
            return @{ status = 'completed'; conclusion = 'success'; event = 'release'; path = '.github/workflows/build.yml'; head_sha = $source; head_repository = @{ full_name = 'grate-devs/grate' } }
        }
        '^repos/grate-devs/grate/git/ref/tags/' { return @{ object = @{ type = 'commit'; sha = $source } } }
        '^repos/microsoft/winget-pkgs$' { return @{ default_branch = 'master' } }
        '^repos/microsoft/winget-pkgs/commits/master$' { return @{ sha = $baseSha; commit = @{ tree = @{ sha = '3' * 40 } } } }
        '^repos/erikbra/winget-pkgs$' { return @{ fork = $true; parent = @{ full_name = 'microsoft/winget-pkgs' }; permissions = @{ push = $true } } }
        '^repos/[^/]+/winget-pkgs/contents/(.+)\?ref=(.+)$' { return Get-FakeContents -Path $Matches[1] -Ref ([Uri]::UnescapeDataString($Matches[2])) }
        '^search/issues\?q=([^&]+)' {
            $query = [Uri]::UnescapeDataString($Matches[1])
            $null = $query -match '"([^"]+)"'
            $identifier = $Matches[1]
            $items = @($script:PullRequests.Values | Where-Object Identifier -CEQ $identifier | ForEach-Object { @{ number = $_.number } })
            return @{ incomplete_results = $false; total_count = $items.Count; items = $items }
        }
        '^repos/microsoft/winget-pkgs/pulls/([0-9]+)/files' {
            return $script:PullRequests[[int]$Matches[1]].Files
        }
        '^repos/microsoft/winget-pkgs/pulls/([0-9]+)$' {
            return $script:PullRequests[[int]$Matches[1]]
        }
        '^repos/erikbra/winget-pkgs/git/ref/heads/(.+)$' {
            if ($script:References.ContainsKey($Matches[1])) {
                return @{ object = @{ sha = $script:References[$Matches[1]] } }
            }
            return $null
        }
        '^repos/erikbra/winget-pkgs/git/blobs$' {
            return @{ sha = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($Body.content))).ToLowerInvariant() }
        }
        '^repos/erikbra/winget-pkgs/git/trees$' {
            $script:FakeNumber++
            $sha = $script:FakeNumber.ToString('x40')
            $script:Trees[$sha] = $Body.tree
            return @{ sha = $sha }
        }
        '^repos/erikbra/winget-pkgs/git/commits$' {
            $script:FakeNumber++
            $sha = $script:FakeNumber.ToString('x40')
            $contents = [ordered]@{}
            foreach ($entry in $script:Trees[$Body.tree]) {
                $contents[$entry.path] = $script:AllContents[$entry.path]
            }
            $script:Commits[$sha] = $contents
            return @{ sha = $sha }
        }
        '^repos/erikbra/winget-pkgs/git/refs$' {
            $script:References[$Body.ref.Substring('refs/heads/'.Length)] = $Body.sha
            return @{ object = @{ sha = $Body.sha } }
        }
        '^repos/microsoft/winget-pkgs/pulls\?state=open&head=' { return @() }
        '^repos/microsoft/winget-pkgs/pulls$' {
            $script:FakeNumber++
            $number = $script:FakeNumber
            $null = $Body.title -match 'New package: ([^ ]+) version '
            $identifier = $Matches[1]
            $branch = $Body.head.Split(':')[1]
            $sha = $script:References[$branch]
            $pr = @{
                number = $number
                html_url = "https://github.com/microsoft/winget-pkgs/pull/$number"
                Identifier = $identifier
                draft = $false
                base = @{ ref = 'master' }
                head = @{ repo = @{ full_name = 'erikbra/winget-pkgs' }; ref = $branch; sha = $sha }
                Files = @($script:Commits[$sha].Keys | ForEach-Object { @{ filename = $_ } })
            }
            $script:PullRequests[$number] = $pr
            return $pr
        }
        default { throw "Unexpected mock GitHub request: $Method $Endpoint" }
    }
}

function Invoke-ReleaseHttp {
    param(
        [string]$Uri,
        [int]$MaxBytes
    )

    return @{ Bytes = $script:ManifestBytes }
}

try {
    $env:GH_TOKEN = 'test-only-not-a-token'
    $env:GITHUB_ACTIONS = 'true'
    $env:RUNNER_ENVIRONMENT = 'github-hosted'
    $env:GITHUB_REPOSITORY = 'grate-devs/grate'
    $env:GITHUB_RUN_ID = '67890'
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    $script:AllContents = [ordered]@{}
    foreach ($profile in $profiles.Keys) {
        $packageId, $identifier = $profiles[$profile]
        $root = Join-Path $temporary "candidates/$profile"
        $versionPath = "manifests/g/$($identifier.Replace('.', '/'))/$version"
        New-Item -ItemType Directory -Path "$root/$versionPath" -Force | Out-Null
        $installerNodes = @()
        foreach ($name in @("$packageId-win-x86-self-contained-$version.zip", "$packageId-win-x64-self-contained-$version.zip", "$packageId-win-arm64-self-contained-$version.zip", "$packageId-msi-win-x64-$version.msi", "$packageId-msi-win-arm64-$version.msi")) {
            $checksum = 'a' * 64
            $script:FixtureManifest.assets += @{ name = $name; sha256 = $checksum; size = 123 }
            $script:FixtureRelease.assets += @{ name = $name; digest = "sha256:$checksum"; size = 123 }
            $installerNodes += "- Architecture: x64`n  InstallerUrl: https://github.com/grate-devs/grate/releases/download/$version/$name`n  InstallerSha256: $checksum"
        }
        foreach ($type in @('version', 'installer', 'defaultLocale')) {
            $suffix = switch ($type) { 'version' { '' } 'installer' { '.installer' } 'defaultLocale' { '.locale.en-US' } }
            $name = "$identifier$suffix.yaml"
            $text = "# yaml-language-server: `$schema=https://aka.ms/winget-manifest.$type.1.12.0.schema.json`nPackageIdentifier: $identifier`nPackageVersion: $version`n"
            if ($type -ceq 'installer') {
                $text += ($installerNodes -join "`n") + "`n"
            }
            $text | Set-Content -LiteralPath "$root/$versionPath/$name" -Encoding utf8NoBOM
            $script:AllContents["$versionPath/$name"] = ConvertTo-WinGetManifestText $text
        }
        @{ Distribution = $profile; PackageIdentifier = $identifier; Version = $version; ReleaseTag = $version; RunId = '12345'; SourceCommit = $source; SchemaValidated = $true } |
            ConvertTo-Json | Set-Content -LiteralPath "$root/provenance.json" -Encoding utf8NoBOM
    }
    $script:ManifestBytes = [Text.Encoding]::UTF8.GetBytes(($script:FixtureManifest | ConvertTo-Json -Depth 10))
    $script:FixtureRelease.assets += @{ name = 'release-manifest.json'; digest = Get-ByteDigest $script:ManifestBytes }
    $records = @(foreach ($profile in $profiles.Keys) {
        $packageId, $identifier = $profiles[$profile]
        $folder = "$temporary/candidates/$profile/manifests/g/$($identifier.Replace('.', '/'))/$version"
        $hashes = @(Get-ChildItem -LiteralPath $folder -File | ForEach-Object { @{ Name = $_.Name; Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } })
        foreach ($case in @('zip/x86', 'zip/x64', 'zip/arm64', 'wix/x64', 'wix/arm64', 'chocolatey/x64')) {
            $parts = $case.Split('/')
            @{
                Channel = if ($parts[0] -ceq 'chocolatey') { 'chocolatey' } else { 'winget' }
                InstallerType = if ($parts[0] -ceq 'chocolatey') { 'zip' } else { $parts[0] }
                Architecture = $parts[1]
                Distribution = $profile
                PackageId = $packageId
                WingetPackageIdentifier = $identifier
                Version = $version
                ReleaseRunId = '12345'
                SourceCommit = $source
                ValidationRunId = '67890'
                ManifestHashes = $hashes
                LegacyMigration = if ($profile -ceq 'All') { 'passed; actual public 2.0.0 to final release through private PreIndexed source' } else { 'not applicable; separate slim identity' }
                Status = 'passed'
            }
        }
    })
    $gate = "$temporary/verified.json"
    $records | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $gate -Encoding utf8NoBOM
    $arguments = @{ SelectedVersion = $version; RunId = '12345'; Commit = $source; Directory = "$temporary/candidates"; Output = "$temporary/output"; VerificationRunId = '67890'; VerificationEvidence = $gate; Fork = 'erikbra/winget-pkgs' }

    $plan = @(Invoke-WinGetSubmission @arguments -PlanOnly)
    if ($plan.Count -ne 6 -or @($plan | Where-Object State -CNE 'new_submission').Count -or @($script:Requests | Where-Object Method -CNE 'GET').Count) {
        throw 'Read-only planning must validate all six candidates without external mutation.'
    }

    # A defect in the final profile must reject the complete set before any write.
    $oracleProvenance = "$temporary/candidates/Oracle/provenance.json"
    $original = Get-Content -LiteralPath $oracleProvenance -Raw
    $original.Replace('12345', '99999') | Set-Content -LiteralPath $oracleProvenance
    Assert-Failure { Invoke-WinGetSubmission @arguments | Out-Null } '*provenance does not match*'
    if (@($script:Requests | Where-Object Method -CNE 'GET').Count) {
        throw 'Invalid provenance must not partially submit other profiles.'
    }
    $original | Set-Content -LiteralPath $oracleProvenance

    $asset = $script:FixtureRelease.assets[0]
    $asset.digest = 'sha256:' + ('b' * 64)
    Assert-Failure { Invoke-WinGetSubmission @arguments | Out-Null } '*installer does not match the public release*'
    $asset.digest = 'sha256:' + ('a' * 64)

    $script:FixtureRelease.prerelease = $true
    Assert-Failure { Invoke-WinGetSubmission @arguments | Out-Null } '*published release*do not agree*'
    $script:FixtureRelease.prerelease = $false
    $script:FixtureRelease.draft = $true
    Assert-Failure { Invoke-WinGetSubmission @arguments | Out-Null } '*published release*do not agree*'
    $script:FixtureRelease.draft = $false

    $changedEvidence = $records | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $changedEvidence[0].ManifestHashes[0].Sha256 = 'b' * 64
    $changedEvidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $gate
    Assert-Failure { Invoke-WinGetSubmission @arguments | Out-Null } '*WinGet manifest changed after native validation*'
    $records | Select-Object -Skip 1 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $gate
    Assert-Failure { Invoke-WinGetSubmission @arguments | Out-Null } '*complete 36-record*'
    $changedEvidence = $records | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $changedEvidence[1] = $changedEvidence[0]
    $changedEvidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $gate
    Assert-Failure { Invoke-WinGetSubmission @arguments | Out-Null } '*duplicate or misbound native validation record*'
    $changedEvidence = $records | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $changedEvidence[0].ValidationRunId = '99999'
    $changedEvidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $gate
    Assert-Failure { Invoke-WinGetSubmission @arguments | Out-Null } '*duplicate or misbound native validation record*'
    $records | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $gate
    $env:GITHUB_RUN_ID = '99999'
    Assert-Failure { Invoke-WinGetSubmission @arguments | Out-Null } '*matching isolated GitHub-hosted*'
    $env:GITHUB_RUN_ID = '67890'

    $script:PullRequests[99] = @{
        number = 99
        Identifier = 'grate-devs.grate'
        html_url = 'https://github.com/microsoft/winget-pkgs/pull/99'
        draft = $false
        base = @{ ref = 'master' }
        head = @{ repo = @{ full_name = 'erikbra/winget-pkgs' }; ref = 'previous-version'; sha = '9' * 40 }
        Files = @($script:AllContents.Keys | Where-Object { $_ -match '/grate/2\.3\.4/' } | ForEach-Object { @{ filename = $_.Replace('/2.3.4/', '/2.2.0/') } })
    }
    Assert-Failure { Invoke-WinGetSubmission @arguments | Out-Null } '*Another open WinGet submission needs reconciliation*'
    if (@($script:Requests | Where-Object Method -CNE 'GET').Count) {
        throw 'A pending earlier package version must block competing first-time submissions before writes.'
    }
    $script:PullRequests.Remove(99)

    $submitted = @(Invoke-WinGetSubmission @arguments)
    $writes = @($script:Requests | Where-Object Method -CNE 'GET')
    if ($submitted.Count -ne 6 -or @($submitted | Where-Object { !$_.PullRequest }).Count -or
        @($writes | Where-Object Endpoint -CEQ 'repos/microsoft/winget-pkgs/pulls').Count -ne 6 -or
        @($writes | Where-Object Endpoint -CEQ 'repos/erikbra/winget-pkgs/git/refs').Count -ne 6) {
        throw 'The full valid set must produce exactly six independent package submissions.'
    }
    if (@($submitted | Where-Object SourceCommit -CNE $source).Count -or
        @($writes | Where-Object { $_.Endpoint -ceq 'repos/erikbra/winget-pkgs/git/refs' -and $_.Body.sha -cnotmatch '^[a-f0-9]{40}$' }).Count -or
        @($writes | Where-Object { $_.Endpoint -ceq 'repos/microsoft/winget-pkgs/pulls' -and !$_.Body.body.Contains($source) }).Count) {
        throw 'Created ref SHAs and PR provenance must preserve the original source commit.'
    }
    foreach ($tree in $script:Trees.Values) {
        if (@($tree).Count -ne 3 -or @($tree | Where-Object { $_.path -notmatch '^manifests/g/grate-devs/grate/' }).Count) {
            throw 'Only each package/version three-manifest set may be committed.'
        }
    }
    $writeCount = $writes.Count
    $reused = @(Invoke-WinGetSubmission @arguments)
    if ($reused.Count -ne 6 -or @($reused | Where-Object State -CNE 'existing_submission').Count -or
        @($script:Requests | Where-Object Method -CNE 'GET').Count -ne $writeCount) {
        throw 'Re-running submission must reuse identical open PRs without another write.'
    }
    $script:Divergent = $true
    Assert-Failure { Invoke-WinGetSubmission @arguments | Out-Null } '*Existing WinGet manifest differs*'
    $script:Divergent = $false
    $script:Public = $true
    $public = @(Invoke-WinGetSubmission @arguments)
    if (@($public | Where-Object State -CNE 'already_public').Count -or
        @($script:Requests | Where-Object Method -CNE 'GET').Count -ne $writeCount) {
        throw 'An identical already-public version must remain a read-only no-op.'
    }
    Write-Output 'PASS: complete-set/native-evidence/hash binding, wrong-context refusals, six isolated PRs, identical reruns, divergent PR refusal and existing public versions.'
} finally {
    $env:GH_TOKEN = $previousToken
    foreach ($name in $previousGitHubEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousGitHubEnvironment[$name])
    }
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
