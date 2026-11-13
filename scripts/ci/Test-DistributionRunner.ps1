#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PSScriptRoot/../release/release_common.ps1"
. "$PSScriptRoot/../release/release_test_helpers.ps1"
. "$PSScriptRoot/Distribution.Artifacts.ps1"

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
$frameworks = @('net8.0', 'net9.0', 'net10.0', 'net11.0')
$libraries = @{
    SQLite = @('grate.sqlite/1', 'Microsoft.Data.Sqlite/1', 'SQLitePCLRaw.bundle_e_sqlite3/1', 'SQLite/1')
    SQLServer = @('grate.sqlserver/1', 'Microsoft.Data.SqlClient/1', 'Microsoft.Data.SqlClient.Extensions.Azure/1')
    MariaDB = @('grate.mariadb/1', 'MySqlConnector/1')
    PostgreSQL = @('grate.postgresql/1', 'Npgsql/1')
    Oracle = @('grate.oracle/1', 'Oracle.ManagedDataAccess.Core/1')
}

function Get-FixtureDependencies {
    param(
        [string]$Distribution
    )

    $dependencies = @{}
    foreach ($profile in $libraries.Keys) {
        if ($Distribution -eq 'All' -or $Distribution -eq $profile) {
            foreach ($library in $libraries[$profile]) {
                $dependencies[$library] = @{}
            }
        }
    }
    return @{ libraries = $dependencies }
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
        [string]$Path,
        [switch]$AliasOnly
    )

    New-Alias -Name $Path -Value Invoke-FixtureGrate -Scope Global -Force
    $fixture.Aliases.Add($Path)
    if (!$AliasOnly) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        Set-Content -LiteralPath $Path -Value 'fixture executable'
    }
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
            $distribution = Get-FixtureProperty -Arguments $arguments -Name 'GrateDistribution'
            $dependencies = Get-FixtureDependencies -Distribution $distribution
            $dependencies | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$build/bin/grate/release_net11.0_linux-x64/grate.deps.json"
            Register-FixtureExecutable -Path "$output/grate"
        }
        'pack' {
            $output = Get-FixtureArgument -Arguments $arguments -Name '-o'
            $version = Get-FixtureProperty -Arguments $arguments -Name 'PackageVersion'
            New-Item -ItemType Directory -Path $output -Force | Out-Null
            $distribution = Get-FixtureProperty -Arguments $arguments -Name 'GrateDistribution'
            $packageId = if ($distribution -eq 'All') { 'grate' } else { 'grate-' + $distribution.ToLowerInvariant() }
            $dependencies = Get-FixtureDependencies -Distribution $distribution | ConvertTo-Json -Depth 5 -Compress
            $package = [IO.Compression.ZipFile]::Open("$output/$packageId.$version.nupkg", [IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($framework in $frameworks) {
                    $entries = @{
                        'grate.deps.json' = $dependencies
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
            $suite = [IO.Path]::GetFileNameWithoutExtension($arguments[1])
            $path = "$build/bin/$suite/release_net11.0"
            New-Item -ItemType Directory -Path "$path/Fixtures/nested" -Force | Out-Null
            foreach ($name in @("$suite.dll", "$suite.deps.json", "$suite.runtimeconfig.json", 'xunit.runner.json', 'Fixtures/nested/example.sql')) {
                Set-Content -LiteralPath "$path/$name" -Value 'fixture'
            }
        }
        default {
            Assert-True ($arguments[0].EndsWith('/CommandLine.PostgreSQL.dll'))
        }
    }
}

function New-PreparedFixture {
    param(
        [string]$Directory
    )

    $source = Join-Path $script:directory 'successful run'
    $profile = Join-Path $Directory 'distribution'
    $tests = Join-Path $Directory 'tests'
    Copy-DistributionPayload -Source "$source/standalone" -Destination "$profile/standalone"
    Copy-DistributionPayload -Source "$source/packages" -Destination "$profile/packages"
    Copy-Item -LiteralPath "$source/grate.deps.json" -Destination "$profile/grate.deps.json"
    Copy-DistributionPayload -Source "$source/test-build/bin/CommandLine.PostgreSQL/release_net11.0" -Destination "$tests/payload"
    $package = Get-ChildItem -LiteralPath "$profile/packages" -Filter '*.nupkg' -File
    $version = $package.Name.Substring('grate-postgresql.'.Length) -replace '\.nupkg$', ''
    $identity = Get-DistributionPayloadIdentity -Kind Distribution -RuntimeIdentifier linux-x64 -Frameworks $frameworks
    $identity.Distribution = 'PostgreSQL'
    $identity.PackageId = 'grate-postgresql'
    $identity.Version = $version
    Write-DistributionPayloadManifest -Directory $profile -Identity $identity
    $identity = Get-DistributionPayloadIdentity -Kind Tests -RuntimeIdentifier linux-x64 -Frameworks $frameworks
    $identity.Database = 'PostgreSQL'
    $identity.Distribution = 'All'
    Write-DistributionPayloadManifest -Directory $tests -Identity $identity
    return @{
        Distribution = 'PostgreSQL'
        Database = 'PostgreSQL'
        PreparedDistributionDirectory = $profile
        PreparedTestsDirectory = $tests
        OutputDirectory = Join-Path $Directory 'consumer'
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
    $fixture.FailAt = ''
    Invoke-Test 'prepared consumer reuses exact artifacts and complete test payload without building' {
        $parameters = New-PreparedFixture -Directory (Join-Path $directory 'prepared successful')
        Register-FixtureExecutable -Path "$($parameters.OutputDirectory)/standalone/grate" -AliasOnly
        if (!$IsWindows) {
            [IO.File]::SetUnixFileMode("$($parameters.PreparedDistributionDirectory)/standalone/grate", [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        $fixture.Events.Clear()
        & $runner @parameters
        Assert-Equal 0 @($fixture.Events | Where-Object { $_.Arguments[0] -in @('publish', 'pack', 'build') }).Count
        Assert-Equal 1 @($fixture.Events | Where-Object { $_.Arguments[0] -eq 'tool' }).Count
        $runs = @($fixture.Events | Where-Object { $_.Arguments[0].EndsWith('/CommandLine.PostgreSQL.dll') })
        Assert-Equal 2 $runs.Count
        Assert-Equal @("$($parameters.OutputDirectory)/standalone/grate", "$($parameters.OutputDirectory)/tool/grate") @($runs.Executable)
        $payload = "$($parameters.OutputDirectory)/test-build/bin/CommandLine.PostgreSQL/release_net11.0"
        foreach ($name in @('CommandLine.PostgreSQL.deps.json', 'CommandLine.PostgreSQL.runtimeconfig.json', 'xunit.runner.json', 'Fixtures/nested/example.sql')) {
            Assert-True (Test-Path -LiteralPath "$payload/$name")
        }
        if (!$IsWindows) {
            Assert-True (([IO.File]::GetUnixFileMode("$($parameters.OutputDirectory)/standalone/grate") -band [IO.UnixFileMode]::UserExecute) -ne 0)
        }
        Assert-Equal 'fixture-original-cache' $env:NUGET_PACKAGES
        Assert-Equal 'fixture-original-executable' $env:GrateExecutablePath
        Assert-Equal $initialLocation (Get-Location).Path
    }
    foreach ($mutation in @(
        @{ Scope = 'Distribution'; Field = 'SourceRevision'; Value = '0000000000000000000000000000000000000000' }
        @{ Scope = 'Distribution'; Field = 'RunId'; Value = 'different-run' }
        @{ Scope = 'Distribution'; Field = 'RuntimeIdentifier'; Value = 'win-x64' }
        @{ Scope = 'Distribution'; Field = 'Framework'; Value = 'net8.0' }
        @{ Scope = 'Distribution'; Field = 'Frameworks'; Value = @('net11.0') }
        @{ Scope = 'Distribution'; Field = 'Configuration'; Value = 'Debug' }
        @{ Scope = 'Distribution'; Field = 'Distribution'; Value = 'All' }
        @{ Scope = 'Distribution'; Field = 'PackageId'; Value = 'grate' }
        @{ Scope = 'Tests'; Field = 'Database'; Value = 'Oracle' }
        @{ Scope = 'Tests'; Field = 'Distribution'; Value = 'PostgreSQL' }
        @{ Scope = 'Tests'; Field = 'SourceRevision'; Value = '0000000000000000000000000000000000000000' }
        @{ Scope = 'Tests'; Field = 'RuntimeIdentifier'; Value = 'linux-arm64' }
    )) {
        Invoke-Test "prepared artifacts reject mismatched $($mutation.Scope) $($mutation.Field)" {
            $parameters = New-PreparedFixture -Directory (Join-Path $directory ([Guid]::NewGuid().ToString('N')))
            $manifestDirectory = if ($mutation.Scope -eq 'Distribution') { $parameters.PreparedDistributionDirectory } else { $parameters.PreparedTestsDirectory }
            $manifestPath = Join-Path $manifestDirectory 'manifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
            $manifest.Identity[$mutation.Field] = $mutation.Value
            $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath
            $fixture.Events.Clear()
            Assert-Throws { & $runner @parameters } "*identity mismatch for $($mutation.Field)*"
            Assert-Equal 0 @($fixture.Events | Where-Object { $_.Arguments[0] -ne 'msbuild' }).Count
            Assert-Equal $initialLocation (Get-Location).Path
        }
    }
    foreach ($mutation in @('changed', 'missing', 'extra', 'duplicate', 'traversal', 'invalid-version')) {
        Invoke-Test "prepared artifacts reject $mutation payload" {
            $parameters = New-PreparedFixture -Directory (Join-Path $directory ([Guid]::NewGuid().ToString('N')))
            $manifestPath = Join-Path $parameters.PreparedTestsDirectory 'manifest.json'
            switch ($mutation) {
                'changed' { Set-Content -LiteralPath "$($parameters.PreparedTestsDirectory)/payload/CommandLine.PostgreSQL.dll" -Value 'tampered' }
                'missing' { Remove-Item -LiteralPath "$($parameters.PreparedTestsDirectory)/payload/Fixtures/nested/example.sql" }
                'extra' { Set-Content -LiteralPath "$($parameters.PreparedTestsDirectory)/payload/extra.dll" -Value 'unexpected' }
                'duplicate' {
                    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
                    $manifest.Files += $manifest.Files[0]
                    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath
                }
                'traversal' {
                    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
                    $manifest.Files[0].Path = '../outside.dll'
                    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath
                }
                'invalid-version' {
                    $manifestPath = Join-Path $parameters.PreparedDistributionDirectory 'manifest.json'
                    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
                    $manifest.Identity.Version = '1.2.3'
                    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath
                }
            }
            $fixture.Events.Clear()
            Assert-Throws { & $runner @parameters } '*payload*'
            Assert-Equal 0 @($fixture.Events | Where-Object { $_.Arguments[0] -ne 'msbuild' }).Count
        }
    }
    foreach ($failure in @('tool', 'suite')) {
        Invoke-Test "prepared $failure failure stops execution and restores environment" {
            $parameters = New-PreparedFixture -Directory (Join-Path $directory ([Guid]::NewGuid().ToString('N')))
            Register-FixtureExecutable -Path "$($parameters.OutputDirectory)/standalone/grate" -AliasOnly
            $fixture.Events.Clear()
            $fixture.FailAt = if ($failure -eq 'tool') { 'tool' } else { "$($parameters.OutputDirectory)/test-build/bin/CommandLine.PostgreSQL/release_net11.0/CommandLine.PostgreSQL.dll" }
            Assert-Throws { & $runner @parameters } '*23*'
            $runs = @($fixture.Events | Where-Object { $_.Arguments[0].EndsWith('/CommandLine.PostgreSQL.dll') })
            Assert-Equal $(if ($failure -eq 'tool') { 0 } else { 1 }) $runs.Count
            Assert-Equal 'fixture-original-cache' $env:NUGET_PACKAGES
            Assert-Equal 'fixture-original-executable' $env:GrateExecutablePath
            Assert-Equal $initialLocation (Get-Location).Path
            $fixture.FailAt = ''
        }
    }
    Invoke-Test 'prepared consumption still validates every tool target framework' {
        $parameters = New-PreparedFixture -Directory (Join-Path $directory 'missing tool framework')
        $package = Get-ChildItem -LiteralPath "$($parameters.PreparedDistributionDirectory)/packages" -Filter '*.nupkg' -File
        $archive = [IO.Compression.ZipFile]::Open($package.FullName, [IO.Compression.ZipArchiveMode]::Update)
        try {
            $archive.GetEntry('tools/net8.0/any/DotnetToolSettings.xml').Delete()
        } finally {
            $archive.Dispose()
        }
        $manifestPath = Join-Path $parameters.PreparedDistributionDirectory 'manifest.json'
        $identity = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable).Identity
        Write-DistributionPayloadManifest -Directory $parameters.PreparedDistributionDirectory -Identity $identity
        $fixture.Events.Clear()
        Assert-Throws { & $runner @parameters } '*Missing net8.0 tool payload*'
        Assert-Equal 0 @($fixture.Events | Where-Object { $_.Arguments[0] -ne 'msbuild' }).Count
    }
    Invoke-Test 'prepared directories must be supplied together' {
        Assert-Throws {
            & $runner -Distribution PostgreSQL -Database PostgreSQL -OutputDirectory "$directory/unpaired" `
                -PreparedDistributionDirectory "$directory/unused"
        } '*supplied together*'
    }
    Invoke-Test 'preparation builds six profiles and suites once with isolated complete payloads' {
        $fixture.Events.Clear()
        $output = Join-Path $directory 'prepared all'
        & "$PSScriptRoot/Prepare-DistributionTests.ps1" -OutputDirectory $output
        foreach ($command in @('publish', 'pack', 'build')) {
            Assert-Equal 6 @($fixture.Events | Where-Object { $_.Arguments[0] -eq $command }).Count
        }
        Assert-Equal 0 @($fixture.Events | Where-Object { $_.Arguments[0] -eq 'tool' }).Count
        $builds = @($fixture.Events | Where-Object { $_.Arguments[0] -eq 'build' })
        Assert-Equal 1 @($builds | ForEach-Object { Get-FixtureProperty -Arguments $_.Arguments -Name ArtifactsPath } | Sort-Object -Unique).Count
        foreach ($build in $builds) {
            Assert-Equal 0 @($build.Arguments | Where-Object { $_.StartsWith('-p:GrateDistribution=') }).Count
        }
        foreach ($profile in @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')) {
            $identity = Get-DistributionPayloadIdentity -Kind Distribution -RuntimeIdentifier linux-x64 -Frameworks $frameworks
            $identity.Distribution = $profile
            Read-DistributionPayloadManifest -Directory "$output/profiles/$profile" -ExpectedIdentity $identity | Out-Null
            Assert-True (!(Test-Path -LiteralPath "$output/profiles/$profile/cli-build"))
            Assert-True (!(Test-Path -LiteralPath "$output/profiles/$profile/tool-build"))
        }
        foreach ($database in @('Sqlite', 'SqlServer', 'SqlServerCaseSensitive', 'PostgreSQL', 'MariaDB', 'Oracle')) {
            Assert-True (Test-Path -LiteralPath "$output/tests/$database/payload/Fixtures/nested/example.sql")
            Assert-True (Test-Path -LiteralPath "$output/tests/$database/payload/CommandLine.$database.runtimeconfig.json")
        }
    }
    foreach ($failure in @('publish', 'pack', 'build')) {
        Invoke-Test "preparation propagates $failure failures" {
            $fixture.FailAt = $failure
            Assert-Throws { & "$PSScriptRoot/Prepare-DistributionTests.ps1" -OutputDirectory (Join-Path $directory ([Guid]::NewGuid().ToString('N'))) } '*23*'
            Assert-Equal $initialLocation (Get-Location).Path
            $fixture.FailAt = ''
        }
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
