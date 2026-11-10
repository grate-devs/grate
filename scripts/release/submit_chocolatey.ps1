[CmdletBinding(DefaultParameterSetName = 'Publish')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Publish')][string]$Version,
    [Parameter(Mandatory, ParameterSetName = 'Publish')][string]$ReleaseRunId,
    [Parameter(Mandatory, ParameterSetName = 'Publish')][string]$SourceCommit,
    [Parameter(Mandatory, ParameterSetName = 'Publish')][string]$CandidateDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Publish')][string]$EvidencePath,
    [Parameter(Mandatory, ParameterSetName = 'Publish')][string]$OutputDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Library')][switch]$FunctionsOnly
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows_channel_common.ps1"

function Assert-ChocolateyPublicationHost {
    if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
        throw 'Chocolatey publication requires the isolated GitHub-hosted Windows publishing job.'
    }
    if ([string]::IsNullOrWhiteSpace($env:CHOCOLATEY_API_KEY)) {
        throw 'The repository secret CHOCOLATEY_API_KEY is not configured.'
    }
}

function Get-ChocolateyPublicVersions {
    param(
        [string]$Id
    )

    [xml]$feed = (Invoke-WebRequest -Uri "https://community.chocolatey.org/api/v2/FindPackagesById()?id=%27$Id%27" -TimeoutSec 60).Content
    return @($feed.SelectNodes("//*[local-name()='entry']//*[local-name()='Version']") | ForEach-Object InnerText)
}

function Save-ChocolateyPublicPackage {
    param(
        [string]$Id,
        [string]$Version,
        [string]$Path
    )

    Invoke-WebRequest -Uri "https://community.chocolatey.org/api/v2/package/$Id/$Version" -OutFile $Path -TimeoutSec 120
}

function Get-ChocolateySubmissionPlan {
    param(
        [string]$Version,
        [string]$ReleaseRunId,
        [string]$SourceCommit,
        [string]$CandidateDirectory,
        [string]$EvidencePath,
        [string]$OutputDirectory
    )

    $context = Get-WindowsChannelReleaseContext -Version $Version -ReleaseRunId $ReleaseRunId
    if ($context.SourceCommit -cne $SourceCommit) {
        throw 'The independently resolved release source differs from the verified source.'
    }
    $evidence = @(Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json)
    Assert-WindowsChannelEvidence -Records $evidence -Version $Version -ReleaseRunId $ReleaseRunId -SourceCommit $SourceCommit -ValidationRunId ([string]$env:GITHUB_RUN_ID) -ExpectedSQLiteVersion $context.ExpectedSQLiteVersion
    $packages = @(Get-ChildItem -LiteralPath $CandidateDirectory -Recurse -File -Filter '*.nupkg')
    if ($packages.Count -ne 6) {
        throw 'Exactly six retained Chocolatey candidates are required.'
    }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    foreach ($distribution in Get-GrateDistributionNames) {
        $profile = Get-GrateDistribution -Name $distribution
        $id = $profile.PackageId
        $package = @($packages | Where-Object Name -CEQ "$id.$Version.nupkg")
        $verified = @($evidence | Where-Object { $_.Channel -ceq 'chocolatey' -and $_.Distribution -ceq $distribution })
        if ($package.Count -ne 1 -or $verified.Count -ne 1 -or
            (Get-FileHash -LiteralPath $package[0].FullName -Algorithm SHA256).Hash -cne $verified[0].PackageSha256) {
            throw "Candidate does not match the exact Windows-tested package: $id"
        }
        $archive = [IO.Compression.ZipFile]::OpenRead($package[0].FullName)
        try {
            $specification = $archive.GetEntry("$id.nuspec")
            $payload = $archive.GetEntry('tools/grate.exe')
            if (!$specification -or !$payload) {
                throw "Incomplete retained Chocolatey package: $id"
            }
            $reader = [IO.StreamReader]::new($specification.Open())
            try {
                [xml]$nuspec = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
            $stream = $payload.Open()
            try {
                $embeddedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))
            } finally {
                $stream.Dispose()
            }
            if ($nuspec.package.metadata.id -cne $id -or $nuspec.package.metadata.version -cne $Version -or
                $embeddedHash -cne $verified[0].PublicExecutableSha256) {
                throw "Package identity or embedded executable changed after native validation: $id"
            }
        } finally {
            $archive.Dispose()
        }
        # Resolve every destination before the first push; a newer version or
        # different existing package must not cause a partial six-profile promotion.
        $versions = @(Get-ChocolateyPublicVersions -Id $id)
        if (@($versions | Where-Object { $_ -cmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z' -and [version]$_ -gt [version]$Version }).Count) {
            throw "A newer stable Chocolatey version exists; refusing an older promotion: $id"
        }
        $existing = $versions -ccontains $Version
        if ($existing) {
            $download = Join-Path $OutputDirectory "$id-existing.nupkg"
            Save-ChocolateyPublicPackage -Id $id -Version $Version -Path $download
            if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -cne $verified[0].PackageSha256) {
                throw "Existing Chocolatey version has different bytes; no overwrite is allowed: $id"
            }
            Remove-Item -LiteralPath $download
        }
        [pscustomobject]@{
            Id = $id
            Version = $Version
            Package = $package[0].FullName
            Sha256 = $verified[0].PackageSha256
            ExistingExactPackage = $existing
        }
    }
}

