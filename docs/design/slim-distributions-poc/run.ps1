#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$OutputDirectory = 'artifacts/slim-poc',

    [Parameter(Position = 1)]
    [ValidateSet('cli', 'packaging', IgnoreCase = $false)]
    [string]$Mode = 'cli'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repository = (Resolve-Path -LiteralPath "$PSScriptRoot/../../..").Path
if ([IO.Path]::IsPathRooted($OutputDirectory) -or (Test-Path -LiteralPath (Join-Path $repository $OutputDirectory))) {
    throw 'Use a fresh repository-relative output directory.'
}
Get-Command docker -ErrorAction Stop | Out-Null
if ($Mode -eq 'packaging') {
    Get-Command python3 -ErrorAction Stop | Out-Null
}

$prefix = "grate-slim-poc-$PID"
$sqlserver = "$prefix-sqlserver"
$mariadb = "$prefix-mariadb"
$sdk = "$prefix-sdk"
$packager = "$prefix-packager"
$password = 'Grate_PoC_' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
$originalEnvironment = @{}
foreach ($name in @('GRATE_POC_SQLSERVER', 'GRATE_POC_MARIADB')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$exitCode = 0
Push-Location -LiteralPath $repository
try {
    & docker network create $prefix | Out-Null
    $sqlArguments = @(
        'run', '-d', '--rm', '--name', $sqlserver, '--network', $prefix, '--platform', 'linux/amd64',
        '-e', 'ACCEPT_EULA=Y', '-e', "MSSQL_SA_PASSWORD=$password", '-e', 'MSSQL_MEMORY_LIMIT_MB=2048',
        'mcr.microsoft.com/mssql/server:2022-latest@sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090'
    )
    & docker @sqlArguments | Out-Null
    $mariaArguments = @(
        'run', '-d', '--rm', '--name', $mariadb, '--network', $prefix,
        '-e', "MYSQL_ROOT_PASSWORD=$password",
        'mariadb:10.4@sha256:22edfe1c78349f8cae88bbb5c2873b7e6c515be767c91c691308ce57445806f3'
    )
    & docker @mariaArguments | Out-Null

    for ($attempt = 1; $attempt -le 90; $attempt++) {
        $PSNativeCommandUseErrorActionPreference = $false
        try {
            & docker exec $sqlserver sh -c 'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -l 2 -t 2 -Q "SELECT 1" -b' > $null 2> $null
            $ready = $LASTEXITCODE -eq 0
            if ($ready) {
                & docker exec $mariadb sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqladmin ping -uroot --silent --connect-timeout=2' > $null 2> $null
                $ready = $LASTEXITCODE -eq 0
            }
        }
        finally {
            $PSNativeCommandUseErrorActionPreference = $true
        }
        if ($ready) {
            break
        }
        if ($attempt -eq 90) {
            throw 'Disposable databases did not become ready within 90 readiness checks.'
        }
        Start-Sleep -Seconds 2
    }

    $env:GRATE_POC_SQLSERVER = "Server=$sqlserver;Database={database};User ID=sa;Password=$password;TrustServerCertificate=true;Encrypt=true"
    $env:GRATE_POC_MARIADB = "Server=$mariadb;Database={database};User ID=root;Password=$password"
    $sdkArguments = @(
        'run', '-d', '--rm', '--name', $sdk, '--network', $prefix, '--platform', 'linux/amd64',
        '-v', "${repository}:/src", '-w', '/src', '-e', 'GRATE_POC_SQLSERVER', '-e', 'GRATE_POC_MARIADB',
        'mcr.microsoft.com/dotnet/sdk:11.0.100-rc.3@sha256:59d092a889fbad09c1a0b0c5dd072c6315125b0294a5cddfa48ec892f63b2ab3',
        'sleep', 'infinity'
    )
    & docker @sdkArguments | Out-Null
    if ($Mode -eq 'cli') {
        & docker exec $sdk sh -c 'apt-get update -qq && apt-get install -y -qq python3 && python3 docs/design/slim-distributions-poc/verify.py --output "/src/$1"' sh $OutputDirectory
    }
    else {
        # Wrap amd64 payloads using the Docker host architecture, as before.
        $packagerArguments = @(
            'run', '-d', '--rm', '--name', $packager,
            '-v', "${repository}:/src", '-w', '/src',
            'mcr.microsoft.com/dotnet/sdk:10.0@sha256:747cbade5bfd918a175ac32f8f1d931edec2c7d0d5397a3de72eaef1ac1f66d2',
            'sleep', 'infinity'
        )
        & docker @packagerArguments | Out-Null
        & python3 docs/design/slim-distributions-poc/verify-packaging.py --output $OutputDirectory --sdk $sdk --packager $packager --network $prefix
    }
}
catch [System.Management.Automation.NativeCommandExitException] {
    $exitCode = $_.Exception.ExitCode
    Write-Error -ErrorRecord $_ -ErrorAction Continue
}
finally {
    # Cleanup must not replace the original native failure code.
    $PSNativeCommandUseErrorActionPreference = $false
    $containers = @(& docker ps -aq --filter "label=io.grate.poc.network=$prefix" 2> $null)
    foreach ($container in $containers) {
        if ($container) {
            & docker rm -f $container > $null 2> $null
        }
    }
    & docker rm -f $packager $sdk $sqlserver $mariadb > $null 2> $null
    & docker network rm $prefix > $null 2> $null
    foreach ($name in $originalEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], 'Process')
    }
    Pop-Location
}
if ($exitCode -ne 0) {
    exit $exitCode
}
