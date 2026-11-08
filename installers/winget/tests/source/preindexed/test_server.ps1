#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../SourceServer.ps1"
. "$PSScriptRoot/../SourceTestHelpers.ps1"

$directory = Join-Path ([IO.Path]::GetTempPath()) ('grate-preindexed-source-' + [guid]::NewGuid().ToString('N'))
$server = $null
$client = $null
$certificate = $null
$sourceFiles = @(
    'source.msix'
    'source2.msix'
    'packages/g/grate-devs.grate/123456/version.zip'
)

try {
    $root = "$directory/source"
    $assets = "$directory/assets"
    $null = New-Item -ItemType Directory "$root/packages/g/grate-devs.grate/123456", $assets -Force

    foreach ($file in $sourceFiles) {
        $sourcePath = [IO.Path]::GetFullPath((Join-Path $root $file))
        Set-Content -LiteralPath $sourcePath -Value "original bytes: $file" -Encoding utf8NoBOM -NoNewline
        Assert-SourceEqual (Get-SourceFilePath $root $assets "/$file" -Preindexed) $sourcePath 'Source relative paths retained'
    }
    $installerPath = [IO.Path]::GetFullPath((Join-Path $assets 'grate-2.1.7.msi'))
    Set-Content -LiteralPath $installerPath -Value 'original installer' -Encoding utf8NoBOM -NoNewline
    Assert-SourceEqual (Get-SourceFilePath $root $assets '/assets/grate-2.1.7.msi' -Preindexed) $installerPath 'Payload remains in asset directory'

    $rejectedPaths = @(
        '/../secret.pem'
        '/%2e%2e/secret.pem'
        '/assets/../secret.pem'
        '/assets/subdir/payload.msi'
        '/C:/secret.pem'
        '/..%5csecret.pem'
        '/x%00y'
    )
    foreach ($path in $rejectedPaths) {
        Assert-SourceEqual (Get-SourceFilePath $root $assets $path -Preindexed) $null "Invalid path rejected: $path"
    }

    Set-Content -LiteralPath "$directory/secret.pem" -Value 'test-only secret' -Encoding utf8NoBOM -NoNewline
    $linkChecked = $false

    try {
        $null = New-Item -ItemType SymbolicLink -Path "$assets/grate.msi" -Target "$directory/secret.pem" -ErrorAction Stop
        $linkChecked = $true
    } catch {
        if (!$IsWindows) {
            throw
        }
        Write-Host 'SKIP: symlink creation unavailable on this Windows host.'
    }
    if ($linkChecked) {
        Assert-SourceEqual (Get-SourceFilePath $root $assets '/assets/grate.msi' -Preindexed) $null 'Symlink cannot expose outside file'
    }

    $certificate = New-SourceTestCertificate $directory
    $client = New-SourceTestClient $certificate
    $serverArguments = @(
        '-Root', $root,
        '-Assets', $assets,
        '-Certificate', "$directory/cert.pem",
        '-PrivateKey', "$directory/key.pem"
    )
    $server = Start-SourceTestProcess "$PSScriptRoot/server.ps1" $serverArguments $directory $client '/source2.msix'

    foreach ($file in $sourceFiles) {
        Assert-SourceEqual (Invoke-SourceTestRequest $client $server.Url "/$file").Body "original bytes: $file" 'HTTPS source data is unchanged'
    }

    Assert-SourceEqual (Invoke-SourceTestRequest $client $server.Url '/assets/grate-2.1.7.msi').Body 'original installer' 'HTTPS installer is unchanged'
    $head = Invoke-SourceTestRequest $client $server.Url '/assets/grate-2.1.7.msi' $null 'HEAD'
    Assert-SourceEqual $head.Length 18L 'Asset HEAD length'
    Assert-SourceEqual $head.Body '' 'Asset HEAD body'

    $null = Invoke-SourceTestRequest $client $server.Url '/' $null 'GET' 404
    if ($linkChecked) {
        $null = Invoke-SourceTestRequest $client $server.Url '/assets/grate.msi' $null 'GET' 404
    }
    Write-Host 'PASS: preindexed source packages, nested paths, unchanged assets, HEAD and path isolation.'
} finally {
    Stop-SourceTestProcess $server
    if ($client) {
        $client.Dispose()
    }
    if ($certificate) {
        $certificate.Dispose()
    }

    Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
}
