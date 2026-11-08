#!/usr/bin/env pwsh
# Package installation runs only in the disposable container, never on the host.
param(
    [string]$InitialPackage,
    [string]$UpgradePackage,
    [ValidateSet('amd64', 'arm64')][string]$Architecture,
    [string]$InitialVersion,
    [string]$UpgradeVersion,
    [string]$OutputDirectory
)
. "$PSScriptRoot/PackageLifecycle.Common.ps1"

function Invoke-PackageLifecycle {
    param(
        [Parameter(Mandatory)][string]$InitialPackage,
        [Parameter(Mandatory)][string]$UpgradePackage,
        [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Architecture,
        [Parameter(Mandatory)][string]$InitialVersion,
        [Parameter(Mandatory)][string]$UpgradeVersion,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    $InitialPackage = (Resolve-Path -LiteralPath $InitialPackage).Path
    $UpgradePackage = (Resolve-Path -LiteralPath $UpgradePackage).Path
    if (!(Test-Path -LiteralPath $InitialPackage -PathType Leaf) -or !(Test-Path -LiteralPath $UpgradePackage -PathType Leaf)) { throw 'Both candidate packages must exist.' }
    if ($InitialVersion -ceq $UpgradeVersion) { throw 'Two distinct expected package versions are required.' }
    $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    $null = [IO.Directory]::CreateDirectory($OutputDirectory)

    function Invoke-LoggedDocker([string[]]$Arguments, [string]$Name, [int]$TimeoutSeconds = 30) {
        $result = Invoke-PackageTestDocker $Arguments $TimeoutSeconds
        ($result.Output + $result.ErrorOutput) | Set-Content -LiteralPath (Join-Path $OutputDirectory "$Name.log")
        if ($result.TimedOut) { throw "$Name exceeded ${TimeoutSeconds}s; see $OutputDirectory/$Name.log." }
        $result
    }
    $info = Invoke-LoggedDocker @('info', '--format', '{{.Architecture}}') 'docker-info'
    if ($info.ExitCode -ne 0) { throw "Cannot inspect the Docker engine; see $OutputDirectory/docker-info.log." }
    $nativeArchitecture = switch ($info.Output.Trim()) {
        { $_ -in 'x86_64', 'amd64' } { 'amd64'; break }
        { $_ -in 'aarch64', 'arm64' } { 'arm64'; break }
        default { $_ }
    }
    if ($nativeArchitecture -cne $Architecture) { throw "Expected native $Architecture Docker engine, found $nativeArchitecture." }

    $token = [Guid]::NewGuid().ToString('N')
    $container = 'grate-deb-lifecycle-' + $token
    try {
        # The pinned multi-architecture image needs no PowerShell installation.
        # Its watchdog leaves time after the verifier's eight-minute work budget
        # to retain diagnostics before this wrapper removes the container.
        $result = Invoke-LoggedDocker @(
            'run', '--detach', '--rm', '--init', '--name', $container, '--platform', "linux/$Architecture",
            '--label', "grate.deb-lifecycle=$token", '--env', 'GRATE_DEB_LIFECYCLE_CONTAINER=1',
            '--mount', "type=bind,source=$InitialPackage,target=/packages/initial.deb,readonly",
            '--mount', "type=bind,source=$UpgradePackage,target=/packages/upgrade.deb,readonly",
            '--mount', "type=bind,source=$OutputDirectory,target=/diagnostics",
            'ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852',
            'timeout', '--kill-after=15s', '10m', 'sleep', 'infinity'
        ) 'container-start' 120
        if ($result.ExitCode -ne 0) { throw "Cannot start lifecycle container; see $OutputDirectory/container-start.log." }
        $result = Invoke-PackageTestProcess (Get-Process -Id $PID).Path @(
            '-NoLogo', '-NoProfile', '-File', "$PSScriptRoot/Verify-PackageLifecycle.ps1",
            '-Container', $container, '-ContainerToken', $token, '-Architecture', $Architecture,
            '-InitialVersion', $InitialVersion, '-UpgradeVersion', $UpgradeVersion, '-OutputDirectory', $OutputDirectory
        ) 600
        ($result.Output + $result.ErrorOutput) | Set-Content -LiteralPath (Join-Path $OutputDirectory 'lifecycle.log')
        Write-Host $result.Output
        if ($result.TimedOut) { throw "Debian package lifecycle exceeded 600s; see $OutputDirectory/lifecycle.log." }
        if ($result.ExitCode -ne 0) { throw "Debian package lifecycle failed with exit code $($result.ExitCode); see $OutputDirectory/lifecycle.log." }
    } finally {
        # A killed Docker client does not stop its container. Remove only ours.
        $cleanup = Invoke-LoggedDocker @('rm', '--force', $container) 'container-cleanup'
        if ($cleanup.ExitCode -ne 0 -and ($cleanup.Output + $cleanup.ErrorOutput) -notmatch 'No such container') { throw "Cannot remove lifecycle container $container; see $OutputDirectory/container-cleanup.log." }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-PackageLifecycle @PSBoundParameters }
