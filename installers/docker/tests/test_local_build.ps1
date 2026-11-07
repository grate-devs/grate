#!/usr/bin/env pwsh
. "$PSScriptRoot/../../../scripts/release/release_common.ps1"
. "$PSScriptRoot/../../../scripts/release/release_test_helpers.ps1"
if ($IsWindows) { Write-Host 'SKIP: build-docker-local.sh command shims require a POSIX shell.'; exit 0 }
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$directory=New-TestDirectory
$events=Join-Path $directory 'docker-events.jsonl'
$oldPath=$env:PATH; $oldEvents=$env:GRATE_TEST_DOCKER_EVENTS; $oldVersion=$env:GRATE_TEST_VERSION; $oldCwd=[Environment]::CurrentDirectory
function Write-TestExecutable([string]$Name,[string]$Body) {
    $path=Join-Path $directory $Name
    [IO.File]::WriteAllText($path,"#!/usr/bin/env pwsh`n"+$Body)
    [IO.File]::SetUnixFileMode($path,[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
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
    Invoke-ReleaseProcess '/bin/bash' (@((Join-Path $repository 'build-docker-local.sh'))+$Arguments) 30
}
try {
    Write-TestExecutable 'docker' @'
$record=@{args=@($args);cwd=[Environment]::CurrentDirectory}|ConvertTo-Json -Compress
[IO.File]::AppendAllText($env:GRATE_TEST_DOCKER_EVENTS,$record+"`n")
if (($args -join '|') -ceq 'buildx|ls') { 'multiarch-builder' }
elseif ($args[0] -cne 'buildx' -or $args[1] -cnotin @('use','build')) { exit 17 }
'@
    Write-TestExecutable 'dotnet' @'
if (($args -join '|') -ceq 'tool|list|-g') { 'gitversion.tool' }
elseif (($args -join '|') -ceq 'gitversion|/showvariable|SemVer') { $env:GRATE_TEST_VERSION }
else { exit 17 }
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
        $result=Invoke-LocalBuild @('--arm64')
        Assert-Equal 0 $result.ExitCode $result.Text
        $arguments=Get-BuildArguments
        Assert-Equal @('gratedevs/grate:2.3.4-rc.1','erikbra/grate:2.3.4-rc.1') @(Get-OptionValues $arguments '--tag')
        Assert-Equal @('VERSION=2.3.4-rc.1') @(Get-OptionValues $arguments '--build-arg')
        Assert-Equal @('linux/arm64') @(Get-OptionValues $arguments '--platform')
        Assert-True ($arguments -ccontains '--load'); Assert-True ($arguments -cnotcontains '--push')
    }
    Invoke-Test 'outside checkout invocation uses repository context' {
        $result=Invoke-LocalBuild @('--platform','linux/amd64')
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
        $result=Invoke-LocalBuild @('--load')
        Assert-True ($result.ExitCode -ne 0)
        Assert-True $result.ErrorText.Contains('--load requires a single platform')
        Assert-Equal 0 @(Read-DockerEvents).Count
    }
    Invoke-Test 'missing platform value rejects before Docker' {
        foreach ($arguments in @(@('--platform'),@('--platform','--load'))) {
            $result=Invoke-LocalBuild $arguments
            Assert-True ($result.ExitCode -ne 0)
            Assert-True $result.ErrorText.Contains('--platform requires a value')
            Assert-Equal 0 @(Read-DockerEvents).Count
        }
    }
} finally {
    $env:PATH=$oldPath;$env:GRATE_TEST_DOCKER_EVENTS=$oldEvents;$env:GRATE_TEST_VERSION=$oldVersion
    [Environment]::CurrentDirectory=$oldCwd
    [IO.Directory]::Delete($directory,$true)
}
Write-Host "$script:TestCount local build checks passed."
