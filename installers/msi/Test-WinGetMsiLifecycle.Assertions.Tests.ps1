#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WinGetMsiLifecycle.Assertions.ps1')

function Assert-Rejected([scriptblock]$Action, [string]$ExpectedMessage) {
    try { & $Action } catch {
        if ($_.Exception.Message -like $ExpectedMessage) { return }
        throw
    }
    throw "Expected rejection: $ExpectedMessage"
}
function Ordinary([int]$ExitCode, [string]$Version, [string]$Hash) {
    Get-WinGetMsiOrdinaryUpdateOutcome -ExitCode $ExitCode -RegisteredVersion $Version -OldVersion '2.1.6' -NewVersion '2.1.7' -InstalledHash $Hash -OldHash 'old' -NewHash 'new'
}
if ((Ordinary 1638 '2.1.6' 'old') -ne 'Rejected1638') { throw 'MSI 1638 must remain an explicit rejected-upgrade observation.' }
if ((Ordinary 0 '2.1.6' 'old') -ne 'NoUpgrade') { throw 'A successful exit without changed registration/payload is not an upgrade.' }
if ((Ordinary 0 '2.1.7' 'new') -ne 'Upgraded') { throw 'A verified replacement must be recognized.' }
if ((Ordinary 3010 '2.1.7' 'new') -ne 'Upgraded') { throw 'A verified replacement that requests reboot must be recognized.' }
Assert-Rejected { Ordinary 0 '2.1.7' 'old' } '*unexpected exit code/state*'
Assert-Rejected { Ordinary 1638 '2.1.7' 'new' } '*unexpected exit code/state*'
Assert-Rejected { Ordinary 1603 '2.1.6' 'old' } '*unexpected exit code/state*'

$arp = [pscustomobject]@{ DisplayName = 'grate'; Publisher = 'erikbra'; DisplayVersion = '2.1.7' }
Assert-WinGetMsiRegistration -State 5 -Version '2.1.7' -AssignmentType 0 -Arp $arp -ExpectedVersion '2.1.7'
Assert-Rejected { Assert-WinGetMsiRegistration -State 5 -Version '2.1.7' -AssignmentType 1 -Arp $arp -ExpectedVersion '2.1.7' } '*per-user MSI registration*'
$arp.DisplayVersion = '2.1.6'
Assert-Rejected { Assert-WinGetMsiRegistration -State 5 -Version '2.1.7' -AssignmentType 0 -Arp $arp -ExpectedVersion '2.1.7' } '*ARP entry*'
Assert-Rejected { Assert-WinGetMsiRegistration -State -1 -Version '2.1.7' -AssignmentType 0 -Arp $arp -ExpectedVersion '2.1.7' } '*product state*'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('winget-msi-assertions-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $fixture | Out-Null
try {
    $data = Join-Path $fixture 'user-data.txt'
    'Original data' | Set-Content $data
    $files = @{ $data = (Get-FileHash $data -Algorithm SHA256).Hash }
    Assert-WinGetMsiProtectedFiles $files
    'Changed data' | Set-Content $data
    Assert-Rejected { Assert-WinGetMsiProtectedFiles $files } '*changed protected user data*'
    Remove-Item $data
    Assert-Rejected { Assert-WinGetMsiProtectedFiles $files } '*removed protected user data*'

    # Minimal synthetic PE headers exercise architecture discrimination, not
    # executable validity. Native CI executes real release payloads separately.
    $pe = Join-Path $fixture 'fixture.exe'
    foreach ($architecture in @('x64', 'arm64')) {
        $bytes = [byte[]]::new(134)
        [BitConverter]::GetBytes([uint16]0x5A4D).CopyTo($bytes, 0)
        [BitConverter]::GetBytes([int]128).CopyTo($bytes, 0x3c)
        [BitConverter]::GetBytes([uint32]0x00004550).CopyTo($bytes, 128)
        $machine = if ($architecture -eq 'x64') { 0x8664 } else { 0xAA64 }
        [BitConverter]::GetBytes([uint16]$machine).CopyTo($bytes, 132)
        [IO.File]::WriteAllBytes($pe, $bytes)
        Assert-WinGetMsiPayloadArchitecture $pe $architecture
        $other = if ($architecture -eq 'x64') { 'arm64' } else { 'x64' }
        Assert-Rejected { Assert-WinGetMsiPayloadArchitecture $pe $other } '*does not match native*'
    }
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
Write-Host 'PASS: MSI upgrade outcome classification, ARP/context, data preservation and PE architecture assertions.'
