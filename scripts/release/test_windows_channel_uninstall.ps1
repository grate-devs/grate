$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows_channel_common.ps1"

function Assert-UninstallArguments {
    param([string[]]$Arguments, [string]$Selector, [string]$Identity)

    if ($Arguments[0] -cne 'uninstall' -or $Arguments[1] -cne $Selector -or $Arguments[2] -cne $Identity) {
        throw 'Uninstall did not select the exact tested installation.'
    }
    foreach ($required in @('--silent', '--disable-interactivity', '--accept-source-agreements')) {
        if (@($Arguments | Where-Object { $_ -ceq $required }).Count -ne 1) {
            throw "Uninstall is missing its required noninteractive option: $required"
        }
    }
}
$msi = @(Get-WindowsChannelUninstallArguments -InstallerType wix -ManifestDirectory 'C:/candidate/manifests')
Assert-UninstallArguments -Arguments $msi -Selector '--manifest' -Identity 'C:/candidate/manifests'
$portable = @(Get-WindowsChannelUninstallArguments -InstallerType zip -ManifestDirectory 'C:/candidate/manifests' -PortableProductCode 'LocalPortableRegistration')
Assert-UninstallArguments -Arguments $portable -Selector '--product-code' -Identity 'LocalPortableRegistration'
$rejected = $false
try {
    Get-WindowsChannelUninstallArguments -InstallerType zip -ManifestDirectory 'C:/candidate/manifests' | Out-Null
} catch {
    $rejected = $true
}
if (!$rejected) {
    throw 'Portable uninstall accepted an unknown registration.'
}
# Demonstrate that the assertions reject the observed faulty argument vector.
$observedRegressionRejected = $false
try {
    Assert-UninstallArguments -Arguments @($msi | Where-Object { $_ -cne '--accept-source-agreements' }) -Selector '--manifest' -Identity 'C:/candidate/manifests'
} catch {
    $observedRegressionRejected = $_.Exception.Message -like '*--accept-source-agreements*'
}
if (!$observedRegressionRejected) {
    throw 'The source-agreement regression was not detected by its intended assertion.'
}
Write-Output 'PASS: MSI and portable uninstall select the exact installation and accept required source agreements noninteractively; observed missing-flag regression rejected.'
