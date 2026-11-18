#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"

function Assert-NativeAotWorkflow {
    param(
        [System.Collections.IDictionary]$Build,
        [System.Collections.IDictionary]$Native,
        [System.Collections.IDictionary]$Database
    )

    $hosts = @{
        'win-x64' = 'windows-latest'
        'win-x86' = 'windows-latest'
        'win-arm64' = 'windows-11-arm'
        'linux-x64' = 'ubuntu-24.04'
        'linux-arm64' = 'ubuntu-24.04-arm'
        'linux-musl-x64' = 'ubuntu-latest'
        'linux-musl-arm64' = 'ubuntu-24.04-arm'
        'osx-x64' = 'macos-15-intel'
        'osx-arm64' = 'macos-15'
    }
    $job = $Native.jobs.main
    $matrix = $job.strategy.matrix
    Assert-Policy (($matrix.distribution -join ',') -ceq 'All,SQLite,SQLServer,MariaDB,PostgreSQL,Oracle') 'All six NativeAOT profiles are required.'
    Assert-Policy ($matrix.Count -eq 2 -and $matrix.target -ceq '${{ fromJSON(inputs.targets) }}') 'Only the caller target array may supply NativeAOT platforms.'

    $partitions = @{
        'build-native-aot-linux-x64' = @('linux-x64')
        'build-native-aot' = @($hosts.Keys | Where-Object { $_ -cne 'linux-x64' })
    }
    foreach ($caller in $partitions.Keys) {
        $call = $Build.jobs[$caller]
        Assert-Policy ($call.uses -ceq './.github/workflows/release-native-aot.yml' -and !$call.if -and !$call.'continue-on-error') "Require NativeAOT producer $caller."
        Assert-Policy (($call.needs -join ',') -ceq 'set-version-number') "$caller must depend only on version resolution."
        $targets = ConvertFrom-Json -InputObject $call.with.targets -AsHashtable -NoEnumerate
        Assert-Policy ($targets -is [array] -and $targets.Count -eq $partitions[$caller].Count) "Incorrect NativeAOT partition size for $caller."
        foreach ($rid in $partitions[$caller]) {
            $platform = @($targets | Where-Object rid -CEQ $rid)
            Assert-Policy ($platform.Count -eq 1) "Expected exactly one $rid target in $caller."
            $target = $platform[0]
            Assert-Policy ($target.Count -eq 3 -and $target.os -ceq $hosts[$rid]) "Native toolchain and execution host required for $rid."
            Assert-Policy ($target.alpine -is [bool] -and $target.alpine -eq $rid.StartsWith('linux-musl-')) 'Only musl builds may execute in Alpine.'
        }
    }
    Assert-Policy ($job.'runs-on' -ceq '${{ matrix.target.os }}' -and !$job.if -and !$job.'continue-on-error' -and $job.strategy.'fail-fast' -eq $false) 'Build every NativeAOT target on its selected native host.'
    $publish = $job.steps | Where-Object name -CEQ 'Publish, archive and execute NativeAOT CLI'
    Assert-Policy ($publish.run.Contains('./scripts/release/Publish-NativeAot.ps1 @parameters') -and $publish.run.Contains('NativeAot.Alpine.Dockerfile') -and $publish.run.Contains('$parameters.ContainerImage')) 'Use the common checked publisher and musl toolchain.'
    Assert-Policy ($publish.env.NATIVE_AOT_RUNTIME_IDENTIFIER -ceq '${{ matrix.target.rid }}' -and
        $publish.run.Contains('RuntimeIdentifier = $env:NATIVE_AOT_RUNTIME_IDENTIFIER') -and
        $publish.env.ALPINE -ceq '${{ matrix.target.alpine }}') 'Publish the exact target and toolchain selected by the caller.'
    $archive = $job.steps | Where-Object name -CEQ 'Upload verified NativeAOT release archive'
    Assert-Policy ($archive.with.name -ceq 'release-${{ steps.distribution.outputs.package-id }}-${{ matrix.target.rid }}-nativeaot-${{ inputs.version }}.zip' -and !$archive.if) 'Retain the exact additional release archive after verification.'

    $expected = @(
        'All/Sqlite', 'SQLite/Sqlite', 'All/SqlServer', 'SQLServer/SqlServer',
        'All/SqlServerCaseSensitive', 'SQLServer/SqlServerCaseSensitive',
        'All/PostgreSQL', 'PostgreSQL/PostgreSQL', 'All/MariaDB', 'MariaDB/MariaDB',
        'All/Oracle', 'Oracle/Oracle'
    )
    $cases = @($Database.jobs.main.strategy.matrix.include | ForEach-Object { "$($_.distribution)/$($_.database)" })
    Assert-Policy (($cases -join ',') -ceq ($expected -join ',')) 'Verify All and slim NativeAOT CLI against every database, including case-sensitive SQL Server.'
    $download = Get-ActionStep -Job $Database.jobs.main -Action 'actions/download-artifact'
    Assert-Policy ($download.with.name -ceq 'release-${{ steps.distribution.outputs.package-id }}-linux-x64-nativeaot-${{ inputs.version }}.zip') 'Test the release artifact from this run without rebuilding.'
    $test = $Database.jobs.main.steps | Where-Object name -CEQ 'Test the archived NativeAOT CLI against its database'
    Assert-Policy ($test.run.Contains('NativeAotArchive =') -and $test.run.Contains('NativeAot = $true') -and $test.run.Contains('./scripts/ci/Invoke-DistributionTests.ps1 @parameters')) 'Run existing database suites with the downloaded NativeAOT executable.'
    Assert-Policy (($Build.jobs['test-native-aot'].needs -join ',') -ceq 'set-version-number,build-native-aot-linux-x64' -and !$Build.jobs['test-native-aot'].if) 'Database verification must wait for only the six Linux x64 archives and version resolution.'
    foreach ($required in @('build-native-aot-linux-x64', 'build-native-aot', 'test-native-aot', 'test-native-aot-compatibility')) {
        Assert-Policy ($Build.jobs['release-ready'].needs -ccontains $required) 'NativeAOT builds and database checks must gate release publication.'
    }
}

