#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)][string]$MsiPath,
    [Parameter(Mandatory)][string]$PublishedExecutable,
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallerLifecycle.Assertions.ps1')
. (Join-Path $PSScriptRoot 'InstallerLifecycle.Process.ps1')
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'MSI lifecycle verification requires a disposable GitHub-hosted Windows runner.'
}
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant() -ne $Architecture) {
    throw "MSI lifecycle verification must execute natively on Windows $Architecture."
}

$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$MsiPath = (Resolve-Path -LiteralPath $MsiPath).Path
$PublishedExecutable = (Resolve-Path -LiteralPath $PublishedExecutable).Path
$repository = Split-Path (Split-Path $PSScriptRoot)
$installer = New-Object -ComObject WindowsInstaller.Installer

function Invoke-ComMember($Target, [string]$Name, [Reflection.BindingFlags]$Flags, [object[]]$Arguments) {
    $Target.GetType().InvokeMember($Name, $Flags, $null, $Target, $Arguments)
}

function Read-MsiMetadata([string]$Path) {
    $database = Invoke-ComMember $installer 'OpenDatabase' InvokeMethod @($Path, 0)
    $values = @{}
    try {
        foreach ($name in @('ProductCode', 'UpgradeCode', 'ProductVersion', 'ProductName')) {
            $view = Invoke-ComMember $database 'OpenView' InvokeMethod @("SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = '$name'")
            $record = $null
            try {
                [void]$view.Execute()
                $record = $view.Fetch()
                if ($null -eq $record) { throw "The MSI has no $name property." }
                $values[$name] = Invoke-ComMember $record 'StringData' GetProperty @(1)
            } finally {
                if ($null -ne $record) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
            }
        }
        $summary = Invoke-ComMember $database 'SummaryInformation' GetProperty @(0)
        try { $values.Platform = (Invoke-ComMember $summary 'Property' GetProperty @(7)).Split(';')[0] }
        finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
    } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
    return $values
}

function Product-State([string]$ProductCode = $metadata.ProductCode) { [int](Invoke-ComMember $installer 'ProductState' GetProperty @($ProductCode)) }
function Product-Info([string]$Name) { Invoke-ComMember $installer 'ProductInfo' GetProperty @($metadata.ProductCode, $Name) }
function Marker-Present { $null -ne (Get-ItemProperty -LiteralPath $marker -Name installed -ErrorAction SilentlyContinue) }

