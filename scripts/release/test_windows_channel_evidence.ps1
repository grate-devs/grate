$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('channel-evidence-tests-' + [Guid]::NewGuid().ToString('N'))
$commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$records = @(foreach ($profile in @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')) {
    foreach ($case in @('zip/x86', 'zip/x64', 'zip/arm64', 'wix/x64', 'wix/arm64', 'chocolatey/x64')) {
        $parts = $case.Split('/')
        [pscustomobject]@{
            Channel = if ($parts[0] -eq 'chocolatey') { 'chocolatey' } else { 'winget' }
            InstallerType = if ($parts[0] -eq 'chocolatey') { 'zip' } else { $parts[0] }
            Architecture = $parts[1]
            Distribution = $profile
            Version = '2.3.0'
            ReleaseRunId = '12345'
            ValidationRunId = '67890'
            SourceCommit = $commit
            Status = 'passed'
            LegacyMigration = if ($profile -eq 'All') { 'passed; actual public 2.0.0 to final release through private PreIndexed source' } else { 'not applicable; separate slim identity' }
        }
    }
})
function Write-Fixture {
    param($Items)
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    for ($index = 0; $index -lt $Items.Count; $index++) {
        $directory = Join-Path $root "lane-$index"
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $Items[$index] | ConvertTo-Json | Set-Content -LiteralPath "$directory/verification.json" -Encoding utf8NoBOM
    }
}
function Test-Fixture {
    param([switch]$Reject)
    $rejected = $false
    try {
        & "$PSScriptRoot/verify_windows_channel_evidence.ps1" -EvidenceDirectory $root -Version '2.3.0' -ReleaseRunId '12345' -ValidationRunId '67890' -SourceCommit $commit -OutputPath "$root/gate.json" | Out-Null
    } catch {
        $rejected = $true
    }
    if ($rejected -ne $Reject.IsPresent) {
        throw "The channel evidence gate rejection was $rejected; expected $($Reject.IsPresent)."
    }
}
try {
    Write-Fixture $records
    Test-Fixture
    Write-Fixture @($records | Select-Object -Skip 1)
    Test-Fixture -Reject
    $duplicate = @($records | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
    $duplicate[1] = $duplicate[0]
    Write-Fixture $duplicate
    Test-Fixture -Reject
    foreach ($field in @('Status', 'SourceCommit', 'LegacyMigration')) {
        $changed = @($records | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
        $changed[0].$field = 'wrong'
        Write-Fixture $changed
        Test-Fixture -Reject
    }
    Write-Output 'PASS: complete native evidence accepted; missing/duplicate/failed/wrong-source/unexecuted-legacy cases rejected.'
} finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