$build = Read-Workflow -Name 'build.yml' -Raw
$native = Read-Workflow -Name 'release-native-aot.yml' -Raw
$database = Read-Workflow -Name 'release-native-aot-tests.yml' -Raw
Assert-NativeAotWorkflow -Build $build -Native $native -Database $database

$mutations = @(
    { param($b, $n, $d) $n.jobs.main.strategy.matrix.include = @(@{ target = @{ rid = 'win-x64'; os = 'windows-latest'; alpine = $false } }) },
    { param($b, $n, $d) $b.jobs.Remove('build-native-aot-linux-x64') },
    { param($b, $n, $d) $b.jobs.Remove('build-native-aot') },
    { param($b, $n, $d) $b.jobs['build-native-aot-linux-x64'].with.targets = '[{"rid":"win-x64","os":"windows-latest","alpine":false}]' },
    { param($b, $n, $d) $b.jobs['build-native-aot-linux-x64'].with.targets = '[{"rid":"linux-x64","os":"ubuntu-latest","alpine":false}]' },
    { param($b, $n, $d) $b.jobs['build-native-aot'].with.targets = $b.jobs['build-native-aot'].with.targets.Replace('"win-x64"', '"linux-x64"') },
    { param($b, $n, $d) $b.jobs['build-native-aot'].with.targets = $b.jobs['build-native-aot'].with.targets.Replace('"linux-musl-x64","os":"ubuntu-latest","alpine":true', '"linux-musl-x64","os":"ubuntu-latest","alpine":false') },
    { param($b, $n, $d) $d.jobs.main.strategy.matrix.include = @($d.jobs.main.strategy.matrix.include | Where-Object database -CNE 'Oracle') },
    { param($b, $n, $d) (Get-ActionStep -Job $d.jobs.main -Action 'actions/download-artifact').with.name = 'unrelated-artifact' },
    { param($b, $n, $d) $b.jobs['test-native-aot'].needs += 'build-native-aot' },
    { param($b, $n, $d) $b.jobs['release-ready'].needs = @($b.jobs['release-ready'].needs | Where-Object { $_ -cne 'build-native-aot-linux-x64' }) },
    { param($b, $n, $d) $b.jobs['release-ready'].needs = @($b.jobs['release-ready'].needs | Where-Object { $_ -cne 'build-native-aot' }) },
    { param($b, $n, $d) $b.jobs['release-ready'].needs = @($b.jobs['release-ready'].needs | Where-Object { $_ -cne 'test-native-aot' }) }
)
foreach ($mutate in $mutations) {
    $changed = @($build, $native, $database) | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    & $mutate $changed[0] $changed[1] $changed[2]
    $rejected = $false
    try {
        Assert-NativeAotWorkflow -Build $changed[0] -Native $changed[1] -Database $changed[2]
    } catch {
        $rejected = $true
    }
    Assert-Policy $rejected 'Malformed NativeAOT platform, artifact or gate wiring escaped validation.'
}
Write-Host "PASS: NativeAOT 6 + 48 archive jobs, database artifact verification and $($mutations.Count) broken wiring scenarios."
