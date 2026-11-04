#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)][string]$Catalog,
    [Parameter(Mandatory)][string]$Assets,
    [Parameter(Mandatory)][string]$LogDirectory,
    [int]$Port=8765,
    [string]$Python='python'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Preindexed source installation/trust changes require a disposable GitHub-hosted Windows runner.'
}
$logs=(New-Item -ItemType Directory -Path $LogDirectory -Force).FullName
$root=(New-Item -ItemType Directory -Path (Join-Path $logs 'source') -Force).FullName
$secrets=(New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString()))).FullName
$state=[pscustomobject]@{
    Pid=$null; Url="https://127.0.0.1:$Port"; SourceType='Microsoft.PreIndexed.Package'
    SourceIdentifier=$null; PackageFullName=$null; CertificateThumbprint=$null
    CertificateDirectory=$secrets; LogDirectory=$logs; RootDirectory=$root
}
function Native([string]$Tool,[string[]]$Arguments,[string]$Name) {
    $info=[Diagnostics.ProcessStartInfo]::new($Tool)
    $info.UseShellExecute=$false; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(60000)) { $process.Kill(); throw "$Name timed out." }
        $output=$stdout.WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()+$stderr.WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()
        $output | Set-Content -LiteralPath (Join-Path $logs "$Name.log")
        if ($process.ExitCode -ne 0) { throw "$Name failed ($($process.ExitCode)): $output" }
    } finally { $process.Dispose() }
}
try {
    $version='1.29.380'
    $hash='A6C67BD8FE35AFCECFFA123B2080B3172E10A5BC15B01413E963D32DDF10C649'
    $url="https://api.nuget.org/v3-flatcontainer/microsoft.windowspackagemanager.utils/$version/microsoft.windowspackagemanager.utils.$version.nupkg"
    $package=Join-Path $logs 'winget-utils.zip'
    Invoke-WebRequest $url -OutFile $package
    if ((Get-FileHash $package -Algorithm SHA256).Hash -cne $hash) { throw 'Pinned Microsoft.WindowsPackageManager.Utils checksum mismatch.' }
    $tools=Join-Path $logs 'winget-utils'
    Expand-Archive $package $tools -Force
    $hostArch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    $dll=Join-Path $tools "runtimes/win-$hostArch/native/WinGetUtil.dll"
    if (!(Test-Path -LiteralPath $dll)) { throw "No pinned WinGetUtil for $hostArch" }
    Add-Type -Path "$PSScriptRoot/preindexed/WinGetIndex.cs"
    [GrateWinGetIndex]::Load($dll)
    $indexLog=Join-Path $logs 'native-index.log'
    [GrateWinGetIndex]::WinGetLoggingInit($indexLog)

    $manifests=@(& "$PSScriptRoot/preindexed/New-SingletonManifests.ps1" -Catalog $Catalog -OutputDirectory $root)
    $certificate=New-SelfSignedCertificate -Subject 'CN=localhost' -Type Custom `
        -KeyUsage DigitalSignature -KeyExportPolicy Exportable -NotAfter (Get-Date).AddDays(1) `
        -TextExtension @('2.5.29.17={text}DNS=localhost&IPAddress=127.0.0.1', '2.5.29.37={text}1.3.6.1.5.5.7.3.1,1.3.6.1.5.5.7.3.3') `
        -CertStoreLocation Cert:\CurrentUser\My -FriendlyName 'grate disposable preindexed source'
    $state.CertificateThumbprint=$certificate.Thumbprint
    $publicCertificate=Join-Path $secrets 'localhost.cer'
    $null=Export-Certificate -Cert $certificate -FilePath $publicCertificate
    foreach ($store in @('Cert:\LocalMachine\Root','Cert:\LocalMachine\TrustedPeople')) {
        $null=Import-Certificate -FilePath $publicCertificate -CertStoreLocation $store
    }
    $certificateFile=Join-Path $secrets 'localhost.pem'
    $privateKeyFile=Join-Path $secrets 'localhost-key.pem'
    [IO.File]::WriteAllText($certificateFile,$certificate.ExportCertificatePem())
    $key=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    try { [IO.File]::WriteAllText($privateKeyFile,$key.ExportPkcs8PrivateKeyPem()) } finally { $key.Dispose() }

    # Same source family in both index formats. Neither identity is the public
    # Microsoft source; the test explicitly records this distinction.
    @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:uap3="http://schemas.microsoft.com/appx/manifest/uap/windows10/3" IgnorableNamespaces="uap uap3">
  <Identity Name="Grate.Migration.CI.Source" ProcessorArchitecture="neutral" Publisher="CN=localhost" Version="1.0.0.0" />
  <Properties><DisplayName>grate migration CI source</DisplayName><PublisherDisplayName>grate CI</PublisherDisplayName><Logo>logo.png</Logo></Properties>
  <Dependencies><TargetDeviceFamily Name="Windows.Universal" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" /></Dependencies>
  <Applications><Application Id="SourceData"><uap:VisualElements DisplayName="grate CI" Square150x150Logo="logo.png" Square44x44Logo="logo.png" Description="Disposable WinGet source" BackgroundColor="transparent" AppListEntry="none" /><Extensions><uap3:Extension Category="windows.appExtension"><uap3:AppExtension Name="com.microsoft.winget.source" Id="IndexDB" DisplayName="grate CI source" Description="Disposable WinGet source" PublicFolder="Public" /></uap3:Extension></Extensions></Application></Applications>
  <Resources><Resource Language="und" /></Resources>
</Package>
'@ | Set-Content -LiteralPath (Join-Path $root 'AppxManifest.xml') -Encoding utf8NoBOM
    # A real PNG is mapped even though makeappx /nv follows Microsoft's source
    # builder convention for the data-only extension package.
    [IO.File]::WriteAllBytes((Join-Path $root 'logo.png'),[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aS1cAAAAASUVORK5CYII='))
    $sdkBase=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
    $sdk=@(Get-ChildItem -LiteralPath $sdkBase -Directory | Where-Object {
        $_.Name -match '^10\.0\.\d+\.0$' -and (Test-Path (Join-Path $_.FullName "$hostArch/makeappx.exe")) -and (Test-Path (Join-Path $_.FullName "$hostArch/signtool.exe"))
    } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1)
    if (!$sdk.Count) { throw 'Windows SDK makeappx/signtool are required.' }
    $sdkBin=Join-Path $sdk[0].FullName $hostArch
    $indexes=@()
    foreach ($format in @(@{Major=2;Minor=0;Name='source2.msix'},@{Major=1;Minor=7;Name='source.msix'})) {
        $indexPath=Join-Path $root "index-$($format.Major).db"
        $index=[IntPtr]::Zero
        try {
            [GrateWinGetIndex]::WinGetSQLiteIndexCreate($indexPath,$format.Major,$format.Minor,[ref]$index)
            foreach ($manifest in $manifests) {
                [GrateWinGetIndex]::WinGetSQLiteIndexAddManifest($index,$manifest,[IO.Path]::GetFileName($manifest))
            }
            $consistent=$false
            [GrateWinGetIndex]::WinGetSQLiteIndexCheckConsistency($index,[ref]$consistent)
            if (!$consistent) { throw 'Native WinGet index consistency check failed.' }
            [GrateWinGetIndex]::WinGetSQLiteIndexPrepareForPackaging($index)
        } finally { if ($index -ne [IntPtr]::Zero) { [GrateWinGetIndex]::WinGetSQLiteIndexClose($index) } }
        $mapping=Join-Path $root "mapping-$($format.Major).txt"
        @('[Files]', "`"$indexPath`" `"Public\index.db`"", "`"$(Join-Path $root 'AppxManifest.xml')`" `"AppxManifest.xml`"", "`"$(Join-Path $root 'logo.png')`" `"logo.png`"") | Set-Content -LiteralPath $mapping
        $output=Join-Path $root $format.Name
        Native (Join-Path $sdkBin 'makeappx.exe') @('pack','/o','/nv','/f',$mapping,'/p',$output) "pack-$($format.Major)"
        Native (Join-Path $sdkBin 'signtool.exe') @('sign','/fd','SHA256','/sha1',$certificate.Thumbprint,'/s','My',$output) "sign-$($format.Major)"
        Native (Join-Path $sdkBin 'signtool.exe') @('verify','/pa',$output) "verify-$($format.Major)"
        $indexes+=@{IndexMajor=$format.Major; IndexMinor=$format.Minor; Package=$format.Name; PackageSha256=(Get-FileHash $output).Hash}
    }
    [GrateWinGetIndex]::WinGetLoggingTerm($indexLog)
    Import-Module Appx -UseWindowsPowerShell
    # Register the same data-only package that WinGet will use. Querying Windows
    # gives the actual family name; it is never guessed from the source name.
    Add-AppxPackage -Path (Join-Path $root 'source2.msix') -ForceApplicationShutdown
    $registered=@(Get-AppxPackage -Name Grate.Migration.CI.Source)
    if ($registered.Count -ne 1) { throw 'Expected exactly one registered CI source package.' }
    $state.SourceIdentifier=$registered[0].PackageFamilyName
    $state.PackageFullName=$registered[0].PackageFullName
    # Identification is the only reason for this temporary registration. Remove
    # it so WinGet must fetch and register the source over the tested protocol.
    Remove-AppxPackage -Package $state.PackageFullName
    @{NuGetPackage='Microsoft.WindowsPackageManager.Utils'; Version=$version; Url=$url; Sha256=$hash; NativeDllSha256=(Get-FileHash $dll).Hash; NativeDllVersion=(Get-Item $dll).VersionInfo.FileVersion; WindowsSdk=$sdk[0].Name; SourceIdentifier=$state.SourceIdentifier; SourceType=$state.SourceType; Manifests=@($manifests | ForEach-Object { @{Name=[IO.Path]::GetFileName($_); Sha256=(Get-FileHash $_).Hash} }); Indexes=$indexes} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $logs 'preindexed-provenance.json')
    $arguments=@('-u',"$PSScriptRoot/preindexed/server.py",'--root',$root,'--assets',(Resolve-Path -LiteralPath $Assets).Path,'--certificate',$certificateFile,'--private-key',$privateKeyFile,'--port',"$Port")
    $quoted=$arguments | ForEach-Object { '"'+$_.Replace('"','\"')+'"' }
    $process=Start-Process -FilePath $Python -ArgumentList $quoted -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $logs 'server.stdout.log') -RedirectStandardError (Join-Path $logs 'server.stderr.log')
    $state.Pid=$process.Id
    for ($attempt=0;$attempt -lt 10;$attempt++) {
        if ($process.HasExited) { throw "Preindexed server exited ($($process.ExitCode))." }
        try {
            $null=Invoke-WebRequest "$($state.Url)/source2.msix" -Method Head -TimeoutSec 5 -NoProxy
            return $state
        } catch {
            if ($attempt -eq 9) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
} catch {
    & "$PSScriptRoot/Stop-PreIndexedSource.ps1" -State $state
    throw
}
