#!/usr/bin/env pwsh
param(
    [string]$OutputDirectory = 'artifacts/slim-poc',
    [ValidateSet('cli', 'packaging')]
    [string]$Mode = 'cli'
)

$ErrorActionPreference = 'Stop'
# Readiness and cleanup inspect or intentionally ignore native failure codes.
# Required commands go through Invoke-PocCommand so their failures propagate.
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-PocCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        $failure = [Exception]::new("$FilePath failed with exit code $LASTEXITCODE.")
        $failure.Data['ExitCode'] = $LASTEXITCODE
        throw $failure
    }
}

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$output = [IO.Path]::GetFullPath($OutputDirectory, $repository)
$relativeOutput = [IO.Path]::GetRelativePath($repository, $output)
if ([IO.Path]::IsPathRooted($OutputDirectory) -or $relativeOutput -eq '.' -or
    $relativeOutput -eq '..' -or $relativeOutput.StartsWith('..' + [IO.Path]::DirectorySeparatorChar) -or
    (Test-Path -LiteralPath $output)) {
    throw 'Use a fresh repository-relative output directory.'
}
$relativeOutput = $relativeOutput.Replace('\', '/')
Get-Command docker -ErrorAction Stop | Out-Null
if ($Mode -eq 'packaging') {
    Get-Command python3 -ErrorAction Stop | Out-Null
}

$prefix = "grate-slim-poc-$PID-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$sqlserver = "$prefix-sqlserver"
$mariadb = "$prefix-mariadb"
$sdk = "$prefix-sdk"
$packager = "$prefix-packager"
$password = 'Grate_PoC_' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
$savedEnvironment = @{}
foreach ($name in @('GRATE_POC_SQLSERVER', 'GRATE_POC_MARIADB')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$exitCode = 0
Push-Location $repository
try {
    $null = Invoke-PocCommand docker @('network', 'create', $prefix)
    $sqlserverArguments = @(
        'run', '-d', '--rm', '--name', $sqlserver, '--network', $prefix, '--platform', 'linux/amd64',
        '-e', 'ACCEPT_EULA=Y', '-e', "MSSQL_SA_PASSWORD=$password", '-e', 'MSSQL_MEMORY_LIMIT_MB=2048',
        'mcr.microsoft.com/mssql/server:2022-latest@sha256:4402d880dd4c34bfa7d8705e56a86cd6c88da80a1f6bbbe741f999e76264a090'
    )
    $null = Invoke-PocCommand docker $sqlserverArguments
    $mariadbArguments = @(
        'run', '-d', '--rm', '--name', $mariadb, '--network', $prefix,
        '-e', "MYSQL_ROOT_PASSWORD=$password",
        'mariadb:10.4@sha256:22edfe1c78349f8cae88bbb5c2873b7e6c515be767c91c691308ce57445806f3'
    )
    $null = Invoke-PocCommand docker $mariadbArguments

    $ready = $false
    for ($attempt = 1; $attempt -le 90; $attempt++) {
        $sqlserverProbe = @(
            'exec', $sqlserver, 'sh', '-c',
            'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -l 2 -t 2 -Q "SELECT 1" -b'
        )
        & docker @sqlserverProbe 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            $mariadbProbe = @(
                'exec', $mariadb, 'sh', '-c',
                'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqladmin ping -uroot --silent --connect-timeout=2'
            )
            & docker @mariadbProbe 1>$null 2>$null
            if ($LASTEXITCODE -eq 0) {
                $ready = $true
                break
            }
        }
        if ($attempt -lt 90) {
            Start-Sleep -Seconds 2
        }
    }
    if (!$ready) {
        throw 'Disposable databases did not become ready within 90 readiness checks.'
    }

    $env:GRATE_POC_SQLSERVER = "Server=$sqlserver;Database={database};User ID=sa;Password=$password;TrustServerCertificate=true;Encrypt=true"
    $env:GRATE_POC_MARIADB = "Server=$mariadb;Database={database};User ID=root;Password=$password"
    $sdkArguments = @(
        'run', '-d', '--rm', '--name', $sdk, '--network', $prefix, '--platform', 'linux/amd64',
        '-v', "${repository}:/src", '-w', '/src', '-e', 'GRATE_POC_SQLSERVER', '-e', 'GRATE_POC_MARIADB',
        'mcr.microsoft.com/dotnet/sdk:11.0.100-rc.3@sha256:59d092a889fbad09c1a0b0c5dd072c6315125b0294a5cddfa48ec892f63b2ab3',
        'sleep', 'infinity'
    )
    $null = Invoke-PocCommand docker $sdkArguments

    if ($Mode -eq 'cli') {
        $driverArguments = @(
            'exec', $sdk, 'sh', '-c',
            'apt-get update -qq && apt-get install -y -qq python3 && python3 docs/design/slim-distributions-poc/verify.py --output "/src/$1"',
            'sh', $relativeOutput
        )
        Invoke-PocCommand docker $driverArguments
    } else {
        # Assemble the amd64 payload using the Docker host architecture on Ubuntu 24.04.
        $packagerArguments = @(
            'run', '-d', '--rm', '--name', $packager, '-v', "${repository}:/src", '-w', '/src',
            'mcr.microsoft.com/dotnet/sdk:10.0@sha256:747cbade5bfd918a175ac32f8f1d931edec2c7d0d5397a3de72eaef1ac1f66d2',
            'sleep', 'infinity'
        )
        $null = Invoke-PocCommand docker $packagerArguments
        $driverArguments = @(
            'docs/design/slim-distributions-poc/verify-packaging.py', '--output', $relativeOutput,
            '--sdk', $sdk, '--packager', $packager, '--network', $prefix
        )
        Invoke-PocCommand python3 $driverArguments
    }
} catch {
    if ($_.Exception.Data.Contains('ExitCode')) {
        $exitCode = [int]$_.Exception.Data['ExitCode']
    } else {
        $exitCode = 1
    }
    Write-Error -ErrorRecord $_ -ErrorAction Continue
} finally {
    try {
        $containers = @(& docker ps -aq --filter "label=io.grate.poc.network=$prefix" 2>$null)
        foreach ($container in $containers) {
            if (![string]::IsNullOrWhiteSpace($container)) {
                & docker rm -f $container 1>$null 2>$null
            }
        }
        & docker rm -f $packager $sdk $sqlserver $mariadb 1>$null 2>$null
        & docker network rm $prefix 1>$null 2>$null
    } finally {
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
        }
        Pop-Location
    }
}
if ($exitCode -ne 0) {
    exit $exitCode
}
