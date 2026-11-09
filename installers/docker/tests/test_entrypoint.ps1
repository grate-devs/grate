#!/usr/bin/env pwsh
. "$PSScriptRoot/../../../scripts/release/release_common.ps1"
. "$PSScriptRoot/../../../scripts/release/release_test_helpers.ps1"
if ($IsWindows) {
    throw 'This POSIX launcher fixture requires a Unix host with sh and PowerShell.'
}
$directory = Join-Path (New-TestDirectory) 'entrypoint with spaces'
$entrypoint = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../entrypoint.sh'))
$savedDirectory = [Environment]::CurrentDirectory
$savedEnvironment = @{}
foreach ($name in @('DATABASE_TYPE', 'VERSION', 'CREATE_DATABASE', 'ENVIRONMENT', 'TRANSACTION', 'APP_CONNSTRING')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, $null)
}
try {
    New-Item -ItemType Directory -Path $directory | Out-Null
    $pwsh = (Get-Process -Id $PID).Path
    $mock = Join-Path $directory 'grate'
    $code = "#!$pwsh`n[Console]::Write((ConvertTo-Json -InputObject @(`$args) -Compress))`n"
    Set-Content -LiteralPath $mock -Value $code -Encoding utf8NoBOM -NoNewline
    [IO.File]::SetUnixFileMode($mock,
        [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    [Environment]::CurrentDirectory = $directory
    $env:APP_CONNSTRING = 'Data Source=/output/database with spaces.db'

    Invoke-Test 'unset or empty database type preserves the compiled default' {
        foreach ($value in @($null, '')) {
            [Environment]::SetEnvironmentVariable('DATABASE_TYPE', $value)
            $result = Invoke-ReleaseProcess '/bin/sh' @($entrypoint) 10
            Assert-Equal 0 $result.ExitCode $result.ErrorText
            $arguments = @($result.Text | ConvertFrom-Json)
            Assert-Equal 0 @($arguments | Where-Object { $_.StartsWith('--databasetype') }).Count
            foreach ($expected in @('--version=1.0.0', '--createdatabase=true', '--environment=LOCAL', '--transaction=false')) {
                Assert-True ($arguments -ccontains $expected)
            }
        }
    }
    Invoke-Test 'environment and extra arguments preserve values and order' {
        $env:DATABASE_TYPE = 'sqlite'
        $env:VERSION = 'candidate 1'
        $env:CREATE_DATABASE = 'false'
        $env:ENVIRONMENT = 'local with spaces'
        $env:TRANSACTION = 'true'
        $extra = @('--databasetype=mariadb', '--folders', 'up=ddl with spaces')
        $result = Invoke-ReleaseProcess '/bin/sh' (@($entrypoint) + $extra) 10
        Assert-Equal 0 $result.ExitCode $result.ErrorText
        $arguments = @($result.Text | ConvertFrom-Json)
        foreach ($expected in @('--connstring=Data Source=/output/database with spaces.db', '--version=candidate 1', '--createdatabase=false', '--environment=local with spaces', '--transaction=true')) {
            Assert-True ($arguments -ccontains $expected)
        }
        Assert-Equal (@('--databasetype=sqlite') + $extra) @($arguments[-4..-1])
    }
    Invoke-Test 'missing connection string fails before launching grate' {
        $env:APP_CONNSTRING = $null
        $result = Invoke-ReleaseProcess '/bin/sh' @($entrypoint) 10
        Assert-True ($result.ExitCode -ne 0)
        Assert-Equal '' $result.Text
        Assert-True $result.ErrorText.Contains('APP_CONNSTRING')
    }
} finally {
    [Environment]::CurrentDirectory = $savedDirectory
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    Remove-Item -LiteralPath (Split-Path $directory -Parent) -Recurse -Force
}
Write-Host "PASS: $script:TestCount POSIX launcher scenarios."