function Invoke-ChocolateyPackagePush {
    param(
        [string]$Package,
        [string]$Id,
        [string]$ApiKey
    )

    # Both streams are captured, never printed. A native tool or server may echo
    # its credential-bearing request even when GitHub masking is configured.
    $arguments = @('push', $Package, '--source=https://push.chocolatey.org/', "--api-key=$ApiKey", '--execution-timeout=500')
    try {
        $response = Invoke-ReleaseProcess -FilePath 'choco' -Arguments $arguments -TimeoutSeconds 600
    } catch {
        throw "Unable to invoke Chocolatey push for $Id."
    }
    if ($response.ExitCode -ne 0) {
        throw "Chocolatey push failed for $Id with exit $($response.ExitCode)."
    }
}

function Invoke-ChocolateySubmission {
    param(
        [string]$Version,
        [string]$ReleaseRunId,
        [string]$SourceCommit,
        [string]$CandidateDirectory,
        [string]$EvidencePath,
        [string]$OutputDirectory
    )

    Assert-ChocolateyPublicationHost
    $plan = @(Get-ChocolateySubmissionPlan @PSBoundParameters)
    $results = [Collections.Generic.List[object]]::new()
    $apiKey = $env:CHOCOLATEY_API_KEY.Trim()
    Remove-Item Env:CHOCOLATEY_API_KEY
    try {
        foreach ($item in $plan) {
            $record = [pscustomobject]@{
                Id = $item.Id
                Version = $Version
                SourceCommit = $SourceCommit
                ReleaseRunId = $ReleaseRunId
                ValidationRunId = [string]$env:GITHUB_RUN_ID
                PackageSha256 = $item.Sha256
                Status = 'already_available_exact_bytes'
                CheckedAt = [DateTimeOffset]::UtcNow.ToString('o')
            }
            if (!$item.ExistingExactPackage) {
                try {
                    Invoke-ChocolateyPackagePush -Package $item.Package -Id $item.Id -ApiKey $apiKey
                } catch {
                    # The feed may have accepted a package before a lost response.
                    # Retain that uncertainty alongside earlier successful uploads.
                    $record.Status = 'submission_failed_or_unknown'
                    $results.Add($record)
                    Write-ReleaseJson -Path "$OutputDirectory/chocolatey-submissions.json" -Value $results.ToArray()
                    throw "Chocolatey submission failed for $($item.Id). Inspect the account's package status before retrying; no native response or credentials were logged."
                }
                $record.Status = 'submitted_pending_validation_or_moderation'
            }
            $results.Add($record)
            Write-ReleaseJson -Path "$OutputDirectory/chocolatey-submissions.json" -Value $results.ToArray()
            Write-Output "$($item.Id) $Version`: $($record.Status)"
        }
    } finally {
        Remove-Variable apiKey -ErrorAction SilentlyContinue
    }
}

if (!$FunctionsOnly) {
    Invoke-ChocolateySubmission -Version $Version -ReleaseRunId $ReleaseRunId -SourceCommit $SourceCommit -CandidateDirectory $CandidateDirectory -EvidencePath $EvidencePath -OutputDirectory $OutputDirectory
}
