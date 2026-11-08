param(
    [Parameter(Mandatory)]
    [ValidateSet('linux-x64', 'linux-arm64')]
    [string]$RuntimeIdentifier,

    [Parameter(Mandatory)]
    [ValidateSet('baseline', 'uncompressed', 'selective-extraction', 'ready-to-run', 'native-aot')]
    [string]$Candidate,

    [Parameter(Mandatory)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) {
    throw 'Use a new output directory for each publish; stale artifacts invalidate comparisons.'
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null

function Invoke-DotnetQuery {
    param(
        [string[]]$Arguments
    )

    $result = & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet query failed with exit code $LASTEXITCODE."
    }
    return ($result -join "`n").Trim()
}

Push-Location $repository
try {
    $sourceCommit = & git rev-parse HEAD
    if ($LASTEXITCODE -ne 0) {
        throw 'Cannot identify the source commit.'
    }
    $sourceStatus = @(& git status --porcelain=v1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Cannot identify working tree changes.'
    }
    # Preserve the exact tracked patch as evidence when experimenting locally.
    & git diff HEAD --binary --output="$OutputDirectory/source.patch"
    if ($LASTEXITCODE -ne 0) {
        throw 'Cannot record the source patch.'
    }
    $untrackedFiles = @(& git ls-files --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) {
        throw 'Cannot identify untracked source files.'
    }
    $untrackedSource = @($untrackedFiles | ForEach-Object {
        [ordered]@{
            path = $_
            sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $sdkVersion = Invoke-DotnetQuery -Arguments @('--version')
    $frameworks = Invoke-DotnetQuery -Arguments @(
        'msbuild', 'src/grate/grate.csproj', '-nologo', '-getProperty:TargetFrameworks'
    )
    $framework = ($frameworks -split ';')[-1]
    # Override only one publishing factor per candidate. All profiles retain all
    # five providers, globalization, diagnostic messages and bundled resources.
    $properties = [ordered]@{
        TargetFrameworks = $framework
        SelfContained = 'true'
        SuppressTrimAnalysisWarnings = 'false'
        TrimmerSingleWarn = 'false'
        ILLinkTreatWarningsAsErrors = 'false'
        IlcTreatWarningsAsErrors = 'false'
        # Keep analyzer diagnostics visible while collecting feasibility evidence.
        # These diagnostics must be assessed before adopting a candidate.
        WarningsNotAsErrors = 'IL2026%3BIL3050'
        NoWarn = ''
    }
    switch ($Candidate) {
        'uncompressed' {
            $properties.EnableCompressionInSingleFile = 'false'
        }
        'selective-extraction' {
            $properties.IncludeAllContentForSelfExtract = 'false'
        }
        'ready-to-run' {
            $properties.PublishReadyToRun = 'true'
        }
        'native-aot' {
            $properties.PublishAot = 'true'
            # AOT supplies its own executable; SDK bundling is a different path.
            $properties.PublishSingleFile = 'false'
            $properties.EnableCompressionInSingleFile = 'false'
            $properties.IncludeAllContentForSelfExtract = 'false'
        }
    }
    $propertyArguments = @($properties.GetEnumerator() | ForEach-Object { "-p:$($_.Key)=$($_.Value)" })
    $queryArguments = @(
        'msbuild', 'src/grate/grate.csproj', '-nologo', '-p:Configuration=Release', "-p:TargetFramework=$framework",
        "-p:RuntimeIdentifier=$RuntimeIdentifier"
    ) + $propertyArguments + @(
        '-getProperty:PublishAot,PublishSingleFile,PublishTrimmed,TrimMode,PublishReadyToRun,PublishReadyToRunComposite,PublishReadyToRunUseCrossgen2,IncludeAllContentForSelfExtract,IncludeNativeLibrariesForSelfExtract,EnableCompressionInSingleFile,InvariantGlobalization,RuntimeFrameworkVersion'
    )
    $evaluated = Invoke-DotnetQuery -Arguments $queryArguments | ConvertFrom-Json -AsHashtable
    $publishArguments = @(
        'publish', 'src/grate/grate.csproj', '-c', 'Release', '-f', $framework,
        '-r', $RuntimeIdentifier, '--self-contained', 'true', '-o', "$OutputDirectory/publish"
    ) + $propertyArguments
    $manifest = [ordered]@{
        schemaVersion = 1
        sourceCommit = $sourceCommit.Trim()
        sourceDirty = $sourceStatus.Count -gt 0
        sourceStatus = $sourceStatus
        sourcePatchSha256 = (Get-FileHash -LiteralPath "$OutputDirectory/source.patch" -Algorithm SHA256).Hash.ToLowerInvariant()
        untrackedSource = $untrackedSource
        sdkVersion = $sdkVersion
        targetFramework = $framework
        runtimeVersion = $evaluated.Properties.RuntimeFrameworkVersion
        runtimeIdentifier = $RuntimeIdentifier
        configuration = 'Release'
        profile = 'all-in-one'
        candidate = $Candidate
        publishProperties = $evaluated.Properties
        propertyOverrides = $properties
        publishCommand = @('dotnet') + $publishArguments
        status = 'publishing'
        executableSha256 = $null
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$OutputDirectory/build.json" -Encoding utf8
    & dotnet @publishArguments 2>&1 | Tee-Object -FilePath "$OutputDirectory/publish.log" | Out-Host
    $publishExitCode = $LASTEXITCODE
    $manifest.publishExitCode = $publishExitCode
    if ($publishExitCode -ne 0) {
        $manifest.status = 'publish-failed'
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$OutputDirectory/build.json" -Encoding utf8
        throw "Publish failed with exit code $publishExitCode; inspect $OutputDirectory/publish.log."
    }
    $binary = Join-Path $OutputDirectory 'publish/grate'
    if (!(Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw 'Publish succeeded without the expected executable.'
    }
    $runtimeConfigPath = "src/grate/bin/Release/$framework/$RuntimeIdentifier/grate.runtimeconfig.json"
    $runtimeConfig = Get-Content -LiteralPath $runtimeConfigPath -Raw | ConvertFrom-Json
    $includedRuntime = @($runtimeConfig.runtimeOptions.includedFrameworks | Where-Object name -eq 'Microsoft.NETCore.App')
    if ($includedRuntime.Count -ne 1) {
        throw 'Cannot identify the self-contained runtime pack.'
    }
    $manifest.runtimeVersion = $includedRuntime[0].version
    Copy-Item -LiteralPath $runtimeConfigPath -Destination "$OutputDirectory/grate.runtimeconfig.json"
    $manifest.executableSha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.status = 'published'
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$OutputDirectory/build.json" -Encoding utf8
    Write-Host "Published $Candidate ($RuntimeIdentifier, $($manifest.runtimeVersion)): $binary"
}
finally {
    Pop-Location
}
