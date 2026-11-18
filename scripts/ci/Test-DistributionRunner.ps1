#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PSScriptRoot/../release/release_common.ps1"
. "$PSScriptRoot/../release/release_test_helpers.ps1"

$runner = Join-Path $PSScriptRoot 'Invoke-DistributionTests.ps1'
$directory = New-TestDirectory
$pwsh = (Get-Process -Id $PID).Path
$savedPackages = $env:NUGET_PACKAGES
$savedExecutable = $env:GrateExecutablePath
$savedActions = @{
    GITHUB_SHA = $env:GITHUB_SHA
    GITHUB_RUN_ID = $env:GITHUB_RUN_ID
    GITHUB_RUN_ATTEMPT = $env:GITHUB_RUN_ATTEMPT
}
$initialLocation = (Get-Location).Path
$fixture = @{
    Events = [Collections.Generic.List[object]]::new()
    Aliases = [Collections.Generic.List[string]]::new()
    FailAt = ''
    Distribution = 'PostgreSQL'
    NativePublishes = [Collections.Generic.List[object]]::new()
}

function Get-FixtureArgument {
    param(
        [string[]]$Arguments,
        [string]$Name
    )

    $index = [Array]::IndexOf($Arguments, $Name)
    if ($index -lt 0) {
        throw "Missing argument $Name."
    }
    $Arguments[$index + 1]
}

function Get-FixtureProperty {
    param(
        [string[]]$Arguments,
        [string]$Name
    )

    $prefix = "-p:${Name}="
    $property = @($Arguments | Where-Object { $_.StartsWith($prefix) })
    Assert-Equal 1 $property.Count
    $property[0].Substring($prefix.Length)
}

function Register-FixtureExecutable {
    param(
        [string]$Path
    )

    New-Alias -Name $Path -Value Invoke-FixtureGrate -Scope Global -Force
    $fixture.Aliases.Add($Path)
}

function Invoke-FixtureGrate {
    $arguments = @($args)
    if ($arguments[0] -eq '--help') {
        $global:LASTEXITCODE = 0
        "This build supports $($fixture.Distribution) only."
    } elseif ($arguments[0] -eq '--databasetype') {
        $global:LASTEXITCODE = 1
        "This build supports $($fixture.Distribution) only."
    } elseif ($arguments[0] -eq 'skills') {
        $path = Get-FixtureArgument -Arguments $arguments -Name '--path'
        New-Item -ItemType Directory -Path "$path/.agents/skills/use-grate" -Force | Out-Null
        Set-Content -LiteralPath "$path/.agents/skills/use-grate/SKILL.md" -Value 'fixture'
        $global:LASTEXITCODE = 0
    } else {
        throw 'Unexpected fixture CLI invocation.'
    }
}

