$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
$publisher = "$PSScriptRoot/Publish-NativeAot.ps1"
$directory = New-TestDirectory
$fixture = @{
    Failure = ''
    Aliases = [Collections.Generic.List[string]]::new()
    Arguments = @()
    ContainerArguments = @()
    Profile = ''
}
$initialLocation = (Get-Location).Path

function Get-FixtureProperty {
    param(
        [string[]]$Arguments,
        [string]$Name
    )

    $prefix = "-p:${Name}="
    $value = @($Arguments | Where-Object { $_.StartsWith($prefix) })
    Assert-Equal 1 $value.Count
    $value[0].Substring($prefix.Length)
}

function Invoke-FixtureGrate {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($fixture.Failure -eq 'smoke') {
        $global:LASTEXITCODE = 43
        return
    }
    if ($arguments[0] -eq '--help') {
        "This build supports $($fixture.Profile) only."
    } elseif ($arguments[0] -eq 'skills') {
        $path = $arguments[[Array]::IndexOf($arguments, '--path') + 1]
        New-Item -ItemType Directory -Path "$path/.agents/skills/use-grate" -Force | Out-Null
        Set-Content -LiteralPath "$path/.agents/skills/use-grate/SKILL.md" -Value 'fixture'
    } elseif ($arguments -contains 'invalid') {
        $global:LASTEXITCODE = 1
        "This build supports $($fixture.Profile) only."
    } else {
        $connectionString = $arguments[[Array]::IndexOf($arguments, '--connectionstring') + 1]
        $database = $connectionString.Substring('Data Source='.Length)
        Set-Content -LiteralPath $database -Value 'fixture database'
        $output = $arguments[[Array]::IndexOf($arguments, '--output') + 1]
        New-Item -ItemType Directory -Path "$output/one/itemsRan/up" -Force | Out-Null
        Set-Content -LiteralPath "$output/one/itemsRan/up/001_create.sql" -Value 'fixture migration'
    }
}

