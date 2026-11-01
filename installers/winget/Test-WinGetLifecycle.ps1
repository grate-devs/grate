#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)][string]$Winget,
    [Parameter(Mandatory)][string]$InventoryPath,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Installation tests require a disposable GitHub-hosted Windows runner.'
}
$inventory = Get-Content $InventoryPath -Raw | ConvertFrom-Json
$type = $inventory.InstallerType
$arch = $inventory.Architecture
$native = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if ($arch -ne $native -and !($arch -eq 'x86' -and $native -eq 'x64')) { throw 'Payload must execute natively, or x86 on the x64 runner.' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$oldId = 'erikbra.grate'
$newId = 'grate-devs.grate'
$sourceName = 'grate-migration-ci'
$sourceIdentifier = 'grate-migration-ci'
$catalogPath = Join-Path $OutputDirectory 'catalog.json'
$assetDirectory = Join-Path (Split-Path $InventoryPath) 'assets'
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$originalProcessPath = $env:Path
$state = $null
$sourceAdded = $false
$testOwnsInstallation = $false
$summary = [ordered]@{ InstallerType=$type; Architecture=$arch; SourceIdentifier=$sourceIdentifier; CommunitySourceMigrationTested=$false; GrateVersionOptionRole='database migration version, not CLI version display' }

function Run([string]$Executable, [string[]]$Arguments, [string]$Name, [switch]$Observe) {
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timeout = !$process.WaitForExit(300000)
        if ($timeout) { $process.Kill($true); $process.WaitForExit() }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        $result = [pscustomobject]@{ Executable=$Executable; Arguments=$Arguments; ExitCode=$process.ExitCode; ExitHex=('0x{0:X8}' -f ($process.ExitCode -band [long]4294967295)); TimedOut=$timeout; Output=$output }
        $output | Set-Content "$OutputDirectory/$Name.log"
        $result | Select-Object * -ExcludeProperty Output | ConvertTo-Json -Depth 8 | Set-Content "$OutputDirectory/$Name.command.json"
        if ($timeout) { throw "$Name timed out." }
        if (!$Observe -and $result.ExitCode -ne 0) { throw "$Name failed: $($result.ExitHex). See $OutputDirectory/$Name.log" }
        return $result
    } finally { $process.Dispose() }
}
function W([string[]]$Arguments, [string]$Name, [switch]$Observe) {
    $dataHash=$null
    if ($Arguments[0] -in @('install','upgrade','uninstall') -and (Test-Path $database)) { $dataHash=(Get-FileHash $database -Algorithm SHA256).Hash }
    $options=@('--disable-interactivity','--verbose-logs')
    if ($Arguments[0] -in @('install','upgrade','uninstall','show','list') -or ($Arguments[0] -eq 'source' -and $Arguments[1] -eq 'add')) { $options+='--no-proxy' }
    try { Run $Winget ($Arguments + $options) $Name -Observe:$Observe }
    finally {
        if ($dataHash -and (!(Test-Path $database) -or (Get-FileHash $database -Algorithm SHA256).Hash -ne $dataHash)) {
            throw "$Name removed or modified migration data outside the installation directory."
        }
    }
}
function Registrations {
    # Read both registry views, deduplicating shared HKCU keys by name.
    $rows = foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, $view)
        $uninstall = $hive.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall')
        try {
            if ($null -eq $uninstall) { continue }
            foreach ($name in $uninstall.GetSubKeyNames()) {
                $entry = $uninstall.OpenSubKey($name)
                try {
                    if ($entry.GetValue('DisplayName') -eq 'grate' -or $entry.GetValue('WinGetPackageIdentifier') -in @($oldId,$newId)) {
                        [pscustomobject]@{ KeyName=$name; DisplayName=$entry.GetValue('DisplayName'); DisplayVersion=$entry.GetValue('DisplayVersion'); Publisher=$entry.GetValue('Publisher'); InstallLocation=$entry.GetValue('InstallLocation'); WinGetPackageIdentifier=$entry.GetValue('WinGetPackageIdentifier'); WinGetSourceIdentifier=$entry.GetValue('WinGetSourceIdentifier') }
                    }
                } finally { $entry.Dispose() }
            }
        } finally { if ($uninstall) { $uninstall.Dispose() }; $hive.Dispose() }
    }
    if ($type -eq 'wix') {
        # Per-user MSI inventory is registered through Windows Installer; it need
        # not author a conventional HKCU Uninstall key. Read the supported API.
        $msiEngine=New-Object -ComObject WindowsInstaller.Installer
        $code='{E281998A-D8A2-4926-AAA3-066EFA4B2E74}'
        try {
            $productState=[int]$msiEngine.GetType().InvokeMember('ProductState',[Reflection.BindingFlags]::GetProperty,$null,$msiEngine,@($code))
            if ($productState -eq 5) {
                $values=@{}
                foreach ($property in @('InstalledProductName','Publisher','VersionString','AssignmentType')) {
                    $values[$property]=$msiEngine.GetType().InvokeMember('ProductInfo',[Reflection.BindingFlags]::GetProperty,$null,$msiEngine,@($code,$property))
                }
                if ([int]$values.AssignmentType -ne 0) { throw 'Expected a per-user MSI registration.' }
                $rows=@($rows)+[pscustomobject]@{KeyName=$code; DisplayName=$values.InstalledProductName; DisplayVersion=$values.VersionString; Publisher=$values.Publisher; InstallLocation="$env:LOCALAPPDATA/erikbra/grate"; WinGetPackageIdentifier=$null; WinGetSourceIdentifier=$null; Context='WindowsInstaller per-user'}
            } elseif ($productState -ne -1) { throw "Unexpected pre-existing MSI state $productState." }
        } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($msiEngine) }
    }
    @($rows | Group-Object KeyName | ForEach-Object { $_.Group[0] })
}
function Snapshot([string]$Name) {
    @(Registrations) | ConvertTo-Json -Depth 6 | Set-Content "$OutputDirectory/$Name.arp.json"
    foreach ($id in @($oldId,$newId)) { $null = W @('list','--id',$id,'--exact','--source',$sourceName,'--accept-source-agreements') "$Name-list-$id" -Observe }
    $null = W @('export','--output',"$OutputDirectory/$Name.export.json",'--source',$sourceName,'--accept-source-agreements') "$Name-export" -Observe
    $env:Path = $originalProcessPath + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    @(Get-Command grate -All -ErrorAction SilentlyContinue | Select-Object Source,CommandType) | ConvertTo-Json | Set-Content "$OutputDirectory/$Name.commands.json"
    $null = Run 'where.exe' @('grate') "$Name-where" -Observe
}
function Package([string]$Id, [object[]]$Versions) {
    $entries = foreach ($version in $Versions) {
        $extension = if ($type -eq 'zip') { 'zip' } else { 'msi' }
        $installer = [ordered]@{
            Architecture=$arch; InstallerType=$type; Scope='user'
            InstallerUrl="https://127.0.0.1:8765/assets/grate-$($version.Version).$extension"
            InstallerSha256=$(if ($type -eq 'zip') { $version.ZipHash } else { $version.MsiHash })
        }
        if ($type -eq 'zip') {
            $installer.NestedInstallerType='portable'
            $installer.NestedInstallerFiles=@(@{RelativeFilePath='grate.exe'; PortableCommandAlias='grate'})
        } else {
            $meta=$version.MsiMetadata
            $installer.ProductCode=$meta.ProductCode
            $installer.AppsAndFeaturesEntries=@(@{DisplayName=$meta.ProductName; Publisher=$meta.Manufacturer; DisplayVersion=$meta.ProductVersion; ProductCode=$meta.ProductCode; UpgradeCode=$meta.UpgradeCode})
            $installer.InstallationMetadata=@{DefaultInstallLocation='%LocalAppData%/erikbra/grate'}
        }
        @{ PackageVersion=$version.Version; DefaultLocale=@{PackageLocale='en-US'; Publisher=$(if ($Id -eq $oldId) {'erikbra'} else {'grate-devs'}); PackageName='grate'; License='MIT'; ShortDescription='grate migration lifecycle test'}; Installers=@($installer) }
    }
    @{PackageIdentifier=$Id; Versions=@($entries)}
}
function Write-Catalog([switch]$Both) {
    $packages = @(Package $oldId @($inventory.Versions | Where-Object Version -ne '2.1.7'))
    if ($Both) { $packages += Package $newId @($inventory.Versions | Where-Object Version -eq '2.1.7') }
    @{SourceIdentifier=$sourceIdentifier; Packages=$packages} | ConvertTo-Json -Depth 15 | Set-Content "$catalogPath.tmp"
    [IO.File]::Move("$catalogPath.tmp", $catalogPath, $true)
}
function Installed-Executable {
    if ($type -eq 'wix') { return (Join-Path $env:LOCALAPPDATA 'erikbra/grate/grate.exe') }
    return (Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Links/grate.exe')
}
function Assert-Installed([string]$Version, [string]$Id) {
    $rows = @(Registrations)
    if ($rows.Count -ne 1 -or $rows[0].DisplayVersion -ne $Version) { throw "Expected one $Version ARP registration: $($rows | ConvertTo-Json -Compress)" }
    if ($type -eq 'zip' -and ($rows[0].WinGetPackageIdentifier -ne $Id -or $rows[0].WinGetSourceIdentifier -ne $sourceIdentifier)) { throw 'Portable ID/source registration did not match the requested source package.' }
    $expected = $inventory.Versions | Where-Object Version -eq $Version
    $exe = Installed-Executable
    if (!(Test-Path $exe) -or (Get-FileHash $exe -Algorithm SHA256).Hash -ne (Get-FileHash $expected.Executable -Algorithm SHA256).Hash) { throw "Installed payload is not $Version." }
    # grate's --version option is a database migration version, including on
    # current main. Keep the historical probe as evidence, not a version oracle.
    $null = Run $exe @('--version') "installed-$Version-version" -Observe
    $null = Run $exe @('--help') "installed-$Version-help"
    $fileVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    $actualVersion=[version]::new($fileVersion.FileMajorPart,$fileVersion.FileMinorPart,$fileVersion.FileBuildPart)
    if ($actualVersion -ne [version]$Version) { throw "Installed file version $actualVersion does not match $Version." }
    $env:Path = $originalProcessPath + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    $commands = @(Get-Command grate -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique)
    if ($commands.Count -ne 1 -or (Get-FileHash $commands[0] -Algorithm SHA256).Hash -ne (Get-FileHash $expected.Executable -Algorithm SHA256).Hash) { throw 'PATH does not resolve exactly one expected grate payload.' }
}
function Assert-Absent {
    if (@(Registrations).Count -ne 0 -or (Test-Path (Installed-Executable))) { throw 'Uninstall left grate registration or payload.' }
    if (@(Get-Command grate -All -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Uninstall left an executable on PATH.' }
}
function Assert-KnownRejection($Result) {
    $known = @('0x8A150014','0x8A150016','0x8A15002B','0x8A150061','0x8A15010D')
    if ($Result.ExitHex -in $known) { return }
    if ($Result.ExitHex -in @('0x8A150006','0x8A150049') -and $Result.Output -match '1638') { return }
    throw "Unexpected failure must not be counted as a migration result: $($Result.ExitHex) $($Result.Output)"
}
function Uninstall([string]$Id,[string]$Name) {
    $attempt = W @('uninstall','--id',$Id,'--exact','--source',$sourceName,'--silent','--accept-source-agreements') $Name -Observe
    if ($attempt.ExitCode -ne 0) {
        Assert-KnownRejection $attempt
        $rows=@(Registrations)
        if ($rows.Count -ne 1) { throw 'Cannot select an unambiguous installed product for fallback uninstall.' }
        $null = W @('uninstall','--product-code',$rows[0].KeyName,'--silent','--accept-source-agreements') "$Name-by-product-code"
    }
    Assert-Absent
    $attempt.ExitHex
}
function Migrate([string]$Name) {
    $exe=Installed-Executable
    foreach ($attempt in 1..2) {
        $null=Run $exe @('--databasetype','sqlite','--connectionstring',"Data Source=$database",'--files',$sql,'--output',"$OutputDirectory/migration-output",'--silent') "$Name-migrate-$attempt"
    }
}

if (@(Registrations).Count -ne 0 -or (Get-Command grate -ErrorAction SilentlyContinue) -or (Test-Path "$env:LOCALAPPDATA/erikbra/grate")) { throw 'Refusing to replace a pre-existing grate installation.' }
$sql=Join-Path $OutputDirectory 'user-data/sql'
$database=Join-Path $OutputDirectory 'user-data/migration.db'
New-Item -ItemType Directory -Force "$sql/up","$sql/afterMigration" | Out-Null
'CREATE TABLE lifecycle_data(id INTEGER PRIMARY KEY); INSERT INTO lifecycle_data VALUES(42);' | Set-Content "$sql/up/001_create.sql"
"CREATE TEMP TABLE lifecycle_assert(value INTEGER CHECK(value=1)); INSERT INTO lifecycle_assert SELECT CASE WHEN COUNT(*)=1 AND MIN(id)=42 THEN 1 ELSE 0 END FROM lifecycle_data; INSERT INTO lifecycle_assert SELECT CASE WHEN COUNT(*)=1 THEN 1 ELSE 0 END FROM grate_ScriptsRun WHERE script_name='001_create.sql'; INSERT INTO lifecycle_assert SELECT CASE WHEN COUNT(*)=0 THEN 1 ELSE 0 END FROM grate_ScriptsRunErrors;" | Set-Content "$sql/afterMigration/900_assert.sql"
try {
    $summary.WinGetVersion=(Run $Winget @('--version') 'winget-version').Output.Trim()
    # Remove unrelated catalogs only inside the disposable VM. Source identity
    # stays constant throughout the single-ID and simultaneous-ID phases below.
    $null=W @('source','export') 'original-sources'
    foreach ($name in @('msstore','winget','winget-font')) { $null=W @('source','remove','--name',$name) "remove-source-$name" -Observe }
    Write-Catalog
    $state=& "$PSScriptRoot/test-source/Start-TestSource.ps1" -Catalog $catalogPath -Assets $assetDirectory -LogDirectory "$OutputDirectory/server"
    $null=W @('source','add','--name',$sourceName,'--arg',$state.Url,'--type','Microsoft.Rest','--accept-source-agreements') 'add-source'
    $sourceAdded=$true
    $null=W @('source','list','--name',$sourceName) 'source-details'
    $testOwnsInstallation=$true
    $common=@('--source',$sourceName,'--exact','--scope','user','--architecture',$arch,'--installer-type',$type,'--silent','--accept-package-agreements','--accept-source-agreements')
    $null=W (@('install','--id',$oldId,'--version','2.0.0')+$common) 'old-install'
    Assert-Installed '2.0.0' $oldId
    Migrate 'old'
    Snapshot 'old-installed'
    $upgrade=W (@('upgrade','--id',$oldId,'--version','2.1.6')+$common) 'same-id-upgrade' -Observe
    $summary.SameIdDefaultUpgrade=$upgrade.ExitHex
    if ($upgrade.ExitCode -ne 0) {
        Assert-KnownRejection $upgrade
        if ($type -eq 'zip') { throw 'Same-ID portable upgrade must succeed.' }
        Assert-Installed '2.0.0' $oldId
        $null=W (@('upgrade','--id',$oldId,'--version','2.1.6','--uninstall-previous')+$common) 'same-id-uninstall-previous'
        $summary.SameIdUninstallPrevious='Passed'
    }
    Assert-Installed '2.1.6' $oldId
    Migrate 'same-id-upgraded'
    Write-Catalog -Both
    foreach ($id in @($oldId,$newId)) { $null=W @('show','--id',$id,'--exact','--source',$sourceName,'--accept-source-agreements') "both-visible-$id" }
    Snapshot 'both-visible'
    $transition=W (@('upgrade','--id',$newId,'--version','2.1.7')+$common) 'new-id-upgrade-attempt' -Observe
    $summary.NewIdUpgradeExit=$transition.ExitHex
    if ($transition.ExitCode -eq 0) {
        Assert-Installed '2.1.7' $newId
        $summary.NewIdPayloadUpgrade='Passed'
        Snapshot 'after-direct-transition'
        $summary.ResetUninstall=Uninstall $newId 'reset-new-id'
        Write-Catalog
        $null=W (@('install','--id',$oldId,'--version','2.1.6')+$common) 'reset-old-id'
        Write-Catalog -Both
    } else {
        Assert-KnownRejection $transition
        Assert-Installed '2.1.6' $oldId
        $summary.NewIdPayloadUpgrade='Rejected; old payload and registration preserved'
        Snapshot 'after-direct-transition'
    }
    $dataHash=(Get-FileHash $database -Algorithm SHA256).Hash
    $summary.FallbackOldUninstall=Uninstall $oldId 'fallback-old-uninstall'
    if ((Get-FileHash $database -Algorithm SHA256).Hash -ne $dataHash) { throw 'Uninstall modified migration data outside the installation directory.' }
    $null=W (@('install','--id',$newId,'--version','2.1.7')+$common) 'fallback-new-install'
    Assert-Installed '2.1.7' $newId
    Migrate 'fallback-new-id'
    Snapshot 'new-id-installed'
    $summary.NewIdListExit=(W @('list','--id',$newId,'--exact','--source',$sourceName,'--accept-source-agreements') 'new-id-correlation' -Observe).ExitHex
    $dataHash=(Get-FileHash $database -Algorithm SHA256).Hash
    $summary.FinalUninstall=Uninstall $newId 'final-new-uninstall'
    if ((Get-FileHash $database -Algorithm SHA256).Hash -ne $dataHash) { throw 'Final uninstall modified migration data.' }
    $summary.FallbackPayloadAndData='Passed'
    $summary.Completed=$true
    Write-Host "PASS: actual $type $arch install/upgrade and both-ID transition characterization. See summary.json for automatic-transition/correlation limitations."
} finally {
    try {
        if ($testOwnsInstallation) {
            foreach ($row in @(Registrations)) { $null=W @('uninstall','--product-code',$row.KeyName,'--silent','--accept-source-agreements') 'cleanup-uninstall' }
            Assert-Absent
        }
    } finally {
        $summary | ConvertTo-Json -Depth 8 | Set-Content "$OutputDirectory/summary.json"
        try {
            if ($sourceAdded) { $null=W @('source','remove','--name',$sourceName) 'remove-test-source' }
        } finally {
            try { if ($state) { & "$PSScriptRoot/test-source/Stop-TestSource.ps1" -State $state } }
            finally {
                try {
                    foreach ($logs in @(
                        "$env:LOCALAPPDATA/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/DiagOutputDir",
                        "$env:LOCALAPPDATA/Microsoft/WinGet/DiagOutputDir"
                    )) {
                        if (Test-Path $logs) {
                            New-Item -ItemType Directory -Force (Join-Path $OutputDirectory 'native-winget-logs') | Out-Null
                            $destination=Join-Path $OutputDirectory ('native-winget-logs/' + [guid]::NewGuid().ToString('N'))
                            Copy-Item -LiteralPath $logs -Destination $destination -Recurse -Force
                        }
                    }
                } finally {
                    [Environment]::SetEnvironmentVariable('Path',$originalUserPath,'User')
                    $env:Path=$originalProcessPath
                }
            }
        }
    }
}
