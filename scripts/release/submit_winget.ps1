#!/usr/bin/env pwsh
param(
    [string]$Version,
    [string]$ReleaseRunId,
    [string]$SourceCommit,
    [string]$CandidateDirectory,
    [string]$OutputDirectory,
    [string]$ValidationRunId,
    [string]$EvidencePath,
    [string]$ForkRepository = 'erikbra/winget-pkgs',
    [switch]$FunctionsOnly,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/distribution_profiles.ps1"

function ConvertTo-WinGetManifestText {
    param(
        [string]$Text
    )

    # Only normalize BOM/newlines. Installer fields and their values are unchanged.
    $normalized = $Text.TrimStart([char]0xfeff).Replace("`r`n", "`n").Replace("`r", "`n")
    return $normalized.TrimEnd("`n").Replace("`n", "`r`n") + "`r`n"
}

function Invoke-WinGetGitHub {
    param(
        [string]$Endpoint,
        [string]$Method = 'GET',
        $Body,
        [switch]$AllowMissing
    )

    $arguments = @('api', '--method', $Method, $Endpoint)
    $inputFile = $null
    try {
        if ($null -ne $Body) {
            $inputFile = Join-Path ([IO.Path]::GetTempPath()) ('grate-winget-api-' + [guid]::NewGuid().ToString('N') + '.json')
            $Body | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $inputFile -Encoding utf8NoBOM
            $arguments += @('--input', $inputFile)
        }
        $response = Invoke-ReleaseProcess -FilePath 'gh' -Arguments $arguments -TimeoutSeconds 120
        if ($response.ExitCode -ne 0) {
            $failure = $null
            try {
                $failure = $response.Text | ConvertFrom-Json
            } catch {
                # Non-JSON errors are still failures; never emit credential-bearing stderr.
            }
            if ($AllowMissing -and [string]$failure.status -ceq '404') {
                return $null
            }
            throw "GitHub $Method failed for $Endpoint."
        }
        if ([string]::IsNullOrWhiteSpace($response.Text)) {
            return $null
        }
        return ($response.Text | ConvertFrom-Json)
    } finally {
        if ($inputFile) {
            Remove-Item -LiteralPath $inputFile -ErrorAction SilentlyContinue
        }
    }
}

function Get-WinGetCandidateSets {
    param(
        [string]$Directory,
        [string]$ExpectedVersion,
        [string]$ExpectedRunId,
        [string]$ExpectedCommit,
        $ReleaseManifest,
        $Release
    )

    $provenanceFiles = @(Get-ChildItem -LiteralPath $Directory -Filter 'provenance.json' -File -Recurse)
    $profiles = @(Get-GrateDistributionNames)
    if ($provenanceFiles.Count -ne $profiles.Count -or $ReleaseManifest.version -cne $ExpectedVersion -or
        $ReleaseManifest.tag -cne $ExpectedVersion -or $ReleaseManifest.repository -cne 'grate-devs/grate') {
        throw 'The complete official six-profile release candidate inventory is required.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $sets = foreach ($provenanceFile in $provenanceFiles) {
        $provenance = Get-Content -LiteralPath $provenanceFile.FullName -Raw | ConvertFrom-Json
        $profileName = [string]$provenance.Distribution
        if ($profileName -cnotin $profiles -or !$seen.Add($profileName)) {
            throw 'Unexpected or duplicate WinGet distribution provenance.'
        }
        $profile = Get-GrateDistribution -Name $profileName
        $identifier = if ($profileName -ceq 'All') { 'grate-devs.grate' } else { "grate-devs.grate.$profileName" }
        if ($provenance.Version -cne $ExpectedVersion -or $provenance.ReleaseTag -cne $ExpectedVersion -or
            [string]$provenance.RunId -cne $ExpectedRunId -or $provenance.SourceCommit -cne $ExpectedCommit -or
            $provenance.PackageIdentifier -cne $identifier -or $provenance.SchemaValidated -cne $true) {
            throw "WinGet provenance does not match the selected release: $identifier."
        }
        $packagePath = $identifier.Replace('.', '/')
        $versionPath = "manifests/g/$packagePath/$ExpectedVersion"
        $folder = Join-Path $provenanceFile.DirectoryName $versionPath
        $expectedNames = @("$identifier.yaml", "$identifier.installer.yaml", "$identifier.locale.en-US.yaml")
        $files = @(Get-ChildItem -LiteralPath $folder -File)
        if ($files.Count -ne 3 -or @(Compare-Object $expectedNames @($files.Name) -CaseSensitive).Count) {
            throw "Expected exactly three WinGet manifests for $identifier."
        }
        $contents = [ordered]@{}
        $rawHashes = [ordered]@{}
        foreach ($name in $expectedNames) {
            $filePath = Join-Path $folder $name
            $rawHashes[$name] = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
            $text = ConvertTo-WinGetManifestText (Get-Content -LiteralPath $filePath -Raw)
            $idMatches = [regex]::Matches($text, '(?m)^PackageIdentifier: ([^\r\n]+)\r?$')
            $versionMatches = [regex]::Matches($text, '(?m)^PackageVersion: ([^\r\n]+)\r?$')
            if ($idMatches.Count -ne 1 -or $idMatches[0].Groups[1].Value -cne $identifier -or
                $versionMatches.Count -ne 1 -or $versionMatches[0].Groups[1].Value -cne $ExpectedVersion -or
                $text -cnotmatch '(?m)^# yaml-language-server: \$schema=https://aka\.ms/winget-manifest\.(version|installer|defaultLocale)\.(1\.12\.0|1\.28\.0)\.schema\.json\r?$') {
                throw "Unexpected manifest identity or schema: $name."
            }
            $contents["$versionPath/$name"] = $text
        }
        $installer = $contents["$versionPath/$identifier.installer.yaml"]
        $pairs = [regex]::Matches($installer, '(?m)^\s*InstallerUrl: ([^\r\n]+)\r?\n\s*InstallerSha256: ([A-Fa-f0-9]{64})\r?$')
        $urls = [regex]::Matches($installer, '(?m)^\s*InstallerUrl: ')
        $expectedAssets = @(
            "$($profile.PackageId)-win-x86-self-contained-$ExpectedVersion.zip"
            "$($profile.PackageId)-win-x64-self-contained-$ExpectedVersion.zip"
            "$($profile.PackageId)-win-arm64-self-contained-$ExpectedVersion.zip"
            "$($profile.PackageId)-msi-win-x64-$ExpectedVersion.msi"
            "$($profile.PackageId)-msi-win-arm64-$ExpectedVersion.msi"
        )
        $assetNames = foreach ($pair in $pairs) {
            $url = $pair.Groups[1].Value
            $name = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
            $checksum = $pair.Groups[2].Value.ToLowerInvariant()
            $manifestAsset = @($ReleaseManifest.assets | Where-Object name -CEQ $name)
            $publicAsset = @($Release.assets | Where-Object name -CEQ $name)
            if ($url -cne "https://github.com/grate-devs/grate/releases/download/$ExpectedVersion/$name" -or
                $manifestAsset.Count -ne 1 -or $publicAsset.Count -ne 1 -or
                $manifestAsset[0].sha256 -cne $checksum -or $publicAsset[0].digest -cne "sha256:$checksum" -or
                [long]$manifestAsset[0].size -ne [long]$publicAsset[0].size) {
                throw "WinGet installer does not match the public release: $identifier/$name."
            }
            $name
        }
        if ($pairs.Count -ne 5 -or $urls.Count -ne 5 -or @(Compare-Object $expectedAssets @($assetNames) -CaseSensitive).Count) {
            throw "Wrong WinGet installer inventory: $identifier."
        }
        [pscustomobject]@{
            Identifier = $identifier
            Distribution = $profileName
            Version = $ExpectedVersion
            VersionPath = $versionPath
            Contents = $contents
            RawHashes = $rawHashes
        }
    }
    return @($sets | Sort-Object Identifier -CaseSensitive)
}

function Assert-WinGetVerificationEvidence {
    param(
        [string]$Path,
        [object[]]$Sets,
        [string]$ExpectedVersion,
        [string]$ExpectedRunId,
        [string]$ExpectedCommit,
        [string]$ExpectedValidationRunId
    )

    $records = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    if ($records.Count -ne 36) {
        throw 'The complete 36-record native channel evidence gate is required.'
    }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($set in $Sets) {
        foreach ($case in @('zip/x86', 'zip/x64', 'zip/arm64', 'wix/x64', 'wix/arm64')) {
            [void]$expected.Add("winget/$($set.Distribution)/$case")
        }
        [void]$expected.Add("chocolatey/$($set.Distribution)/zip/x64")
    }
    foreach ($record in $records) {
        $key = "$($record.Channel)/$($record.Distribution)/$($record.InstallerType)/$($record.Architecture)"
        if (!$expected.Remove($key) -or $record.Status -cne 'passed' -or $record.Version -cne $ExpectedVersion -or
            [string]$record.ReleaseRunId -cne $ExpectedRunId -or $record.SourceCommit -cne $ExpectedCommit -or
            [string]$record.ValidationRunId -cne $ExpectedValidationRunId) {
            throw "Missing, duplicate or misbound native validation record: $key."
        }
        if ($record.Channel -cne 'winget') {
            continue
        }
        $set = @($Sets | Where-Object Distribution -CEQ $record.Distribution)[0]
        $hashes = @($record.ManifestHashes)
        if ($record.WingetPackageIdentifier -cne $set.Identifier -or $hashes.Count -ne 3 -or
            @(Compare-Object @($set.RawHashes.Keys) @($hashes.Name) -CaseSensitive).Count) {
            throw "Wrong tested WinGet manifest inventory: $key."
        }
        foreach ($name in $set.RawHashes.Keys) {
            $hash = @($hashes | Where-Object Name -CEQ $name)
            if ($hash.Count -ne 1 -or $hash[0].Sha256 -cnotmatch '\A[A-Fa-f0-9]{64}\z' -or
                $hash[0].Sha256 -ine $set.RawHashes[$name]) {
                throw "WinGet manifest changed after native validation: $key/$name."
            }
        }
        if ($record.Distribution -ceq 'All' -and
            $record.LegacyMigration -cne 'passed; actual public 2.0.0 to final release through private PreIndexed source') {
            throw "The final All WinGet legacy migration did not pass: $key."
        }
    }
    if ($expected.Count -ne 0) {
        throw 'The native channel evidence gate omits required coverage.'
    }
}

function Assert-WinGetRemoteContents {
    param(
        $Set,
        [string]$Repository,
        [string]$Ref
    )

    $encodedRef = [Uri]::EscapeDataString($Ref)
    $listing = Invoke-WinGetGitHub "repos/$Repository/contents/$($Set.VersionPath)?ref=$encodedRef" -AllowMissing
    if ($null -eq $listing) {
        return $false
    }
    if (@($listing).Count -ne 3 -or @($listing | Where-Object type -CNE 'file').Count -gt 0 -or
        @(Compare-Object @($Set.Contents.Keys) @($listing.path) -CaseSensitive).Count) {
        throw "Remote WinGet manifest inventory differs: $($Set.Identifier)."
    }
    foreach ($path in $Set.Contents.Keys) {
        $remote = Invoke-WinGetGitHub "repos/$Repository/contents/${path}?ref=$encodedRef"
        if ($remote.encoding -cne 'base64') {
            throw 'Unexpected GitHub manifest encoding.'
        }
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($remote.content))
        if ((ConvertTo-WinGetManifestText $text) -cne $Set.Contents[$path]) {
            throw "Existing WinGet manifest differs from the selected release: $path."
        }
    }
    return $true
}

