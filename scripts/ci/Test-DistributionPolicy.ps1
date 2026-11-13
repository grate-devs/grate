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

function Assert-PreparedDistributionWorkflow {
    param(
        [hashtable]$Workflow
    )

    $producer = $Workflow.jobs['cli-distribution-build']
    if (!$producer -or $producer.name -cne 'Prepare CLI artifacts' -or $producer.Contains('strategy') -or
        $producer.Contains('continue-on-error') -or $producer.Contains('if')) {
        throw 'Require one unconditional distribution preparation job.'
    }
    $prepare = @($producer.steps | Where-Object name -CEQ 'Prepare standalone, tool and test payloads')
    if ($prepare.Count -ne 1 -or $prepare[0].Contains('if') -or $prepare[0].Contains('continue-on-error') -or
        $prepare[0].run -cne './scripts/ci/Prepare-DistributionTests.ps1 -RuntimeIdentifier linux-x64 -OutputDirectory ''${{ runner.temp }}/distribution-artifacts''') {
        throw 'Require preparation of the complete current-run candidate set.'
    }

    $expectedUploads = @{}
    foreach ($profile in @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')) {
        $expectedUploads["cli-profile-$profile-linux-x64"] = '${{ runner.temp }}/distribution-artifacts/profiles/' + $profile + '/'
    }
    foreach ($database in @('Sqlite', 'SqlServer', 'SqlServerCaseSensitive', 'PostgreSQL', 'MariaDB', 'Oracle')) {
        $expectedUploads["cli-tests-$database-linux-x64"] = '${{ runner.temp }}/distribution-artifacts/tests/' + $database + '/'
    }
    $uploads = @($producer.steps | Where-Object { $_.uses -like 'actions/upload-artifact@*' })
    if ($uploads.Count -ne $expectedUploads.Count) {
        throw 'Upload exactly six profile and six complete test payload artifacts.'
    }
    foreach ($name in $expectedUploads.Keys) {
        $upload = @($uploads | Where-Object { $_.with.name -ceq $name })
        if ($upload.Count -ne 1 -or $upload[0].with.path -cne $expectedUploads[$name] -or
            $upload[0].with.'if-no-files-found' -cne 'error' -or $upload[0].with.'include-hidden-files' -ne $true -or
            $upload[0].Contains('if') -or $upload[0].Contains('continue-on-error')) {
            throw "Require the complete prepared artifact $name without optional uploads."
        }
    }

    $consumer = $Workflow.jobs['cli-distributions']
    $downloads = @($consumer.steps | Where-Object { $_.uses -like 'actions/download-artifact@*' })
    $expectedDownloads = @{
        'Download selected distribution payload' = @('cli-profile-${{ matrix.distribution }}-linux-x64', '${{ runner.temp }}/prepared-distribution')
        'Download selected test payload' = @('cli-tests-${{ matrix.database }}-linux-x64', '${{ runner.temp }}/prepared-tests')
    }
    if ($downloads.Count -ne 2) {
        throw 'Download only the selected profile and test suite from this workflow run.'
    }
    foreach ($name in $expectedDownloads.Keys) {
        $download = @($downloads | Where-Object name -CEQ $name)
        $artifactName, $destination = $expectedDownloads[$name]
        if ($download.Count -ne 1 -or $download[0].with.Count -ne 2 -or
            $download[0].with.name -cne $artifactName -or $download[0].with.path -cne $destination -or
            $download[0].Contains('if') -or $download[0].Contains('continue-on-error')) {
            throw 'Download only the selected profile and test suite from this workflow run.'
        }
    }
    $execution = $consumer.steps | Where-Object name -CEQ 'Test published CLI and installed tool against database'
    if (!$execution.run.Contains('-PreparedDistributionDirectory ''${{ runner.temp }}/prepared-distribution''') -or
        !$execution.run.Contains('-PreparedTestsDirectory ''${{ runner.temp }}/prepared-tests''')) {
        throw 'Consumers must use both prepared payloads without rebuilding candidates.'
    }
}

Assert-PreparedDistributionWorkflow -Workflow $workflow
foreach ($mutation in @(
    @{
        Change = {
            param($w)
            $w.jobs.Remove('cli-distribution-build')
        }
        Message = 'one unconditional'
    }
    @{
        Change = {
            param($w)
            $w.jobs['cli-distribution-build'].strategy = @{ matrix = @{ profile = @('All') } }
        }
        Message = 'one unconditional'
    }
    @{
        Change = {
            param($w)
            $w.jobs['cli-distribution-build'].steps = @($w.jobs['cli-distribution-build'].steps | Where-Object name -CNE 'Upload tests Oracle')
        }
        Message = 'exactly six profile'
    }
    @{
        Change = {
            param($w)
            ($w.jobs['cli-distribution-build'].steps | Where-Object name -CEQ 'Upload profile All').with.path = '${{ runner.temp }}/distribution-artifacts/'
        }
        Message = 'complete prepared artifact'
    }
    @{
        Change = {
            param($w)
            ($w.jobs['cli-distributions'].steps | Where-Object name -CEQ 'Download selected test payload').with['run-id'] = 123
        }
        Message = 'selected profile and test suite'
    }
    @{
        Change = {
            param($w)
            ($w.jobs['cli-distributions'].steps | Where-Object name -CEQ 'Download selected distribution payload').with.name = 'cli-profile-All-linux-x64'
        }
        Message = 'selected profile and test suite'
    }
    @{
        Change = {
            param($w)
            ($w.jobs['cli-distributions'].steps | Where-Object name -CEQ 'Test published CLI and installed tool against database').run = './scripts/ci/Invoke-DistributionTests.ps1'
        }
        Message = 'both prepared payloads'
    }
)) {
    $changed = $workflow | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    & $mutation.Change $changed
    Assert-Rejected -MessagePattern $mutation.Message -Action { Assert-PreparedDistributionWorkflow -Workflow $changed }
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
