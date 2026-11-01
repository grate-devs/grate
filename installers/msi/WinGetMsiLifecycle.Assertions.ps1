function Assert-WinGetMsiPayload {
    param([string]$InstalledExecutable, [string]$ExpectedExecutable, [string]$ExpectedVersion)
    if (!(Test-Path -LiteralPath $InstalledExecutable -PathType Leaf)) { throw 'The installed grate executable is missing.' }
    if ((Get-FileHash -LiteralPath $InstalledExecutable -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $ExpectedExecutable -Algorithm SHA256).Hash) {
        throw 'The installed executable does not match the expected release payload.'
    }
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($InstalledExecutable)
    $actual = [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart)
    $expected = [version]$ExpectedVersion
    if ($actual.Major -ne $expected.Major -or $actual.Minor -ne $expected.Minor -or $actual.Build -ne $expected.Build) {
        throw "The installed executable file version $actual does not match MSI version $ExpectedVersion."
    }
}

function Assert-WinGetMsiRegistration {
    param([int]$State, [string]$Version, [int]$AssignmentType, $Arp, [string]$ExpectedVersion)
    if ($State -ne 5) { throw "Expected installed MSI product state 5, got $State." }
    if ($Version -ne $ExpectedVersion) { throw "Expected registered MSI version $ExpectedVersion, got $Version." }
    if ($AssignmentType -ne 0) { throw "Expected per-user MSI registration, got assignment type $AssignmentType." }
    if (!$Arp -or $Arp.DisplayName -ne 'grate' -or $Arp.Publisher -ne 'erikbra' -or $Arp.DisplayVersion -ne $ExpectedVersion) {
        throw 'The per-user ARP entry does not match the expected product, publisher and version.'
    }
}

function Get-WinGetMsiOrdinaryUpdateOutcome {
    param([int]$ExitCode, [string]$RegisteredVersion, [string]$OldVersion, [string]$NewVersion, [string]$InstalledHash, [string]$OldHash, [string]$NewHash)
    if ($ExitCode -in @(0, 3010) -and $RegisteredVersion -eq $NewVersion -and $InstalledHash -eq $NewHash) {
        return 'Upgraded'
    }
    if ($RegisteredVersion -eq $OldVersion -and $InstalledHash -eq $OldHash) {
        if ($ExitCode -eq 1638) { return 'Rejected1638' }
        if ($ExitCode -in @(0, 3010)) { return 'NoUpgrade' }
    }
    throw "Ordinary MSI update has unexpected exit code/state: exit=$ExitCode, registeredVersion=$RegisteredVersion."
}

function Assert-WinGetMsiProtectedFiles {
    param([System.Collections.IDictionary]$Files)
    foreach ($path in $Files.Keys) {
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Installer removed protected user data: $path" }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Files[$path]) {
            throw "Installer changed protected user data: $path"
        }
    }
}

function Assert-WinGetMsiPayloadArchitecture {
    param([string]$Executable, [ValidateSet('x64', 'arm64')][string]$Architecture)
    $stream = [IO.File]::OpenRead($Executable)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "The payload is not a PE executable: $Executable" }
        $stream.Position = 0x3c
        $offset = $reader.ReadInt32()
        if ($offset -lt 0 -or $offset -gt $stream.Length - 6) { throw 'The payload has an invalid PE header offset.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'The payload has an invalid PE signature.' }
        $machine = $reader.ReadUInt16()
        $expected = if ($Architecture -eq 'x64') { 0x8664 } else { 0xAA64 }
        if ($machine -ne $expected) { throw "The payload PE machine $machine does not match native $Architecture." }
    } finally { $reader.Dispose() }
}
