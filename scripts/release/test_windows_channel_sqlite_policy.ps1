$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows_channel_common.ps1"

function Resolve-Fixture {
    param(
        [string]$Bundle,
        [string]$Native
    )

    [xml]$central = "<Project><ItemGroup><PackageVersion Include='SQLitePCLRaw.bundle_e_sqlite3' Version='$Bundle'/></ItemGroup></Project>"
    $reader = {
        param(
            $requested
        )
        if ($requested -cne $Bundle) {
            throw 'The resolver did not use the exact selected source package pin.'
        }
        "<package><metadata><id>SQLitePCLRaw.bundle_e_sqlite3</id><version>$Bundle</version><dependencies><dependency id='SQLite' version='$Native'/></dependencies></metadata></package>"
    }.GetNewClosure()
    Resolve-WindowsChannelSQLitePolicy -CentralPackages $central -ReadBundleNuspec $reader
}
foreach ($example in @(
    @{ Bundle = '3.0.2'; Native = '3.50.3' },
    @{ Bundle = '3.0.5'; Native = '3.53.4' },
    @{ Bundle = '3.1.0'; Native = '3.54.0' }
)) {
    $result = Resolve-Fixture -Bundle $example.Bundle -Native $example.Native
    if ($result.ExpectedSQLiteVersion -cne $example.Native -or $result.SQLiteBundleVersion -cne $example.Bundle) {
        throw 'The resolver substituted a current-workflow version for selected release package metadata.'
    }
}
# Historical/future values above are synthetic contract fixtures, not claims
# that those bundle versions really contain the sample native versions.
foreach ($bad in @('3.53.4&apos;; SELECT 1;', '3.53.4-preview', '[3.53.4,4.0.0)')) {
    $rejected = $false
    try {
        Resolve-Fixture -Bundle '3.0.5' -Native $bad | Out-Null
    } catch {
        $rejected = $true
    }
    if (!$rejected) {
        throw 'An unsafe, prerelease or ambiguous native SQLite version was accepted into probe SQL.'
    }
}
$rejected = $false
try {
    Resolve-WindowsChannelSQLitePolicy -CentralPackages ([xml]'<Project/>') -ReadBundleNuspec { throw 'No bundle should be fetched.' } | Out-Null
} catch {
    $rejected = $true
}
if (!$rejected) {
    throw 'Missing source SQLite policy was accepted.'
}
$rejected = $false
try {
    Resolve-WindowsChannelSQLitePolicy -CentralPackages ([xml]"<Project><ItemGroup><PackageVersion Include='SQLitePCLRaw.bundle_e_sqlite3' Version='3.0.5'/></ItemGroup></Project>") -ReadBundleNuspec {
        '<package><metadata><id>SQLitePCLRaw.bundle_e_sqlite3</id><version>3.0.5</version><dependencies><dependency id="SQLite" version="3.53.4"/><dependency id="SQLite" version="3.54.0"/></dependencies></metadata></package>'
    } | Out-Null
} catch {
    $rejected = $true
}
if (!$rejected) {
    throw 'Conflicting native dependency groups were accepted.'
}
Write-Output 'PASS: selected-source SQLite pins determine historical/current/future probe versions; missing, conflicting and SQL-unsafe versions rejected.'
