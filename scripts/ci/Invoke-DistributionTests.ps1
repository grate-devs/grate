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
    [string]$RuntimeIdentifier = 'linux-x64',
    [string]$PreparedDistributionDirectory,
    [string]$PreparedTestsDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PSScriptRoot/Distribution.Common.ps1"
. "$PSScriptRoot/Distribution.Build.ps1"
. "$PSScriptRoot/Distribution.Artifacts.ps1"

function Invoke-DistributionSuites {
    param(
        [string]$Distribution,
        [string]$Database,
        [string]$Framework,
        [string]$RuntimeIdentifier,
        [string]$OutputDirectory
    )

    $testAssembly = "$OutputDirectory/test-build/bin/CommandLine.$Database/release_$Framework/CommandLine.$Database.dll"
    if (!(Test-Path -LiteralPath $testAssembly)) {
        throw "Missing built test assembly: $testAssembly"
    }
    $executableName = if ($RuntimeIdentifier.StartsWith('win-')) { 'grate.exe' } else { 'grate' }
    foreach ($form in @('standalone', 'tool')) {
        $env:GrateExecutablePath = "$OutputDirectory/$form/$executableName"
        Assert-DistributionExecutable -Executable $env:GrateExecutablePath -Distribution $Distribution
        & $env:GrateExecutablePath skills install --local --path "$OutputDirectory/skills-$form"
        if (!(Test-Path -LiteralPath "$OutputDirectory/skills-$form/.agents/skills/use-grate/SKILL.md")) {
            throw "$Distribution $form did not install its bundled skill."
        }
        $testArguments = @(
            $testAssembly, '--minimum-expected-tests', '1', '--long-running', '60', '--timeout', '20m',
            '--results-directory', "$OutputDirectory/results/$form", '--report-xunit-trx'
        )
        dotnet @testArguments
    }
    Write-Host "PASS: $Distribution standalone and installed tool passed CommandLine.$Database on $Framework."
}

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
if ([bool]$PreparedDistributionDirectory -ne [bool]$PreparedTestsDirectory) {
    throw 'Prepared distribution and test directories must be supplied together.'
}
if ($PreparedDistributionDirectory) {
    $PreparedDistributionDirectory = [IO.Path]::GetFullPath($PreparedDistributionDirectory)
    $PreparedTestsDirectory = [IO.Path]::GetFullPath($PreparedTestsDirectory)
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
    $frameworks = @(Get-DistributionFrameworks)
    $framework = $frameworks[-1]
    $version = '0.0.0-ci.' + [Guid]::NewGuid().ToString('N')
    $packageId = if ($Distribution -eq 'All') { 'grate' } else { 'grate-' + $Distribution.ToLowerInvariant() }
    if ($PreparedDistributionDirectory) {
        $expectedDistribution = Get-DistributionPayloadIdentity -Kind 'Distribution' -RuntimeIdentifier $RuntimeIdentifier -Frameworks $frameworks
        $expectedDistribution.Distribution = $Distribution
        $expectedDistribution.PackageId = $packageId
        $prepared = Read-DistributionPayloadManifest -Directory $PreparedDistributionDirectory -ExpectedIdentity $expectedDistribution
        if ([string]$prepared.Version -cnotmatch '^0\.0\.0-ci\.[a-f0-9]{32}$') {
            throw 'Prepared payload has an invalid package version.'
        }
        $version = $prepared.Version
        $expectedTests = Get-DistributionPayloadIdentity -Kind 'Tests' -RuntimeIdentifier $RuntimeIdentifier -Frameworks $frameworks
        $expectedTests.Database = $Database
        $expectedTests.Distribution = 'All'
        Read-DistributionPayloadManifest -Directory $PreparedTestsDirectory -ExpectedIdentity $expectedTests | Out-Null

        Copy-DistributionPayload -Source "$PreparedDistributionDirectory/standalone" -Destination "$output/standalone"
        Copy-DistributionPayload -Source "$PreparedDistributionDirectory/packages" -Destination "$output/packages"
        Copy-Item -LiteralPath "$PreparedDistributionDirectory/grate.deps.json" -Destination "$output/grate.deps.json"
        Copy-DistributionPayload -Source "$PreparedTestsDirectory/payload" `
            -Destination "$output/test-build/bin/CommandLine.$Database/release_$framework"
        $dependencies = Get-Content -LiteralPath "$output/grate.deps.json" -Raw | ConvertFrom-Json -AsHashtable
        Assert-DistributionDependencies -Dependencies $dependencies -Distribution $Distribution
        Assert-DistributionToolPackage -PackagePath "$output/packages/$packageId.$version.nupkg" `
            -Frameworks $frameworks -Distribution $Distribution
        if (!$IsWindows) {
            # Artifact transport resets files to 0644; restore the published CLI's execute bit.
            $executable = "$output/standalone/grate"
            $mode = [IO.File]::GetUnixFileMode($executable)
            [IO.File]::SetUnixFileMode($executable, $mode -bor [IO.UnixFileMode]::UserExecute)
        }
    } else {
        $publishParameters = @{
            Distribution = $Distribution
            Framework = $framework
            RuntimeIdentifier = $RuntimeIdentifier
            Version = $version
            OutputDirectory = $output
        }
        Publish-DistributionCli @publishParameters

        $toolParameters = @{
            Distribution = $Distribution
            Frameworks = $frameworks
            Version = $version
            PackageId = $packageId
            OutputDirectory = $output
        }
        Build-DistributionTool @toolParameters
    }
    Install-DistributionTool -PackageId $packageId -Version $version -Framework $framework -OutputDirectory $output
    if (!$PreparedTestsDirectory) {
        Build-DistributionTests -Database $Database -Framework $framework -OutputDirectory $output
    }

    $suiteParameters = @{
        Distribution = $Distribution
        Database = $Database
        Framework = $framework
        RuntimeIdentifier = $RuntimeIdentifier
        OutputDirectory = $output
    }
    Invoke-DistributionSuites @suiteParameters
} finally {
    $env:GrateExecutablePath = $savedExecutable
    $env:NUGET_PACKAGES = $savedPackages
    Pop-Location
}
