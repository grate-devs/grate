#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Distribution.Common.ps1"
Import-Module powershell-yaml -RequiredVersion 0.4.12
. "$PSScriptRoot/../release/workflow_test_helpers.ps1"
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workflow = Read-Workflow 'ci.yml'
$integration = Get-Content -LiteralPath "$repository/.github/workflows/integration-tests.yml" -Raw | ConvertFrom-Yaml
$expected = @{
    Sqlite = 'SQLite'
    SqlServer = 'SQLServer'
    SqlServerCaseSensitive = 'SQLServer'
    PostgreSQL = 'PostgreSQL'
    MariaDB = 'MariaDB'
    Oracle = 'Oracle'
}
$lanes = @($workflow.jobs.'cli-distributions'.strategy.matrix.include)
if ($lanes.Count -ne 12) {
    throw 'Require all six database categories against both All and the matching slim CLI.'
}
foreach ($database in $expected.Keys) {
    foreach ($distribution in @('All', $expected[$database])) {
        $matches = @($lanes | Where-Object { $_.database -ceq $database -and $_.distribution -ceq $distribution })
        if ($matches.Count -ne 1) {
            throw "Missing or duplicate CLI lane: $distribution / $database."
        }
    }
}
$cliJob = $workflow.jobs.'cli-distributions'
$setup = $cliJob.steps | Where-Object { $_.uses -like 'actions/setup-dotnet@*' }
$sdk = (Get-Content -LiteralPath "$repository/global.json" -Raw | ConvertFrom-Json).sdk.version
$sdkVersions = @($setup.with.'dotnet-version' -split '\r?\n' | ForEach-Object { $_.Trim() })
foreach ($required in @('8.0.x', '9.0.x', '10.0.x', $sdk)) {
    if ($sdkVersions -cnotcontains $required) {
        throw "Missing explicit supported SDK $required in the CLI database job."
    }
}
if ($cliJob.Contains('continue-on-error') -or $cliJob.Contains('if')) {
    throw 'Distribution tests must not be optional.'
}
$testStep = @($cliJob.steps | Where-Object name -EQ 'Test published CLI and installed tool against database')
if ($testStep.Count -ne 1 -or !$testStep[0].run.Contains('-Distribution ''${{ matrix.distribution }}''') -or
    !$testStep[0].run.Contains('-Database ''${{ matrix.database }}''')) {
    throw 'The database suite must receive its matrix distribution and database.'
}
$integrationJob = $integration.jobs.'cli-database-integration-tests'
if ($integrationJob.Contains('continue-on-error') -or @($integrationJob.strategy.matrix.variant).Count -ne 2) {
    throw 'All and slim version-matrix tests must propagate failures.'
}
foreach ($entry in $integrationJob.strategy.matrix.database) {
    if ($entry.distribution -cne $expected[$entry.type]) {
        throw "Incorrect version-matrix distribution for $($entry.name)."
    }
}
$buildProfiles = @($integration.jobs.'build-standalone'.strategy.matrix.distribution | Sort-Object)
if (($buildProfiles -join ',') -cne 'All,MariaDB,Oracle,PostgreSQL,SQLite,SQLServer') {
    throw 'Integration CLI artifacts must include all six profiles.'
}

function Assert-Rejected {
    param(
        [scriptblock]$Action,
        [string]$MessagePattern = '.'
    )

    $rejected = $false
    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw
        }
        $rejected = $true
    }
    if (!$rejected) {
        throw 'Expected the incorrect artifact or suite mapping to be rejected.'
    }
}

# Independent package fixtures distinguish missing selected clients and leaked
# omitted clients, including an All artifact substituted into a slim lane.
$libraries = @{
    SQLite = @('grate.sqlite/1', 'Microsoft.Data.Sqlite/1', 'SQLitePCLRaw.bundle_e_sqlite3/1', 'SQLite/1')
    SQLServer = @('grate.sqlserver/1', 'Microsoft.Data.SqlClient/1', 'Microsoft.Data.SqlClient.Extensions.Azure/1')
    MariaDB = @('grate.mariadb/1', 'MySqlConnector/1')
    PostgreSQL = @('grate.postgresql/1', 'Npgsql/1')
    Oracle = @('grate.oracle/1', 'Oracle.ManagedDataAccess.Core/1')
}
$all = @{}
foreach ($profile in $libraries.Keys) {
    $fixture = @{}
    foreach ($library in $libraries[$profile]) {
        $fixture[$library] = @{}
        $all[$library] = @{}
    }
    Assert-DistributionDependencies -Distribution $profile -Dependencies @{ libraries = $fixture }
    foreach ($library in $libraries[$profile]) {
        $missing = $fixture.Clone()
        $missing.Remove($library)
        Assert-Rejected { Assert-DistributionDependencies -Distribution $profile -Dependencies @{ libraries = $missing } }
    }
    $leaked = $fixture.Clone()
    $other = if ($profile -eq 'Oracle') { 'grate.sqlite/1' } else { 'Oracle.ManagedDataAccess.Core/1' }
    $leaked[$other] = @{}
    Assert-Rejected { Assert-DistributionDependencies -Distribution $profile -Dependencies @{ libraries = $leaked } }
    if ($profile -ne 'SQLServer') {
        $leakedAzure = $fixture.Clone()
        $leakedAzure['Microsoft.Data.SqlClient.Extensions.Azure/1'] = @{}
        Assert-Rejected -MessagePattern 'dependency mismatch for Microsoft\.Data\.SqlClient\.Extensions\.Azure ' -Action {
            Assert-DistributionDependencies -Distribution $profile -Dependencies @{ libraries = $leakedAzure }
        }
    }
}
Assert-DistributionDependencies -Distribution All -Dependencies @{ libraries = $all }
$missingAzure = $all.Clone()
$missingAzure.Remove('Microsoft.Data.SqlClient.Extensions.Azure/1')
Assert-Rejected -MessagePattern 'dependency mismatch for Microsoft\.Data\.SqlClient\.Extensions\.Azure ' -Action {
    Assert-DistributionDependencies -Distribution All -Dependencies @{ libraries = $missingAzure }
}
foreach ($profile in $libraries.Keys) {
    Assert-Rejected { Assert-DistributionDependencies -Distribution $profile -Dependencies @{ libraries = $all } }
}
Assert-Rejected -MessagePattern '^The Oracle suite cannot validate a SQLite distribution\.$' -Action {
    & "$PSScriptRoot/Invoke-DistributionTests.ps1" -Distribution SQLite -Database Oracle -OutputDirectory ([IO.Path]::GetTempPath())
}
Assert-Rejected -MessagePattern '^Use a fresh output directory' -Action {
    & "$PSScriptRoot/Invoke-DistributionTests.ps1" -Distribution SQLite -Database Sqlite -OutputDirectory ([IO.Path]::GetTempPath())
}
Write-Host 'PASS: required All/slim database lanes, version-matrix mapping, missing/leaked clients and wrong suite rejection.'
