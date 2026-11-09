#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)]
    [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Distribution,
    [Parameter(Mandatory)]
    [ValidateSet('Sqlite', 'SqlServer', 'SqlServerCaseSensitive', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Database,
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    [string]$RuntimeIdentifier = 'linux-x64'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PSScriptRoot/Distribution.Common.ps1"

$databaseDistributions = @{
    Sqlite = 'SQLite'
    SqlServer = 'SQLServer'
    SqlServerCaseSensitive = 'SQLServer'
    MariaDB = 'MariaDB'
    PostgreSQL = 'PostgreSQL'
    Oracle = 'Oracle'
}
if ($Distribution -ne 'All' -and $Distribution -ne $databaseDistributions[$Database]) {
    throw "The $Database suite cannot validate a $Distribution distribution."
}
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) {
    throw 'Use a fresh output directory to avoid stale executable or package evidence.'
}
$savedExecutable = $env:GrateExecutablePath
$savedPackages = $env:NUGET_PACKAGES
Push-Location $repository
try {
    $frameworks = @((dotnet msbuild src/grate/grate.csproj -nologo -getProperty:TargetFrameworks).Trim() -split ';')
    $framework = $frameworks[-1]
    $version = '0.0.0-ci.' + [Guid]::NewGuid().ToString('N')
    $packageId = if ($Distribution -eq 'All') { 'grate' } else { 'grate-' + $Distribution.ToLowerInvariant() }
    $publishArguments = @(
        'publish', 'src/grate/grate.csproj', '-c', 'Release', '-f', $framework,
        '-r', $RuntimeIdentifier, '--self-contained', 'true',
        "-p:TargetFrameworks=$framework", "-p:GrateDistribution=$Distribution",
        "-p:ArtifactsPath=$output/cli-build", "-p:Version=$version", '-o', "$output/standalone"
    )
    dotnet @publishArguments
    $dependencyFiles = @(Get-ChildItem -LiteralPath "$output/cli-build/bin/grate" -Filter grate.deps.json -Recurse)
    if ($dependencyFiles.Count -ne 1) {
        throw 'Expected exactly one self-contained CLI dependency manifest.'
    }
    $dependencies = Get-Content -LiteralPath $dependencyFiles[0].FullName -Raw | ConvertFrom-Json -AsHashtable
    Assert-DistributionDependencies -Dependencies $dependencies -Distribution $Distribution
    Copy-Item -LiteralPath $dependencyFiles[0].FullName -Destination "$output/grate.deps.json"

    $packArguments = @(
        'pack', 'src/grate/grate.csproj', '-c', 'Release', '-p:PackAsTool=true', '-p:SelfContained=false',
        "-p:GrateDistribution=$Distribution", "-p:ArtifactsPath=$output/tool-build",
        "-p:PackageVersion=$version", '-o', "$output/packages"
    )
    dotnet @packArguments
    $package = "$output/packages/$packageId.$version.nupkg"
    $archive = [IO.Compression.ZipFile]::OpenRead($package)
    try {
        foreach ($toolFramework in $frameworks) {
            $prefix = "tools/$toolFramework/any"
            $dependencyEntry = $archive.GetEntry("$prefix/grate.deps.json")
            $settingsEntry = $archive.GetEntry("$prefix/DotnetToolSettings.xml")
            if (!$dependencyEntry -or !$settingsEntry) {
                throw "Missing $toolFramework tool payload."
            }
            $reader = [IO.StreamReader]::new($dependencyEntry.Open())
            try {
                $toolDependencies = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable
                Assert-DistributionDependencies -Dependencies $toolDependencies -Distribution $Distribution
            } finally {
                $reader.Dispose()
            }
            $reader = [IO.StreamReader]::new($settingsEntry.Open())
            try {
                [xml]$settings = $reader.ReadToEnd()
                if ($settings.DotNetCliTool.Commands.Command.Name -cne 'grate') {
                    throw 'Every distribution must expose the command grate.'
                }
            } finally {
                $reader.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }

    # Install only the freshly built package, with no global cache or remote feed.
    $feed = [Security.SecurityElement]::Escape("$output/packages")
    "<configuration><packageSources><clear/><add key=`"local`" value=`"$feed`"/></packageSources></configuration>" |
        Set-Content -LiteralPath "$output/NuGet.Config" -Encoding utf8NoBOM
    $env:NUGET_PACKAGES = "$output/tool-cache"
    dotnet tool install $packageId --version $version --framework $framework --tool-path "$output/tool" --configfile "$output/NuGet.Config"

    # Test references remain All; only the explicitly selected executable is slim.
    $env:NUGET_PACKAGES = $savedPackages
    $testProject = "unittests/CommandLine/CommandLine.$Database/CommandLine.$Database.csproj"
    dotnet build $testProject -c Release "-p:TargetFrameworks=$framework" "-p:ArtifactsPath=$output/test-build"
    $testAssembly = "$output/test-build/bin/CommandLine.$Database/release_$framework/CommandLine.$Database.dll"
    if (!(Test-Path -LiteralPath $testAssembly)) {
        throw "Missing built test assembly: $testAssembly"
    }
    $executableName = if ($RuntimeIdentifier.StartsWith('win-')) { 'grate.exe' } else { 'grate' }
    foreach ($form in @('standalone', 'tool')) {
        $env:GrateExecutablePath = "$output/$form/$executableName"
        Assert-DistributionExecutable -Executable $env:GrateExecutablePath -Distribution $Distribution
        & $env:GrateExecutablePath skills install --local --path "$output/skills-$form"
        if (!(Test-Path -LiteralPath "$output/skills-$form/.agents/skills/use-grate/SKILL.md")) {
            throw "$Distribution $form did not install its bundled skill."
        }
        $testArguments = @(
            $testAssembly, '--minimum-expected-tests', '1', '--long-running', '60', '--timeout', '20m',
            '--results-directory', "$output/results/$form", '--report-xunit-trx'
        )
        dotnet @testArguments
    }
    Write-Host "PASS: $Distribution standalone and installed tool passed CommandLine.$Database on $framework."
} finally {
    $env:GrateExecutablePath = $savedExecutable
    $env:NUGET_PACKAGES = $savedPackages
    Pop-Location
}
