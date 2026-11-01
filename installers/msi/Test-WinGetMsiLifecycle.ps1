#!/usr/bin/env pwsh
param (
    [Parameter(Mandatory=$true)] [string[]]$HistoricalMsiPaths,
    [Parameter(Mandatory=$true)] [string[]]$HistoricalExecutablePaths,
    [Parameter(Mandatory=$true)] [string]$CandidateMsiPath,
    [Parameter(Mandatory=$true)] [string]$CandidateExecutable,
    [Parameter(Mandatory=$true)] [ValidateSet('x64', 'arm64')] [string]$Architecture,
    [Parameter(Mandatory=$true)] [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'WinGetMsiLifecycle.Assertions.ps1')
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'MSI lifecycle verification requires a disposable GitHub-hosted Windows runner.'
}
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant() -ne $Architecture) {
    throw "MSI lifecycle verification requires native Windows $Architecture."
}
if ($HistoricalMsiPaths.Count -eq 0 -or $HistoricalMsiPaths.Count -ne $HistoricalExecutablePaths.Count) {
    throw 'Supply matching historical MSI and release ZIP executable paths, in the same order.'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ((Test-Path -LiteralPath $OutputDirectory) -and @(Get-ChildItem -LiteralPath $OutputDirectory -Force).Count -gt 0) {
    throw 'The lifecycle output directory must be new or empty, so evidence from different runs cannot be mixed.'
}
$reader = Join-Path $PSScriptRoot 'Get-InstallerMetadata.ps1'
$CandidateMsiPath = (Resolve-Path -LiteralPath $CandidateMsiPath).Path
$CandidateExecutable = (Resolve-Path -LiteralPath $CandidateExecutable).Path
$candidate = & $reader -MsiPath $CandidateMsiPath
$productCode = '{E281998A-D8A2-4926-AAA3-066EFA4B2E74}'
if ($candidate.ProductCode -ne $productCode -or $candidate.ProductName -ne 'grate' -or
    $candidate.Manufacturer -ne 'erikbra' -or $candidate.Platform -ne $Architecture -or
    $candidate.AllUsers -or $candidate.MsiInstallPerUser) {
    throw 'The candidate MSI changed the released product identity/context or does not use the native MSI platform.'
}
Assert-WinGetMsiPayloadArchitecture $CandidateExecutable $Architecture
$history = @()
for ($index = 0; $index -lt $HistoricalMsiPaths.Count; $index++) {
    $msi = (Resolve-Path -LiteralPath $HistoricalMsiPaths[$index]).Path
    $exe = (Resolve-Path -LiteralPath $HistoricalExecutablePaths[$index]).Path
    $metadata = & $reader -MsiPath $msi
    # Historical Arm64 releases were wrapped in x64 MSI databases. Record that
    # limitation while requiring a genuinely native payload and candidate MSI.
    $platforms = if ($Architecture -eq 'arm64') { @('arm64', 'x64') } else { @('x64') }
    if ($metadata.ProductCode -ne $productCode -or $metadata.ProductName -ne 'grate' -or
        $metadata.Manufacturer -ne 'erikbra' -or $metadata.Platform -notin $platforms -or
        $metadata.AllUsers -or $metadata.MsiInstallPerUser) {
        throw "The historical MSI has an unexpected identity/context/platform: $msi"
    }
    if ([version]$candidate.ProductVersion -le [version]$metadata.ProductVersion) { throw 'The candidate must have a higher MSI version than every historical package.' }
    Assert-WinGetMsiPayloadArchitecture $exe $Architecture
    $history += [pscustomobject]@{ Msi = $msi; Executable = $exe; Metadata = $metadata }
}

$installDirectory = Join-Path $env:LOCALAPPDATA 'erikbra/grate'
$installedExe = Join-Path $installDirectory 'grate.exe'
$companyDirectory = Split-Path $installDirectory
$marker = 'HKCU:\Software\Microsoft\erikbra\grate'
$arpKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
$currentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$packedProductCode = ConvertTo-WinGetMsiProductRegistryKey $productCode
$userDataKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\$currentUserSid\Products\$packedProductCode\InstallProperties"
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
function Product-State { [int](Invoke-InstallerMember 'ProductState' GetProperty @($productCode)) }
function Product-Info([string]$Name) { Invoke-InstallerMember 'ProductInfo' GetProperty @($productCode, $Name) }

if ((Product-State) -ne -1 -or (Test-Path -LiteralPath $installDirectory) -or
    (Test-Path -LiteralPath $marker) -or (Test-Path -LiteralPath $arpKey)) {
    throw 'Refusing to replace a pre-existing grate product, directory, marker or ARP entry.'
}

$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$companyAlreadyExisted = Test-Path -LiteralPath $companyDirectory
$caseDirectory = $OutputDirectory
$protectedFiles = @{}
$installationAttempted = $false
$unrelatedFile = $null
$failures = [Collections.Generic.List[Exception]]::new()
$results = [Collections.Generic.List[object]]::new()

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
function Protect-File([string]$Path) { $protectedFiles[$Path] = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Check-Protected { Assert-WinGetMsiProtectedFiles $protectedFiles }
function Check-Installed($Metadata, [string]$Payload, [string]$Name) {
    $state = Product-State
    $version = Product-Info 'VersionString'
    $assignment = [int](Product-Info 'AssignmentType')
    $arp = Get-WinGetMsiRegisteredProduct -ReadProductInfo { param($property) Product-Info $property }
    Assert-WinGetMsiRegistration -State $state -Version $version -AssignmentType $assignment -Arp $arp -ExpectedVersion $Metadata.ProductVersion
    Assert-WinGetMsiPayload -InstalledExecutable $installedExe -ExpectedExecutable $Payload -ExpectedVersion $Metadata.ProductVersion
    if ((Get-ItemPropertyValue -LiteralPath $marker -Name installed) -ne 1) { throw 'The per-user installed marker is missing or incorrect.' }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($installDirectory.TrimEnd('\') -notin @($userPath.Split(';') | ForEach-Object { $_.TrimEnd('\') })) { throw 'The per-user PATH entry is missing.' }
    $userData = if (Test-Path -LiteralPath $userDataKey) {
        Get-ItemProperty -LiteralPath $userDataKey | Select-Object DisplayName, DisplayVersion, Publisher, WindowsInstaller, LocalPackage, InstallSource
    } else { $null }
    @{ ProductCode = $productCode; ProductState = $state; AssignmentType = $assignment; InventorySource = 'WindowsInstaller.ProductInfo'; CurrentUserSid = $currentUserSid; DisplayName = $arp.DisplayName; Publisher = $arp.Publisher; DisplayVersion = $arp.DisplayVersion; ConventionalHkcuUninstallKeyPresent = (Test-Path -LiteralPath $arpKey); DiagnosticUserDataKey = $userDataKey; DiagnosticUserData = $userData; PayloadSha256 = (Get-FileHash $installedExe -Algorithm SHA256).Hash; FileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($installedExe).FileVersion } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $caseDirectory "$Name.installed.json")
    Check-Protected
    # --version requires a database migration version; it is not a package
    # information command. Package identity is asserted from MSI/file metadata.
    @{ Option = '--version'; Outcome = 'NotRun'; NotRunReason = 'DatabaseMigrationVersionOption'; RequiredForLifecyclePass = $false } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $caseDirectory "$Name-version.observation.json")
    $null = Run-Process $installedExe @('--help') "$Name-help"
}
function Uninstall-Current([string]$Name, [bool]$RequireDirectoryCleanup = $false) {
    if ((Product-State) -ne -1) { $null = Run-Msi @('/x', $productCode) $Name }
    if ((Product-State) -ne -1 -or (Test-Path -LiteralPath $installedExe) -or (Test-Path -LiteralPath $marker) -or (Test-Path -LiteralPath $arpKey)) {
        throw 'MSI product, payload, marker or ARP entry remains after uninstall.'
    }
    if ($RequireDirectoryCleanup -and (Test-Path -LiteralPath $installDirectory)) { throw 'The current candidate MSI left its installation directory after uninstall.' }
    Check-Protected
}
function Stage-Msi([string]$Source, [string]$Directory) {
    New-Item -ItemType Directory -Path $Directory | Out-Null
    $path = Join-Path $Directory 'grate.msi'
    Copy-Item -LiteralPath $Source -Destination $path
    return $path
}
function Run-MigrationSmoke([string]$Name) {
    foreach ($attempt in 1..2) {
        $null = Run-Process $installedExe @('--databasetype', 'sqlite', '--connectionstring', "Data Source=$databasePath", '--files', $sql, '--output', (Join-Path $caseDirectory 'migration-output'), '--silent') "$Name-migration-$attempt"
    }
    if (!(Test-Path -LiteralPath $databasePath) -or (Get-Item -LiteralPath $databasePath).Length -eq 0) { throw 'Installed grate did not create the SQLite database.' }
    Protect-File $databasePath
}

try {
    New-Item -ItemType Directory -Force -Path $OutputDirectory, $companyDirectory | Out-Null
    $unrelatedFile = Join-Path $companyDirectory ('unrelated-' + [Guid]::NewGuid().ToString('N') + '.txt')
    'Unrelated user data outside the installer-owned grate directory.' | Set-Content -LiteralPath $unrelatedFile
    Protect-File $unrelatedFile
    $candidateSource = Stage-Msi $CandidateMsiPath (Join-Path $OutputDirectory 'candidate-source')
    $candidateSourceHash = (Get-FileHash $candidateSource -Algorithm SHA256).Hash
    @{ Metadata = $candidate; MsiSha256 = $candidateSourceHash; PayloadSha256 = (Get-FileHash $CandidateExecutable -Algorithm SHA256).Hash; NativeArchitecture = $Architecture } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'candidate.json')

    foreach ($historical in $history) {
        $old = $historical.Metadata
        $caseDirectory = Join-Path $OutputDirectory ('from-' + $old.ProductVersion)
        New-Item -ItemType Directory -Path $caseDirectory | Out-Null
        $baselineSource = Stage-Msi $historical.Msi (Join-Path $caseDirectory 'historical-source')
        $oldHash = (Get-FileHash $historical.Executable -Algorithm SHA256).Hash
        $newHash = (Get-FileHash $CandidateExecutable -Algorithm SHA256).Hash
        $observation = [ordered]@{ HistoricalVersion = $old.ProductVersion; HistoricalPlatform = $old.Platform; HistoricalUpgradeCode = $old.UpgradeCode; CandidateVersion = $candidate.ProductVersion; CandidatePlatform = $candidate.Platform; CandidateUpgradeCode = $candidate.UpgradeCode; OrdinaryUpdate = 'NotRun'; ExplicitMinorUpdate = 'NotRun'; UninstallReinstall = 'NotRun'; Succeeded = $false }
        $results.Add($observation)
        @{ Metadata = $old; MsiSha256 = (Get-FileHash $baselineSource -Algorithm SHA256).Hash; PayloadSha256 = $oldHash; NativePayloadArchitecture = $Architecture; LegacyX64WrapperOnArm64 = ($Architecture -eq 'arm64' -and $old.Platform -eq 'x64') } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $caseDirectory 'historical.json')
        $sql = Join-Path $caseDirectory 'user-data/sql'
        $databasePath = Join-Path $caseDirectory 'user-data/migrations.db'
        New-Item -ItemType Directory -Force -Path "$sql/up", "$sql/afterMigration" | Out-Null
        'CREATE TABLE package_smoke(id INTEGER PRIMARY KEY); INSERT INTO package_smoke VALUES(42);' | Set-Content -LiteralPath "$sql/up/001_create.sql"
        'CREATE TEMP TABLE package_assert(value INTEGER CHECK(value = 1)); INSERT INTO package_assert SELECT CASE WHEN COUNT(*) = 1 AND MIN(id) = 42 THEN 1 ELSE 0 END FROM package_smoke; INSERT INTO package_assert SELECT CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END FROM grate_ScriptsRun WHERE script_name = ''001_create.sql''; INSERT INTO package_assert SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END FROM grate_ScriptsRunErrors;' | Set-Content -LiteralPath "$sql/afterMigration/900_assert.sql"
        try {
            $installationAttempted = $true
            $null = Run-Msi @('/i', $baselineSource) 'historical-install'
            Check-Installed $old $historical.Executable 'historical-install'
            Run-MigrationSmoke 'historical-install'

            # Characterize an ordinary MSI update without assuming that exit 0
            # or an MSI manifest proves the old package was actually replaced.
            $ordinary = Run-Msi @('/i', $candidateSource) 'ordinary-update' @(0, 3010, 1638)
            $observation.OrdinaryUpdate = Get-WinGetMsiOrdinaryUpdateOutcome -ExitCode $ordinary.ExitCode -RegisteredVersion (Product-Info 'VersionString') -OldVersion $old.ProductVersion -NewVersion $candidate.ProductVersion -InstalledHash (Get-FileHash $installedExe -Algorithm SHA256).Hash -OldHash $oldHash -NewHash $newHash
            if ($observation.OrdinaryUpdate -eq 'Upgraded') { Check-Installed $candidate $CandidateExecutable 'ordinary-update' }
            else { Check-Installed $old $historical.Executable 'ordinary-update-unchanged' }
            $observation.OrdinaryExitCode = $ordinary.ExitCode

            # Reset to a real historical installation even when ordinary /i
            # happened to work, so explicit-update evidence has the same trigger.
            Uninstall-Current 'ordinary-reset-uninstall'
            $null = Run-Msi @('/i', $baselineSource) 'explicit-baseline-install'
            Check-Installed $old $historical.Executable 'explicit-baseline-install'
            try {
                # Same ProductCode requires a minor update. This candidate keeps
                # the normal builder's fresh UpgradeCode, rather than silently
                # fixing the test by copying the historical UpgradeCode.
                $null = Run-Msi @('/i', $candidateSource, 'REINSTALL=ALL', 'REINSTALLMODE=vomus') 'explicit-minor-update'
                Check-Installed $candidate $CandidateExecutable 'explicit-minor-update'
                Run-MigrationSmoke 'explicit-minor-update'
                $observation.ExplicitMinorUpdate = 'Upgraded'
            } catch {
                $observation.ExplicitMinorUpdate = 'Failed'
                $observation.ExplicitMinorUpdateError = $_.Exception.Message
                $failures.Add($_.Exception)
            }

            # Exercise the documented fallback from a historical package, not
            # just uninstall/reinstall of the candidate that is already current.
            Uninstall-Current 'fallback-reset-uninstall'
            $null = Run-Msi @('/i', $baselineSource) 'fallback-baseline-install'
            Check-Installed $old $historical.Executable 'fallback-baseline-install'
            Uninstall-Current 'fallback-historical-uninstall'
            $null = Run-Msi @('/i', $candidateSource) 'fallback-candidate-install'
            Check-Installed $candidate $CandidateExecutable 'fallback-candidate-install'
            Run-MigrationSmoke 'fallback-candidate-install'
            $observation.UninstallReinstall = 'Reinstalled'
            Uninstall-Current 'final-candidate-uninstall' $true
            $observation.Succeeded = $observation.ExplicitMinorUpdate -eq 'Upgraded'
        } catch {
            $observation.Error = $_.Exception.Message
            $failures.Add($_.Exception)
        } finally {
            try { Uninstall-Current 'case-cleanup-uninstall' } catch {
                $observation.Succeeded = $false
                $observation.CleanupError = $_.Exception.Message
                $failures.Add($_.Exception)
            }
            $observation | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $caseDirectory 'result.json')
        }
    }
    if ((Get-FileHash $candidateSource -Algorithm SHA256).Hash -ne $candidateSourceHash) { throw 'The candidate MSI source changed during lifecycle verification.' }
} catch { $failures.Add($_.Exception) }
finally {
    try {
        if ($installationAttempted) { Uninstall-Current 'cleanup-uninstall' }
    } catch { $failures.Add($_.Exception) }
    finally {
        try {
            # The installer intentionally authors Permanent=yes for user PATH.
            # Restore the disposable runner's original value as test cleanup.
            [Environment]::SetEnvironmentVariable('Path', $originalUserPath, 'User')
            if ($unrelatedFile -and (Test-Path -LiteralPath $unrelatedFile)) { Remove-Item -LiteralPath $unrelatedFile -Force }
            if (!$companyAlreadyExisted -and (Test-Path -LiteralPath $companyDirectory) -and @(Get-ChildItem -LiteralPath $companyDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $companyDirectory }
        } catch { $failures.Add($_.Exception) }
    }
    if (Test-Path -LiteralPath $OutputDirectory) {
        @{ Architecture = $Architecture; PowerShellApartmentState = [Threading.Thread]::CurrentThread.GetApartmentState().ToString(); Cases = $results.ToArray(); Failures = @($failures | ForEach-Object Message); Succeeded = ($failures.Count -eq 0 -and $results.Count -eq $history.Count); OrdinaryUpgradeSupported = ($results.Count -eq $history.Count -and @($results | Where-Object { $_.OrdinaryUpdate -ne 'Upgraded' }).Count -eq 0); WinGetIdentityTransitionTested = $false } |
            ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json')
    }
}
if ($failures.Count) { throw [AggregateException]::new('MSI lifecycle verification or cleanup failed; inspect summary.json and retained installer logs.', $failures) }
Write-Host 'PASS: native payload, installed MSI/ARP/context, explicit minor update and uninstall/reinstall fallback. Ordinary /i outcomes are recorded separately; this script does not assert a WinGet identity transition.'
