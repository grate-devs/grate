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

function Publish-DistributionCli {
    param(
        [string]$Distribution,
        [string]$Framework,
        [string]$RuntimeIdentifier,
        [string]$Version,
        [string]$OutputDirectory
    )

    $publishArguments = @(
        'publish', 'src/grate/grate.csproj', '-c', 'Release', '-f', $Framework,
        '-r', $RuntimeIdentifier, '--self-contained', 'true',
        "-p:TargetFrameworks=$Framework", "-p:GrateDistribution=$Distribution",
        "-p:ArtifactsPath=$OutputDirectory/cli-build", "-p:Version=$Version",
        '-o', "$OutputDirectory/standalone"
    )
    dotnet @publishArguments

    $dependencyFiles = @(Get-ChildItem -LiteralPath "$OutputDirectory/cli-build/bin/grate" -Filter grate.deps.json -Recurse)
    if ($dependencyFiles.Count -ne 1) {
        throw 'Expected exactly one self-contained CLI dependency manifest.'
    }
    $dependencies = Get-Content -LiteralPath $dependencyFiles[0].FullName -Raw | ConvertFrom-Json -AsHashtable
    Assert-DistributionDependencies -Dependencies $dependencies -Distribution $Distribution
    Copy-Item -LiteralPath $dependencyFiles[0].FullName -Destination "$OutputDirectory/grate.deps.json"
}

function Assert-DistributionToolPackage {
    param(
        [string]$PackagePath,
        [string[]]$Frameworks,
        [string]$Distribution
    )

    $archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        foreach ($framework in $Frameworks) {
            $prefix = "tools/$framework/any"
            $dependencyEntry = $archive.GetEntry("$prefix/grate.deps.json")
            $settingsEntry = $archive.GetEntry("$prefix/DotnetToolSettings.xml")
            if (!$dependencyEntry -or !$settingsEntry) {
                throw "Missing $framework tool payload."
            }
            $reader = [IO.StreamReader]::new($dependencyEntry.Open())
            try {
                $dependencies = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable
                Assert-DistributionDependencies -Dependencies $dependencies -Distribution $Distribution
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
}

function Build-DistributionTool {
    param(
        [string]$Distribution,
        [string[]]$Frameworks,
        [string]$Version,
        [string]$PackageId,
        [string]$OutputDirectory
    )

    $packArguments = @(
        'pack', 'src/grate/grate.csproj', '-c', 'Release',
        '-p:PackAsTool=true', '-p:SelfContained=false',
        "-p:GrateDistribution=$Distribution", "-p:ArtifactsPath=$OutputDirectory/tool-build",
        "-p:PackageVersion=$Version", '-o', "$OutputDirectory/packages"
    )
    dotnet @packArguments
    $packageParameters = @{
        PackagePath = "$OutputDirectory/packages/$PackageId.$Version.nupkg"
        Frameworks = $Frameworks
        Distribution = $Distribution
    }
    Assert-DistributionToolPackage @packageParameters
}

function Install-DistributionTool {
    param(
        [string]$PackageId,
        [string]$Version,
        [string]$Framework,
        [string]$OutputDirectory
    )

    # Only the freshly built package may satisfy this installation.
    $feed = [Security.SecurityElement]::Escape("$OutputDirectory/packages")
    "<configuration><packageSources><clear/><add key=`"local`" value=`"$feed`"/></packageSources></configuration>" |
        Set-Content -LiteralPath "$OutputDirectory/NuGet.Config" -Encoding utf8NoBOM
    $savedPackages = $env:NUGET_PACKAGES
    try {
        $env:NUGET_PACKAGES = "$OutputDirectory/tool-cache"
        $installArguments = @(
            'tool', 'install', $PackageId, '--version', $Version, '--framework', $Framework,
            '--tool-path', "$OutputDirectory/tool", '--configfile', "$OutputDirectory/NuGet.Config"
        )
        dotnet @installArguments
    } finally {
        $env:NUGET_PACKAGES = $savedPackages
    }
}

function Build-DistributionTests {
    param(
        [string]$Database,
        [string]$Framework,
        [string]$OutputDirectory
    )

    # Tests retain normal All references; only the explicitly selected executable is slim.
    $buildArguments = @(
        'build', "unittests/CommandLine/CommandLine.$Database/CommandLine.$Database.csproj",
        '-c', 'Release', "-p:TargetFrameworks=$Framework", "-p:ArtifactsPath=$OutputDirectory/test-build"
    )
    dotnet @buildArguments
}

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
    Install-DistributionTool -PackageId $packageId -Version $version -Framework $framework -OutputDirectory $output
    Build-DistributionTests -Database $Database -Framework $framework -OutputDirectory $output

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
