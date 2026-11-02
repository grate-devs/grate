#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory)][string]$Winget,
    [Parameter(Mandatory)][string]$InventoryPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Rest','PreIndexed')][string]$SourceType='Rest',
    [switch]$PublicBaseline
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Installation tests require a disposable GitHub-hosted Windows runner.'
}
$inventory = Get-Content $InventoryPath -Raw | ConvertFrom-Json
. "$PSScriptRoot/../msi/WinGetMsiLifecycle.Assertions.ps1"
. "$PSScriptRoot/WinGetSourceCorrelation.Assertions.ps1"
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
$script:nativeInventoryCache=$null
$script:nativeInventoryGeneration=0
$summary = [ordered]@{ InstallerType=$type; Architecture=$arch; SourceType=$SourceType; SourceIdentifier=$sourceIdentifier; CommunityOriginMigrationTested=$false; CommunityDestinationMigrationTested=$false; CommunitySourceMigrationTested=$false; GrateVersionOptionRole='database migration version, not CLI version display' }

function Run([string]$Executable, [string[]]$Arguments, [string]$Name, [switch]$Observe, [int]$TimeoutSeconds=300) {
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
        @{Executable=$Executable; Arguments=$Arguments; ProcessId=$process.Id; State='Running'; StartedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 8 | Set-Content "$OutputDirectory/$Name.command.json"
        $timeout = !$process.WaitForExit($TimeoutSeconds*1000)
        if ($timeout) {
            $process.Kill()
            if (!$process.WaitForExit(5000)) { throw "$Name did not terminate after its deadline." }
        }
        $output = $stdout.WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult() + $stderr.WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()
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
        if ($Arguments[0] -in @('install','upgrade','uninstall')) { $script:nativeInventoryCache=$null }
        if ($dataHash -and (!(Test-Path $database) -or (Get-FileHash $database -Algorithm SHA256).Hash -ne $dataHash)) {
            throw "$Name removed or modified migration data outside the installation directory."
        }
    }
}
function Native-Inventories {
    if ($null -eq $script:nativeInventoryCache) {
        $script:nativeInventoryGeneration++
        $name='native-inventory-'+$script:nativeInventoryGeneration.ToString('D4')
        $request="$OutputDirectory/$name.request.json"
        $snapshot="$OutputDirectory/$name.snapshot.json"
        @($inventory.Versions.MsiMetadata.ProductCode | Select-Object -Unique) | ConvertTo-Json | Set-Content $request
        $null=Run (Join-Path $PSHOME 'pwsh.exe') @('-NoLogo','-NoProfile','-NonInteractive','-MTA','-File',"$PSScriptRoot/../msi/Get-InstalledProductInventoryBatch.ps1",'-RequestPath',$request,'-OutputPath',$snapshot) "$name-worker" -TimeoutSeconds 30
        $script:nativeInventoryCache=@(Get-Content $snapshot -Raw | ConvertFrom-Json -AsHashtable)
    }
    $script:nativeInventoryCache
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
        foreach ($row in @(Native-Inventories)) {
            $code=$row.ProductCode
            $nativeInventory=$row.Inventory
            foreach ($instance in @($nativeInventory.Contexts)) {
                if ($instance.Context -notin @(1,2) -or $instance.UserSid -ne $nativeInventory.CurrentUserSid) { throw 'Unexpected machine or foreign-user MSI installation.' }
                $values=$instance.Properties
                $rows=@($rows)+[pscustomobject]@{KeyName=$code; DisplayName=$values['InstalledProductName'].Value; DisplayVersion=$values['VersionString'].Value; Publisher=$values['Publisher'].Value; InstallLocation="$env:LOCALAPPDATA/erikbra/grate"; WinGetPackageIdentifier=$null; WinGetSourceIdentifier=$null; Context=$instance.Context}
            }
        }
    }
    @($rows | Group-Object KeyName | ForEach-Object { $_.Group[0] })
}
function Snapshot([string]$Name) {
    @(Registrations) | ConvertTo-Json -Depth 6 | Set-Content "$OutputDirectory/$Name.arp.json"
    if ($type -eq 'wix') {
        @(Native-Inventories | ForEach-Object { $_.Inventory }) | ConvertTo-Json -Depth 12 | Set-Content "$OutputDirectory/$Name.native-msi.json"
    }
    foreach ($id in @($oldId,$newId)) { $null = W @('list','--id',$id,'--exact','--source',$sourceName,'--accept-source-agreements') "$Name-list-$id" -Observe }
    $null = W @('export','--output',"$OutputDirectory/$Name.export.json",'--source',$sourceName,'--accept-source-agreements') "$Name-export" -Observe
    $env:Path = $originalProcessPath + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    @(Get-Command grate -All -ErrorAction SilentlyContinue | Select-Object Source,CommandType) | ConvertTo-Json | Set-Content "$OutputDirectory/$Name.commands.json"
    $null = Run 'where.exe' @('grate') "$Name-where" -Observe
}
function Write-Catalog([switch]$Both,[switch]$IncludeBridge) {
    # A preindexed source is immutable for this run. Both IDs are present from
    # the start; source updates must never silently depend on REST hot reload.
    $catalog=& "$PSScriptRoot/New-LifecycleCatalog.ps1" -Inventory $inventory -Both:($Both -or $SourceType -eq 'PreIndexed' -or $PublicBaseline) -IncludeBridge:$IncludeBridge
    if ($PublicBaseline) { $catalog.Packages=@($catalog.Packages | Where-Object PackageIdentifier -eq $newId) }
    $catalog | ConvertTo-Json -Depth 15 | Set-Content "$catalogPath.tmp"
    [IO.File]::Move("$catalogPath.tmp", $catalogPath, $true)
}
function Assert-NewIdCorrelation([string]$Name) {
    Snapshot $Name
    $new=Get-Content "$OutputDirectory/$Name-list-$newId.command.json" -Raw | ConvertFrom-Json
    $old=Get-Content "$OutputDirectory/$Name-list-$oldId.command.json" -Raw | ConvertFrom-Json
    if ($new.ExitCode -ne 0 -or $old.ExitHex -ne '0x8A150014') { throw 'Both-ID catalog must correlate the installed corrected package exclusively to the new ID.' }
    $export=Get-Content "$OutputDirectory/$Name.export.json" -Raw | ConvertFrom-Json
    $ids=@($export.Sources.Packages.PackageIdentifier)
    if ($newId -notin $ids -or $oldId -in $ids) { throw 'WinGet export did not exclusively select the new package ID.' }
}
function Installed-Executable {
    if ($type -eq 'wix') { return (Join-Path $env:LOCALAPPDATA 'erikbra/grate/grate.exe') }
    return (Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Links/grate.exe')
}
function Assert-Installed([string]$Version, [string]$Id, [string]$ExpectedSourceIdentifier=$sourceIdentifier) {
    $rows = @(Registrations)
    if ($rows.Count -ne 1 -or $rows[0].DisplayVersion -ne $Version) { throw "Expected one $Version ARP registration: $($rows | ConvertTo-Json -Compress)" }
    if ($type -eq 'zip' -and ($rows[0].WinGetPackageIdentifier -ne $Id -or $rows[0].WinGetSourceIdentifier -ne $ExpectedSourceIdentifier)) { throw 'Portable ID/source registration did not match the requested source package.' }
    $expected = $inventory.Versions | Where-Object Version -eq $Version
    if ($type -eq 'wix') {
        $nativeInventory=@(Native-Inventories | Where-Object ProductCode -eq $expected.MsiMetadata.ProductCode)[0].Inventory
        Assert-WinGetMsiNativeContext -Inventory $nativeInventory -ExpectedVersion $Version -ExpectedPublisher $expected.MsiMetadata.Manufacturer
        if ($rows[0].Publisher -ne $expected.MsiMetadata.Manufacturer -or $rows[0].KeyName -ne $expected.MsiMetadata.ProductCode) { throw 'The installed MSI identity does not match the requested version.' }
        $directory=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'erikbra/grate')).TrimEnd('\','/')
        $pathEntries=@([Environment]::GetEnvironmentVariable('Path','User').Split(';') | Where-Object {
            $_.Trim() -and [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($_.Trim())).TrimEnd('\','/') -ieq $directory
        })
        if ($pathEntries.Count -ne 1) { throw 'The MSI installation directory must appear exactly once on the user PATH.' }
    }
    $exe = Installed-Executable
    if (!(Test-Path $exe) -or (Get-FileHash $exe -Algorithm SHA256).Hash -ne (Get-FileHash $expected.Executable -Algorithm SHA256).Hash) { throw "Installed payload is not $Version." }
    # grate's --version option is a database migration version, including on
    # current main. Read the executable version without invoking that option.
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
    if ($type -eq 'wix' -and $Result.ExitHex -eq '0x8A150010') {
        $files=foreach ($directory in @(
            "$env:LOCALAPPDATA/Packages/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe/LocalState/DiagOutputDir",
            "$env:LOCALAPPDATA/Microsoft/WinGet/DiagOutputDir"
        )) {
            if (Test-Path $directory) { Get-ChildItem $directory -Filter 'WinGet-*.log' -File }
        }
        $latest=@($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
        if ($latest.Count -eq 1 -and (Get-Content $latest[0].FullName -Raw).Contains('Installer scope does not match currently installed scope: User != Machine')) {
            $summary.WinGetMsiScopeMismatchObserved=$true
            return
        }
        throw 'No applicable installer is only an expected MSI observation when the current native log proves the User/Machine mismatch.'
    }
    if ($Result.ExitHex -in @('0x8A150006','0x8A150049') -and $Result.Output -match '1638') { return }
    throw "Unexpected failure must not be counted as a migration result: $($Result.ExitHex) $($Result.Output)"
}
function Native-Msi([string[]]$Arguments,[string]$Name) {
    $hash=$null
    if (Test-Path $database) { $hash=(Get-FileHash $database -Algorithm SHA256).Hash }
    try { $result=Run "$env:SystemRoot/System32/msiexec.exe" ($Arguments+@('/qn','/norestart','/l*v',"$OutputDirectory/$Name.msi.log")) $Name -Observe }
    finally { $script:nativeInventoryCache=$null }
    if ($result.ExitCode -notin @(0,3010)) { throw "$Name failed with MSI code $($result.ExitCode)." }
    if ($hash -and (!(Test-Path $database) -or (Get-FileHash $database -Algorithm SHA256).Hash -ne $hash)) { throw 'Native MSI fallback modified migration data.' }
}
function Uninstall([string]$Id,[string]$Name,[string]$Source=$sourceName) {
    # Acceptance requires the correlated package to uninstall by its exact ID.
    # Product-code/native recovery is reserved for finally cleanup on failures.
    $attempt = W @('uninstall','--id',$Id,'--exact','--source',$Source,'--silent','--accept-source-agreements') $Name
    Assert-Absent
    $attempt.ExitHex
}
function Migrate([string]$Name) {
    $exe=Installed-Executable
    foreach ($attempt in 1..2) {
        $null=Run $exe @('--databasetype','sqlite','--connectionstring',"Data Source=$database",'--files',$sql,'--output',"$OutputDirectory/migration-output",'--silent') "$Name-migrate-$attempt"
    }
}
function Assert-PublicCorrelation([string]$Name,[switch]$Legacy) {
    $queries=@{}
    foreach ($source in @('global','winget',$sourceName)) {
        foreach ($id in @($oldId,$newId)) {
            $arguments=@('list','--id',$id,'--exact','--accept-source-agreements')
            if ($source -ne 'global') { $arguments+=@('--source',$source) }
            $result=W $arguments "$Name-$source-$id" -Observe
            $queries["$source/$id"]=$result.ExitHex
        }
    }
    $exportPath="$OutputDirectory/$Name.global-export.json"
    $null=W @('export','--output',$exportPath,'--accept-source-agreements') "$Name-global-export"
    $export=Get-Content $exportPath -Raw | ConvertFrom-Json
    Assert-WinGetSourceCorrelation -Queries $queries -Export $export -Legacy:$Legacy -PublicSourceIdentifier $publicSource.Identifier -CandidateSourceIdentifier $sourceIdentifier -CandidateSourceName $sourceName
    $sourceExport=W @('source','export','--name','winget') "$Name-public-source"
    $current=$sourceExport.Output.Trim() | ConvertFrom-Json
    foreach ($field in @('Arg','Type','Identifier','Data')) {
        if ($current.$field -cne $publicSource.$field) { throw "Public source $field changed during migration." }
    }
    Snapshot $Name
}

if (@(Registrations).Count -ne 0 -or (Get-Command grate -ErrorAction SilentlyContinue) -or (Test-Path "$env:LOCALAPPDATA/erikbra/grate")) { throw 'Refusing to replace a pre-existing grate installation.' }
$sql=Join-Path $OutputDirectory 'user-data/sql'
$database=Join-Path $OutputDirectory 'user-data/migration.db'
New-Item -ItemType Directory -Force "$sql/up","$sql/afterMigration" | Out-Null
'CREATE TABLE lifecycle_data(id INTEGER PRIMARY KEY); INSERT INTO lifecycle_data VALUES(42);' | Set-Content "$sql/up/001_create.sql"
"CREATE TEMP TABLE lifecycle_assert(value INTEGER CHECK(value=1)); INSERT INTO lifecycle_assert SELECT CASE WHEN COUNT(*)=1 AND MIN(id)=42 THEN 1 ELSE 0 END FROM lifecycle_data; INSERT INTO lifecycle_assert SELECT CASE WHEN COUNT(*)=1 THEN 1 ELSE 0 END FROM grate_ScriptsRun WHERE script_name='001_create.sql'; INSERT INTO lifecycle_assert SELECT CASE WHEN COUNT(*)=0 THEN 1 ELSE 0 END FROM grate_ScriptsRunErrors;" | Set-Content "$sql/afterMigration/900_assert.sql"
try {
    $summary.WinGetVersion=(Run $Winget @('--version') 'winget-version').Output.Trim()
    # The public-origin case preserves its source and tracking without resets.
    $null=W @('source','export') 'original-sources'
    $removeSources=if ($PublicBaseline) { @('msstore','winget-font') } else { @('msstore','winget','winget-font') }
    foreach ($name in $removeSources) { $null=W @('source','remove','--name',$name) "remove-source-$name" -Observe }
    if ($PublicBaseline) {
        $publicSource=(W @('source','export','--name','winget') 'public-source-before').Output.Trim() | ConvertFrom-Json
        if ($publicSource.Name -ne 'winget' -or $publicSource.Type -ne 'Microsoft.PreIndexed.Package' -or $publicSource.Arg -ne 'https://cdn.winget.microsoft.com/cache' -or !$publicSource.Identifier) { throw 'Public baseline requires the genuine default winget source.' }
        $summary.PublicSource=$publicSource
        $null=W @('source','update','--name','winget') 'public-source-update'
        $null=W @('show','--id',$oldId,'--exact','--version','2.0.0','--source','winget','--architecture',$arch,'--installer-type',$type,'--accept-source-agreements') 'public-baseline-manifest'
        $testOwnsInstallation=$true
        $null=W @('install','--id',$oldId,'--exact','--version','2.0.0','--source','winget','--architecture',$arch,'--installer-type',$type,'--scope','user','--silent','--accept-source-agreements','--accept-package-agreements') 'public-baseline-install'
        Assert-Installed '2.0.0' $oldId $publicSource.Identifier
        Migrate 'public-baseline'
        $null=W @('export','--output',"$OutputDirectory/public-baseline-before-candidate.export.json",'--accept-source-agreements') 'public-baseline-before-candidate-export'
        $beforeCandidate=Get-Content "$OutputDirectory/public-baseline-before-candidate.export.json" -Raw | ConvertFrom-Json
        Assert-WinGetExportIdentity -Export $beforeCandidate -ExpectedId $oldId -ExpectedSourceIdentifier $publicSource.Identifier
    }
    Write-Catalog
    $startScript=if ($SourceType -eq 'PreIndexed') { 'Start-PreIndexedSource.ps1' } else { 'Start-TestSource.ps1' }
    $state=& "$PSScriptRoot/test-source/$startScript" -Catalog $catalogPath -Assets $assetDirectory -LogDirectory "$OutputDirectory/server"
    $sourceIdentifier=$state.SourceIdentifier
    $summary.SourceIdentifier=$sourceIdentifier
    $nativeSourceType=if ($SourceType -eq 'PreIndexed') { 'Microsoft.PreIndexed.Package' } else { 'Microsoft.Rest' }
    $null=W @('source','add','--name',$sourceName,'--arg',$state.Url,'--type',$nativeSourceType,'--accept-source-agreements') 'add-source'
    $sourceAdded=$true
    $null=W @('source','list','--name',$sourceName) 'source-details'
    $candidateSource=(W @('source','export','--name',$sourceName) 'candidate-source-export').Output.Trim() | ConvertFrom-Json
    if ($candidateSource.Type -ne $nativeSourceType -or $candidateSource.Identifier -ne $sourceIdentifier -or $candidateSource.Arg.TrimEnd('/') -ne $state.Url.TrimEnd('/')) { throw 'Registered candidate source type, identifier or URL did not match the actual test source.' }
    $summary.CandidateSource=$candidateSource
    $testOwnsInstallation=$true
    $upgradeOptions=@('--source',$sourceName,'--exact','--silent','--accept-package-agreements','--accept-source-agreements')
    $installOptions=$upgradeOptions+@('--scope','user','--architecture',$arch,'--installer-type',$type)
    if ($PublicBaseline) {
        Assert-PublicCorrelation 'public-baseline-tracking' -Legacy
        $summary.PublicBaselineVersion='2.0.0'
        $direct=W (@('upgrade','--id',$newId,'--version','2.1.7')+$upgradeOptions) 'public-new-id-direct-upgrade' -Observe
        if ($direct.ExitHex -ne '0x8A150014') { throw "New ID unexpectedly matched the public legacy installation: $($direct.ExitHex)." }
        Assert-Installed '2.0.0' $oldId $publicSource.Identifier
        Assert-PublicCorrelation 'public-after-rejected-upgrade' -Legacy
        if ($type -eq 'zip') { $null=Uninstall $oldId 'public-old-uninstall' 'winget' }
        $replacementOptions=$upgradeOptions+@('--architecture',$arch,'--installer-type',$type)
        if ($type -eq 'zip') { $replacementOptions+=@('--scope','user') }
        $null=W (@('install','--id',$newId,'--version','2.1.7')+$replacementOptions) 'public-new-id-replacement-install'
        Assert-Installed '2.1.7' $newId
        Assert-PublicCorrelation 'public-after-replacement'
        Migrate 'public-after-replacement'
        $null=W (@('upgrade','--id',$newId,'--version','2.1.8')+$upgradeOptions) 'public-new-id-next-upgrade'
        Assert-Installed '2.1.8' $newId
        Assert-PublicCorrelation 'public-after-next'
        Migrate 'public-after-next'
        $null=Uninstall $newId 'public-final-new-uninstall'
        $summary.CommunityOriginMigrationTested=$true
        $summary.ExclusiveWinGetNewIdCorrelationVerified=$true
        $summary.PublicTrackingPreserved=$true
        $summary.NewIdNextVersionUpgrade='Passed'
        $summary.Completed=$true
        Write-Host "PASS: actual public-source $type $arch baseline, preserved tracking, private-$SourceType transition, exclusive multi-source correlation, next upgrade and strict uninstall."
    } elseif ($type -eq 'wix') {
        Write-Catalog -Both
        $summary.LegacyUpgrades=@()
        foreach ($legacy in @('2.0.0','2.1.6')) {
            $name="legacy-$legacy"
            $null=W (@('install','--id',$oldId,'--version',$legacy)+$installOptions) "$name-install"
            Assert-Installed $legacy $oldId
            Migrate "$name-before"
            Snapshot "$name-before"
            # New ID has no historic aliases: its direct upgrade must leave the
            # old package intact. The publisher bridge is reached via old ID.
            $direct=W (@('upgrade','--id',$newId,'--version','2.1.7')+$upgradeOptions) "$name-new-id-direct" -Observe
            if ($direct.ExitHex -ne '0x8A150014') { throw "New ID unexpectedly matched a legacy MSI: $($direct.ExitHex)." }
            Assert-Installed $legacy $oldId
            # Install the new identity directly. Its MSI transaction detects
            # and upgrades the legacy product; WinGet records the new ARP codes
            # under the new ID, so it never contaminates the old tracking record.
            $null=W (@('install','--id',$newId,'--version','2.1.7')+$upgradeOptions+@('--architecture',$arch,'--installer-type',$type)) "$name-new-id-replacement-install"
            Assert-Installed '2.1.7' $newId
            Assert-NewIdCorrelation "$name-after-replacement"
            Migrate "$name-after-replacement"
            $null=W (@('upgrade','--id',$newId,'--version','2.1.8')+$upgradeOptions) "$name-next-upgrade"
            Assert-Installed '2.1.8' $newId
            Assert-NewIdCorrelation "$name-after-next"
            Migrate "$name-after-next"
            $null=Uninstall $newId "$name-uninstall"
            $summary.LegacyUpgrades+=@{From=$legacy; NewIdentityVersion='2.1.7'; Next='2.1.8'; WinGetReplacementInstall='Passed'; PreviousProductRemoved=$true; ExplicitNewIdTransitionVerified=$true; ExclusiveNewId=$true; DataPreserved=$true}
        }
        # Probe the explicit scope selector separately. Some clients reject
        # unspecified manifest scope; either outcome must preserve actual
        # per-user context and exclusive package identity.
        $scope=W (@('install','--id',$newId,'--version','2.1.7')+$installOptions) 'fresh-explicit-user-scope' -Observe
        $summary.ExplicitUserScopeSelector=$scope.ExitHex
        if ($scope.ExitCode -eq 0) {
            Assert-Installed '2.1.7' $newId
            Assert-NewIdCorrelation 'fresh-explicit-user-scope'
            $null=Uninstall $newId 'fresh-explicit-user-scope-uninstall'
        } elseif ($scope.ExitHex -eq '0x8A150010') { Assert-Absent }
        else { throw "Unexpected explicit-scope result $($scope.ExitHex)." }
        $null=W (@('install','--id',$newId,'--version','2.1.7')+$upgradeOptions+@('--architecture',$arch,'--installer-type',$type)) 'fresh-new-id-install'
        Assert-Installed '2.1.7' $newId
        Assert-NewIdCorrelation 'fresh-new-id'
        Migrate 'fresh-new-id'
        $null=Uninstall $newId 'fresh-new-id-uninstall'
        $summary.ExclusiveWinGetNewIdCorrelationVerified=$true
        $summary.LegacyWinGetMsiReplacementVerified=$true
        # Characterize the rejected publisher-bridge strategy only AFTER every
        # acceptance test, since this command poisons the old ID tracking with
        # the new stable family. This manifest is never a publishing output.
        if ($SourceType -eq 'Rest') {
        Write-Catalog -Both -IncludeBridge
        $null=W (@('install','--id',$oldId,'--version','2.1.6')+$installOptions) 'diagnostic-bridge-legacy-install'
        Assert-Installed '2.1.6' $oldId
        $null=W (@('upgrade','--id',$oldId,'--version','2.1.7')+$upgradeOptions) 'diagnostic-bridge-upgrade'
        Assert-Installed '2.1.7' $newId
        Snapshot 'diagnostic-bridge-after-upgrade'
        $oldBridge=Get-Content "$OutputDirectory/diagnostic-bridge-after-upgrade-list-$oldId.command.json" -Raw | ConvertFrom-Json
        $summary.RejectedBridgeStrategyOldIdStillMatches=$oldBridge.ExitCode -eq 0
        $summary.AutomaticBridgeCorrelationVerified=$false
        Migrate 'diagnostic-bridge'
        $null=Uninstall $oldId 'diagnostic-bridge-final-uninstall'
        }
        $summary.ExplicitNewIdTransitionVerified=$true
        $summary.Completed=$true
        Write-Host "PASS: $type $arch per-user MSI, both legacy MSI replacement installs, exclusive ID transition, next-version upgrade, fresh install and data preservation. Automatic tracking behavior is recorded separately."
    } else {
        $null=W (@('install','--id',$oldId,'--version','2.0.0')+$installOptions) 'old-install'
        Assert-Installed '2.0.0' $oldId
        Migrate 'old'
        Snapshot 'old-installed'
        $upgrade=W (@('upgrade','--id',$oldId,'--version','2.1.6')+$upgradeOptions) 'same-id-upgrade' -Observe
        $summary.SameIdDefaultUpgrade=$upgrade.ExitHex
        if ($upgrade.ExitCode -ne 0) { throw 'Same-ID portable upgrade must succeed.' }
        Assert-Installed '2.1.6' $oldId
        Migrate 'same-id-upgraded'
        Write-Catalog -Both
        foreach ($id in @($oldId,$newId)) { $null=W @('show','--id',$id,'--exact','--source',$sourceName,'--accept-source-agreements') "both-visible-$id" }
        Snapshot 'both-visible'
        $transition=W (@('upgrade','--id',$newId,'--version','2.1.7')+$upgradeOptions) 'new-id-upgrade-attempt' -Observe
        $summary.NewIdUpgradeExit=$transition.ExitHex
        $summary.DirectNewIdCorrelationVerified=$false
        if ($transition.ExitCode -eq 0) {
            Assert-Installed '2.1.7' $newId
            $summary.NewIdPayloadUpgrade='Passed'
            Snapshot 'after-direct-transition'
            $directNewQuery=W @('list','--id',$newId,'--exact','--source',$sourceName,'--accept-source-agreements') 'direct-new-id-correlation' -Observe
            $directOldQuery=Get-Content "$OutputDirectory/after-direct-transition-list-$oldId.command.json" -Raw | ConvertFrom-Json
            $summary.DirectNewIdCorrelationVerified=$directNewQuery.ExitCode -eq 0 -and $directOldQuery.ExitHex -eq '0x8A150014'
            $summary.ResetUninstall=Uninstall $newId 'reset-new-id'
            Write-Catalog
            $null=W (@('install','--id',$oldId,'--version','2.1.6')+$installOptions) 'reset-old-id'
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
        $null=W (@('install','--id',$newId,'--version','2.1.7')+$installOptions) 'fallback-new-install'
        Assert-Installed '2.1.7' $newId
        Migrate 'fallback-new-id'
        Snapshot 'new-id-installed'
        $summary.NewIdListExit=(W @('list','--id',$newId,'--exact','--source',$sourceName,'--accept-source-agreements') 'new-id-correlation' -Observe).ExitHex
        $summary.WinGetNewIdExactQuerySucceeded=$summary.NewIdListExit -eq '0x00000000'
        $oldQuery=Get-Content "$OutputDirectory/new-id-installed-list-$oldId.command.json" -Raw | ConvertFrom-Json
        $summary.OldIdAlsoMatchesAfterFallback=$oldQuery.ExitCode -eq 0
        $summary.ExclusiveWinGetNewIdCorrelationVerified=$summary.WinGetNewIdExactQuerySucceeded -and $oldQuery.ExitHex -eq '0x8A150014'
        if (!$summary.ExclusiveWinGetNewIdCorrelationVerified) { throw 'Portable new ID must correlate exclusively after the explicit transition.' }
        $summary.AutomaticWinGetMigrationVerified=$transition.ExitCode -eq 0 -and $summary.DirectNewIdCorrelationVerified
        $null=W (@('upgrade','--id',$newId,'--version','2.1.8')+$upgradeOptions) 'new-id-next-upgrade'
        Assert-Installed '2.1.8' $newId
        Assert-NewIdCorrelation 'new-id-next'
        Migrate 'new-id-next'
        $summary.NewIdNextVersionUpgrade='Passed'
        $dataHash=(Get-FileHash $database -Algorithm SHA256).Hash
        $summary.FinalUninstall=Uninstall $newId 'final-new-uninstall'
        if ((Get-FileHash $database -Algorithm SHA256).Hash -ne $dataHash) { throw 'Final uninstall modified migration data.' }
        $summary.FallbackPayloadAndData='Passed'
        $summary.Completed=$true
        Write-Host "PASS: actual $type $arch install/upgrade and both-ID transition characterization. See summary.json for automatic-transition/correlation limitations."
    }
} finally {
    try {
        if ($testOwnsInstallation) {
            foreach ($row in @(Registrations)) {
                $cleanup=W @('uninstall','--product-code',$row.KeyName,'--silent','--accept-source-agreements') 'cleanup-uninstall' -Observe
                if ($cleanup.ExitCode -ne 0) {
                    if ($type -ne 'wix' -or $cleanup.ExitHex -ne '0x8A150014') { throw 'Cleanup uninstall failed unexpectedly.' }
                    Native-Msi @('/x',$row.KeyName) 'cleanup-native-msi-uninstall'
                }
            }
            Assert-Absent
        }
    } finally {
        $summary | ConvertTo-Json -Depth 8 | Set-Content "$OutputDirectory/summary.json"
        try {
            if ($sourceAdded) { $null=W @('source','remove','--name',$sourceName) 'remove-test-source' }
        } finally {
            try {
                if ($state) {
                    $stopScript=if ($SourceType -eq 'PreIndexed') { 'Stop-PreIndexedSource.ps1' } else { 'Stop-TestSource.ps1' }
                    & "$PSScriptRoot/test-source/$stopScript" -State $state
                }
            }
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
