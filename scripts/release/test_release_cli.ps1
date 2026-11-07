#!/usr/bin/env pwsh
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
$directory = New-TestDirectory
$saved = @{}
$environment = @{ EXPECTED_DIGEST='sha256:bafebd36189ad3688b7b3915ea55d461e0bfcfbdde11e54b0a123999fb6be50f'; DOCKER_TAGS="gratedevs/grate:2.3.4`nerikbra/grate:2.3.4";DOCKER_HUB_USER='';DOCKER_HUB_TOKEN='';GRATE_CLI_FAILURE='' }
foreach ($key in $environment.Keys) { $saved[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,$environment[$key]) }
try {
    # Isolate the external registry/tool boundary while exercising the real CLI
    # parameter binding, imports, mode dispatch, journaling and exit codes.
    foreach ($file in @('release_common.ps1','docker_copy_common.ps1','publish_docker_archive.ps1','copy_docker_release.ps1')) { Copy-Item -LiteralPath "$PSScriptRoot/$file" -Destination $directory }
    $fake = @'
function Invoke-Skopeo {
    param([string[]]$Arguments,[string]$Operation)
    if ($env:GRATE_CLI_FAILURE) { throw 'SECRET_RESPONSE' }
    if ($Operation -cne 'archive inspection') { throw 'Unexpected native operation.' }
    ,[Text.Encoding]::UTF8.GetBytes('{"schemaVersion":2}')
}
function Get-ExistingDigest { return $null }
'@
    [IO.File]::AppendAllText("$directory/release_common.ps1", "`n$fake`n")
    [IO.File]::WriteAllText("$directory/image.tar", 'fixture archive')
    [IO.File]::WriteAllText("$directory/auth.json", '{}')
    $pwsh = (Get-Process -Id $PID).Path
    Invoke-Test 'archive CLI binds report and dispatches verify/preflight without credentials' {
        foreach ($mode in @('-VerifyOnly','-PreflightOnly')) {
            $report = "$directory/$mode.json"
            & $pwsh -NoLogo -NoProfile -File "$directory/publish_docker_archive.ps1" $mode -Archive "$directory/image.tar" -Report $report
            Assert-Equal 0 $LASTEXITCODE
            Assert-Equal 'verified' (Get-Content -LiteralPath $report -Raw | ConvertFrom-Json).status
        }
    }
    Invoke-Test 'archive CLI rejects conflicting modes and publication without authfile' {
        foreach ($arguments in @(@('-VerifyOnly','-PreflightOnly'),@())) {
            & $pwsh -NoLogo -NoProfile -File "$directory/publish_docker_archive.ps1" @arguments -Archive "$directory/image.tar" -Report "$directory/invalid.json" *> $null
            Assert-True ($LASTEXITCODE -ne 0) 'Invalid mode/authfile selection must fail.'
        }
        Assert-True (!(Test-Path -LiteralPath "$directory/invalid.json")) 'Invalid CLI selection must not start publication.'
    }
    Invoke-Test 'archive and compatibility CLI redact unexpected dependency failures' {
        $env:GRATE_CLI_FAILURE='true'
        $env:DOCKER_HUB_USER='test-user'; $env:DOCKER_HUB_TOKEN='SECRET_TOKEN'
        foreach ($name in @('publish_docker_archive','copy_docker_release')) {
            $report = "$directory/$name.json"
            $arguments = if ($name -ceq 'publish_docker_archive') { @('-VerifyOnly','-Archive',"$directory/image.tar") } else { @('-SourceAuthfile',"$directory/auth.json") }
            $result = & $pwsh -NoLogo -NoProfile -File "$directory/$name.ps1" @arguments -Report $report 2>&1
            Assert-True ($LASTEXITCODE -ne 0 -and ($result -join "`n") -cnotmatch 'SECRET_RESPONSE|SECRET_TOKEN') 'Do not leak dependency output or credentials.'
            $content = Get-Content -LiteralPath $report -Raw
            Assert-True ($content -cnotmatch 'SECRET_RESPONSE|SECRET_TOKEN') 'Do not leak details into journal.'
            Assert-Equal 'failed' ($content | ConvertFrom-Json).status
        }
    }
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    Remove-Item -LiteralPath $directory -Recurse -Force
}
Write-Host "PASS: $script:TestCount release CLI scenarios."