function New-FixtureNativeAotArchive {
    param(
        [string]$Path,
        [int]$UnixMode = 0x1ed
    )

    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry('grate')
        $entry.ExternalAttributes = (0x8000 -bor $UnixMode) -shl 16
        $writer = [IO.StreamWriter]::new($entry.Open())
        try {
            $writer.Write('exact native archive payload')
        } finally {
            $writer.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

function Invoke-FixtureNativeAotPublisher {
    param(
        [string]$Distribution,
        [string]$RuntimeIdentifier,
        [string]$Version,
        [string]$OutputDirectory
    )

    $fixture.NativePublishes.Add(@{
        Distribution = $Distribution
        RuntimeIdentifier = $RuntimeIdentifier
        Version = $Version
        OutputDirectory = $OutputDirectory
    })
    if ($fixture.FailAt -eq 'native-publish') {
        & $pwsh -NoProfile -Command 'exit 23'
        throw 'The native publisher failure was not propagated.'
    }
    New-Item -ItemType Directory -Path "$OutputDirectory/extracted" -Force | Out-Null
    Register-FixtureExecutable -Path "$OutputDirectory/extracted/grate"
}

function dotnet {
    $arguments = @($args)
    $fixture.Events.Add(@{
        Arguments = $arguments
        Packages = $env:NUGET_PACKAGES
        Executable = $env:GrateExecutablePath
    })
    if ($fixture.FailAt -eq $arguments[0] -or
        ($fixture.FailAt -eq 'suite' -and $arguments[0].EndsWith('.dll'))) {
        # Use a real native failure, so the runner's ErrorActionPreference is tested.
        & $pwsh -NoProfile -Command 'exit 23'
        throw 'The native failure was not propagated.'
    }
    $global:LASTEXITCODE = 0
    switch ($arguments[0]) {
        'msbuild' {
            'net8.0;net9.0;net10.0;net11.0'
        }
        'publish' {
            $output = Get-FixtureArgument -Arguments $arguments -Name '-o'
            $build = Get-FixtureProperty -Arguments $arguments -Name 'ArtifactsPath'
            New-Item -ItemType Directory -Path "$build/bin/grate/release_net11.0_linux-x64" -Force | Out-Null
            $dependencies = @{ libraries = @{ 'grate.postgresql/1' = @{}; 'Npgsql/1' = @{} } }
            $dependencies | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$build/bin/grate/release_net11.0_linux-x64/grate.deps.json"
            Register-FixtureExecutable -Path "$output/grate"
        }
        'pack' {
            $output = Get-FixtureArgument -Arguments $arguments -Name '-o'
            $version = Get-FixtureProperty -Arguments $arguments -Name 'PackageVersion'
            New-Item -ItemType Directory -Path $output -Force | Out-Null
            $package = [IO.Compression.ZipFile]::Open("$output/grate-postgresql.$version.nupkg", [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($framework in @('net8.0', 'net9.0', 'net10.0', 'net11.0')) {
                    $entries = @{
                        'grate.deps.json' = '{"libraries":{"grate.postgresql/1":{},"Npgsql/1":{}}}'
                        'DotnetToolSettings.xml' = '<DotNetCliTool><Commands><Command Name="grate" /></Commands></DotNetCliTool>'
                    }
                    foreach ($name in $entries.Keys) {
                        $entry = $package.CreateEntry("tools/$framework/any/$name")
                        $writer = [IO.StreamWriter]::new($entry.Open())
                        try {
                            $writer.Write($entries[$name])
                        } finally {
                            $writer.Dispose()
                        }
                    }
                }
            } finally {
                $package.Dispose()
            }
        }
        'tool' {
            $output = Get-FixtureArgument -Arguments $arguments -Name '--tool-path'
            Register-FixtureExecutable -Path "$output/grate"
        }
        'build' {
            $build = Get-FixtureProperty -Arguments $arguments -Name 'ArtifactsPath'
            $project = [IO.Path]::GetFileNameWithoutExtension($arguments[1])
            $path = "$build/bin/$project/release_net11.0"
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Set-Content -LiteralPath "$path/$project.dll" -Value 'fixture'
            Set-Content -LiteralPath "$path/$project.deps.json" -Value '{}'
            Set-Content -LiteralPath "$path/$project.runtimeconfig.json" -Value '{}'
            Set-Content -LiteralPath "$path/xunit.runner.json" -Value '{}'
            $null = New-Item -ItemType Directory -Path "$path/nested"
            Set-Content -LiteralPath "$path/nested/provider-fixture.sql" -Value 'select 1;'
        }
        default {
            Assert-True ($arguments[0] -match '/CommandLine\.(PostgreSQL|SqlServerCaseSensitive)\.dll$')
        }
    }
}

$publisher = "$PSScriptRoot/../release/Publish-NativeAot.ps1"
New-Alias -Name $publisher -Value Invoke-FixtureNativeAotPublisher -Scope Global -Force
$fixture.Aliases.Add($publisher)

try {
    $env:NUGET_PACKAGES = 'fixture-original-cache'
    $env:GrateExecutablePath = 'fixture-original-executable'
    Invoke-Test 'matching suites use exact fresh artifacts, isolated installation and normal All test references' {
        $output = Join-Path $directory 'successful run'
        & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory $output
        Assert-Equal 'fixture-original-cache' $env:NUGET_PACKAGES
        Assert-Equal 'fixture-original-executable' $env:GrateExecutablePath
        Assert-Equal $initialLocation (Get-Location).Path
        $install = @($fixture.Events | Where-Object { $_.Arguments[0] -eq 'tool' })
        Assert-Equal 1 $install.Count
        Assert-Equal "$output/tool-cache" $install[0].Packages
        [xml]$configuration = Get-Content -LiteralPath "$output/NuGet.Config" -Raw
        Assert-True ($null -ne $configuration.configuration.packageSources.clear)
        Assert-Equal "$output/packages" $configuration.configuration.packageSources.add.value
        $build = @($fixture.Events | Where-Object { $_.Arguments[0] -eq 'build' })
        Assert-Equal 1 $build.Count
        Assert-Equal 'fixture-original-cache' $build[0].Packages
        Assert-Equal 0 @($build[0].Arguments | Where-Object { $_.StartsWith('-p:GrateDistribution=') }).Count
        $runs = @($fixture.Events | Where-Object { $_.Arguments[0].EndsWith('/CommandLine.PostgreSQL.dll') })
        Assert-Equal 2 $runs.Count
        Assert-Equal @("$output/standalone/grate", "$output/tool/grate") @($runs.Executable)
        foreach ($run in $runs) {
            Assert-True ($run.Arguments -contains '--minimum-expected-tests')
        }
    }
    Invoke-Test 'native installation failure stops test execution and restores caller environment and location' {
        $fixture.Events.Clear()
        $fixture.FailAt = 'tool'
        $output = Join-Path $directory 'failed run'
        Assert-Throws { & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory $output } '*23*'
        Assert-Equal 0 @($fixture.Events | Where-Object { $_.Arguments[0] -eq 'build' }).Count
        Assert-Equal 'fixture-original-cache' $env:NUGET_PACKAGES
        Assert-Equal 'fixture-original-executable' $env:GrateExecutablePath
        Assert-Equal $initialLocation (Get-Location).Path
    }
    Invoke-Test 'NativeAOT archive runs the exact unpacked CLI with all provider tests and ordinary JIT references' {
        $fixture.Events.Clear()
        $fixture.NativePublishes.Clear()
        $fixture.FailAt = ''
        $output = Join-Path $directory 'native archive run'
        $archive = Join-Path $directory 'grate-postgresql-linux-x64-nativeaot-1.2.3.zip'
        New-FixtureNativeAotArchive -Path $archive
        Register-FixtureExecutable -Path "$output/nativeaot/extracted/grate"
        & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory $output -NativeAot -NativeAotArchive $archive
        Assert-Equal 'exact native archive payload' (Get-Content -LiteralPath "$output/nativeaot/extracted/grate" -Raw)
        Assert-Equal @('msbuild', 'build') @($fixture.Events | Where-Object { !$_.Arguments[0].EndsWith('.dll') } | ForEach-Object { $_.Arguments[0] })
        $build = @($fixture.Events | Where-Object { $_.Arguments[0] -eq 'build' })
        Assert-Equal 0 @($build[0].Arguments | Where-Object { $_ -match 'PublishAot|GrateDistribution|SelfContained' }).Count
        $runs = @($fixture.Events | Where-Object { $_.Arguments[0].EndsWith('/CommandLine.PostgreSQL.dll') })
        Assert-Equal 1 $runs.Count
        Assert-Equal "$output/nativeaot/extracted/grate" $runs[0].Executable
        Assert-True ($runs[0].Arguments -contains '--minimum-expected-tests')
        Assert-Equal 0 @($runs[0].Arguments | Where-Object { $_.StartsWith('--filter') }).Count
        Assert-True (Test-Path -LiteralPath "$output/skills-nativeaot/.agents/skills/use-grate/SKILL.md")
        Assert-True (!(Test-Path -LiteralPath "$output/packages"))
        Assert-Equal 0 $fixture.NativePublishes.Count
        Assert-Equal 'fixture-original-cache' $env:NUGET_PACKAGES
        Assert-Equal 'fixture-original-executable' $env:GrateExecutablePath
    }
    Invoke-Test 'NativeAOT local mode delegates to the shared publisher and preserves SQL Server case-sensitive suite selection' {
        $fixture.Events.Clear()
        $fixture.NativePublishes.Clear()
        $fixture.FailAt = ''
        $fixture.Distribution = 'SQLServer'
        $output = Join-Path $directory 'native publisher run'
        & $runner -Distribution SQLServer -Database SqlServerCaseSensitive -OutputDirectory $output -NativeAot
        Assert-Equal 1 $fixture.NativePublishes.Count
        Assert-Equal 'SQLServer' $fixture.NativePublishes[0].Distribution
        Assert-Equal 'linux-x64' $fixture.NativePublishes[0].RuntimeIdentifier
        Assert-Equal "$output/nativeaot" $fixture.NativePublishes[0].OutputDirectory
        Assert-True ($fixture.NativePublishes[0].Version.StartsWith('0.0.0-ci.'))
        $runs = @($fixture.Events | Where-Object { $_.Arguments[0].EndsWith('.dll') })
        Assert-Equal 1 $runs.Count
        Assert-True ($runs[0].Arguments[0].EndsWith('/CommandLine.SqlServerCaseSensitive.dll'))
        Assert-Equal "$output/nativeaot/extracted/grate" $runs[0].Executable
        Assert-Equal 0 @($fixture.Events | Where-Object { $_.Arguments[0] -in @('publish', 'pack', 'tool') }).Count
    }
    Invoke-Test 'NativeAOT publisher failure stops builds and restores caller environment and location' {
        $fixture.Events.Clear()
        $fixture.FailAt = 'native-publish'
        $output = Join-Path $directory 'native publisher failed run'
        Assert-Throws { & $runner -Distribution SQLServer -Database SqlServerCaseSensitive -OutputDirectory $output -NativeAot } '*23*'
        Assert-Equal 0 @($fixture.Events | Where-Object { $_.Arguments[0] -eq 'build' }).Count
        Assert-Equal 'fixture-original-cache' $env:NUGET_PACKAGES
        Assert-Equal 'fixture-original-executable' $env:GrateExecutablePath
        Assert-Equal $initialLocation (Get-Location).Path
    }
    Invoke-Test 'NativeAOT test failure propagates and restores caller environment and location' {
        $fixture.Events.Clear()
        $fixture.Distribution = 'PostgreSQL'
        $fixture.FailAt = 'suite'
        $output = Join-Path $directory 'native suite failed run'
        $archive = Join-Path $directory 'grate-postgresql-linux-x64-nativeaot-suite-failure.zip'
        New-FixtureNativeAotArchive -Path $archive
        Register-FixtureExecutable -Path "$output/nativeaot/extracted/grate"
        Assert-Throws { & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory $output -NativeAot -NativeAotArchive $archive } '*23*'
        Assert-Equal 'fixture-original-cache' $env:NUGET_PACKAGES
        Assert-Equal 'fixture-original-executable' $env:GrateExecutablePath
        Assert-Equal $initialLocation (Get-Location).Path
    }
    Invoke-Test 'NativeAOT archives require opt-in and matching distribution and runtime names' {
        $fixture.Events.Clear()
        $output = Join-Path $directory 'native invalid archive run'
        $archive = Join-Path $directory 'grate-postgresql-linux-x64-nativeaot-1.2.3.zip'
        Assert-Throws { & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory $output -NativeAotArchive $archive } '*requires -NativeAot*'
        Assert-Equal 0 $fixture.Events.Count
        Assert-Throws { & $runner -Distribution All -Database PostgreSQL -OutputDirectory $output -NativeAot -NativeAotArchive $archive } '*name must match*'
        Assert-Equal 0 @($fixture.Events | Where-Object { $_.Arguments[0] -eq 'build' }).Count
    }
    if (!$IsWindows) {
        Invoke-Test 'NativeAOT archive missing executable permissions fails before tests instead of repairing release payload' {
            $fixture.Events.Clear()
            $output = Join-Path $directory 'native missing mode run'
            $archive = Join-Path $directory 'grate-postgresql-linux-x64-nativeaot-no-mode.zip'
            New-FixtureNativeAotArchive -Path $archive -UnixMode 0x1a4
            Assert-Throws { & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory $output -NativeAot -NativeAotArchive $archive } '*no Unix execute bits*'
            Assert-Equal 0 @($fixture.Events | Where-Object { $_.Arguments[0] -eq 'build' }).Count
        }
    }
    $env:GITHUB_SHA = (git -C (Join-Path $PSScriptRoot '../..') rev-parse HEAD).Trim()
    $env:GITHUB_RUN_ID = '12345'
    $env:GITHUB_RUN_ATTEMPT = '1'
    $prepared = Join-Path $directory 'test payload'
    $archive = Join-Path $directory 'grate-postgresql-linux-x64-nativeaot-prepared.zip'
    New-FixtureNativeAotArchive -Path $archive
    Invoke-Test 'prepare one complete JIT project and reuse its same-run payload in a later attempt' {
        $fixture.Events.Clear()
        $fixture.FailAt = ''
        & "$PSScriptRoot/Prepare-NativeAotTests.ps1" -Database PostgreSQL -OutputDirectory $prepared
        $build = @($fixture.Events | Where-Object { $_.Arguments[0] -ceq 'build' })
        Assert-Equal 1 $build.Count
        Assert-True ($build[0].Arguments[1].EndsWith('/CommandLine.PostgreSQL.csproj'))
        Assert-Equal 'Release' (Get-FixtureArgument -Arguments $build[0].Arguments -Name '-c')
        Assert-Equal 'net11.0' (Get-FixtureProperty -Arguments $build[0].Arguments -Name 'TargetFrameworks')
        Assert-Equal 0 @($build[0].Arguments | Where-Object { $_ -match '(PublishAot|GrateDistribution|SelfContained)' }).Count
        Assert-True (Test-Path -LiteralPath "$prepared/payload/nested/provider-fixture.sql" -PathType Leaf)

        $env:GITHUB_RUN_ATTEMPT = '2'
        $fixture.Events.Clear()
        $output = Join-Path $directory 'prepared aot tests'
        Register-FixtureExecutable -Path "$output/nativeaot/extracted/grate"
        & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory $output -NativeAot -NativeAotArchive $archive -PreparedTestsDirectory $prepared
        Assert-Equal 2 $fixture.Events.Count
        Assert-Equal 'msbuild' $fixture.Events[0].Arguments[0]
        Assert-Equal "$prepared/payload/CommandLine.PostgreSQL.dll" $fixture.Events[1].Arguments[0]
        Assert-Equal "$output/nativeaot/extracted/grate" $fixture.Events[1].Executable
        Assert-True ($fixture.Events[1].Arguments -contains '--minimum-expected-tests')
        Assert-Equal 0 @($fixture.Events[1].Arguments | Where-Object { $_.StartsWith('--filter') }).Count
        Assert-Equal 'exact native archive payload' (Get-Content -LiteralPath "$output/nativeaot/extracted/grate" -Raw)
    }
    Invoke-Test 'prepared test payload cannot be silently replaced by a fresh build' {
        $fixture.Events.Clear()
        $output = Join-Path $directory 'missing test payload run'
        $missing = Join-Path $directory 'missing test payload'
        Assert-Throws { & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory $output -NativeAot -NativeAotArchive $archive -PreparedTestsDirectory $missing } '*Missing prepared NativeAOT test directory*'
        Assert-Throws { & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory $output -NativeAot -NativeAotArchive $archive -PreparedTestsDirectory '' } '*requires a nonempty directory*'
        Assert-Throws { & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory $output -PreparedTestsDirectory $prepared } '*Linux x64 NativeAOT archive*'
        Assert-Equal 1 $fixture.Events.Count
        Assert-Equal 'msbuild' $fixture.Events[0].Arguments[0]
        Assert-True (!(Test-Path -LiteralPath $output))
    }
    Invoke-Test 'prepared tests reject wrong provenance, future attempts, and altered or incomplete contents' {
        $cases = @(
            @{ Name = 'other checkout'; Error = '*mismatch for SourceRevision*'; Change = { param($path, $manifest) $manifest.Identity.SourceRevision = 'a' * 40 } }
            @{ Name = 'other run'; Error = '*mismatch for RunId*'; Change = { param($path, $manifest) $manifest.Identity.RunId = '67890' } }
            @{ Name = 'other project'; Error = '*mismatch for Project*'; Change = { param($path, $manifest) $manifest.Identity.Project = 'CommandLine.Sqlite' } }
            @{ Name = 'other framework'; Error = '*mismatch for Framework*'; Change = { param($path, $manifest) $manifest.Identity.Framework = 'net10.0' } }
            @{ Name = 'other RID'; Error = '*mismatch for RuntimeIdentifier*'; Change = { param($path, $manifest) $manifest.Identity.RuntimeIdentifier = 'linux-arm64' } }
            @{ Name = 'future attempt'; Error = '*invalid or future producer attempt*'; Change = { param($path, $manifest) $manifest.Attempt = 3 } }
            @{ Name = 'altered fixture'; Error = '*integrity mismatch*'; Change = { param($path, $manifest) Add-Content -LiteralPath "$path/payload/nested/provider-fixture.sql" -Value 'select 2;' } }
            @{ Name = 'missing fixture'; Error = '*inventory does not match*'; Change = { param($path, $manifest) Remove-Item -LiteralPath "$path/payload/nested/provider-fixture.sql" } }
            @{ Name = 'extra file'; Error = '*inventory does not match*'; Change = { param($path, $manifest) Set-Content -LiteralPath "$path/payload/untracked.dll" -Value 'unexpected' } }
            @{ Name = 'extra manifest hash'; Error = '*inventory does not match*'; Change = { param($path, $manifest) $manifest.Files += @{ Path = 'untracked.dll'; Sha256 = 'A' * 64 } } }
            @{ Name = 'duplicate hash entry'; Error = '*Invalid prepared NativeAOT test file inventory*'; Change = { param($path, $manifest) $manifest.Files += $manifest.Files[0] } }
            @{ Name = 'extra root file'; Error = '*Expected only the prepared NativeAOT test payload*'; Change = { param($path, $manifest) Set-Content -LiteralPath "$path/untracked.dll" -Value 'unexpected' } }
            @{ Name = 'missing test config'; Error = '*missing xunit.runner.json*'; Change = {
                param($path, $manifest)
                Remove-Item -LiteralPath "$path/payload/xunit.runner.json"
                $manifest.Files = @($manifest.Files | Where-Object Path -CNE 'xunit.runner.json')
            } }
        )
        foreach ($case in $cases) {
            $fixture.Events.Clear()
            $altered = Join-Path $directory $case.Name
            Copy-Item -LiteralPath $prepared -Destination $altered -Recurse -Force
            $manifestPath = Join-Path $altered 'manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
            & $case.Change $altered $manifest
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath
            $output = Join-Path $directory 'invalid prepared payload run'
            Assert-Throws { & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory $output -NativeAot -NativeAotArchive $archive -PreparedTestsDirectory $altered } $case.Error
            Assert-Equal 1 $fixture.Events.Count
            Assert-Equal 'msbuild' $fixture.Events[0].Arguments[0]
            Assert-True (!(Test-Path -LiteralPath $output))
        }
    }
    Write-Host "PASS: $script:TestCount distribution runner contract scenarios."
} finally {
    foreach ($name in $fixture.Aliases) {
        Remove-Alias -Name $name -Scope Global -ErrorAction SilentlyContinue
    }
    $env:NUGET_PACKAGES = $savedPackages
    $env:GrateExecutablePath = $savedExecutable
    foreach ($name in $savedActions.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedActions[$name])
    }
    Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
}
