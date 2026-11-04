#!/usr/bin/env pwsh
param([Parameter(Mandatory)][psobject]$State)
$ErrorActionPreference='Stop'
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Preindexed cleanup requires a disposable GitHub-hosted Windows runner.'
}
try {
    if ($State.PackageFullName) {
        Import-Module Appx -UseWindowsPowerShell
        if (Get-AppxPackage -Name Grate.Migration.CI.Source) { Remove-AppxPackage -Package $State.PackageFullName }
    }
} finally {
    try {
        if ($State.CertificateThumbprint) {
            $path=Join-Path 'Cert:\LocalMachine\TrustedPeople' $State.CertificateThumbprint
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    } finally { & "$PSScriptRoot/Stop-TestSource.ps1" -State $State }
}
