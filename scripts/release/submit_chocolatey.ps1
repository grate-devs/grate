param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$ReleaseRunId,
    [Parameter(Mandatory)][string]$SourceCommit,
    [Parameter(Mandatory)][string]$CandidateDirectory,
    [Parameter(Mandatory)][string]$EvidencePath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows_channel_common.ps1"
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Chocolatey publication requires the isolated GitHub-hosted Windows publishing job.'
}
if ([string]::IsNullOrWhiteSpace($env:CHOCOLATEY_API_KEY)) {
    throw 'The repository secret CHOCOLATEY_API_KEY is not configured.'
}
$context = Get-WindowsChannelReleaseContext -Version $Version -ReleaseRunId $ReleaseRunId
if ($context.SourceCommit -cne $SourceCommit) {
    throw 'The independently resolved release source differs from the verified source.'
}
$evidence = @(Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json)
Assert-WindowsChannelEvidence -Records $evidence -Version $Version -ReleaseRunId $ReleaseRunId -SourceCommit $SourceCommit -ValidationRunId ([string]$env:GITHUB_RUN_ID)
$packages = @(Get-ChildItem -LiteralPath $CandidateDirectory -Recurse -File -Filter '*.nupkg')
if ($packages.Count -ne 6) {
    throw 'Exactly six retained Chocolatey candidates are required.'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$plan = @(foreach ($distribution in Get-GrateDistributionNames) {
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
    # Inventory all six destinations before writing any package. Never use push
    # to test credentials and never replay an older release over a newer one.
    [xml]$feed = (Invoke-WebRequest -Uri "https://community.chocolatey.org/api/v2/FindPackagesById()?id=%27$id%27" -TimeoutSec 60).Content
    $versions = @($feed.SelectNodes("//*[local-name()='entry']//*[local-name()='Version']") | ForEach-Object InnerText)
    if (@($versions | Where-Object { $_ -cmatch '\A[0-9]+\.[0-9]+\.[0-9]+\z' -and [version]$_ -gt [version]$Version }).Count) {
        throw "A newer stable Chocolatey version exists; refusing an older promotion: $id"
    }
    $existing = $versions -ccontains $Version
    if ($existing) {
        $download = Join-Path $OutputDirectory "$id-existing.nupkg"
        Invoke-WebRequest -Uri "https://community.chocolatey.org/api/v2/package/$id/$Version" -OutFile $download -TimeoutSec 120
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
})
$results = [Collections.Generic.List[object]]::new()
$apiKey = $env:CHOCOLATEY_API_KEY.Trim()
Remove-Item Env:CHOCOLATEY_API_KEY
try {
    foreach ($item in $plan) {
        $state = 'already_available_exact_bytes'
        if (!$item.ExistingExactPackage) {
            # Capture all native output and return only fixed diagnostics, since
            # an external tool or server may echo its credential-bearing request.
            $PSNativeCommandUseErrorActionPreference = $false
            try {
                $response = & choco push $item.Package '--source=https://push.chocolatey.org/' "--api-key=$apiKey" --execution-timeout=500 2>&1
                $code = $LASTEXITCODE
            } catch {
                throw "Unable to invoke Chocolatey push for $($item.Id)."
            }
            if ($code -ne 0) {
                throw "Chocolatey push failed for $($item.Id) with exit $code. No response or credentials were logged; inspect the account's package status before retrying."
            }
            $state = 'submitted_pending_validation_or_moderation'
            Remove-Variable response
        }
        $results.Add([pscustomobject]@{
            Id = $item.Id
            Version = $Version
            SourceCommit = $SourceCommit
            ReleaseRunId = $ReleaseRunId
            ValidationRunId = [string]$env:GITHUB_RUN_ID
            PackageSha256 = $item.Sha256
            Status = $state
            CheckedAt = [DateTimeOffset]::UtcNow.ToString('o')
        })
        Write-ReleaseJson -Path "$OutputDirectory/chocolatey-submissions.json" -Value $results.ToArray()
        Write-Output "$($item.Id) $Version`: $state"
    }
} finally {
    Remove-Variable apiKey -ErrorAction SilentlyContinue
}
