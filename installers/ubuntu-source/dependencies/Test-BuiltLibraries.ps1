#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DapperPackage,
    [Parameter(Mandatory)]
    [string]$MySqlConnectorPackage,
    [Parameter(Mandatory)]
    [string]$UbuntuFeedDirectory,
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    [string]$BuilderImage = 'grate-ubuntu-source:26.04',
    [string]$DatabaseImage = 'mariadb:10.4'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$output = [IO.Path]::GetFullPath($OutputDirectory)
$feed = (Resolve-Path -LiteralPath $UbuntuFeedDirectory).Path
if (Test-Path -LiteralPath $output) {
    throw 'Use a new OutputDirectory for fresh consumer source and package caches.'
}
New-Item -ItemType Directory -Path $output, "$output/local-feed", "$output/consumer" | Out-Null
Copy-Item -LiteralPath "$PSScriptRoot/consumer/Consumer.csproj", "$PSScriptRoot/consumer/Program.cs" -Destination "$output/consumer"
$inputs = @()
foreach ($path in @($DapperPackage, $MySqlConnectorPackage)) {
    $package = (Resolve-Path -LiteralPath $path).Path
    Copy-Item -LiteralPath $package -Destination "$output/local-feed"
    $inputs += @{
        package = $package
        sha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$inputs | ConvertTo-Json | Set-Content -LiteralPath "$output/package-inputs.json" -Encoding utf8
& docker image inspect --platform linux/arm64 $BuilderImage $DatabaseImage |
    Set-Content -LiteralPath "$output/images.json" -Encoding utf8
'<configuration><packageSources><clear/><add key="source-built-libraries" value="/work/local-feed"/><add key="ubuntu" value="/ubuntu-feed"/></packageSources></configuration>' |
    Set-Content -LiteralPath "$output/NuGet.Config" -Encoding utf8
$compile = @'
set -eu
cd /
dotnet restore /work/consumer/Consumer.csproj --configfile /work/NuGet.Config -p:NuGetAudit=false
dotnet build /work/consumer/Consumer.csproj --no-restore -c Release
'@
$buildArguments = @(
    'run', '--rm', '--pull=never', '--network=none', '--platform=linux/arm64',
    '--mount', "type=bind,src=$output,dst=/work",
    '--mount', "type=bind,src=$feed,dst=/ubuntu-feed,readonly",
    '--env', 'DOTNET_CLI_HOME=/tmp/consumer-home',
    '--env', 'NUGET_PACKAGES=/work/nuget-packages',
    '--env', 'NUGET_HTTP_CACHE_PATH=/tmp/consumer-http',
    '--env', 'DOTNET_CLI_TELEMETRY_OPTOUT=1',
    $BuilderImage, 'sh', '-ec', $compile
)
$buildArguments | ConvertTo-Json | Set-Content -LiteralPath "$output/build-arguments.json" -Encoding utf8
& docker @buildArguments 2>&1 | Tee-Object -FilePath "$output/build.log" | Out-Host

# Verify the consumer restored the supplied ZIPs and copied their actual DLLs.
# Package IDs/versions alone cannot distinguish a local rebuild from NuGet.org.
foreach ($identity in @(@{ Id = 'Dapper'; Version = '2.1.89' }, @{ Id = 'MySqlConnector'; Version = '2.6.2' })) {
    $id = $identity.Id
    $version = $identity.Version
    $package = Get-ChildItem -LiteralPath "$output/local-feed" -Filter "$id.$version.nupkg"
    $unpacked = "$output/inspected/$id"
    [IO.Compression.ZipFile]::ExtractToDirectory($package.FullName, $unpacked)
    $cached = "$output/nuget-packages/$($id.ToLowerInvariant())/$version/$($id.ToLowerInvariant()).$version.nupkg"
    if ((Get-FileHash -LiteralPath $package.FullName).Hash -cne (Get-FileHash -LiteralPath $cached).Hash) {
        throw "The consumer did not restore the supplied $id package bytes."
    }
    $originalDll = "$unpacked/lib/net10.0/$id.dll"
    $consumerDll = "$output/consumer/bin/Release/net10.0/$id.dll"
    if ((Get-FileHash -LiteralPath $originalDll).Hash -cne (Get-FileHash -LiteralPath $consumerDll).Hash) {
        throw "The consumer did not copy the supplied $id assembly bytes."
    }
}

$identifier = [Guid]::NewGuid().ToString('N')
$network = "grate-source-$identifier"
$database = "grate-source-db-$identifier"
$password = [Guid]::NewGuid().ToString('N')
$networkCreated = $false
$databaseCreated = $false
$succeeded = $false
try {
    & docker network create --internal --label "grate.source-probe=$identifier" $network | Out-Null
    $networkCreated = $true
    $databaseArguments = @(
        'run', '--detach', '--pull=never', '--platform=linux/arm64',
        '--name', $database, '--label', "grate.source-probe=$identifier",
        '--network', $network, '--network-alias=db',
        '--env', 'MYSQL_DATABASE=source_probe', '--env', 'MYSQL_USER=source_probe',
        '--env', "MYSQL_PASSWORD=$password", '--env', "MYSQL_ROOT_PASSWORD=$password",
        $DatabaseImage
    )
    & docker @databaseArguments | Out-Null
    $databaseCreated = $true
    $readyQuery = 'mysql --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" "$MYSQL_DATABASE" --execute="SELECT 1" --skip-column-names'
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        $PSNativeCommandUseErrorActionPreference = $false
        $null = & docker exec $database sh -ec $readyQuery 2>$null
        $ready = $LASTEXITCODE -eq 0
        $PSNativeCommandUseErrorActionPreference = $true
        if (!$ready) {
            Start-Sleep -Milliseconds 500
        }
    } while (!$ready -and [DateTime]::UtcNow -lt $deadline)
    if (!$ready) {
        throw 'Disposable MariaDB did not become ready within 120 seconds.'
    }
    $runtimeArguments = @(
        'run', '--rm', '--pull=never', '--platform=linux/arm64', '--network', $network,
        '--mount', "type=bind,src=$output,dst=/work,readonly",
        '--env', "GRATE_PROBE_PASSWORD=$password", $BuilderImage,
        'timeout', '60', 'dotnet', '/work/consumer/bin/Release/net10.0/Consumer.dll'
    )
    $runtimeArguments | ForEach-Object {
        if ($_ -like 'GRATE_PROBE_PASSWORD=*') {
            'GRATE_PROBE_PASSWORD=<redacted disposable credential>'
        }
        else {
            $_
        }
    } | ConvertTo-Json | Set-Content -LiteralPath "$output/runtime-arguments.json" -Encoding utf8
    & docker @runtimeArguments 2>&1 | Tee-Object -FilePath "$output/consumer.log" | Out-Host
    $query = 'mysql --batch --skip-column-names --user="$MYSQL_USER" --password="$MYSQL_PASSWORD" "$MYSQL_DATABASE" --execute="SELECT id, HEX(name), amount FROM probe ORDER BY id"'
    $independent = (& docker exec $database sh -ec $query) -join "`n"
    $independent | Set-Content -LiteralPath "$output/independent-query.txt" -Encoding utf8
    if ($independent.Trim() -cne "7`t5472C3B86E64656C616720272026203C`t123.45") {
        throw 'The independent MariaDB client did not see the expected single committed row and no rolled-back row.'
    }
    $succeeded = $true
}
finally {
    $PSNativeCommandUseErrorActionPreference = $false
    if ($databaseCreated) {
        & docker logs $database 2>&1 | Set-Content -LiteralPath "$output/database.log" -Encoding utf8
        & docker rm --force --volumes $database | Out-Null
    }
    if ($networkCreated) {
        & docker network rm $network | Out-Null
    }
    $PSNativeCommandUseErrorActionPreference = $true
    [ordered]@{
        passed = $succeeded
        platform = 'linux/arm64'
        checks = @('Supplied package and DLL hashes', 'Parameterized SQL', 'Typed Unicode/decimal mapping', 'Transaction rollback', 'Assembly identities', 'Independent MariaDB client query')
        scope = 'Framework-dependent library consumer; no claim about grate migration, trimming, packaging or archive approval'
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$output/result.json" -Encoding utf8
}
