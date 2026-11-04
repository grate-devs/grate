#!/usr/bin/env pwsh

param (
    [Parameter(Mandatory=$true)] [string]$MsiPath
)

$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'MSI metadata inspection requires Windows Installer on Windows; it does not install the package.' }
$MsiPath = (Resolve-Path -LiteralPath $MsiPath).Path

function Invoke-MsiMember($Target, [string]$Name, [Reflection.BindingFlags]$Flags, [object[]]$Arguments) {
    $Target.GetType().InvokeMember($Name, $Flags, $null, $Target, $Arguments)
}

$installer = $null
$database = $null
$view = $null
$summary = $null
try {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    # msiOpenDatabaseModeReadOnly (0). This never invokes installation, repair,
    # product inventory (Win32_Product), or a write/commit against the MSI.
    # https://learn.microsoft.com/windows/win32/msi/installer-opendatabase
    $database = Invoke-MsiMember $installer 'OpenDatabase' InvokeMethod @($MsiPath, 0)
    $view = Invoke-MsiMember $database 'OpenView' InvokeMethod @('SELECT `Property`, `Value` FROM `Property`')
    [void](Invoke-MsiMember $view 'Execute' InvokeMethod @())
    $properties = @{}
    while ($null -ne ($record = Invoke-MsiMember $view 'Fetch' InvokeMethod @())) {
        try {
            $name = Invoke-MsiMember $record 'StringData' GetProperty @(1)
            $properties[$name] = Invoke-MsiMember $record 'StringData' GetProperty @(2)
        } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }
    }
    foreach ($name in @('ProductCode', 'UpgradeCode', 'ProductVersion', 'ProductName', 'Manufacturer')) {
        if ([string]::IsNullOrWhiteSpace($properties[$name])) { throw "The MSI has no $name property: $MsiPath" }
    }
    $summary = Invoke-MsiMember $database 'SummaryInformation' GetProperty @(0)
    $template = [string](Invoke-MsiMember $summary 'Property' GetProperty @(7))
    if ([string]::IsNullOrWhiteSpace($template)) { throw "The MSI has no platform summary: $MsiPath" }
    [pscustomobject]@{
        ProductCode = $properties.ProductCode
        UpgradeCode = $properties.UpgradeCode
        ProductVersion = $properties.ProductVersion
        ReleaseVersion = $properties['GRATE_RELEASE_VERSION']
        ProductName = $properties.ProductName
        Manufacturer = $properties.Manufacturer
        Platform = $template.Split(';')[0].ToLowerInvariant()
        PackageCode = [string](Invoke-MsiMember $summary 'Property' GetProperty @(9))
        AllUsers = $properties['ALLUSERS']
        MsiInstallPerUser = $properties['MSIINSTALLPERUSER']
    }
} finally {
    foreach ($comObject in @($summary, $view, $database, $installer)) {
        if ($null -ne $comObject) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject) }
    }
}
