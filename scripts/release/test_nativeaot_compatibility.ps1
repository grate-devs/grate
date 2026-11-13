#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"

function Assert-NativeAotCompatibility {
    param(
        [System.Collections.IDictionary]$Build,
        [System.Collections.IDictionary]$Compatibility,
        [System.Collections.IDictionary]$Integration
    )

    Assert-Policy ($Compatibility.on.Count -eq 1 -and $Compatibility.on.Contains('workflow_call')) 'Compatibility must be callable only.'
    $inputs = $Compatibility.on.workflow_call.inputs
    Assert-Policy ($inputs.Count -eq 1 -and $inputs.version.required -eq $true -and $inputs.version.type -ceq 'string') 'Require the release candidate version input.'
    Assert-Policy ($Compatibility.permissions.Count -eq 1 -and $Compatibility.permissions.contents -ceq 'read') 'Compatibility needs only read access.'
    Assert-Policy ($Compatibility.jobs.Count -eq 1 -and $Compatibility.jobs.Contains('main')) 'Compatibility must remain one reusable leaf.'
    $job = $Compatibility.jobs.main
    Assert-Policy ($job.'runs-on' -ceq 'ubuntu-latest' -and !$job.needs -and !$job.uses -and !$job.if) 'Compatibility runs directly on Linux x64.'
    Assert-Policy ($job.strategy.'fail-fast' -eq $false -and !$job.'continue-on-error') 'Every compatibility result must count, including failures.'

    $matrix = $job.strategy.matrix
    Assert-Policy ($matrix.Count -eq 2 -and ($matrix.variant -join ',') -ceq 'All,Slim') 'Run both All and matching slim profiles without matrix exclusions.'
    $canonical = @($Integration.jobs['cli-database-integration-tests'].strategy.matrix.database)
    Assert-Policy ($canonical.Count -eq 21 -and @($matrix.database).Count -eq 21) 'Preserve all 21 existing database/image cases, yielding 42 compatibility jobs.'
    foreach ($reference in $canonical) {
        $matches = @($matrix.database | Where-Object name -CEQ $reference.name)
        Assert-Policy ($matches.Count -eq 1) "Missing or duplicate compatibility case: $($reference.name)."
        $candidate = $matches[0]
        Assert-Policy ($candidate.Count -eq 4) "Preserve the database schema for $($reference.name)."
        foreach ($field in @('name', 'type', 'distribution', 'image')) {
            Assert-Policy ($candidate[$field] -ceq $reference[$field]) "Compatibility $field differs for $($reference.name)."
        }
    }

    $checkout = Get-ActionStep -Job $job -Action 'actions/checkout'
    Assert-Policy ($checkout.with.ref -ceq '${{ github.sha }}' -and $checkout.with.'persist-credentials' -eq $false) 'Use immutable source without persisted checkout credentials.'
    $sdk = Get-ActionStep -Job $job -Action 'actions/setup-dotnet'
    Assert-Policy ($sdk.with.'global-json-file' -ceq 'global.json') 'Build ordinary JIT test assemblies using the pinned SDK.'
    $selection = $job.steps | Where-Object id -CEQ 'distribution'
    $profileExpression = '${{ matrix.variant == ''All'' && ''All'' || matrix.database.distribution }}'
    Assert-Policy ($selection.run.Contains("Get-GrateDistribution -Name '$profileExpression'") -and $selection.run.Contains('package-id=$($profile.PackageId)')) 'Resolve All and matching slim package identities from the selected profile.'

    $downloads = @($job.steps | Where-Object { $_.uses -like 'actions/download-artifact@*' })
    Assert-Policy ($downloads.Count -eq 1) 'Download exactly the NativeAOT release candidate.'
    $download = $downloads[0]
    Assert-Policy ($download.with.Count -eq 2 -and !$download.if -and !$download.'continue-on-error') 'Download from this run without cross-run or cross-repository overrides.'
    Assert-Policy ($download.with.name -ceq 'release-${{ steps.distribution.outputs.package-id }}-linux-x64-nativeaot-${{ inputs.version }}.zip') 'Consume the versioned NativeAOT archive from this run.'
    Assert-Policy ($download.with.path -ceq '${{ runner.temp }}/nativeaot-compatibility-archive') 'Keep the downloaded release candidate separate from fresh test output.'

    $test = $job.steps | Where-Object name -CEQ 'Test archived NativeAOT CLI database compatibility'
    Assert-Policy (!$test.if -and !$test.'continue-on-error' -and $test.shell -ceq 'pwsh') 'Run compatibility checks with failures propagated.'
    Assert-Policy ($test.env.GrateTestConfig__DockerImage -ceq '${{ matrix.database.image }}' -and $test.env.LogLevel -ceq 'Warning' -and $test.env.TZ -ceq 'UTC') 'Route every suite to its exact database image.'
    Assert-Policy ($test.env.PACKAGE_VERSION -ceq '${{ inputs.version }}') 'Use the release candidate version for archive execution.'
    foreach ($line in @(
        "Distribution = '$profileExpression'",
        'Database = ''${{ matrix.database.type }}''',
        "RuntimeIdentifier = 'linux-x64'",
        'OutputDirectory = ''${{ runner.temp }}/nativeaot-compatibility-tests''',
        'NativeAot = $true',
        'NativeAotArchive = ''${{ runner.temp }}/nativeaot-compatibility-archive/${{ steps.distribution.outputs.package-id }}-linux-x64-nativeaot-'' + $env:PACKAGE_VERSION + ''.zip''',
        './scripts/ci/Invoke-DistributionTests.ps1 @parameters'
    )) {
        Assert-Policy ($test.run.Contains($line)) "Missing archived NativeAOT runner routing: $line"
    }
    Assert-Policy ($test.run -cnotmatch 'PublishAot|dotnet (publish|pack|tool)|Publish-NativeAot|--filter') 'Use existing complete CommandLine suites with ordinary JIT builds and the already built archive.'
    foreach ($step in $job.steps) {
        Assert-Policy (!$step.'continue-on-error') 'Compatibility steps must propagate failures.'
    }
    $upload = Get-ActionStep -Job $job -Action 'actions/upload-artifact'
    Assert-Policy ($upload.if -ceq 'always()' -and $upload.with.name -ceq 'nativeaot-compatibility-results-${{ matrix.variant }}-${{ matrix.database.name }}') 'Retain distinct reports for every compatibility identity even when tests fail.'
    Assert-Policy ($upload.with.path -ceq '${{ runner.temp }}/nativeaot-compatibility-tests/results/') 'Upload results from the actual archive test invocation.'

    $call = $Build.jobs['test-native-aot-compatibility']
    Assert-Policy ($call.uses -ceq './.github/workflows/release-native-aot-compatibility.yml' -and ($call.needs -join ',') -ceq 'set-version-number,build-native-aot') 'Compatibility must wait for this run''s versioned NativeAOT producer.'
    Assert-Policy ($call.with.version -ceq '${{ needs.set-version-number.outputs.semVer }}' -and !$call.if -and !$call.'continue-on-error') 'Forward the candidate version without making compatibility optional.'
    Assert-Policy ($Build.jobs['release-ready'].needs -ccontains 'test-native-aot-compatibility') 'Compatibility must gate release publication.'
}