function Get-WinGetPullRequest {
    param(
        $Set,
        [string]$Fork,
        [string]$DefaultBranch
    )

    $query = [Uri]::EscapeDataString("repo:microsoft/winget-pkgs is:pr is:open `"$($Set.Identifier)`" in:title")
    $search = Invoke-WinGetGitHub "search/issues?q=$query&per_page=100"
    if ($search.incomplete_results -or $search.total_count -gt 100) {
        throw 'Could not establish the complete set of existing WinGet submissions.'
    }
    $matching = @()
    foreach ($item in $search.items) {
        $files = @(Invoke-WinGetGitHub "repos/microsoft/winget-pkgs/pulls/$($item.number)/files?per_page=100")
        # Package-scoped search only: a profile's filename is not the All filename.
        $identifierFile = "$($Set.Identifier).yaml"
        if (!@($files | Where-Object { [IO.Path]::GetFileName($_.filename) -ceq $identifierFile }).Count) {
            continue
        }
        $pr = Invoke-WinGetGitHub "repos/microsoft/winget-pkgs/pulls/$($item.number)"
        if ($pr.head.repo.full_name -cne $Fork -or $pr.base.ref -cne $DefaultBranch -or $pr.draft -or
            $files.Count -ne 3 -or @(Compare-Object @($Set.Contents.Keys) @($files.filename) -CaseSensitive).Count) {
            throw "Another open WinGet submission needs reconciliation for $($Set.Identifier): $($pr.html_url)."
        }
        if (!(Assert-WinGetRemoteContents -Set $Set -Repository $Fork -Ref $pr.head.sha)) {
            throw 'The existing pull request does not contain the selected release.'
        }
        $matching += $pr
    }
    if ($matching.Count -gt 1) {
        throw "Multiple open WinGet submissions exist for $($Set.Identifier)."
    }
    return $matching | Select-Object -First 1
}

function New-WinGetPullRequestBody {
    param(
        $Set,
        [string]$RunId,
        [string]$VerificationRunId,
        [string]$Commit
    )

    return @"
## 📖 Description

Add **$($Set.Identifier) $($Set.Version)** from the [official stable release](https://github.com/grate-devs/grate/releases/tag/$($Set.Version)). This PR contains only this package's three manifest files. Historical ``erikbra.grate`` manifests remain unchanged.

The original [release workflow](https://github.com/grate-devs/grate/actions/runs/$RunId) checked out immutable source ``$Commit``. All five installer URLs and hashes match the published GitHub assets and release manifest. The [Windows channel verification](https://github.com/grate-devs/grate/actions/runs/$VerificationRunId) validated and installed the final manifests and payloads; this submission does not rebuild the application.

This is a command-line tool. Invoking ``grate.exe`` without required arguments returns an expected argument-validation error; ``grate --help`` is the appropriate launch smoke check. SQLite-capable profiles additionally run an explicit migration probe.

## ✅ Checklist

- [ ] Microsoft Contributor License Agreement check (reported separately by the upstream service)
- [x] Related project context: [grate WinGet migration](https://github.com/grate-devs/grate/issues/800)

## 📦 Manifest Checklist

- [x] Checked for competing open pull requests for this package/version
- [x] This PR modifies exactly one package/version manifest set
- [x] Validated using ``winget validate --manifest`` on GitHub-hosted Windows
- [x] Installed using ``winget install --manifest`` on GitHub-hosted Windows
- [x] Uses the supported multi-file schema declared by the retained release candidate and checked by Windows validation

Upstream validation, moderator approval and public-source availability remain separate from submission.
"@
}

function Invoke-WinGetSubmission {
    param(
        [string]$SelectedVersion,
        [string]$RunId,
        [string]$Commit,
        [string]$Directory,
        [string]$Output,
        [string]$VerificationRunId,
        [string]$VerificationEvidence,
        [string]$Fork,
        [switch]$PlanOnly
    )

    if ($SelectedVersion -cnotmatch '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z' -or
        $RunId -notmatch '\A[1-9][0-9]*\z' -or $VerificationRunId -notmatch '\A[1-9][0-9]*\z' -or
        $Commit -cnotmatch '\A[a-f0-9]{40}\z' -or $Fork -cnotmatch '\A[A-Za-z0-9-]+/winget-pkgs\z') {
        throw 'Stable version, immutable source, numeric run IDs and an explicit winget-pkgs fork are required.'
    }
    if (!$env:GH_TOKEN) {
        throw 'GH_TOKEN must be supplied only to the WinGet publishing job.'
    }
    if ([string]::IsNullOrWhiteSpace($Directory) -or !(Test-Path -LiteralPath $Directory -PathType Container) -or
        [string]::IsNullOrWhiteSpace($Output) -or [string]::IsNullOrWhiteSpace($VerificationEvidence) -or $VerificationRunId -ceq $RunId) {
        throw 'Candidate/evidence paths and a separate channel-validation run are required.'
    }
    if (!$PlanOnly -and ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
        $env:GITHUB_REPOSITORY -cne 'grate-devs/grate' -or $env:GITHUB_RUN_ID -cne $VerificationRunId)) {
        throw 'WinGet writes require the matching isolated GitHub-hosted channel publishing job.'
    }
    $null = New-Item -ItemType Directory -Path $Output -Force
    $release = Invoke-WinGetGitHub "repos/grate-devs/grate/releases/tags/$SelectedVersion"
    $run = Invoke-WinGetGitHub "repos/grate-devs/grate/actions/runs/$RunId"
    $tag = Invoke-WinGetGitHub "repos/grate-devs/grate/git/ref/tags/$SelectedVersion"
    $tagObject = $tag.object
    for ($depth = 0; $tagObject.type -ceq 'tag' -and $depth -lt 5; $depth++) {
        $tagObject = (Invoke-WinGetGitHub "repos/grate-devs/grate/git/tags/$($tagObject.sha)").object
    }
    if ($release.draft -or $release.prerelease -or !$release.published_at -or $release.tag_name -cne $SelectedVersion -or
        $run.status -cne 'completed' -or $run.conclusion -cne 'success' -or $run.event -cne 'release' -or
        $run.path -cne '.github/workflows/build.yml' -or $run.head_sha -cne $Commit -or
        $run.head_repository.full_name -cne 'grate-devs/grate' -or $tagObject.type -cne 'commit' -or $tagObject.sha -cne $Commit) {
        throw 'The published release, successful release workflow and immutable tag do not agree.'
    }
    $manifestAssets = @($release.assets | Where-Object name -CEQ 'release-manifest.json')
    if ($manifestAssets.Count -ne 1) {
        throw 'The published release manifest is missing or ambiguous.'
    }
    $manifestResponse = Invoke-ReleaseHttp -Uri "https://github.com/grate-devs/grate/releases/download/$SelectedVersion/release-manifest.json" -MaxBytes 1048576
    if ((Get-ByteDigest $manifestResponse.Bytes) -cne $manifestAssets[0].digest) {
        throw 'The downloaded release manifest does not match the GitHub asset digest.'
    }
    $manifest = [Text.Encoding]::UTF8.GetString($manifestResponse.Bytes) | ConvertFrom-Json
    $sets = @(Get-WinGetCandidateSets -Directory $Directory -ExpectedVersion $SelectedVersion -ExpectedRunId $RunId -ExpectedCommit $Commit -ReleaseManifest $manifest -Release $release)
    Assert-WinGetVerificationEvidence -Path $VerificationEvidence -Sets $sets -ExpectedVersion $SelectedVersion -ExpectedRunId $RunId -ExpectedCommit $Commit -ExpectedValidationRunId $VerificationRunId
    $upstream = Invoke-WinGetGitHub 'repos/microsoft/winget-pkgs'
    $base = Invoke-WinGetGitHub "repos/microsoft/winget-pkgs/commits/$($upstream.default_branch)"
    $forkInfo = Invoke-WinGetGitHub "repos/$Fork"
    if (!$forkInfo.fork -or $forkInfo.parent.full_name -cne 'microsoft/winget-pkgs' -or !$forkInfo.permissions.push) {
        throw 'The configured identity cannot push to the expected WinGet fork.'
    }
    # Establish the complete plan before any external writes. An unrelated pending
    # package version or a divergent manifest must not cause a partial submission.
    $plans = foreach ($set in $sets) {
        if (Assert-WinGetRemoteContents -Set $set -Repository 'microsoft/winget-pkgs' -Ref $base.sha) {
            [pscustomobject]@{ Set = $set; State = 'already_public'; PullRequest = $null; Branch = $null; Head = $null }
            continue
        }
        $pr = Get-WinGetPullRequest -Set $set -Fork $Fork -DefaultBranch $upstream.default_branch
        if ($pr) {
            [pscustomobject]@{ Set = $set; State = 'existing_submission'; PullRequest = $pr; Branch = $pr.head.ref; Head = $pr.head.sha }
            continue
        }
        $branch = $set.Identifier.Replace('.', '-').ToLowerInvariant() + "-$SelectedVersion"
        $reference = Invoke-WinGetGitHub "repos/$Fork/git/ref/heads/$branch" -AllowMissing
        if ($reference) {
            if (!(Assert-WinGetRemoteContents -Set $set -Repository $Fork -Ref $reference.object.sha)) {
                throw "The existing submission branch is incomplete: $branch."
            }
            $comparison = Invoke-WinGetGitHub "repos/$Fork/compare/$($base.sha)...$($reference.object.sha)"
            if (@($comparison.files).Count -ne 3 -or @(Compare-Object @($set.Contents.Keys) @($comparison.files.filename) -CaseSensitive).Count) {
                throw "The existing submission branch changes unrelated files: $branch."
            }
        }
        [pscustomobject]@{ Set = $set; State = 'new_submission'; PullRequest = $null; Branch = $branch; Head = $reference.object.sha }
    }
    $results = @()
    foreach ($plan in $plans) {
        $set = $plan.Set
        $url = if ($plan.PullRequest) { $plan.PullRequest.html_url } else { $null }
        if (!$PlanOnly -and $plan.State -ceq 'new_submission') {
            if (!$plan.Head) {
                $entries = foreach ($path in $set.Contents.Keys) {
                    $blob = Invoke-WinGetGitHub "repos/$Fork/git/blobs" -Method POST -Body @{ content = $set.Contents[$path]; encoding = 'utf-8' }
                    @{ path = $path; mode = '100644'; type = 'blob'; sha = $blob.sha }
                }
                $tree = Invoke-WinGetGitHub "repos/$Fork/git/trees" -Method POST -Body @{ base_tree = $base.commit.tree.sha; tree = @($entries) }
                $createdCommit = Invoke-WinGetGitHub "repos/$Fork/git/commits" -Method POST -Body @{
                    message = "New package: $($set.Identifier) version $SelectedVersion"
                    tree = $tree.sha
                    parents = @($base.sha)
                }
                # Creating a new ref never replaces a concurrent actor's branch.
                $null = Invoke-WinGetGitHub "repos/$Fork/git/refs" -Method POST -Body @{ ref = "refs/heads/$($plan.Branch)"; sha = $createdCommit.sha }
                $plan.Head = $createdCommit.sha
            }
            $current = Invoke-WinGetGitHub "repos/$Fork/git/ref/heads/$($plan.Branch)"
            if ($current.object.sha -cne $plan.Head -or !(Assert-WinGetRemoteContents -Set $set -Repository $Fork -Ref $plan.Head)) {
                throw 'The submission branch changed before pull request creation.'
            }
            $owner = $Fork.Split('/')[0]
            $head = "${owner}:$($plan.Branch)"
            $open = @(Invoke-WinGetGitHub "repos/microsoft/winget-pkgs/pulls?state=open&head=$([Uri]::EscapeDataString($head))&per_page=100")
            if ($open.Count -gt 1) {
                throw 'Multiple pull requests unexpectedly reference the submission branch.'
            }
            $created = if ($open.Count -eq 1) {
                $open[0]
            } else {
                Invoke-WinGetGitHub 'repos/microsoft/winget-pkgs/pulls' -Method POST -Body @{
                    title = "New package: $($set.Identifier) version $SelectedVersion"
                    head = $head
                    base = $upstream.default_branch
                    body = New-WinGetPullRequestBody -Set $set -RunId $RunId -VerificationRunId $VerificationRunId -Commit $Commit
                    maintainer_can_modify = $true
                }
            }
            $url = $created.html_url
        }
        $results += [pscustomobject]@{
            Identifier = $set.Identifier
            Version = $SelectedVersion
            State = $plan.State
            PullRequest = $url
            Head = $plan.Head
            DryRun = [bool]$PlanOnly
            SourceCommit = $Commit
            ReleaseRunId = $RunId
            ValidationRunId = $VerificationRunId
        }
        Write-ReleaseJson -Path (Join-Path $Output 'winget-submissions.json') -Value $results
    }
    return $results
}

if (!$FunctionsOnly) {
    Invoke-WinGetSubmission -SelectedVersion $Version -RunId $ReleaseRunId -Commit $SourceCommit -Directory $CandidateDirectory -Output $OutputDirectory -VerificationRunId $ValidationRunId -VerificationEvidence $EvidencePath -Fork $ForkRepository -PlanOnly:$DryRun
}
