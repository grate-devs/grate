#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-publish-benchmark-tests-' + [Guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
$oldExit = $env:GRATE_BENCHMARK_MOCK_EXIT
$oldCommands = $env:GRATE_BENCHMARK_MOCK_COMMANDS
$hadNativeExitCode = $null -ne (Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue)
$oldNativeExitCode = $global:LASTEXITCODE

function Assert-Contract {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )

    if (!$Condition) {
        throw $Message
    }
}

function Invoke-FixtureGit {
    param(
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $result = & git @Arguments
    Assert-Contract ($LASTEXITCODE -eq 0) "Fixture git command failed: $Arguments"
    return $result
}

try {
    $repository = Join-Path $root 'repository'
    New-Item -ItemType Directory -Path "$repository/scripts/performance", "$root/bin" -Force | Out-Null
    $publisher = Join-Path $repository 'scripts/performance/Publish-CliBenchmark.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Publish-CliBenchmark.ps1') -Destination $publisher
    Set-Content -LiteralPath "$repository/.gitignore" -Value 'src/grate/bin/'
    Set-Content -LiteralPath "$repository/source.txt" -Value 'original source'
    Push-Location $repository
    try {
        Invoke-FixtureGit @('init', '--quiet') | Out-Null
        Invoke-FixtureGit @('add', '.') | Out-Null
        Invoke-FixtureGit @('-c', 'user.name=Benchmark fixture', '-c', 'user.email=benchmark@example.invalid', '-c', 'commit.gpgsign=false', '-c', "core.hooksPath=$root/empty-hooks", 'commit', '--quiet', '-m', 'Fixture source') | Out-Null
        $commit = Invoke-FixtureGit @('rev-parse', 'HEAD')
    }
    finally {
        Pop-Location
    }
    Set-Content -LiteralPath "$repository/source.txt" -Value 'modified source'
    Set-Content -LiteralPath "$repository/untracked.txt" -Value 'untracked source'
    # Real child processes preserve native argument/exit handling. No SDK or
    # network is used: the fake only implements the publisher's observed boundary.
    $mock = @'
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$nativeArguments = @()
for ($index = 0; $index -lt $args.Count; $index++) {
    if ($args[$index] -in @('-p', '-getProperty')) {
        $nativeArguments += $args[$index] + ':' + $args[++$index]
    }
    else {
        $nativeArguments += $args[$index]
    }
}
$args = $nativeArguments
@{ arguments = @($args) } | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:GRATE_BENCHMARK_MOCK_COMMANDS
if ($args[0] -eq '--version') {
    '11.0.100-test'
    exit 0
}
if ($args[0] -eq 'msbuild') {
    if ($args -contains '-getProperty:TargetFrameworks') {
        'net8.0;net11.0'
    }
    else {
        $properties = @{ Configuration = 'Debug'; RuntimeFrameworkVersion = '11.0.0-config'; PublishReadyToRun = 'false'; EnableCompressionInSingleFile = 'true'; IncludeAllContentForSelfExtract = 'true' }
        foreach ($argument in $args) {
            if ($argument.StartsWith('-p:')) {
                $pair = $argument.Substring(3).Split('=', 2)
                $properties[$pair[0]] = $pair[1]
            }
        }
        @{ Properties = $properties } | ConvertTo-Json -Depth 5
    }
    exit 0
}
if ($args[0] -ne 'publish') {
    throw "Unexpected fake dotnet command: $args"
}
'fixture publish diagnostic'
if ($env:GRATE_BENCHMARK_MOCK_EXIT) {
    exit ([int] $env:GRATE_BENCHMARK_MOCK_EXIT)
}
$output = $args[[Array]::IndexOf($args, '-o') + 1]
$rid = $args[[Array]::IndexOf($args, '-r') + 1]
$build = "src/grate/bin/Release/net11.0/$rid"
New-Item -ItemType Directory -Path $output, $build -Force | Out-Null
Set-Content -LiteralPath "$output/grate" -Value 'standalone fixture'
'{"runtimeOptions":{"includedFrameworks":[{"name":"Microsoft.NETCore.App","version":"11.0.1-pack"}]}}' | Set-Content -LiteralPath "$build/grate.runtimeconfig.json"
'@
    Set-Content -LiteralPath "$root/bin/mock.ps1" -Value $mock
    if ($IsWindows) {
        Set-Content -LiteralPath "$root/bin/dotnet.cmd" -Value "@echo off`r`n`"$PSHOME/pwsh.exe`" -NoLogo -NoProfile -File `"%~dp0mock.ps1`" %*`r`nexit /b %errorlevel%"
    }
    else {
        Set-Content -LiteralPath "$root/bin/dotnet" -Value $mock
        & chmod +x "$root/bin/dotnet"
        Assert-Contract ($LASTEXITCODE -eq 0) 'Cannot make fake dotnet executable.'
    }
    $env:PATH = "$root/bin$([IO.Path]::PathSeparator)$oldPath"
    $env:GRATE_BENCHMARK_MOCK_EXIT = $null
    $env:GRATE_BENCHMARK_MOCK_COMMANDS = "$root/commands.jsonl"
    $baseline = $null
    foreach ($candidate in @('baseline', 'uncompressed', 'selective-extraction', 'ready-to-run', 'native-aot')) {
        $output = "$root/$candidate"
        & $publisher -RuntimeIdentifier linux-arm64 -Candidate $candidate -OutputDirectory $output
        $manifest = Get-Content -LiteralPath "$output/build.json" -Raw | ConvertFrom-Json -AsHashtable
        Assert-Contract ($manifest.status -ceq 'published' -and $manifest.publishExitCode -eq 0) 'Successful publish status is incorrect.'
        Assert-Contract ($manifest.sourceCommit -ceq $commit -and $manifest.sourceDirty) 'Manifest lost the source identity/dirty state.'
        Assert-Contract ((Get-Content -LiteralPath "$output/source.patch" -Raw).Contains('+modified source')) 'Tracked source patch was not preserved.'
        Assert-Contract ($manifest.sourcePatchSha256 -ceq (Get-FileHash -LiteralPath "$output/source.patch").Hash.ToLowerInvariant()) 'Tracked source patch hash is incorrect.'
        Assert-Contract ($manifest.untrackedSource[0].sha256 -ceq (Get-FileHash -LiteralPath "$repository/untracked.txt").Hash.ToLowerInvariant()) 'Untracked source hash is incorrect.'
        Assert-Contract ($manifest.configuration -ceq 'Release' -and $manifest.publishProperties.Configuration -ceq 'Release') 'Effective settings were not queried in Release.'
        Assert-Contract ($manifest.sdkVersion -ceq '11.0.100-test' -and $manifest.targetFramework -ceq 'net11.0' -and $manifest.runtimeVersion -ceq '11.0.1-pack') 'SDK/framework/resolved runtime evidence is incorrect.'
        Assert-Contract ($manifest.executableSha256 -ceq (Get-FileHash -LiteralPath "$output/publish/grate").Hash.ToLowerInvariant()) 'Published executable hash is incorrect.'
        Assert-Contract ($manifest.runtimeIdentifier -ceq 'linux-arm64' -and $manifest.profile -ceq 'all-in-one' -and $manifest.candidate -ceq $candidate) 'Distribution identity is incorrect.'
        if ($candidate -eq 'baseline') {
            $baseline = $manifest.propertyOverrides
            Assert-Contract ($baseline.Count -eq 8 -and $baseline.SelfContained -ceq 'true' -and $baseline.TargetFrameworks -ceq 'net11.0') 'Baseline must retain self-contained publishing and only its eight shared investigation overrides.'
        }
        $expected = @{}
        foreach ($key in $baseline.Keys) {
            $expected[$key] = $baseline[$key]
        }
        switch ($candidate) {
            'uncompressed' { $expected.EnableCompressionInSingleFile = 'false' }
            'selective-extraction' { $expected.IncludeAllContentForSelfExtract = 'false' }
            'ready-to-run' { $expected.PublishReadyToRun = 'true' }
            'native-aot' {
                $expected.PublishAot = 'true'
                $expected.PublishSingleFile = 'false'
                $expected.EnableCompressionInSingleFile = 'false'
                $expected.IncludeAllContentForSelfExtract = 'false'
            }
        }
        Assert-Contract ($manifest.propertyOverrides.Count -eq $expected.Count) "Unexpected candidate override for $candidate."
        foreach ($key in $expected.Keys) {
            Assert-Contract ($manifest.propertyOverrides[$key] -ceq $expected[$key]) "Wrong $key override for $candidate."
        }
        $recorded = @(Get-Content -LiteralPath $env:GRATE_BENCHMARK_MOCK_COMMANDS | ForEach-Object { $_ | ConvertFrom-Json })[-1].arguments
        Assert-Contract (($manifest.publishCommand[1..($manifest.publishCommand.Count - 1)] -join "`n") -ceq ($recorded -join "`n")) 'Manifest publish command differs from actual native arguments.'
    }
    Set-Content -LiteralPath "$root/baseline/sentinel" -Value 'preserve me'
    $rejectedExisting = $false
    try {
        & $publisher -RuntimeIdentifier linux-arm64 -Candidate baseline -OutputDirectory "$root/baseline"
    }
    catch {
        $rejectedExisting = $_.Exception.Message -like '*new output directory*'
    }
    Assert-Contract ($rejectedExisting -and (Get-Content -LiteralPath "$root/baseline/sentinel") -ceq 'preserve me') 'Preexisting output was not rejected/preserved.'
    $env:GRATE_BENCHMARK_MOCK_EXIT = '23'
    $rejectedFailure = $false
    try {
        & $publisher -RuntimeIdentifier linux-arm64 -Candidate baseline -OutputDirectory "$root/failed"
    }
    catch {
        $rejectedFailure = $_.Exception.Message -like '*exit code 23*'
    }
    $failed = Get-Content -LiteralPath "$root/failed/build.json" -Raw | ConvertFrom-Json
    Assert-Contract ($rejectedFailure -and $failed.status -ceq 'publish-failed' -and $failed.publishExitCode -eq 23 -and $null -eq $failed.executableSha256) 'Failed publish did not propagate and retain an explicitly failed manifest.'
    Assert-Contract ((Get-Content -LiteralPath "$root/failed/publish.log" -Raw).Contains('fixture publish diagnostic')) 'Failed publish diagnostic log was lost.'
    Write-Host 'PASS: publisher source/runtime/effective-settings/executable manifest, isolated candidate overrides, output preservation and native failure propagation.'
}
finally {
    $env:PATH = $oldPath
    $env:GRATE_BENCHMARK_MOCK_EXIT = $oldExit
    $env:GRATE_BENCHMARK_MOCK_COMMANDS = $oldCommands
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    if ($hadNativeExitCode) {
        $global:LASTEXITCODE = $oldNativeExitCode
    }
    else {
        Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    }
}
