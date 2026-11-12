#!/usr/bin/env pwsh
# Generate and render native Kubernetes Helm artifacts without contacting a cluster or registry.
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$HelmPath = $env:GRATE_HELM_PATH,
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($HelmPath)) {
    $HelmPath = 'helm'
}
$repository = Split-Path $PSScriptRoot -Parent
$directory = Join-Path $repository 'examples/aspire/Kubernetes/PublicationChecks'
$project = Join-Path $directory 'PublicationChecks.csproj'
$assembly = Join-Path $directory "bin/$Configuration/net10.0/PublicationChecks.dll"
$workspace = Join-Path ([IO.Path]::GetTempPath()) "grate-kubernetes-publication-$([Guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $workspace
$previousOutput = $env:GRATE_KUBE_CHECK_OUTPUT
$previousHelm = $env:GRATE_HELM_PATH
$previousImage = $env:GRATE_KUBE_BUILD_IMAGE

function Invoke-BoundedCommand {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$LogPath,
        [int]$TimeoutSeconds = 240
    )

    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.WorkingDirectory = [IO.Path]::GetTempPath()
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    if ($null -eq $process) {
        throw "Could not start $Executable."
    }
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            if (!$process.HasExited) {
                $process.Kill($true)
            }
            $process.WaitForExit()
            $timeoutText = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
            Set-Content -LiteralPath $LogPath -Value $timeoutText -NoNewline -Encoding utf8
            throw "$Executable exceeded its verification timeout."
        }
        $text = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        Set-Content -LiteralPath $LogPath -Value ($text + $errorText) -NoNewline -Encoding utf8
        if ($process.ExitCode -ne 0) {
            throw "$Executable failed; see $LogPath."
        }
        return $text
    }
    finally {
        $process.Dispose()
    }
}

try {
    if (!$NoBuild) {
        $null = Invoke-BoundedCommand -Executable 'dotnet' -Arguments @(
            'build', $project, '--configuration', $Configuration, '--nologo'
        ) -LogPath (Join-Path $workspace 'build.log')
    }
    if (!(Test-Path -LiteralPath $assembly -PathType Leaf)) {
        throw "Build the publication checks before using -NoBuild: $assembly"
    }
    $env:GRATE_KUBE_CHECK_OUTPUT = $workspace
    $env:GRATE_HELM_PATH = $HelmPath
    # This reusable artifact check is offline even if a caller previously requested a runtime image build.
    $env:GRATE_KUBE_BUILD_IMAGE = $null
    $text = Invoke-BoundedCommand -Executable 'dotnet' -Arguments @($assembly) -LogPath (Join-Path $workspace 'publication.log')
    $text -split "`n" | Where-Object { $_ -match '^PASS:' } | Write-Output
    Remove-Item -LiteralPath $workspace -Recurse -Force
}
catch {
    throw "Kubernetes publication verification failed. Local artifacts and diagnostics: $workspace. $($_.Exception.Message)"
}
finally {
    $env:GRATE_KUBE_CHECK_OUTPUT = $previousOutput
    $env:GRATE_HELM_PATH = $previousHelm
    $env:GRATE_KUBE_BUILD_IMAGE = $previousImage
}
