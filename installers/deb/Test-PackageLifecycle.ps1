#!/usr/bin/env pwsh
# Install only inside the disposable container, never on the invoking host.
param(
    [Parameter(Mandatory)][string]$InitialPackage,
    [Parameter(Mandatory)][string]$UpgradePackage,
    [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Architecture,
    [Parameter(Mandatory)][string]$InitialVersion,
    [Parameter(Mandatory)][string]$UpgradeVersion,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$InitialPackage = (Resolve-Path -LiteralPath $InitialPackage).Path
$UpgradePackage = (Resolve-Path -LiteralPath $UpgradePackage).Path
if (!(Test-Path -LiteralPath $InitialPackage -PathType Leaf) -or !(Test-Path -LiteralPath $UpgradePackage -PathType Leaf)) {
    throw 'Both candidate packages must exist.'
}
if ($InitialVersion -eq $UpgradeVersion) { throw 'Two distinct expected package versions are required.' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null

function Invoke-Docker([string[]]$Arguments, [string]$Name, [int]$TimeoutSeconds) {
    $start = [Diagnostics.ProcessStartInfo]::new('docker')
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = !$process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        $output | Set-Content -LiteralPath (Join-Path $OutputDirectory "$Name.log")
        if ($timedOut) { throw "$Name exceeded ${TimeoutSeconds}s; see $OutputDirectory/$Name.log." }
        return @{ ExitCode = $process.ExitCode; Output = $output }
    } finally { $process.Dispose() }
}

$info = Invoke-Docker @('info', '--format', '{{.Architecture}}') 'docker-info' 30
if ($info.ExitCode -ne 0) { throw "Cannot inspect the Docker engine; see $OutputDirectory/docker-info.log." }
$nativeArchitecture = switch ($info.Output.Trim()) {
    { $_ -in 'x86_64', 'amd64' } { 'amd64'; break }
    { $_ -in 'aarch64', 'arm64' } { 'arm64'; break }
    default { $_ }
}
if ($nativeArchitecture -ne $Architecture) {
    throw "Expected native $Architecture Docker engine, found $nativeArchitecture."
}

$container = 'grate-deb-lifecycle-' + [Guid]::NewGuid().ToString('N')
try {
    # The pinned multi-architecture Ubuntu LTS image matches the native CI host.
    # Packages and migration state disappear with the container; diagnostics survive.
    $result = Invoke-Docker @(
        'run', '--rm', '--init', '--name', $container, '--platform', "linux/$Architecture",
        '--env', 'GRATE_DEB_LIFECYCLE_CONTAINER=1',
        '--mount', "type=bind,source=$InitialPackage,target=/packages/initial.deb,readonly",
        '--mount', "type=bind,source=$UpgradePackage,target=/packages/upgrade.deb,readonly",
        '--mount', "type=bind,source=$PSScriptRoot/Verify-PackageLifecycle.sh,target=/verification/verify.sh,readonly",
        '--mount', "type=bind,source=$OutputDirectory,target=/diagnostics",
        'ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852',
        'timeout', '--kill-after=15s', '8m', 'bash', '/verification/verify.sh',
        $Architecture, $InitialVersion, $UpgradeVersion
    ) 'lifecycle' 600
    Write-Host $result.Output
    if ($result.ExitCode -ne 0) { throw "Debian package lifecycle failed with exit code $($result.ExitCode); see $OutputDirectory/lifecycle.log." }
} finally {
    # A timed-out Docker client does not stop its container. Remove only ours.
    $cleanup = Invoke-Docker @('rm', '--force', $container) 'container-cleanup' 30
    # --rm normally removed it already, so a nonzero result here is expected.
    if ($cleanup.ExitCode -ne 0 -and $cleanup.Output -notmatch 'No such container') {
        throw "Cannot remove lifecycle container $container; see $OutputDirectory/container-cleanup.log."
    }
}