function dotnet {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    if ($arguments[0] -eq 'msbuild') {
        '11.0.0-rc.3.26522.148'
        return
    }
    Assert-Equal 'publish' $arguments[0]
    $fixture.Arguments = $arguments
    if ($fixture.Failure -eq 'publish') {
        $global:LASTEXITCODE = 42
        return
    }
    $output = $arguments[[Array]::IndexOf($arguments, '-o') + 1]
    $root = Split-Path $output
    $build = Get-FixtureProperty -Arguments $arguments -Name ArtifactsPath
    $fixture.Profile = Get-FixtureProperty -Arguments $arguments -Name GrateDistribution
    $rid = $arguments[[Array]::IndexOf($arguments, '-r') + 1]
    $version = if ($fixture.Failure -eq 'runtime') { '10.0.0' } else { '11.0.0-rc.3.26522.148' }
    $runtimePack = "$root/packages/microsoft.netcore.app.runtime.nativeaot.$rid/$version"
    $compilerPack = "$root/packages/runtime.$rid.microsoft.dotnet.ilcompiler/$version"
    $native = "$build/bin/grate/release_net11.0_$rid/native"
    $intermediate = "$build/obj/grate/release_net11.0_$rid/native"
    $compilerName = if ($IsWindows) { 'ilc.exe' } else { 'ilc' }
    $executableName = if ($rid.StartsWith('win-')) { 'grate.exe' } else { 'grate' }
    $paths = @($output, $native, $intermediate, "$runtimePack/runtimes/$rid/native", "$compilerPack/tools")
    New-Item -ItemType Directory -Path $paths -Force | Out-Null
    Set-Content -LiteralPath "$compilerPack/tools/$compilerName" -Value 'compiler fixture'
    Set-Content -LiteralPath "$runtimePack/runtimes/$rid/native/System.Private.CoreLib.dll" -Value 'runtime fixture'
    $evidence = @(
        "RuntimePackagePath=$runtimePack/"
        "IlcHostPackagePath=$compilerPack/"
        "NativeBinary=$native/$executableName"
        "NativeIntermediateOutputPath=$intermediate/"
    )
    $evidence | Set-Content -LiteralPath "$root/native-build.txt"
    Set-Content -LiteralPath "$intermediate/grate.ilc.rsp" -Value "-r:$runtimePack/runtimes/$rid/native/System.Private.CoreLib.dll"
    Set-Content -LiteralPath "$native/$executableName" -Value 'native linker fixture'
    Copy-Item -LiteralPath "$native/$executableName" -Destination "$output/$executableName"
    if (!$IsWindows) {
        [IO.File]::SetUnixFileMode("$output/$executableName", [IO.UnixFileMode]493)
    }
    Set-Content -LiteralPath "$output/grate.pdb" -Value 'debug fixture'
    Set-Content -LiteralPath "$output/grate.dbg" -Value 'debug fixture'
    New-Item -ItemType Directory -Path "$output/grate.dSYM/Contents" -Force | Out-Null
    Set-Content -LiteralPath "$output/grate.dSYM/Contents/symbol" -Value 'debug fixture'
    Set-Content -LiteralPath "$output/mandatory-native-library.dll" -Value 'mandatory native dependency fixture'
    if ($fixture.Failure -eq 'impostor') {
        Set-Content -LiteralPath "$output/$executableName" -Value 'managed impostor'
    }
    if ($fixture.Failure -eq 'managed') {
        Set-Content -LiteralPath "$output/grate.dll" -Value 'managed fixture'
    }
    if ($fixture.Profile -in @('All', 'SQLite') -and $fixture.Failure -ne 'sqlite') {
        $sqlite = if ($rid.StartsWith('win-')) { 'e_sqlite3.dll' } elseif ($rid.StartsWith('osx-')) { 'libe_sqlite3.dylib' } else { 'libe_sqlite3.so' }
        Set-Content -LiteralPath "$output/$sqlite" -Value 'sqlite native fixture'
    }
    $libraries = @{}
    $providers = @{
        SQLite = @('grate.sqlite', 'Microsoft.Data.Sqlite', 'SQLitePCLRaw.bundle_e_sqlite3', 'SQLite')
        SQLServer = @('grate.sqlserver', 'Microsoft.Data.SqlClient', 'Microsoft.Data.SqlClient.Extensions.Azure')
        MariaDB = @('grate.mariadb', 'MySqlConnector')
        PostgreSQL = @('grate.postgresql', 'Npgsql')
        Oracle = @('grate.oracle', 'Oracle.ManagedDataAccess.Core')
    }
    foreach ($provider in $providers.Keys) {
        if ($fixture.Profile -eq 'All' -or $fixture.Profile -eq $provider) {
            foreach ($dependency in $providers[$provider]) {
                $libraries["$dependency/1"] = @{}
            }
        }
    }
    if ($fixture.Failure -eq 'dependencies') {
        $libraries['Npgsql/1'] = @{}
    }
    $dependencyTarget = if ($fixture.Failure -eq 'dependency-rid') { 'net11.0/wrong-rid' } else { "net11.0/$rid" }
    New-Item -ItemType Directory -Path "$build/obj/grate" -Force | Out-Null
    @{
        targets = @{ $dependencyTarget = $libraries }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$build/obj/grate/project.assets.json"
    $aliasPath = "$root/extracted/$executableName"
    New-Alias -Name $aliasPath -Value Invoke-FixtureGrate -Scope Global -Force
    $fixture.Aliases.Add($aliasPath)
}

function docker {
    $arguments = @($args)
    $fixture.ContainerArguments = $arguments
    $entrypoint = [Array]::IndexOf($arguments, '--entrypoint')
    Assert-True ($entrypoint -gt 0)
    $executable = $arguments[$entrypoint + 1]
    $commandArguments = $arguments[($entrypoint + 3)..($arguments.Count - 1)]
    & $executable @commandArguments
}

try {
    $rid = if ($IsWindows) { 'win-x64' } elseif ($IsMacOS) { 'osx-arm64' } else { 'linux-x64' }
    foreach ($profile in @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')) {
        Invoke-Test "$profile produces a distinct complete ZIP and enforces the native publish settings" {
            $output = "$directory/$profile"
            & $publisher -Distribution $profile -RuntimeIdentifier $rid -Version '1.2.3-rc.1' -OutputDirectory $output
            Assert-Equal $initialLocation (Get-Location).Path
            $expectedProperties = @(
                '-p:PublishAot=true', '-p:PublishTrimmed=true', '-p:TrimMode=full',
                '-p:PublishSingleFile=false', '-p:EnableCompressionInSingleFile=false',
                '-p:IncludeNativeLibrariesForSelfExtract=false', '-p:IncludeAllContentForSelfExtract=false',
                '-p:SuppressTrimAnalysisWarnings=false', '-p:TrimmerSingleWarn=false',
                '-p:ILLinkTreatWarningsAsErrors=false', '-p:IlcTreatWarningsAsErrors=false',
                '-p:WarningsNotAsErrors=IL2026%3BIL3050', "-p:ArtifactsPath=$output/build",
                '-p:TargetFrameworks=net11.0', '-p:Version=1.2.3-rc.1'
            )
            foreach ($property in $expectedProperties) {
                Assert-True ($fixture.Arguments -ccontains $property) "Missing $property"
            }
            Assert-Equal 0 @($fixture.Arguments | Where-Object { $_ -like '-p:NoWarn=*' -or $_ -eq '-p:TreatWarningsAsErrors=false' }).Count
            $id = if ($profile -eq 'All') { 'grate' } else { 'grate-' + $profile.ToLowerInvariant() }
            $zip = [IO.Compression.ZipFile]::OpenRead("$output/$id-$rid-nativeaot-1.2.3-rc.1.zip")
            try {
                Assert-True ($null -ne $zip.GetEntry('mandatory-native-library.dll'))
                Assert-Equal 0 @($zip.Entries | Where-Object { $_.FullName -match '(\.pdb$|\.dbg$|\.dSYM/)' }).Count
                if (!$IsWindows) {
                    Assert-Equal 493 (($zip.GetEntry('grate').ExternalAttributes -shr 16) -band 0x1ff)
                    Assert-Equal 493 ([int][IO.File]::GetUnixFileMode("$output/extracted/grate"))
                }
            } finally {
                $zip.Dispose()
            }
            Assert-Throws { & $publisher -Distribution $profile -RuntimeIdentifier $rid -Version '1.2.3' -OutputDirectory $output } '*fresh output*'
        }
    }
    Invoke-Test 'container execution uses identical bind paths and smoke tests the unpacked native CLI' {
        $output = "$directory/container"
        $cache = "$directory/nuget"
        $image = 'example/sdk@sha256:' + ('a' * 64)
        & $publisher -Distribution PostgreSQL -RuntimeIdentifier $rid -Version '1.2.3' -OutputDirectory $output -ContainerImage $image -NuGetPackagesDirectory $cache
        Assert-True ($fixture.ContainerArguments -contains "${output}:$output")
        Assert-True ($fixture.ContainerArguments -contains "${cache}:$cache")
        Assert-True ($fixture.ContainerArguments -contains "NUGET_PACKAGES=$cache")
        Assert-True ($fixture.ContainerArguments -contains "$output/extracted/$(if ($IsWindows) { 'grate.exe' } else { 'grate' })")
    }
    $failures = @{
        publish = '*code 42*'
        runtime = '*pack does not match*'
        impostor = '*native linker output*'
        managed = '*managed CLI assembly*'
        dependencies = '*dependency mismatch*'
        'dependency-rid' = '*dependency graph does not match*'
        sqlite = '*SQLite payload is missing*'
        smoke = '*code 43*'
    }
    foreach ($failure in $failures.Keys) {
        Invoke-Test "$failure rejects the candidate and leaves no archive" {
            $fixture.Failure = $failure
            $output = "$directory/failure-$failure"
            Assert-Throws { & $publisher -Distribution SQLite -RuntimeIdentifier $rid -Version '1.2.3' -OutputDirectory $output } $failures[$failure]
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $output -Filter '*.zip' -File).Count
            Assert-Equal $initialLocation (Get-Location).Path
        }
    }
    Write-Host "PASS: $script:TestCount NativeAOT publisher contract scenarios (fixture executables; real publish tested separately)."
} finally {
    foreach ($aliasPath in $fixture.Aliases) {
        Remove-Alias -Name $aliasPath -Scope Global -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
}