$build = Read-Workflow -Name 'build.yml' -Raw
$compatibility = Read-Workflow -Name 'release-native-aot-compatibility.yml' -Raw
$integration = Read-Workflow -Name 'integration-tests.yml' -Raw
Assert-NativeAotCompatibility -Build $build -Compatibility $compatibility -Integration $integration

$mutations = @(
    @{ Change = { param($b, $c) $c.jobs.main.strategy.matrix.database = @($c.jobs.main.strategy.matrix.database | Where-Object name -CNE 'PostgreSQL 12') }; Error = '*all 21*' },
    @{ Change = { param($b, $c) $c.jobs.main.strategy.matrix.database[0].image = 'mcr.microsoft.com/mssql/server:2022-latest' }; Error = '*image differs*' },
    @{ Change = { param($b, $c) $c.jobs.main.strategy.matrix.variant = @('All') }; Error = '*both All*' },
    @{ Change = { param($b, $c) (Get-ActionStep -Job $c.jobs.main -Action 'actions/download-artifact').with.name = 'grate-linux-x64-self-contained' }; Error = '*versioned NativeAOT archive*' },
    @{ Change = { param($b, $c) (Get-ActionStep -Job $c.jobs.main -Action 'actions/download-artifact').with['run-id'] = 123 }; Error = '*this run*' },
    @{ Change = { param($b, $c) ($c.jobs.main.steps | Where-Object name -CEQ 'Test archived NativeAOT CLI database compatibility').env.GrateTestConfig__DockerImage = 'postgres:18' }; Error = '*exact database image*' },
    @{ Change = { param($b, $c) $step = $c.jobs.main.steps | Where-Object name -CEQ 'Test archived NativeAOT CLI database compatibility'; $step.run = $step.run.Replace('NativeAot = $true', 'NativeAot = $false') }; Error = '*NativeAot = $true*' },
    @{ Change = { param($b, $c) $c.jobs.main.strategy['fail-fast'] = $true }; Error = '*including failures*' },
    @{ Change = { param($b, $c) $b.jobs['test-native-aot-compatibility'].with.version = 'stale-version' }; Error = '*candidate version*' },
    @{ Change = { param($b, $c) $b.jobs['release-ready'].needs = @($b.jobs['release-ready'].needs | Where-Object { $_ -cne 'test-native-aot-compatibility' }) }; Error = '*gate release publication*' }
)
foreach ($mutation in $mutations) {
    $changed = @($build, $compatibility) | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    & $mutation.Change $changed[0] $changed[1]
    $caught = $null
    try {
        Assert-NativeAotCompatibility -Build $changed[0] -Compatibility $changed[1] -Integration $integration
    } catch {
        $caught = $_
    }
    Assert-Policy ($null -ne $caught -and $caught.Exception.Message -like $mutation.Error) "Mutation escaped its intended compatibility assertion: $($mutation.Error)"
}
Write-Host "PASS: all 42 NativeAOT compatibility identities match the existing 21 database/images; same-run archive/image routing and release gates reject $($mutations.Count) broken configurations."
