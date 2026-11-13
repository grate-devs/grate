#!/usr/bin/env pwsh
# Check raw call edges independently of the effective-job policy resolver.
. "$PSScriptRoot/workflow_test_helpers.ps1"

$expectedRoutes = @{
    'build-netcore-tool' = 'release-tools.yml'
    'build-nuget-package' = 'release-libraries.yml'
    'build-standalone' = 'release-cli.yml'
    'build-standalone-mac-arm64' = 'release-cli.yml'
    'build-native-aot' = 'release-native-aot.yml'
    'test-native-aot' = 'release-native-aot-tests.yml'
    'test-native-aot-compatibility' = 'release-native-aot-compatibility.yml'
    'build-msi' = 'release-msi.yml'
    'build-deb' = 'release-debian.yml'
    'build-chocolatey' = 'release-chocolatey.yml'
    'build-docker-image' = 'release-docker-build.yml'
    'build-slim-docker-images' = 'release-docker-slim-build.yml'
    'release-ready' = 'release-validate.yml'
    'publish-github-release' = 'release-github.yml'
    'publish-docker' = 'release-docker-publish.yml'
    'publish-slim-docker' = 'release-docker-slim-publish.yml'
    'prepare-winget' = 'release-winget.yml'
    'publish-homebrew' = 'release-homebrew.yml'
    'test' = 'release-tests.yml'
}
$expectedInputNames = @{
    'release-tools.yml' = @('version')
    'release-libraries.yml' = @('version', 'core-version')
    'release-cli.yml' = @('version', 'publish', 'runner', 'runtime-identifiers', 'native-arm-sdk')
    'release-native-aot.yml' = @('version')
    'release-native-aot-tests.yml' = @('version')
    'release-native-aot-compatibility.yml' = @('version')
    'release-msi.yml' = @('version', 'core-version')
    'release-debian.yml' = @('version')
    'release-chocolatey.yml' = @('version', 'release-tag')
    'release-docker-build.yml' = @('version', 'publish', 'prerelease')
    'release-docker-slim-build.yml' = @('version', 'publish', 'prerelease')
    'release-validate.yml' = @('version', 'release-tag', 'required-results')
    'release-github.yml' = @('version', 'publish', 'release-tag')
    'release-docker-publish.yml' = @('version', 'publish', 'prerelease', 'expected-digest')
    'release-docker-slim-publish.yml' = @('version', 'publish', 'prerelease')
    'release-winget.yml' = @('version', 'release-tag', 'publish', 'prerelease')
    'release-homebrew.yml' = @('version', 'release-tag', 'publish', 'prerelease')
    'release-tests.yml' = @()
}
$expectedSources = @{
    version = '${{ needs.set-version-number.outputs.semVer }}'
    'core-version' = '${{ needs.set-version-number.outputs.nuGetVersion }}'
    publish = '${{ needs.set-version-number.outputs.is-release }}'
    prerelease = '${{ needs.set-version-number.outputs.is-prerelease }}'
    'release-tag' = '${{ needs.set-version-number.outputs.release-tag }}'
    'expected-digest' = '${{ needs.build-docker-image.outputs.digest }}'
    'required-results' = '${{ toJSON(needs) }}'
}
$releaseCondition = '${{ needs.set-version-number.outputs.is-release == ''true'' }}'
$stableCondition = '${{ needs.set-version-number.outputs.is-release == ''true'' && needs.set-version-number.outputs.is-prerelease != ''true'' }}'
$publisherGuard = '${{ startsWith(github.workflow_ref, format(''{0}/.github/workflows/build.yml@'', github.repository)) && inputs.publish == ''true'' }}'
$stableGuard = '${{ startsWith(github.workflow_ref, format(''{0}/.github/workflows/build.yml@'', github.repository)) && inputs.publish == ''true'' && inputs.prerelease != ''true'' }}'

function Assert-ExactMapping {
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$Actual,
        [System.Collections.IDictionary]$Expected,
        [string]$Context
    )

    if ($null -eq $Actual) {
        $Actual = @{}
    }
    Assert-Policy (@($Actual.Keys).Count -eq $Expected.Count) "$Context must have exactly the expected keys."
    foreach ($key in $Expected.Keys) {
        Assert-Policy ($Actual.Contains($key) -and $Actual[$key] -ceq $Expected[$key]) "$Context has incorrect '$key'."
    }
}

