#!/usr/bin/env pwsh
# Small installer-policy test, not an application/lifecycle matrix. Framework-
# dependent probe apphosts provide real Windows version resources; never release
# these fixtures. All authoring happens in an isolated copy, not installers/msi/tmp.
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('x64','arm64')][string]$Architecture=([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant())
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'Prerelease MSI installation tests require a disposable GitHub-hosted Windows runner.' }
if ($Architecture -ne [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()) { throw 'Policy installation tests must run on the target architecture.' }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path $OutputDirectory) { throw 'Use a fresh output directory for prerelease MSI policy evidence.' }
New-Item -ItemType Directory $OutputDirectory | Out-Null
$installed=Join-Path $env:LOCALAPPDATA 'erikbra/grate/grate.exe'
if ((Test-Path (Split-Path $installed)) -or (Get-Command grate -ErrorAction SilentlyContinue)) { throw 'Refusing to replace a pre-existing grate installation.' }
$authoring=Join-Path $OutputDirectory 'authoring'
New-Item -ItemType Directory $authoring | Out-Null
Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object Extension -In @('.ps1','.cpp','.wxs','.json') | Copy-Item -Destination $authoring
. "$PSScriptRoot/WinGetMsiLifecycle.Assertions.ps1"
$originalUserPath=[Environment]::GetEnvironmentVariable('Path','User')
$fixtures=@{}
$ownsInstallation=$false
$generation=0
$summary=[ordered]@{Architecture=$Architecture; Purpose='Installer policy using disposable probe apphosts'; Completed=$false}
$data=Join-Path $OutputDirectory 'external-user-data.txt'
'Preserve this external user data through every allowed or refused MSI operation.' | Set-Content $data
$dataHash=(Get-FileHash $data).Hash
function Run([string]$Tool,[string[]]$Arguments,[string]$Name,[int]$Timeout=180) {
    $info=[Diagnostics.ProcessStartInfo]::new($Tool)
    $info.UseShellExecute=$false; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        @{Executable=$Tool; Arguments=$Arguments; State='Running'; ProcessId=$process.Id} | ConvertTo-Json -Depth 6 | Set-Content "$OutputDirectory/$Name.command.json"
        $timedOut=!$process.WaitForExit($Timeout*1000)
        if ($timedOut) { $process.Kill(); if (!$process.WaitForExit(5000)) { throw "$Name did not terminate." } }
        $output=$stdout.WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()+$stderr.WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()
        $output | Set-Content "$OutputDirectory/$Name.log"
        @{Executable=$Tool; Arguments=$Arguments; ExitCode=$process.ExitCode; TimedOut=$timedOut} | ConvertTo-Json -Depth 6 | Set-Content "$OutputDirectory/$Name.command.json"
        if ($timedOut) { throw "$Name timed out." }
        return $process.ExitCode
    } finally { $process.Dispose() }
}
function Inventory {
    $script:generation++
    $request="$OutputDirectory/inventory-$generation.request.json"
    $snapshot="$OutputDirectory/inventory-$generation.snapshot.json"
    @($fixtures.Values.Identity.ProductCode) | ConvertTo-Json | Set-Content $request
    $exit=Run (Join-Path $PSHOME 'pwsh.exe') @('-NoLogo','-NoProfile','-NonInteractive','-MTA','-File',"$authoring/Get-InstalledProductInventoryBatch.ps1",'-RequestPath',$request,'-OutputPath',$snapshot) "inventory-$generation" 30
    if ($exit -ne 0) { throw 'Native MSI inventory worker failed.' }
    @(Get-Content $snapshot -Raw | ConvertFrom-Json -AsHashtable)
}
function Assert-Current([string]$Release) {
    $expected=$fixtures[$Release]
    $inventories=@(Inventory)
    $current=@($inventories | Where-Object ProductCode -IEQ $expected.Identity.ProductCode)
    if ($current.Count -ne 1) { throw 'Inventory did not return exactly the expected product.' }
    Assert-WinGetMsiNativeContext -Inventory $current[0].Inventory -ExpectedVersion $expected.Core -ExpectedPublisher 'grate-devs'
    foreach ($item in $inventories) {
        if ($item.ProductCode -ine $expected.Identity.ProductCode -and @($item.Inventory.Contexts).Count -ne 0) { throw 'An unexpected fixture product is still installed.' }
    }
    if (!(Test-Path $installed) -or (Get-FileHash $installed).Hash -ne $expected.PayloadHash) { throw "Installed payload is not exactly $Release." }
    if ((Get-FileHash $data).Hash -ne $dataHash) { throw 'MSI operation changed external data.' }
}
function Msi([string]$Operation,[string]$Release,[string]$Name,[int]$ExpectedExit=0) {
    # Windows Installer rejects forward slashes inside a local package path
    # (1324/1619), even though COM metadata reads accept the same path.
    $package=(Resolve-Path -LiteralPath $fixtures[$Release].Msi).ProviderPath
    $log=Join-Path $OutputDirectory "$Name.msi.log"
    $result=Run "$env:SystemRoot/System32/msiexec.exe" @($Operation,$package,'/qn','/norestart','/l*v',$log) $Name
    if ($result -ne $ExpectedExit) { throw "$Name returned $result; expected $ExpectedExit." }
    if ((Get-FileHash $data).Hash -ne $dataHash) { throw "$Name changed external data." }
    if ($ExpectedExit -eq 1603 -and (Get-Content "$OutputDirectory/$Name.msi.log" -Raw) -notmatch 'A different grate MSI has the same numeric version') { throw 'Refusal did not come from the same-core policy guard.' }
}
try {
    $probe=Join-Path $OutputDirectory 'probe'
    New-Item -ItemType Directory $probe | Out-Null
    '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><AssemblyName>grate-policy-probe</AssemblyName><UseAppHost>true</UseAppHost></PropertyGroup></Project>' | Set-Content "$probe/Probe.csproj"
    'System.Console.WriteLine("Disposable MSI policy probe; not a grate release.");' | Set-Content "$probe/Program.cs"
    foreach ($release in @('2.1.9','2.2.0-rc.1','2.2.0-rc.2','2.2.0','2.2.1')) {
        $core=$release.Split('-')[0]
        $payload=Join-Path $OutputDirectory "payload-$release"
        $exit=Run 'dotnet' @('publish',"$probe/Probe.csproj",'-c','Release','-r',"win-$Architecture",'--self-contained','false',"-p:Version=$release",'-o',$payload) "publish-$release"
        if ($exit -ne 0) { throw 'Probe apphost build failed.' }
        $exe=Join-Path $payload 'grate-policy-probe.exe'
        $identity=& "$authoring/Get-InstallerIdentity.ps1" -Version $core -ReleaseVersion $release -Architecture $Architecture
        $fixtures[$release]=@{Core=$core; Identity=$identity; PayloadHash=(Get-FileHash $exe).Hash; Msi="$OutputDirectory/grate-$release.msi"}
        if ($release -eq '2.2.0-rc.1') {
            # Explicitly catch the integration bug: core-only argument on an RC
            # payload must fail before producing/replacing an MSI.
            $rejected=$false
            try { & "$authoring/Create-Installer.ps1" -grateExe $exe -version $core -arch $Architecture }
            catch { $rejected=$_.Exception.Message -like 'The executable ProductVersion must match ReleaseVersion*' }
            if (!$rejected) { throw 'Core-only prerelease authoring was not rejected.' }
        }
        & "$authoring/Create-Installer.ps1" -grateExe $exe -version $core -ReleaseVersion $release -arch $Architecture
        Copy-Item "$authoring/tmp/grate-$core.msi" $fixtures[$release].Msi
        # COM metadata inspection stays in a bounded child, out of the waiting
        # msiexec thread, as in the existing verified native harness.
        $exit=Run (Join-Path $PSHOME 'pwsh.exe') @('-NoLogo','-NoProfile','-NonInteractive','-MTA','-File',"$authoring/Test-InstallerMetadata.Tests.ps1",'-MsiPath',$fixtures[$release].Msi,'-ExpectedVersion',$core,'-ExpectedReleaseVersion',$release,'-ExpectedArchitecture',$Architecture) "metadata-$release" 30
        if ($exit -ne 0) { throw 'Actual fixture MSI metadata mismatch.' }
    }
    if (@(Inventory | ForEach-Object { $_.Inventory.Contexts }).Count -ne 0) { throw 'Refusing to own an existing policy fixture installation.' }
    $ownsInstallation=$true
    Msi '/i' '2.1.9' 'older-stable-install'
    Assert-Current '2.1.9'
    Msi '/i' '2.2.0-rc.1' 'higher-core-rc-upgrade'
    Assert-Current '2.2.0-rc.1'
    Msi '/i' '2.2.0-rc.2' 'same-core-rc-refused' 1603
    Assert-Current '2.2.0-rc.1'
    Msi '/i' '2.2.0' 'same-core-final-refused' 1603
    Assert-Current '2.2.0-rc.1'
    Msi '/x' '2.2.0-rc.1' 'explicit-rc-uninstall'
    Msi '/i' '2.2.0' 'explicit-final-install'
    Assert-Current '2.2.0'
    Msi '/i' '2.2.0-rc.1' 'same-core-stable-to-rc-refused' 1603
    Assert-Current '2.2.0'
    Msi '/i' '2.2.1' 'next-stable-upgrade'
    Assert-Current '2.2.1'
    Msi '/x' '2.2.1' 'final-uninstall'
    if ((Test-Path $installed) -or @(Inventory | ForEach-Object { $_.Inventory.Contexts }).Count -ne 0) { throw 'Final uninstall left a fixture product or payload.' }
    $summary.Completed=$true
    $summary.CoreOnlyPrereleaseAuthoringRejected=$true
    $summary.SameCoreRefusals=3
    $summary.ExplicitUninstallReinstallVerified=$true
    $summary.GreaterCoreUpgradesVerified=$true
    $summary.ExternalDataPreserved=$true
    Write-Host "PASS: $Architecture prerelease identities, same-core refusals, explicit replacement and higher-core upgrades."
} finally {
    try {
        if ($ownsInstallation) {
            foreach ($item in @(Inventory)) {
                if (@($item.Inventory.Contexts).Count) {
                    $release=@($fixtures.Keys | Where-Object { $fixtures[$_].Identity.ProductCode -ieq $item.ProductCode })[0]
                    Msi '/x' $release 'failure-cleanup'
                }
            }
        }
    } finally {
        $summary | ConvertTo-Json -Depth 6 | Set-Content "$OutputDirectory/summary.json"
        [Environment]::SetEnvironmentVariable('Path',$originalUserPath,'User')
    }
}
