#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)] [string[]]$AssetsFile,
    [Parameter(Mandatory)] [string]$OutputDirectory,
    [string[]]$PackageRoot,
    [string]$RepositoryRoot = (Join-Path $PSScriptRoot '../..'),
    [string]$SourceDirectory = $PSScriptRoot,
    [switch]$AllowMissingLicenseEvidence
)

$ErrorActionPreference = 'Stop'
$inputs = Join-Path ([IO.Path]::GetTempPath()) ('grate-license-inputs-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $inputs -Force | Out-Null
[IO.File]::WriteAllLines((Join-Path $inputs 'assets.txt'), [string[]]@($AssetsFile | ForEach-Object { [IO.Path]::GetFullPath($_) }))
[IO.File]::WriteAllLines((Join-Path $inputs 'roots.txt'), [string[]]@($PackageRoot | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_) }))
$parameters = [ordered]@{
    LicenseAssetsListFile = Join-Path $inputs 'assets.txt'
    LicenseRootsListFile = Join-Path $inputs 'roots.txt'
    LicenseOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    LicenseRepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
    LicenseSourceDirectory = [IO.Path]::GetFullPath($SourceDirectory)
    LicenseAllowMissing = $AllowMissingLicenseEvidence.IsPresent.ToString().ToLowerInvariant()
}
$start = [Diagnostics.ProcessStartInfo]::new('dotnet')
# This metadata-only task needs any installed SDK, not necessarily the app's
# prerelease SDK in global.json. Publish/pack execute it in their selected SDK.
$start.WorkingDirectory = [IO.Path]::GetTempPath()
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($argument in @('msbuild', (Join-Path $PSScriptRoot 'Export.proj'), '-nologo', '-verbosity:minimal')) {
    $start.ArgumentList.Add($argument)
}
foreach ($parameter in $parameters.GetEnumerator()) {
    $start.ArgumentList.Add("-p:$($parameter.Key)=$($parameter.Value)")
}
$process = [Diagnostics.Process]::Start($start)
try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        throw $output
    }
    Write-Host $output.TrimEnd()
}
finally {
    $process.Dispose()
    Remove-Item -LiteralPath $inputs -Recurse -Force
}
