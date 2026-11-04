#!/usr/bin/env pwsh
param ([Parameter(Mandatory=$true)] [psobject]$State)

$ErrorActionPreference = 'Stop'
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Certificate trust changes are restricted to disposable GitHub-hosted Windows CI runners.'
}
if ($State.Pid) {
    $process = Get-Process -Id $State.Pid -ErrorAction SilentlyContinue
    if ($process) { $process | Stop-Process -Force }
}
if ($State.CertificateThumbprint) {
    foreach ($store in @('Cert:\LocalMachine\Root', 'Cert:\CurrentUser\My')) {
        $path = Join-Path $store $State.CertificateThumbprint
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
if ($State.CertificateDirectory -and (Test-Path -LiteralPath $State.CertificateDirectory)) {
    Remove-Item -LiteralPath $State.CertificateDirectory -Recurse -Force
}