function Assert-ReleaseCallContracts {
    param(
        [System.Collections.IDictionary]$Workflow,
        [System.Collections.IDictionary]$Children
    )

    Assert-Policy ($Workflow.on.pull_request.paths -ccontains '.github/workflows/release-*.yml') 'Changes to release children must run the release workflow.'
    Assert-Policy ($Workflow.permissions.Count -eq 1 -and $Workflow.permissions.contents -ceq 'read') 'Keep orchestration read-only by default.'
    $calls = @($Workflow.jobs.Keys | Where-Object { $Workflow.jobs[$_].uses })
    Assert-Policy ($calls.Count -eq $expectedRoutes.Count) 'Retain the complete release call graph.'

    foreach ($jobId in $expectedRoutes.Keys) {
        $file = $expectedRoutes[$jobId]
        $call = $Workflow.jobs[$jobId]
        $child = $Children[$file]
        Assert-Policy ($call.uses -ceq "./.github/workflows/$file") "Incorrect phase for $jobId."
        Assert-Policy ($child.on.Count -eq 1 -and $child.on.Contains('workflow_call')) "$file is callable only."
        Assert-Policy ($child.jobs.Count -eq 1 -and $child.jobs.Contains('main')) "$file must contain one coherent leaf job."
        Assert-Policy ($child.permissions.Count -eq 1 -and $child.permissions.contents -ceq 'read') "$file must default to read-only."

        $inputs = @{}
        foreach ($inputName in $expectedInputNames[$file]) {
            $inputs[$inputName] = $expectedSources[$inputName]
        }
        if ($file -ceq 'release-cli.yml') {
            $nativeArm = $jobId -ceq 'build-standalone-mac-arm64'
            $inputs.runner = if ($nativeArm) {
                'macos-15'
            } else {
                'ubuntu-latest'
            }
            $inputs['native-arm-sdk'] = $nativeArm
            $inputs['runtime-identifiers'] = if ($nativeArm) {
                '["osx-arm64"]'
            } else {
                '["win-x64","win-x86","win-arm64","linux-musl-x64","linux-musl-arm64","linux-x64","linux-arm64","osx-x64"]'
            }
        }
        Assert-ExactMapping -Actual $call.with -Expected $inputs -Context "$jobId inputs"
        $definitions = if ($child.on.workflow_call.inputs) {
            $child.on.workflow_call.inputs
        } else {
            @{}
        }
        Assert-Policy (@($definitions.Keys).Count -eq $inputs.Count) "Declared inputs disagree with $jobId."
        foreach ($inputName in $inputs.Keys) {
            $expectedType = if ($inputName -ceq 'native-arm-sdk') {
                'boolean'
            } else {
                'string'
            }
            Assert-Policy ($definitions[$inputName].required -eq $true -and $definitions[$inputName].type -ceq $expectedType) "Required typed input missing: $jobId/$inputName."
        }
        Assert-Policy (!$call.env -and !$call.environment -and !$child.jobs.main.needs -and !$child.jobs.main.uses) "Keep phase boundaries explicit for $jobId."
        foreach ($step in $child.jobs.main.steps) {
            if ($step.uses -like 'actions/checkout@*' -and !$step.with.repository) {
                Assert-Policy ($step.with.ref -ceq '${{ github.sha }}') "Immutable event source required in $jobId."
            }
        }

        $secrets = switch ($jobId) {
            'publish-docker' {
                @{
                    DOCKER_HUB_USER = '${{ secrets.DOCKER_HUB_USER }}'
                    DOCKER_HUB_TOKEN = '${{ secrets.DOCKER_HUB_TOKEN }}'
                }
            }
            'publish-homebrew' { @{ HOMEBREW_TAP_TOKEN = '${{ secrets.HOMEBREW_TAP_TOKEN }}' } }
            default { @{} }
        }
        Assert-ExactMapping -Actual $call.secrets -Expected $secrets -Context "$jobId secrets"
        $secretDefinitions = if ($child.on.workflow_call.secrets) {
            $child.on.workflow_call.secrets
        } else {
            @{}
        }
        Assert-Policy ($secretDefinitions.Count -eq $secrets.Count) "Secret declaration scope changed for $jobId."
        foreach ($secret in $secrets.Keys) {
            Assert-Policy ($child.on.workflow_call.secrets[$secret].required -eq $false) "Allow the protected environment to supply $secret."
        }

        $permissions = switch ($jobId) {
            'publish-github-release' { @{ contents = 'write' } }
            { $_ -in @('publish-docker', 'publish-slim-docker') } {
                @{
                    contents = 'read'
                    'id-token' = 'write'
                }
            }
            default { @{ contents = 'read' } }
        }
        $callerPermissions = if ($call.permissions) {
            $call.permissions
        } else {
            $Workflow.permissions
        }
        $leafPermissions = if ($child.jobs.main.permissions) {
            $child.jobs.main.permissions
        } else {
            $child.permissions
        }
        Assert-ExactMapping -Actual $callerPermissions -Expected $permissions -Context "$jobId caller permissions"
        Assert-ExactMapping -Actual $leafPermissions -Expected $permissions -Context "$jobId child permissions"

        if ($jobId -in @('publish-github-release', 'publish-docker', 'publish-slim-docker', 'prepare-winget', 'publish-homebrew')) {
            $stableOnly = $jobId -in @('prepare-winget', 'publish-homebrew')
            $expectedCondition = if ($stableOnly) {
                $stableCondition
            } else {
                $releaseCondition
            }
            $expectedGuard = if ($stableOnly) {
                $stableGuard
            } else {
                $publisherGuard
            }
            Assert-Policy ($call.if -ceq $expectedCondition) "Release/stable condition changed for $jobId."
            Assert-Policy ($child.jobs.main.if -ceq $expectedGuard) "Publisher $jobId must require the trusted caller and matching publication policy."
            Assert-Policy ($call.needs -ccontains 'release-ready') "$jobId must wait for the complete release contract."
            if ($jobId -cne 'publish-github-release') {
                Assert-Policy ($call.needs -ccontains 'publish-github-release') "$jobId must wait for the GitHub release."
            }
        } else {
            Assert-Policy (!$child.jobs.main.if) "Unexpected child gate for $jobId."
        }
    }

    $required = @(
        'set-version-number', 'validate-release-policy', 'build-netcore-tool', 'build-nuget-package',
        'build-standalone', 'build-standalone-mac-arm64', 'build-native-aot', 'test-native-aot', 'test-native-aot-compatibility', 'build-msi', 'build-docker-image',
        'build-slim-docker-images', 'build-chocolatey', 'build-deb'
    )
    $ready = $Workflow.jobs['release-ready']
    Assert-Policy (($ready.needs -join ',') -ceq ($required -join ',') -and $ready.if -ceq '${{ always() }}') 'The release contract must evaluate every producer, including failed jobs.'
    $validation = $Children['release-validate.yml'].jobs.main.steps[0]
    Assert-Policy ($validation.env.REQUIRED_RESULTS -ceq '${{ inputs.required-results }}' -and $validation.run.Contains('all(.[]; .result == "success")')) 'Validate caller prerequisite results, never the empty child needs context.'

    $dockerBuild = $Children['release-docker-build.yml']
    Assert-Policy ($dockerBuild.on.workflow_call.outputs.digest.value -ceq '${{ jobs.main.outputs.digest }}') 'Export the built Docker digest through the workflow output.'
    Assert-Policy ($dockerBuild.jobs.main.outputs.digest -ceq '${{ steps.image.outputs.digest }}') 'Export the actual archive digest.'
    foreach ($jobId in @('publish-docker', 'publish-slim-docker')) {
        $leaf = $Children[$expectedRoutes[$jobId]].jobs.main
        Assert-Policy ($leaf.environment -ceq 'docker-hub') 'Preserve the Docker protected environment and OIDC subject.'
        $login = Get-ActionStep -Job $leaf -Action 'docker/login-action'
        Assert-Policy ($login.env.DOCKERHUB_OIDC_CONNECTIONID -ceq '${{ vars.DOCKERHUB_OIDC_CONNECTIONID }}' -and $login.with.username -ceq 'gratedevs') 'Keep the canonical OIDC connection and account.'
    }
    Assert-Policy ($Children['release-homebrew.yml'].jobs.main.environment -ceq 'homebrew-cask') 'Preserve the Homebrew protected environment.'

    $nuget = $Workflow.jobs['publish-nuget']
    Assert-Policy (!$nuget.uses -and $nuget.'runs-on' -ceq 'ubuntu-latest' -and $nuget.if -ceq $releaseCondition) 'Keep the NuGet trusted-publisher job in build.yml.'
    Assert-Policy ($nuget.permissions.'id-token' -ceq 'write' -and (Get-ActionStep -Job $nuget -Action 'NuGet/login')) 'Retain short-lived NuGet authentication.'
    Assert-Policy ($nuget.needs -ccontains 'release-ready' -and $nuget.needs -ccontains 'publish-github-release') 'NuGet publication must remain gated.'

    $cli = $Children['release-cli.yml'].jobs.main
    Assert-Policy ($cli.'runs-on' -ceq '${{ inputs.runner }}' -and $cli.strategy.matrix.arch -ceq '${{ fromJSON(inputs.runtime-identifiers) }}') 'Use the explicit caller platform selection.'
    Assert-Policy (($cli.strategy.matrix.distribution -join ',') -ceq 'All,SQLite,SQLServer,MariaDB,PostgreSQL,Oracle') 'Keep all six CLI profiles.'
    $standardSdk = Get-ActionStep -Job $cli -Action 'actions/setup-dotnet'
    $nativeSdk = $cli.steps | Where-Object uses -CEQ './.github/actions/setup-dotnet-macos-arm64'
    Assert-Policy ($standardSdk.if -ceq '${{ !inputs.native-arm-sdk }}' -and $nativeSdk.if -ceq '${{ inputs.native-arm-sdk }}') 'Select exactly one SDK setup for each CLI platform.'
}

