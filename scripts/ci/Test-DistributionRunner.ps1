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
$initialLocation = (Get-Location).Path
$fixture = @{
    Events = [Collections.Generic.List[object]]::new()
    Aliases = [Collections.Generic.List[string]]::new()
    FailAt = ''
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
        'This build supports PostgreSQL only.'
    } elseif ($arguments[0] -eq '--databasetype') {
        $global:LASTEXITCODE = 1
        'This build supports PostgreSQL only.'
    } elseif ($arguments[0] -eq 'skills') {
        $path = Get-FixtureArgument -Arguments $arguments -Name '--path'
        New-Item -ItemType Directory -Path "$path/.agents/skills/use-grate" -Force | Out-Null
        Set-Content -LiteralPath "$path/.agents/skills/use-grate/SKILL.md" -Value 'fixture'
        $global:LASTEXITCODE = 0
    } else {
        throw 'Unexpected fixture CLI invocation.'
    }
}

function dotnet {
    $arguments = @($args)
    $fixture.Events.Add(@{
        Arguments = $arguments
        Packages = $env:NUGET_PACKAGES
        Executable = $env:GrateExecutablePath
    })
    if ($fixture.FailAt -eq $arguments[0]) {
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
            $path = "$build/bin/CommandLine.PostgreSQL/release_net11.0"
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            Set-Content -LiteralPath "$path/CommandLine.PostgreSQL.dll" -Value 'fixture'
        }
        default {
            Assert-True ($arguments[0].EndsWith('/CommandLine.PostgreSQL.dll'))
        }
    }
}

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
    Write-Host "PASS: $script:TestCount distribution runner contract scenarios."
} finally {
    foreach ($name in $fixture.Aliases) {
        Remove-Alias -Name $name -Scope Global -ErrorAction SilentlyContinue
    }
    $env:NUGET_PACKAGES = $savedPackages
    $env:GrateExecutablePath = $savedExecutable
    Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
}
