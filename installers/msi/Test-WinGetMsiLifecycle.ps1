#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory=$true)] [string[]]$HistoricalMsiPaths,
    [Parameter(Mandatory=$true)] [string[]]$HistoricalExecutablePaths,
    [Parameter(Mandatory=$true)] [string]$CandidateMsiPath,
    [Parameter(Mandatory=$true)] [string]$CandidateExecutable,
    [Parameter(Mandatory=$true)] [ValidateSet('x64', 'arm64')] [string]$Architecture,
    [Parameter(Mandatory=$true)] [string]$OutputDirectory,
    [string]$NextMsiPath,
    [string]$NextExecutable,
    [string]$RollbackMsiPath,
    [string]$OtherArchitectureMsiPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'WinGetMsiLifecycle.Assertions.ps1')
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') { throw 'MSI lifecycle verification requires a disposable GitHub-hosted Windows runner.' }
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant() -ne $Architecture) { throw "MSI lifecycle verification requires native Windows $Architecture." }
if (!$HistoricalMsiPaths.Count -or $HistoricalMsiPaths.Count -ne $HistoricalExecutablePaths.Count) { throw 'Supply matching historical MSI and release ZIP executable paths.' }
if ([bool]$NextMsiPath -ne [bool]$NextExecutable) { throw 'Supply both NextMsiPath and NextExecutable.' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ((Test-Path $OutputDirectory) -and @(Get-ChildItem $OutputDirectory -Force).Count) { throw 'The evidence directory must be new or empty.' }
$reader = Join-Path $PSScriptRoot 'Get-InstallerMetadata.ps1'
$inventoryReader = Join-Path $PSScriptRoot 'Get-InstalledProductInventory.ps1'
$contract = Get-Content (Join-Path $PSScriptRoot 'identity-contract.json') -Raw | ConvertFrom-Json
$legacyCode = $contract.LegacyProductCode
$CandidateMsiPath = (Resolve-Path $CandidateMsiPath).Path
$CandidateExecutable = (Resolve-Path $CandidateExecutable).Path
$candidate = & $reader -MsiPath $CandidateMsiPath
$identity = & (Join-Path $PSScriptRoot 'Get-InstallerIdentity.ps1') -Version $candidate.ProductVersion -Architecture $Architecture
foreach ($name in @('ProductCode', 'UpgradeCode', 'ProductName', 'Manufacturer')) {
    if ($candidate.$name -ne $identity.$name) { throw "Unexpected candidate $name." }
}
if ($candidate.Platform -ne $Architecture -or $candidate.AllUsers -or $candidate.MsiInstallPerUser) { throw 'Candidate platform/per-user context changed.' }
Assert-WinGetMsiPayloadArchitecture $CandidateExecutable $Architecture
$history = @()
for ($index = 0; $index -lt $HistoricalMsiPaths.Count; $index++) {
    $msi = (Resolve-Path $HistoricalMsiPaths[$index]).Path
    $exe = (Resolve-Path $HistoricalExecutablePaths[$index]).Path
    $metadata = & $reader -MsiPath $msi
    $allowedPlatforms = if ($Architecture -eq 'arm64') { @('arm64', 'x64') } else { @('x64') }
    if ($metadata.ProductCode -ne $legacyCode -or $metadata.Manufacturer -ne 'erikbra' -or $metadata.ProductName -ne 'grate' -or $metadata.Platform -notin $allowedPlatforms -or $metadata.AllUsers -or $metadata.MsiInstallPerUser) { throw 'Unexpected historical MSI identity/platform/context.' }
    if ([version]$candidate.ProductVersion -le [version]$metadata.ProductVersion) { throw 'Candidate must be newer than the historical MSI.' }
    Assert-WinGetMsiPayloadArchitecture $exe $Architecture
    $history += [pscustomobject]@{ Msi = $msi; Executable = $exe; Metadata = $metadata }
}
$next = $null
if ($NextMsiPath) {
    $NextMsiPath = (Resolve-Path $NextMsiPath).Path
    $NextExecutable = (Resolve-Path $NextExecutable).Path
    $next = & $reader -MsiPath $NextMsiPath
    $nextIdentity = & (Join-Path $PSScriptRoot 'Get-InstallerIdentity.ps1') -Version $next.ProductVersion -Architecture $Architecture
    if ($next.ProductCode -ne $nextIdentity.ProductCode -or $next.UpgradeCode -ne $candidate.UpgradeCode -or $next.ProductCode -eq $candidate.ProductCode -or $next.Manufacturer -ne $candidate.Manufacturer -or $next.Platform -ne $Architecture -or [version]$next.ProductVersion -le [version]$candidate.ProductVersion) { throw 'Next MSI must be a newer product in the same stable architecture family.' }
    Assert-WinGetMsiPayloadArchitecture $NextExecutable $Architecture
}
$rollback = $null
if ($RollbackMsiPath) {
    $RollbackMsiPath = (Resolve-Path $RollbackMsiPath).Path
    $rollback = & $reader -MsiPath $RollbackMsiPath
    if ($rollback.ProductCode -ne $candidate.ProductCode -or $rollback.UpgradeCode -ne $candidate.UpgradeCode -or $rollback.ProductVersion -ne $candidate.ProductVersion -or $rollback.PackageCode -eq $candidate.PackageCode) { throw 'Rollback variant must target the candidate product with a separate PackageCode.' }
}
$other = $null
if ($OtherArchitectureMsiPath) {
    $OtherArchitectureMsiPath = (Resolve-Path $OtherArchitectureMsiPath).Path
    $other = & $reader -MsiPath $OtherArchitectureMsiPath
    $otherArchitecture = if ($Architecture -eq 'arm64') { 'x64' } else { 'arm64' }
    $otherIdentity = & (Join-Path $PSScriptRoot 'Get-InstallerIdentity.ps1') -Version $other.ProductVersion -Architecture $otherArchitecture
    if ($other.ProductCode -ne $otherIdentity.ProductCode -or $other.UpgradeCode -ne $otherIdentity.UpgradeCode -or $other.Platform -ne $otherArchitecture) { throw 'Other-architecture candidate has unexpected identity/platform.' }
}
$knownCodes = @(@($legacyCode, $candidate.ProductCode) + @($next, $other | Where-Object { $null -ne $_ } | ForEach-Object ProductCode) | Select-Object -Unique)
$installDirectory = Join-Path $env:LOCALAPPDATA 'erikbra/grate'
$installedExe = Join-Path $installDirectory 'grate.exe'
$companyDirectory = Split-Path $installDirectory
$marker = 'HKCU:\Software\Microsoft\erikbra\grate'
$caseDirectory = $OutputDirectory
$protectedFiles = @{}
$results = [Collections.Generic.List[object]]::new()
$failures = [Collections.Generic.List[Exception]]::new()
$installationAttempted = $false
$unrelatedFile = $null
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$companyAlreadyExisted = Test-Path $companyDirectory
function Invoke-InstallerMember([string]$Name, [Reflection.BindingFlags]$Flags, [object[]]$Arguments) {
    # Do not retain an apartment-bound Windows Installer object while blocking
    # on msiexec. Windows message broadcasts and COM can require STA dispatch.
    # This bounds COM ownership to an inventory query; it does not establish the
    # cause of a particular runner hang. Keep entry/exit evidence for diagnosis.
    # https://learn.microsoft.com/windows/win32/sync/wait-functions
    $installer = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    if (Test-Path -LiteralPath $OutputDirectory) {
        @{ phase = 'InventoryQueryStart'; member = $Name; arguments = $Arguments; utc = [DateTime]::UtcNow.ToString('o'); apartment = [Threading.Thread]::CurrentThread.GetApartmentState().ToString() } |
            ConvertTo-Json -Depth 4 -Compress | Add-Content -LiteralPath (Join-Path $OutputDirectory 'inventory-calls.log')
    }
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $installer.GetType().InvokeMember($Name, $Flags, $null, $installer, $Arguments)
    } finally {
        if ($null -ne $installer) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }
        if (Test-Path -LiteralPath $OutputDirectory) {
            @{ phase = 'InventoryQueryReleased'; member = $Name; utc = [DateTime]::UtcNow.ToString('o'); elapsedMilliseconds = $watch.ElapsedMilliseconds } |
                ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $OutputDirectory 'inventory-calls.log')
        }
    }
}
function Product-State([string]$Code) { [int](Invoke-InstallerMember 'ProductState' GetProperty @($Code)) }
function Product-Info([string]$Code, [string]$Name) { Invoke-InstallerMember 'ProductInfo' GetProperty @($Code, $Name) }
foreach ($code in $knownCodes) {
    $existing = & $inventoryReader -ProductCode $code
    if (@($existing.Contexts).Count -or @($existing.RegistryEntries).Count) { throw 'Refusing to replace a pre-existing MSI registration.' }
}
if ((Test-Path $installDirectory) -or (Test-Path $marker)) { throw 'Refusing to replace a pre-existing grate directory or marker.' }
function Run-Process([string]$Executable, [string[]]$Arguments, [string]$Name, [int[]]$AllowedExitCodes = @(0)) {
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        @{ executable = $Executable; arguments = $Arguments; processId = $process.Id; state = 'Running'; startedUtc = [DateTime]::UtcNow.ToString('o') } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $caseDirectory "$Name.command.json")
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = !$process.WaitForExit(180000)
        if ($timedOut) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        # A child/WER process can retain inherited pipe handles after the parent
        # exits. Bound the combined stream drain rather than waiting forever.
        $drainFailure = $null
        try {
            [void][Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr)).WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()
        } catch { $drainFailure = $_.Exception.Message }
        $output = if ($stdout.IsCompletedSuccessfully) { $stdout.GetAwaiter().GetResult() } else { '[stdout drain did not complete successfully]' }
        $errorOutput = if ($stderr.IsCompletedSuccessfully) { $stderr.GetAwaiter().GetResult() } else { '[stderr drain did not complete successfully]' }
        $output | Set-Content -LiteralPath (Join-Path $caseDirectory "$Name.stdout.log")
        $errorOutput | Set-Content -LiteralPath (Join-Path $caseDirectory "$Name.stderr.log")
        $command = [pscustomobject]@{ executable = $Executable; arguments = $Arguments; exitCode = $(if ($process.HasExited) { $process.ExitCode } else { $null }); timedOut = $timedOut; streamDrainFailure = $drainFailure }
        $command | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $caseDirectory "$Name.command.json")
        if ($timedOut) { throw "$Name exceeded its three-minute timeout; inspect retained logs." }
        if ($drainFailure) { throw "$Name output drain failed or exceeded five seconds: $drainFailure" }
        if ($process.ExitCode -notin $AllowedExitCodes) { throw "$Name failed with exit code $($process.ExitCode); inspect retained logs." }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StandardOutput = $output; StandardError = $errorOutput }
    } finally { $process.Dispose() }
}
function Run-Msi([string[]]$Arguments, [string]$Name, [int[]]$AllowedExitCodes = @(0, 3010)) {
    Run-Process (Join-Path $env:SystemRoot 'System32/msiexec.exe') ($Arguments + @('/qn', '/norestart', '/l*v', (Join-Path $caseDirectory "$Name.msi.log"))) $Name $AllowedExitCodes
}
function Protect-File([string]$Path) { $protectedFiles[$Path] = (Get-FileHash $Path -Algorithm SHA256).Hash }
function Check-Protected { Assert-WinGetMsiProtectedFiles $protectedFiles }
function Stage-Msi([string]$Source, [string]$Directory) {
    New-Item -ItemType Directory -Path $Directory | Out-Null
    $path = Join-Path $Directory 'grate.msi'
    Copy-Item -LiteralPath $Source -Destination $path
    return $path
}
function Check-Installed($Metadata, [string]$Payload, [string]$Name) {
    $native = & $inventoryReader -ProductCode $Metadata.ProductCode
    $native | ConvertTo-Json -Depth 8 | Set-Content "$caseDirectory/$Name.native-inventory.json"
    Assert-WinGetMsiNativeContext $native $Metadata.ProductVersion $Metadata.Manufacturer
    $arp = Get-WinGetMsiRegisteredProduct -ReadProductInfo { param($property) Product-Info $Metadata.ProductCode $property }
    Assert-WinGetMsiRegistration -State (Product-State $Metadata.ProductCode) -Version (Product-Info $Metadata.ProductCode 'VersionString') -AssignmentType ([int](Product-Info $Metadata.ProductCode 'AssignmentType')) -Arp $arp -ExpectedVersion $Metadata.ProductVersion -ExpectedPublisher $Metadata.Manufacturer
    Assert-WinGetMsiPayload $installedExe $Payload $Metadata.ProductVersion
    if ((Get-ItemPropertyValue $marker -Name installed) -ne 1) { throw 'The per-user installed marker is missing.' }
    $path = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = @($path.Split(';') | ForEach-Object { $_.Trim().TrimEnd('\', '/') } | Where-Object { $_ -eq $installDirectory.TrimEnd('\', '/') })
    if ($pathEntries.Count -ne 1) { throw "Expected exactly one per-user grate PATH entry, found $($pathEntries.Count)." }
    Check-Protected
    $null = Run-Process $installedExe @('--help') "$Name-help"
}
function Check-Absent([string]$Code, [string]$Name) {
    $native = & $inventoryReader -ProductCode $Code
    $native | ConvertTo-Json -Depth 8 | Set-Content "$caseDirectory/$Name.absent-inventory.json"
    if (@($native.Contexts).Count -or @($native.RegistryEntries).Count) { throw "Previous MSI registration/ARP entry remains: $Code" }
}
function Uninstall-Current([string]$Name, [bool]$RequireDirectoryCleanup = $false) {
    $index = 0
    foreach ($code in $knownCodes) {
        if ((Product-State $code) -ne -1) { $null = Run-Msi @('/x', $code) "$Name-$index" }
        Check-Absent $code "$Name-$index"
        $index++
    }
    if ((Test-Path $installedExe) -or (Test-Path $marker)) { throw 'Payload or marker remains after uninstall.' }
    if ($RequireDirectoryCleanup -and (Test-Path $installDirectory)) { throw 'Candidate installation directory remains after uninstall.' }
    Check-Protected
}
function Run-MigrationSmoke([string]$Name) {
    foreach ($attempt in 1..2) {
        $null = Run-Process $installedExe @('--databasetype', 'sqlite', '--connectionstring', "Data Source=$databasePath", '--files', $sql, '--output', "$caseDirectory/migration-output", '--silent') "$Name-migration-$attempt"
    }
    if (!(Test-Path $databasePath) -or (Get-Item $databasePath).Length -eq 0) { throw 'Installed grate did not create the SQLite database.' }
    Protect-File $databasePath
}
try {
    New-Item -ItemType Directory -Force -Path $OutputDirectory, $companyDirectory | Out-Null
    $unrelatedFile = Join-Path $companyDirectory ('unrelated-' + [Guid]::NewGuid().ToString('N') + '.txt')
    'Unrelated user data outside the installer-owned directory.' | Set-Content $unrelatedFile
    Protect-File $unrelatedFile
    $candidateSource = Stage-Msi $CandidateMsiPath "$OutputDirectory/candidate-source"
    $nextSource = if ($next) { Stage-Msi $NextMsiPath "$OutputDirectory/next-source" } else { $null }
    $rollbackSource = if ($rollback) { Stage-Msi $RollbackMsiPath "$OutputDirectory/rollback-source" } else { $null }
    @{ Candidate = $candidate; Next = $next; RollbackVariant = $rollback; CandidateSha256 = (Get-FileHash $candidateSource).Hash; RollbackSha256 = $(if ($rollbackSource) { (Get-FileHash $rollbackSource).Hash } else { $null }); NativeArchitecture = $Architecture } | ConvertTo-Json -Depth 6 | Set-Content "$OutputDirectory/candidate.json"
    $otherObservation = [ordered]@{ Tested = $false; Reason = 'OtherArchitectureMsiPathNotProvided' }
    if ($other) {
        if ($Architecture -ne 'arm64') { $otherObservation.Reason = 'ARM64 MSI cannot be installed on the x64 runner; runtime cross-family guard is tested on ARM64.' }
        else {
            $caseDirectory = "$OutputDirectory/other-architecture"
            New-Item -ItemType Directory $caseDirectory | Out-Null
            $otherSource = Stage-Msi $OtherArchitectureMsiPath "$caseDirectory/source"
            $zip = Join-Path (Split-Path $OtherArchitectureMsiPath) 'grate.zip'
            Expand-Archive -LiteralPath $zip -DestinationPath "$caseDirectory/payload"
            $otherExe = (Get-ChildItem "$caseDirectory/payload" -Filter grate.exe -File -Recurse | Select-Object -First 1).FullName
            Assert-WinGetMsiPayloadArchitecture $otherExe 'x64'
            $installationAttempted = $true
            $null = Run-Msi @('/i', $otherSource) 'other-family-install'
            Check-Installed $other $otherExe 'other-family-installed'
            $null = Run-Msi @('/i', $candidateSource) 'other-family-conflict' @(1603)
            if ((Get-Content "$caseDirectory/other-family-conflict.msi.log" -Raw) -notmatch 'other architecture of grate is already installed') { throw 'Candidate failure did not prove the explicit architecture-family guard executed.' }
            Check-Installed $other $otherExe 'other-family-preserved'
            Check-Absent $candidate.ProductCode 'native-candidate-not-installed'
            $otherObservation.Tested = $true
            $otherObservation.Reason = 'Other current-user family rejected with original payload/context/data preserved.'
            Uninstall-Current 'other-family-uninstall' $true
        }
    }
    $otherObservation | ConvertTo-Json | Set-Content "$OutputDirectory/other-architecture.json"
    foreach ($historical in $history) {
        $old = $historical.Metadata
        $caseDirectory = "$OutputDirectory/from-$($old.ProductVersion)"
        New-Item -ItemType Directory $caseDirectory | Out-Null
        $baselineSource = Stage-Msi $historical.Msi "$caseDirectory/historical-source"
        $observation = [ordered]@{ HistoricalVersion = $old.ProductVersion; HistoricalPlatform = $old.Platform; HistoricalUpgradeCode = $old.UpgradeCode; CandidateVersion = $candidate.ProductVersion; CandidateProductCode = $candidate.ProductCode; CandidateUpgradeCode = $candidate.UpgradeCode; Rollback = 'NotRun'; OrdinaryUpdate = 'NotRun'; NextFamilyUpgrade = 'NotRun'; DowngradeRejected = $false; Succeeded = $false }
        $results.Add($observation)
        $sql = "$caseDirectory/user-data/sql"
        $databasePath = "$caseDirectory/user-data/migrations.db"
        New-Item -ItemType Directory -Force -Path "$sql/up", "$sql/afterMigration" | Out-Null
        'CREATE TABLE package_smoke(id INTEGER PRIMARY KEY); INSERT INTO package_smoke VALUES(42);' | Set-Content "$sql/up/001_create.sql"
        'CREATE TEMP TABLE package_assert(value INTEGER CHECK(value = 1)); INSERT INTO package_assert SELECT CASE WHEN COUNT(*) = 1 AND MIN(id) = 42 THEN 1 ELSE 0 END FROM package_smoke; INSERT INTO package_assert SELECT CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END FROM grate_ScriptsRun WHERE script_name = ''001_create.sql''; INSERT INTO package_assert SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END FROM grate_ScriptsRunErrors;' | Set-Content "$sql/afterMigration/900_assert.sql"
        try {
            $installationAttempted = $true
            $null = Run-Msi @('/i', $baselineSource) 'historical-install'
            Check-Installed $old $historical.Executable 'historical-install'
            Run-MigrationSmoke 'historical-install'
            if ($rollbackSource) {
                $null = Run-Msi @('/i', $rollbackSource) 'injected-rollback' @(1603)
                $log = Get-Content "$caseDirectory/injected-rollback.msi.log" -Raw
                Assert-WinGetMsiRollbackLog -Log $log -LegacyProductCode $legacyCode -LegacyUpgradeCode $old.UpgradeCode -CandidateProductCode $candidate.ProductCode
                Check-Installed $old $historical.Executable 'rollback-restored-legacy'
                Check-Absent $candidate.ProductCode 'rollback-candidate-absent'
                $observation.Rollback = 'LegacyRegistrationPayloadAndDataRestored'
            }
            $null = Run-Msi @('/i', $candidateSource) 'ordinary-major-upgrade'
            Check-Installed $candidate $CandidateExecutable 'major-upgraded'
            Check-Absent $legacyCode 'legacy-removed'
            Run-MigrationSmoke 'major-upgraded'
            $observation.OrdinaryUpdate = 'Upgraded'
            if ($next) {
                $null = Run-Msi @('/i', $nextSource) 'next-family-upgrade'
                Check-Installed $next $NextExecutable 'next-family-upgraded'
                Check-Absent $candidate.ProductCode 'previous-new-product-removed'
                Check-Absent $legacyCode 'legacy-still-absent'
                Run-MigrationSmoke 'next-family-upgraded'
                $observation.NextFamilyUpgrade = 'Upgraded'
                $null = Run-Msi @('/i', $candidateSource) 'reject-family-downgrade' @(1603)
                if ((Get-Content "$caseDirectory/reject-family-downgrade.msi.log" -Raw) -notmatch 'A newer version of grate is already installed') { throw 'Candidate failure did not prove the downgrade guard executed.' }
                Check-Installed $next $NextExecutable 'newer-family-preserved'
                $observation.DowngradeRejected = $true
            }
            Uninstall-Current 'final-uninstall' $true
            $observation.Succeeded = $true
        } catch { $observation.Error = $_.Exception.Message; $failures.Add($_.Exception) }
        finally {
            try { Uninstall-Current 'case-cleanup' } catch { $observation.Succeeded = $false; $observation.CleanupError = $_.Exception.Message; $failures.Add($_.Exception) }
            $observation | ConvertTo-Json -Depth 6 | Set-Content "$caseDirectory/result.json"
        }
    }
} catch { $failures.Add($_.Exception) }
finally {
    try { if ($installationAttempted) { Uninstall-Current 'cleanup-uninstall' } } catch { $failures.Add($_.Exception) }
    finally {
        try {
            [Environment]::SetEnvironmentVariable('Path', $originalUserPath, 'User')
            if ($unrelatedFile -and (Test-Path $unrelatedFile)) { Remove-Item $unrelatedFile -Force }
            if (!$companyAlreadyExisted -and (Test-Path $companyDirectory) -and @(Get-ChildItem $companyDirectory -Force).Count -eq 0) { Remove-Item $companyDirectory }
        } catch { $failures.Add($_.Exception) }
    }
    if (Test-Path $OutputDirectory) {
        @{ Architecture = $Architecture; PowerShellApartmentState = [Threading.Thread]::CurrentThread.GetApartmentState().ToString(); Cases = $results.ToArray(); Failures = @($failures | ForEach-Object Message); Succeeded = ($failures.Count -eq 0 -and $results.Count -eq $history.Count); OrdinaryUpgradeSupported = ($results.Count -eq $history.Count -and @($results | Where-Object { $_.OrdinaryUpdate -ne 'Upgraded' }).Count -eq 0); WinGetIdentityTransitionTested = $false } | ConvertTo-Json -Depth 8 | Set-Content "$OutputDirectory/summary.json"
    }
}
if ($failures.Count) { throw [AggregateException]::new('MSI major-upgrade/rollback verification or cleanup failed; inspect retained native evidence.', $failures) }
Write-Host 'PASS: native legacy major upgrade, installed payload/context/SQL/data, requested rollback/family/cross-architecture checks and uninstall. WinGet identity transition is a separate test.'
