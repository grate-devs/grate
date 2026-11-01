#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory=$true)] [string]$Catalog,
    [Parameter(Mandatory=$true)] [string]$LogDirectory,
    [string]$Assets,
    [int]$Port = 8765,
    [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Certificate trust changes are restricted to disposable GitHub-hosted Windows CI runners.'
}

$catalogPath = (Resolve-Path -LiteralPath $Catalog).Path
$sourceIdentifier = (Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json).SourceIdentifier
$logs = (New-Item -ItemType Directory -Path $LogDirectory -Force).FullName
$certificateDirectory = (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString()))).FullName
$state = [pscustomobject]@{
    Pid = $null
    Url = "https://localhost:$Port"
    SourceIdentifier = $sourceIdentifier
    CertificateThumbprint = $null
    CertificateDirectory = $certificateDirectory
    LogDirectory = $logs
}

try {
    $certificate = New-SelfSignedCertificate -DnsName localhost -CertStoreLocation Cert:\CurrentUser\My `
        -KeyExportPolicy Exportable -NotAfter (Get-Date).AddDays(1) -FriendlyName 'grate disposable WinGet CI source'
    $state.CertificateThumbprint = $certificate.Thumbprint
    $certificateFile = Join-Path $certificateDirectory 'localhost.pem'
    $privateKeyFile = Join-Path $certificateDirectory 'localhost-key.pem'
    [IO.File]::WriteAllText($certificateFile, $certificate.ExportCertificatePem())
    $privateKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    try {
        [IO.File]::WriteAllText($privateKeyFile, $privateKey.ExportPkcs8PrivateKeyPem())
    } finally {
        $privateKey.Dispose()
    }

    $publicCertificateFile = Join-Path $certificateDirectory 'localhost.cer'
    $null = Export-Certificate -Cert $certificate -FilePath $publicCertificateFile
    # WinGet's HTTP stack must trust the certificate itself; readiness does not
    # bypass certificate checks. This store is removed by Stop-TestSource.
    $null = Import-Certificate -FilePath $publicCertificateFile -CertStoreLocation Cert:\LocalMachine\Root

    $arguments = @('-u', (Join-Path $PSScriptRoot 'server.py'), '--catalog', $catalogPath,
        '--certificate', $certificateFile, '--private-key', $privateKeyFile, '--port', "$Port")
    if ($Assets) {
        $arguments += @('--assets', (Resolve-Path -LiteralPath $Assets).Path)
    }
    # Start-Process joins ArgumentList into a Windows command line. Quote every
    # argument so checkout/temp paths with spaces retain their boundaries.
    $quotedArguments = $arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }
    $process = Start-Process -FilePath $Python -ArgumentList $quotedArguments -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $logs 'test-source.stdout.log') `
        -RedirectStandardError (Join-Path $logs 'test-source.stderr.log')
    $state.Pid = $process.Id
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        if ($process.HasExited) { throw "Test source exited with code $($process.ExitCode). See $logs." }
        try {
            $information = Invoke-RestMethod -Uri "$($state.Url)/information" -TimeoutSec 1
            if ($information.Data.SourceIdentifier -ne $sourceIdentifier) { throw 'Unexpected source identity.' }
            return $state
        } catch {
            if ($attempt -eq 99) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
} catch {
    & (Join-Path $PSScriptRoot 'Stop-TestSource.ps1') -State $state
    throw
}
