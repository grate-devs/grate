#!/usr/bin/env pwsh
. "$PSScriptRoot/../../../scripts/release/release_common.ps1"
. "$PSScriptRoot/../../../scripts/release/release_test_helpers.ps1"
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$directory=New-TestDirectory
$events=Join-Path $directory 'docker-events.jsonl'
$oldPath=$env:PATH; $oldEvents=$env:GRATE_TEST_DOCKER_EVENTS; $oldVersion=$env:GRATE_TEST_VERSION; $oldCwd=[Environment]::CurrentDirectory
$savedFakeEnvironment = @{}
foreach ($key in @('GRATE_TEST_DOCKER_FAILURE','GRATE_TEST_BUILDER_MISSING','GRATE_TEST_GITVERSION_FAILURE')) {
    $savedFakeEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
    [Environment]::SetEnvironmentVariable($key, '')
}
function Write-TestExecutable([string]$Name,[string]$Body) {
    $path=Join-Path $directory "$Name.ps1"
    [IO.File]::WriteAllText($path,"#!/usr/bin/env pwsh`n"+$Body)
}
function Read-DockerEvents { if ([IO.File]::Exists($events)) { Get-Content -LiteralPath $events | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable } } }
function Get-BuildArguments {
    $builds=@(Read-DockerEvents | Where-Object { $_.args[0] -ceq 'buildx' -and $_.args[1] -ceq 'build' })
    Assert-Equal 1 $builds.Count
    ,$builds[0].args
}
function Get-OptionValues([string[]]$Arguments,[string]$Option) { for ($index=0;$index -lt $Arguments.Length;$index++) { if ($Arguments[$index] -ceq $Option) { $Arguments[$index+1] } } }
function Invoke-LocalBuild([string[]]$Arguments=@()) {
    [IO.File]::Delete($events)
    Invoke-ReleaseProcess (Get-Process -Id $PID).Path (@('-NoLogo','-NoProfile','-File',(Join-Path $repository 'build-docker-local.ps1'))+$Arguments) 30
}
try {
    Write-TestExecutable 'docker' @'
$record=@{args=@($args);cwd=$PWD.Path}|ConvertTo-Json -Compress
[IO.File]::AppendAllText($env:GRATE_TEST_DOCKER_EVENTS,$record+"`n")
if ($env:GRATE_TEST_DOCKER_FAILURE -and $args[1] -ceq $env:GRATE_TEST_DOCKER_FAILURE) { exit 19 }
if (($args -join '|') -ceq 'buildx|ls') { if (!$env:GRATE_TEST_BUILDER_MISSING) { 'multiarch-builder' } }
elseif ($args[0] -cne 'buildx' -or $args[1] -cnotin @('use','build','create')) { exit 17 }
exit 0
'@
    Write-TestExecutable 'dotnet' @'
if ($env:GRATE_TEST_GITVERSION_FAILURE) { exit 23 }
if (($args -join '|') -ceq 'tool|list|-g') { 'gitversion.tool' }
elseif (($args -join '|') -ceq 'gitversion|/showvariable|SemVer') { $env:GRATE_TEST_VERSION }
else { exit 17 }
exit 0
'@
    $env:PATH=$directory+[IO.Path]::PathSeparator+$oldPath
    $env:GRATE_TEST_DOCKER_EVENTS=$events
    $env:GRATE_TEST_VERSION='2.3.4'
    [Environment]::CurrentDirectory=$directory
    Invoke-Test 'stable local build tags both names without publishing' {
        $result=Invoke-LocalBuild
        Assert-Equal 0 $result.ExitCode $result.Text
        $arguments=Get-BuildArguments
        Assert-Equal @('gratedevs/grate:2.3.4','gratedevs/grate:latest','erikbra/grate:2.3.4','erikbra/grate:latest') @(Get-OptionValues $arguments '--tag')
        Assert-Equal @('VERSION=2.3.4') @(Get-OptionValues $arguments '--build-arg')
        Assert-Equal @('linux/amd64,linux/arm64') @(Get-OptionValues $arguments '--platform')
        Assert-True ($arguments -cnotcontains '--load'); Assert-True ($arguments -cnotcontains '--push')
    }
    Invoke-Test 'prerelease keeps exact version without latest' {
        $env:GRATE_TEST_VERSION='2.3.4-rc.1'
        $result=Invoke-LocalBuild @('-Arm64')
        Assert-Equal 0 $result.ExitCode $result.Text
        $arguments=Get-BuildArguments
        Assert-Equal @('gratedevs/grate:2.3.4-rc.1','erikbra/grate:2.3.4-rc.1') @(Get-OptionValues $arguments '--tag')
        Assert-Equal @('VERSION=2.3.4-rc.1') @(Get-OptionValues $arguments '--build-arg')
        Assert-Equal @('linux/arm64') @(Get-OptionValues $arguments '--platform')
        Assert-True ($arguments -ccontains '--load'); Assert-True ($arguments -cnotcontains '--push')
    }
    Invoke-Test 'outside checkout invocation uses repository context' {
        $result=Invoke-LocalBuild @('-Platform','linux/amd64')
        Assert-Equal 0 $result.ExitCode $result.Text
        $records=@(Read-DockerEvents)
        Assert-True ($records.Count -gt 0)
        foreach ($record in $records) { Assert-Equal $repository $record.cwd }
        $arguments=Get-BuildArguments
        Assert-Equal @('./installers/docker/Dockerfile') @(Get-OptionValues $arguments '--file')
        Assert-Equal '.' $arguments[-1]
        Assert-Equal @('linux/amd64') @(Get-OptionValues $arguments '--platform')
        Assert-True ($arguments -ccontains '--load')
    }
    Invoke-Test 'multiplatform load rejects before Docker' {
        $result=Invoke-LocalBuild @('-Load')
        Assert-True ($result.ExitCode -ne 0)
        Assert-True $result.ErrorText.Contains('-Load requires a single platform')
        Assert-Equal 0 @(Read-DockerEvents).Count
    }
    Invoke-Test 'missing platform value rejects before Docker' {
        foreach ($arguments in @(@('-Platform'),@('-Platform','--load'))) {
            $result=Invoke-LocalBuild $arguments
            Assert-True ($result.ExitCode -ne 0)
            Assert-True ($result.ErrorText -match 'Missing an argument|requires a value')
            Assert-Equal 0 @(Read-DockerEvents).Count
        }
    }
    Invoke-Test 'conflicting architecture selections fail before Docker' {
        foreach ($arguments in @(@('-Amd64','-Arm64'),@('-Platform','linux/amd64','-Arm64'))) {
            $result=Invoke-LocalBuild $arguments
            Assert-True ($result.ExitCode -ne 0)
            Assert-Equal 0 @(Read-DockerEvents).Count
        }
    }
    Invoke-Test 'invalid version cannot create or build an image' {
        $previous=$env:GRATE_TEST_VERSION; $env:GRATE_TEST_VERSION='latest'
        try {
            $result=Invoke-LocalBuild
            Assert-True ($result.ExitCode -ne 0)
            Assert-Equal 0 @(Read-DockerEvents).Count
        } finally { $env:GRATE_TEST_VERSION=$previous }
    }
    Invoke-Test 'missing GitVersion uses the local prerelease fallback' {
        $env:GRATE_TEST_GITVERSION_FAILURE='1'
        try {
            $result=Invoke-LocalBuild
            Assert-Equal 0 $result.ExitCode $result.ErrorText
            Assert-Equal @('gratedevs/grate:1.0.0-local','erikbra/grate:1.0.0-local') @(Get-OptionValues (Get-BuildArguments) '--tag')
        } finally { $env:GRATE_TEST_GITVERSION_FAILURE='' }
    }
    Invoke-Test 'a missing builder is created before building' {
        $env:GRATE_TEST_BUILDER_MISSING='1'
        try {
            $result=Invoke-LocalBuild
            Assert-Equal 0 $result.ExitCode $result.ErrorText
            $records=@(Read-DockerEvents)
            Assert-Equal @('buildx','create','--name','multiarch-builder','--use') $records[1].args
            $null=Get-BuildArguments
        } finally { $env:GRATE_TEST_BUILDER_MISSING='' }
    }
    Invoke-Test 'Docker failures propagate without reporting success' {
        foreach ($operation in @('ls','use','build')) {
            $env:GRATE_TEST_DOCKER_FAILURE=$operation
            $result=Invoke-LocalBuild
            Assert-True ($result.ExitCode -ne 0 -and !$result.Text.Contains('Build completed successfully!'))
            if ($operation -ne 'build') { Assert-Equal 0 @(Read-DockerEvents | Where-Object { $_.args[1] -ceq 'build' }).Count }
        }
        $env:GRATE_TEST_DOCKER_FAILURE=''
    }
} finally {
    foreach ($key in $savedFakeEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key,$savedFakeEnvironment[$key]) }
    $env:PATH=$oldPath;$env:GRATE_TEST_DOCKER_EVENTS=$oldEvents;$env:GRATE_TEST_VERSION=$oldVersion
    [Environment]::CurrentDirectory=$oldCwd
    [IO.Directory]::Delete($directory,$true)
}
Write-Host "$script:TestCount local build checks passed."
