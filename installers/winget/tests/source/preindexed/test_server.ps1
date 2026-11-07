#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../SourceServer.ps1"
. "$PSScriptRoot/../SourceTestHelpers.ps1"
$directory = Join-Path ([IO.Path]::GetTempPath()) ('grate-preindexed-source-' + [guid]::NewGuid().ToString('N'))
$server = $null; $client = $null; $certificate = $null
try {
    $root = "$directory/source"; $assets = "$directory/assets"
    $null = New-Item -ItemType Directory "$root/packages/g/grate-devs.grate/123456", $assets -Force
    foreach ($file in @('source.msix','source2.msix','packages/g/grate-devs.grate/123456/version.zip')) {
        [IO.File]::WriteAllText("$root/$file", "original bytes: $file")
        Assert-SourceEqual (Get-SourceFilePath $root $assets "/$file" -Preindexed) "$root/$file" 'Source relative paths retained'
    }
    [IO.File]::WriteAllText("$assets/grate-2.1.7.msi", 'original installer')
    Assert-SourceEqual (Get-SourceFilePath $root $assets '/assets/grate-2.1.7.msi' -Preindexed) "$assets/grate-2.1.7.msi" 'Payload remains in asset directory'
    foreach ($path in @('/../secret.pem','/%2e%2e/secret.pem','/assets/../secret.pem','/assets/subdir/payload.msi','/C:/secret.pem','/..%5csecret.pem','/x%00y')) {
        Assert-SourceEqual (Get-SourceFilePath $root $assets $path -Preindexed) $null "Invalid path rejected: $path"
    }
    [IO.File]::WriteAllText("$directory/secret.pem", 'test-only secret')
    $linkChecked = $false
    try {
        $null = New-Item -ItemType SymbolicLink -Path "$assets/grate.msi" -Target "$directory/secret.pem" -ErrorAction Stop
        $linkChecked = $true
    } catch { if (!$IsWindows) { throw }; Write-Host 'SKIP: symlink creation unavailable on this Windows host.' }
    if ($linkChecked) { Assert-SourceEqual (Get-SourceFilePath $root $assets '/assets/grate.msi' -Preindexed) $null 'Symlink cannot expose outside file' }

    $certificate = New-SourceTestCertificate $directory; $client = New-SourceTestClient $certificate
    $server = Start-SourceTestProcess "$PSScriptRoot/server.ps1" @('-Root',$root,'-Assets',$assets,'-Certificate',"$directory/cert.pem",'-PrivateKey',"$directory/key.pem") $directory $client '/source2.msix'
    foreach ($file in @('source.msix','source2.msix','packages/g/grate-devs.grate/123456/version.zip')) {
        Assert-SourceEqual (Invoke-SourceTestRequest $client $server.Url "/$file").Body "original bytes: $file" 'HTTPS source data is unchanged'
    }
    Assert-SourceEqual (Invoke-SourceTestRequest $client $server.Url '/assets/grate-2.1.7.msi').Body 'original installer' 'HTTPS installer is unchanged'
    $head = Invoke-SourceTestRequest $client $server.Url '/assets/grate-2.1.7.msi' $null 'HEAD'
    Assert-SourceEqual $head.Length 18L 'Asset HEAD length'; Assert-SourceEqual $head.Body '' 'Asset HEAD body'
    $null = Invoke-SourceTestRequest $client $server.Url '/' $null 'GET' 404
    if ($linkChecked) { $null = Invoke-SourceTestRequest $client $server.Url '/assets/grate.msi' $null 'GET' 404 }
    Write-Host 'PASS: preindexed source packages, nested paths, unchanged assets, HEAD and path isolation.'
} finally {
    Stop-SourceTestProcess $server
    if ($client) { $client.Dispose() }; if ($certificate) { $certificate.Dispose() }
    Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
}