$workflow = Read-Workflow -Name 'build.yml' -Raw
$children = @{}
foreach ($file in $expectedRoutes.Values) {
    $children[$file] = Read-Workflow -Name $file -Raw
}
Assert-ReleaseCallContracts -Workflow $workflow -Children $children

# Mutate raw wiring to prove that resolving jobs cannot hide a broken call edge.
$mutations = @(
    {
        param($workflow, $children)
        $workflow.jobs['build-msi'].with['core-version'] = 'wrong-version'
    },
    {
        param($workflow, $children)
        $workflow.jobs['build-standalone-mac-arm64'].with['native-arm-sdk'] = $false
    },
    {
        param($workflow, $children)
        $workflow.jobs['publish-docker'].with['expected-digest'] = 'sha256:unverified'
    },
    {
        param($workflow, $children)
        $children['release-docker-build.yml'].on.workflow_call.outputs.digest.value = '${{ jobs.wrong.outputs.digest }}'
    },
    {
        param($workflow, $children)
        $workflow.jobs['release-ready'].with['required-results'] = '${{ toJSON(github) }}'
    },
    {
        param($workflow, $children)
        $workflow.jobs['publish-homebrew'].secrets = 'inherit'
    },
    {
        param($workflow, $children)
        $workflow.jobs['publish-github-release'].if = '${{ always() }}'
    },
    {
        param($workflow, $children)
        $children['release-docker-slim-publish.yml'].jobs.main.environment = 'unprotected'
    },
    {
        param($workflow, $children)
        $workflow.jobs['prepare-winget'].with['release-tag'] = 'wrong-tag'
    },
    {
        param($workflow, $children)
        $workflow.jobs['publish-docker'].permissions['id-token'] = 'read'
    },
    {
        param($workflow, $children)
        $children['release-homebrew.yml'].jobs.main.if = $publisherGuard
    }
)
foreach ($mutate in $mutations) {
    $changedWorkflow = $workflow | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $changedChildren = $children | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    & $mutate $changedWorkflow $changedChildren
    $rejected = $false
    try {
        Assert-ReleaseCallContracts -Workflow $changedWorkflow -Children $changedChildren
    } catch {
        $rejected = $true
    }
    Assert-Policy $rejected 'A malformed release call edge escaped validation.'
}

Write-Host "PASS: release call forwarding, publication boundaries, source/platform selection and $($mutations.Count) malformed wiring fixtures."

# Execute the retained aggregation command with representative caller outcomes.
$originalResults = $env:REQUIRED_RESULTS
$aggregation = $children['release-validate.yml'].jobs.main.steps[0]
try {
    foreach ($result in @('success', 'failure', 'cancelled', 'skipped', '')) {
        $results = @{}
        if ($result) {
            $results['producer'] = @{ result = $result }
        }
        $env:REQUIRED_RESULTS = $results | ConvertTo-Json -Compress
        $output = & bash -c $aggregation.run 2>&1
        Assert-Policy (($LASTEXITCODE -eq 0) -eq ($result -ceq 'success')) "Incorrect release gate outcome for '$result': $output"
    }
} finally {
    $env:REQUIRED_RESULTS = $originalResults
}
Write-Host 'PASS: release aggregation accepts success and rejects failure, cancellation, skip and empty prerequisites.'