function Run-Process([string]$Executable, [string[]]$Arguments, [string]$Name, [int[]]$AllowedExitCodes = @(0)) {
    Invoke-InstallerLifecycleProcess -Executable $Executable -Arguments $Arguments -Name $Name `
        -AllowedExitCodes $AllowedExitCodes -OutputDirectory $OutputDirectory
}

function Run-Msi([string[]]$Arguments, [string]$Name) {
    Run-Process (Join-Path $env:SystemRoot 'System32/msiexec.exe') ($Arguments + @('/qn', '/norestart', '/l*v', (Join-Path $OutputDirectory "$Name.msi.log"))) $Name @(0, 3010)
}

function Check-Installed([string]$Version, [string]$Payload) {
    Assert-MsiRegistration -State (Product-State) -Version (Product-Info 'VersionString') -AssignmentType ([int](Product-Info 'AssignmentType')) -ExpectedVersion $Version
    Assert-MsiPayload -InstalledExecutable $installedExe -ExpectedExecutable $Payload
    if (!(Marker-Present) -or (Get-ItemPropertyValue -LiteralPath $marker -Name installed) -ne 1) { throw 'The per-user installed registry marker is missing or incorrect.' }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($installDirectory.TrimEnd('\') -notin @($userPath.Split(';') | ForEach-Object { $_.TrimEnd('\') })) {
        throw 'The installed per-user PATH entry is missing.'
    }
}

function Run-Migrations([string]$Name) {
    Run-Process $installedExe @('--help') "$Name-help"
    foreach ($attempt in 1..2) {
        Run-Process $installedExe @('--databasetype', 'sqlite', '--connectionstring', "Data Source=$databasePath", '--files', $sql, '--output', (Join-Path $state 'output'), '--silent') "$Name-migration-$attempt"
    }
    $archived = @(Get-ChildItem (Join-Path $state 'output') -Filter '001_create.sql' -File -Recurse |
        Where-Object { $_.FullName -match '[\\/]itemsRan[\\/]up[\\/]001_create\.sql$' })
    if ($archived.Count -ne 1) { throw "Expected the initial migration exactly once, found $($archived.Count) archived executions." }
    if (!(Test-Path $databasePath) -or (Get-Item $databasePath).Length -eq 0) { throw 'Installed grate did not create the SQLite database.' }
}

$metadata = Read-MsiMetadata $MsiPath
$expectedIdentity = & (Join-Path $PSScriptRoot 'helpers/Get-InstallerIdentity.ps1') -Version $metadata.ProductVersion -Architecture $Architecture
if ($metadata.ProductCode -ne $expectedIdentity.ProductCode -or $metadata.UpgradeCode -ne $expectedIdentity.UpgradeCode -or $metadata.ProductName -ne $expectedIdentity.ProductName -or $metadata.Platform -ne $Architecture) {
    throw "Unexpected candidate MSI identity/platform: $($metadata | ConvertTo-Json -Compress)"
}
$metadata | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'baseline-package.json')
$installDirectory = Join-Path $env:LOCALAPPDATA 'erikbra/grate'
$installedExe = Join-Path $installDirectory 'grate.exe'
$companyDirectory = Split-Path $installDirectory
$marker = 'HKCU:\Software\Microsoft\erikbra\grate'
if ((Product-State) -ne -1 -or (Test-Path $installDirectory) -or (Test-Path $marker)) {
    throw 'Refusing to replace a pre-existing grate product, installation directory or registry key.'
}
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$companyAlreadyExisted = Test-Path $companyDirectory
$state = Join-Path $OutputDirectory ('state-' + [Guid]::NewGuid().ToString('N'))
$sql = Join-Path $state 'sql'
$databasePath = Join-Path $state 'user migration data.db'
New-Item -ItemType Directory -Force "$sql/up", "$sql/afterMigration", $companyDirectory | Out-Null
$unrelatedFile = Join-Path $companyDirectory ('unrelated-' + [Guid]::NewGuid().ToString('N') + '.txt')
'Unrelated user file, owned by this test only.' | Set-Content $unrelatedFile
$unrelatedHash = (Get-FileHash $unrelatedFile -Algorithm SHA256).Hash
'CREATE TABLE package_smoke(id INTEGER PRIMARY KEY); INSERT INTO package_smoke VALUES(42);' | Set-Content "$sql/up/001_create.sql"
$assertData = 'CREATE TEMP TABLE package_assert(value INTEGER CHECK(value = 1)); INSERT INTO package_assert SELECT CASE WHEN COUNT(*) = 1 AND MIN(id) = 42 THEN 1 ELSE 0 END FROM package_smoke; INSERT INTO package_assert SELECT CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END FROM grate_ScriptsRun WHERE script_name = ''001_create.sql''; INSERT INTO package_assert SELECT CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END FROM grate_ScriptsRunErrors;'
$assertData | Set-Content "$sql/afterMigration/900_assert.sql"
$attemptedProducts = [Collections.Generic.List[string]]::new()
$uninstalled = $false
$failure = $null
$cleanupFailures = [Collections.Generic.List[Exception]]::new()
try {
    $baselineSource = Copy-MsiLifecycleSource $MsiPath (Join-Path $OutputDirectory 'baseline-source')
    $baselineSourceHash = (Get-FileHash $baselineSource -Algorithm SHA256).Hash
    $attemptedProducts.Add($metadata.ProductCode)
    Run-Msi @('/i', $baselineSource) 'install'
    Check-Installed $metadata.ProductVersion $PublishedExecutable
    Run-Migrations 'installed'
    $skill = Join-Path $state 'skill'
    Run-Process $installedExe @('skills', 'install', '--local', '--path', $skill) 'installed-skill'
    foreach ($agent in @('.agents', '.claude')) {
        if (!(Test-Path "$skill/$agent/skills/use-grate/SKILL.md")) { throw "Installed grate did not install the bundled $agent skill." }
    }

    $dataHash = (Get-FileHash $databasePath -Algorithm SHA256).Hash
    $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($PublishedExecutable)
    $upgradeVersion = Get-MsiUpgradeVersion ([version]$metadata.ProductVersion) ([version]"$($fileVersion.FileMajorPart).$($fileVersion.FileMinorPart).$($fileVersion.FileBuildPart)")
    $frameworks = ((& dotnet msbuild (Join-Path $repository 'src/grate/grate.csproj') -nologo -getProperty:TargetFrameworks).Trim() -split ';')
    if ($LASTEXITCODE -ne 0 -or !$frameworks[-1]) { throw 'Cannot determine the upgrade publish target framework.' }
    $framework = $frameworks[-1]
    $upgradePayload = Join-Path $OutputDirectory 'upgrade-payload'
    Run-Process 'dotnet' @('publish', (Join-Path $repository 'src/grate/grate.csproj'), '-c', 'Release', '-f', $framework, '-r', "win-$Architecture", '--self-contained', '-p:SelfContained=true', "-p:TargetFrameworks=$framework", "-p:Version=$upgradeVersion", '-o', $upgradePayload) 'publish-upgrade'
    $upgradeExe = Join-Path $upgradePayload 'grate.exe'
    if ((Get-FileHash $upgradeExe).Hash -eq (Get-FileHash $PublishedExecutable).Hash) { throw 'Upgrade verification requires a genuinely different published executable.' }

    # The initial installation's source must remain available while the builder
    # recreates tmp and Windows Installer resolves the subsequent update source.
    & (Join-Path $PSScriptRoot 'Create-Installer.ps1') -grateExe $upgradeExe -version $upgradeVersion -arch $Architecture -upgradeCode $metadata.UpgradeCode
    Assert-MsiDataPreserved $baselineSource $baselineSourceHash
    $upgradeMsi = Join-Path $PSScriptRoot "tmp/grate-$upgradeVersion.msi"
    $updated = Read-MsiMetadata $upgradeMsi
    $expectedUpgrade = & (Join-Path $PSScriptRoot 'helpers/Get-InstallerIdentity.ps1') -Version $upgradeVersion -Architecture $Architecture
    if ($updated.ProductCode -ne $expectedUpgrade.ProductCode -or $updated.ProductCode -eq $metadata.ProductCode -or $updated.UpgradeCode -ne $metadata.UpgradeCode -or $updated.Platform -ne $Architecture -or $updated.ProductVersion -ne $upgradeVersion) {
        throw 'The upgrade MSI must have its per-release ProductCode, the same architecture family and the expected version.'
    }
    if ((Product-State $updated.ProductCode) -ne -1) { throw 'Refusing to replace a pre-existing upgrade product.' }
    $updated | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'upgrade-package.json')
    $upgradeSource = Copy-MsiLifecycleSource $upgradeMsi (Join-Path $OutputDirectory 'upgrade-source')
    # A new release has its own ProductCode in the same UpgradeCode family.
    # MajorUpgrade must remove the baseline product within the install transaction.
    $baselineProductCode = $metadata.ProductCode
    $attemptedProducts.Add($updated.ProductCode)
    Run-Msi @('/i', $upgradeSource) 'upgrade'
    if ((Product-State $baselineProductCode) -ne -1) { throw 'The major upgrade left the baseline product registered.' }
    $metadata = $updated
    Check-Installed $upgradeVersion $upgradeExe
    Assert-MsiDataPreserved $databasePath $dataHash
    'ALTER TABLE package_smoke ADD COLUMN upgraded INTEGER; UPDATE package_smoke SET upgraded = 7;' | Set-Content "$sql/up/002_upgrade.sql"
    ($assertData + ' INSERT INTO package_assert SELECT CASE WHEN upgraded = 7 THEN 1 ELSE 0 END FROM package_smoke; INSERT INTO package_assert SELECT CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END FROM grate_ScriptsRun WHERE script_name = ''002_upgrade.sql'';') | Set-Content "$sql/afterMigration/900_assert.sql"
    Run-Migrations 'upgraded'
    $dataHash = (Get-FileHash $databasePath -Algorithm SHA256).Hash

    Run-Msi @('/x', $metadata.ProductCode) 'uninstall'
    $uninstalled = $true
    Assert-MsiUninstalled -State (Product-State) -InstallDirectory $installDirectory -MarkerPresent (Marker-Present)
    Assert-MsiDataPreserved $databasePath $dataHash
    Assert-MsiDataPreserved $unrelatedFile $unrelatedHash
    Write-Host "PASS: native $Architecture per-user MSI install, major upgrade, installed migrations/skill and uninstall."
} catch {
    $failure = $_
} finally {
    try {
        if (!$uninstalled) {
            foreach ($productCode in $attemptedProducts) {
                try {
                    if ((Product-State $productCode) -ne -1) { Run-Msi @('/x', $productCode) ('cleanup-uninstall-' + $productCode.Trim('{}')) }
                } catch { $cleanupFailures.Add($_.Exception) }
            }
        }
    } finally {
        # The package deliberately authors a permanent user PATH entry. Restore the
        # disposable runner's original value instead of claiming MSI removes it.
        try {
            [Environment]::SetEnvironmentVariable('Path', $originalUserPath, 'User')
            Remove-Item -LiteralPath $unrelatedFile -Force
            if (!$companyAlreadyExisted -and (Test-Path $companyDirectory) -and @(Get-ChildItem $companyDirectory -Force).Count -eq 0) {
                Remove-Item -LiteralPath $companyDirectory
            }
        } catch {
            $cleanupFailures.Add($_.Exception)
        }
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
    }
}
if ($failure -or $cleanupFailures.Count) {
    $exceptions = [Collections.Generic.List[Exception]]::new()
    if ($failure) { $exceptions.Add($failure.Exception) }
    $exceptions.AddRange($cleanupFailures)
    throw [AggregateException]::new('MSI lifecycle verification or cleanup failed; inspect the retained command and installer logs.', $exceptions)
}
