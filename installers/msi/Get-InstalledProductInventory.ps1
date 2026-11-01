#!/usr/bin/env pwsh
param (
    [Guid]$ProductCode = 'E281998A-D8A2-4926-AAA3-066EFA4B2E74'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows) { throw 'Native MSI product/context inventory requires Windows; this script does not install, repair or modify products.' }
. (Join-Path $PSScriptRoot 'WinGetMsiLifecycle.Assertions.ps1')

# Query documented MSI installation contexts rather than deriving scope from an
# ARP registry hive. Per-user MSI registrations can have HKLM uninstall entries.
# https://learn.microsoft.com/windows/win32/api/msi/nf-msi-msienumproductsexw
# https://learn.microsoft.com/windows/win32/api/msi/nf-msi-msigetproductinfoexw
if (!('Grate.Installers.NativeMsiInventory' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Grate.Installers
{
    public sealed class MsiPropertyRead
    {
        public string Value { get; set; }
        public uint ErrorCode { get; set; }
    }

    public sealed class MsiProductContext
    {
        public string ProductCode { get; set; }
        public uint Context { get; set; }
        public string UserSid { get; set; }
        public Dictionary<string, MsiPropertyRead> Properties { get; set; }
    }

    public static class NativeMsiInventory
    {
        [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint MsiEnumProductsExW(string productCode, string userSid, uint context, uint index,
            StringBuilder installedProductCode, out uint installedContext, StringBuilder installedUserSid, ref uint sidLength);

        [DllImport("msi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern uint MsiGetProductInfoExW(string productCode, string userSid, uint context, string property,
            StringBuilder value, ref uint valueLength);

        private static MsiPropertyRead ReadProperty(string productCode, string userSid, uint context, string property)
        {
            uint length = 0;
            uint status = MsiGetProductInfoExW(productCode, userSid, context, property, null, ref length);
            if (status != 0 && status != 234) { return new MsiPropertyRead { ErrorCode = status }; }
            var value = new StringBuilder(checked((int)length + 1));
            length = (uint)value.Capacity;
            status = MsiGetProductInfoExW(productCode, userSid, context, property, value, ref length);
            return new MsiPropertyRead { Value = status == 0 ? value.ToString() : null, ErrorCode = status };
        }

        public static MsiProductContext[] Enumerate(string productCode, string currentUserSid)
        {
            var result = new List<MsiProductContext>();
            // USERMANAGED=1, USERUNMANAGED=2, MACHINE=4. Never enumerate other
            // users or reinterpret machine SID S-1-5-18 as the calling user.
            foreach (uint context in new uint[] { 1, 2, 4 })
            {
                string requestedSid = context == 4 ? null : currentUserSid;
                for (uint index = 0; ; index++)
                {
                    var code = new StringBuilder(39);
                    var sid = new StringBuilder(256);
                    uint sidLength = (uint)sid.Capacity;
                    uint installedContext;
                    uint status = MsiEnumProductsExW(productCode, requestedSid, context, index, code, out installedContext, sid, ref sidLength);
                    if (status == 259) { break; } // ERROR_NO_MORE_ITEMS
                    if (status == 234)
                    {
                        sid = new StringBuilder(checked((int)sidLength + 1));
                        sidLength = (uint)sid.Capacity;
                        status = MsiEnumProductsExW(productCode, requestedSid, context, index, code, out installedContext, sid, ref sidLength);
                    }
                    if (status != 0) { throw new Win32Exception((int)status, "MsiEnumProductsExW failed for context " + context); }
                    var properties = new Dictionary<string, MsiPropertyRead>();
                    foreach (string name in new[] { "ProductState", "AssignmentType", "InstalledProductName", "VersionString", "Publisher", "LocalPackage" })
                    {
                        properties[name] = ReadProperty(code.ToString(), installedContext == 4 ? null : sid.ToString(), installedContext, name == "ProductState" ? "State" : name);
                    }
                    result.Add(new MsiProductContext { ProductCode = code.ToString(), Context = installedContext, UserSid = sid.ToString(), Properties = properties });
                }
            }
            return result.ToArray();
        }
    }
}
'@
}

$code = $ProductCode.ToString('B').ToUpperInvariant()
$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$contexts = @([Grate.Installers.NativeMsiInventory]::Enumerate($code, $userSid))
$registryEntries = foreach ($hiveName in @('CurrentUser', 'LocalMachine')) {
    foreach ($viewName in @('Registry64', 'Registry32')) {
        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$hiveName, [Microsoft.Win32.RegistryView]$viewName)
        $subKey = "Software\Microsoft\Windows\CurrentVersion\Uninstall\$code"
        $entry = $null
        try {
            $entry = $hive.OpenSubKey($subKey, $false)
            if ($entry) {
                $values = [ordered]@{ Hive = $hiveName; View = $viewName; SubKey = $subKey }
                foreach ($name in @('DisplayName', 'DisplayVersion', 'Publisher', 'WindowsInstaller', 'UninstallString', 'ModifyPath', 'SystemComponent', 'InstallLocation', 'WinGetPackageIdentifier', 'WinGetSourceIdentifier')) {
                    $values[$name] = $entry.GetValue($name)
                }
                [pscustomobject]$values
            }
        } finally {
            if ($entry) { $entry.Dispose() }
            $hive.Dispose()
        }
    }
}
$userData = foreach ($sid in @($userSid, 'S-1-5-18')) {
    $packed = ConvertTo-WinGetMsiProductRegistryKey $ProductCode
    $key = "Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Installer\UserData\$sid\Products\$packed\InstallProperties"
    if (Test-Path -LiteralPath $key) {
        [pscustomobject]@{ UserSid = $sid; RegistryKey = $key; Values = (Get-ItemProperty -LiteralPath $key | Select-Object DisplayName, DisplayVersion, Publisher, WindowsInstaller, LocalPackage, InstallSource, SystemComponent) }
    }
}
[pscustomobject]@{
    ProductCode = $code
    CurrentUserSid = $userSid
    InventoryApi = 'MsiEnumProductsExW + MsiGetProductInfoExW'
    Contexts = $contexts
    RegistryEntries = @($registryEntries)
    InstallerUserData = @($userData)
}
