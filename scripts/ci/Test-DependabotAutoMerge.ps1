#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$revision = '0123456789abcdef0123456789abcdef01234567'
$patch = 'version-update:semver-patch'
$minor = 'version-update:semver-minor'
$major = 'version-update:semver-major'

function Confirm-FixtureUpdate {
    param(
        [string[]]$SignedTypes,
        [string[]]$ReportedTypes = $SignedTypes,
        [string]$Summary = $ReportedTypes[0],
        [string]$ExpectedHead = $revision,
        [string]$Author = 'dependabot[bot]',
        [string]$Committer = 'web-flow',
        [bool]$Verified = $true
    )

    $lines = @('Bump test dependencies', '', '---', 'updated-dependencies:')
    for ($index = 0; $index -lt $SignedTypes.Count; $index++) {
        $lines += "- dependency-name: example-$index"
        $lines += '  dependency-version: 2.0.1'
        $lines += '  dependency-type: direct:production'
        if ($SignedTypes[$index]) {
            $lines += "  update-type: $($SignedTypes[$index])"
        }
    }
    $lines += '...', '', 'Signed-off-by: dependabot[bot] <support@github.com>'
    $commit = [pscustomobject]@{
        sha = $revision
        author = @{ login = $Author }
        committer = @{ login = $Committer }
        commit = @{
            verification = @{ verified = $Verified }
            message = $lines -join "`n"
        }
    }
    $dependencies = @(for ($index = 0; $index -lt $ReportedTypes.Count; $index++) {
        [pscustomobject]@{
            dependencyName = "example-$index"
            updateType = $ReportedTypes[$index]
        }
    })

    & "$PSScriptRoot/Confirm-DependabotUpdate.ps1" -UpdateType $Summary -Dependencies $dependencies -Commit $commit -ExpectedHead $ExpectedHead
}

$metadataCases = @(
    @{ Name = 'patch'; Accept = $true; Input = @{ SignedTypes = @($patch) } }
    @{ Name = 'minor'; Accept = $true; Input = @{ SignedTypes = @($minor) } }
    @{ Name = 'patch and minor'; Accept = $true; Input = @{ SignedTypes = @($patch, $minor); Summary = $minor } }
    @{ Name = 'major'; Input = @{ SignedTypes = @($major) } }
    @{ Name = 'missing summary'; Input = @{ SignedTypes = @($patch); Summary = '' } }
    @{ Name = 'unknown member'; Input = @{ SignedTypes = @($minor, 'unknown') } }
    @{ Name = 'major member masked by summary'; Input = @{ SignedTypes = @($patch, $major) } }
    @{ Name = 'signed major reported as patch'; Input = @{ SignedTypes = @($major); ReportedTypes = @($patch) } }
    @{ Name = 'signed type missing despite patch output'; Input = @{ SignedTypes = @(''); ReportedTypes = @($patch) } }
    @{ Name = 'omitted group member'; Input = @{ SignedTypes = @($minor, $major); ReportedTypes = @($minor) } }
    @{ Name = 'different head'; Input = @{ SignedTypes = @($patch); ExpectedHead = ('f' * 40) } }
    @{ Name = 'different commit author'; Input = @{ SignedTypes = @($patch); Author = 'contributor' } }
    @{ Name = 'different verified committer'; Input = @{ SignedTypes = @($patch); Committer = 'contributor' } }
    @{ Name = 'unsigned commit'; Input = @{ SignedTypes = @($patch); Verified = $false } }
)
foreach ($case in $metadataCases) {
    $arguments = $case.Input
    $accepted = Confirm-FixtureUpdate @arguments
    if ($accepted -isnot [bool] -or $accepted -ne [bool]$case['Accept']) {
        throw "Incorrect metadata decision for '$($case.Name)'."
    }
}

$contexts = @(
    'PR validation'
    'CI result'
    'Security analysis / Analyze Code Security'
    'Dependency Review'
    'NuGet dependency audit'
    'Dependabot auto-merge revision'
)
function New-FixtureRules {
    $checks = @(foreach ($context in $contexts) {
        @{ context = $context; integration_id = 15368 }
    })
    @(
        @{ type = 'pull_request'; parameters = @{ allowed_merge_methods = @('squash') } }
        @{ type = 'required_status_checks'; parameters = @{
            strict_required_status_checks_policy = $true
            required_status_checks = $checks
        } }
        @{ type = 'code_scanning'; parameters = @{ code_scanning_tools = @(
            @{ tool = 'CodeQL'; security_alerts_threshold = 'high_or_higher'; alerts_threshold = 'none' }
        ) } }
    ) | ConvertTo-Json -Depth 10 | ConvertFrom-Json
}

function Assert-RulesRejected {
    param(
        [string]$Description,
        [AllowEmptyCollection()][object[]]$Rules
    )

    try {
        & "$PSScriptRoot/Assert-DependabotAutoMergeRules.ps1" -Rules $Rules
    }
    catch {
        return
    }
    throw "Auto-merge accepted $Description."
}

$rules = New-FixtureRules
& "$PSScriptRoot/Assert-DependabotAutoMergeRules.ps1" -Rules $rules
Assert-RulesRejected 'no active rules' @()
foreach ($rule in $rules) {
    Assert-RulesRejected "missing $($rule.type) rule" @($rules | Where-Object type -CNE $rule.type)
}
foreach ($context in $contexts) {
    $rules = New-FixtureRules
    $status = $rules[1].parameters
    $status.required_status_checks = @($status.required_status_checks | Where-Object context -CNE $context)
    Assert-RulesRejected "missing required check $context" $rules
}
$rules = New-FixtureRules
$rules[1].parameters.required_status_checks[0].integration_id = -1
Assert-RulesRejected 'an unbound check source' $rules
$rules = New-FixtureRules
$rules[1].parameters.strict_required_status_checks_policy = $false
Assert-RulesRejected 'checks on a stale branch' $rules
$rules = New-FixtureRules
$rules[2].parameters.code_scanning_tools[0].security_alerts_threshold = 'critical'
Assert-RulesRejected 'a CodeQL rule that allows high severity alerts' $rules
Assert-RulesRejected 'a merge queue' (@(New-FixtureRules) + @{ type = 'merge_queue' })

Write-Host "Dependabot metadata ($($metadataCases.Count) cases) and active main rules passed."

# Exercise the final API boundary without a token or a live merge mutation.
$fixturePr = @{
    number = 17
    node_id = 'PR_fixture'
    state = 'open'
    draft = $false
    base = @{ ref = 'main' }
    head = @{ sha = $revision; repo = @{ full_name = 'fixture/repo' } }
    user = @{ login = 'dependabot[bot]' }
    commits = 1
    auto_merge = $null
}
$api = @{
    Rules = @(New-FixtureRules)
    DenyRules = $false
    Queue = $null
    AutoMergeAllowed = $true
    Mutations = 0
}
function gh {
    if ($args -contains 'graphql' -and $args -contains 'owner=fixture' -and $args -contains 'name=repo') {
        return (@{ autoMergeAllowed = $api.AutoMergeAllowed; squashMergeAllowed = $true; mergeQueue = $api.Queue } | ConvertTo-Json)
    }
    if ($args -contains 'repos/fixture/repo/pulls/17') {
        return ($fixturePr | ConvertTo-Json -Depth 5)
    }
    if ($args -contains 'repos/fixture/repo/rules/branches/main?per_page=100') {
        if ($api.DenyRules) {
            throw 'Fixture denied rules access.'
        }
        foreach ($rule in $api.Rules) {
            $rule | ConvertTo-Json -Compress -Depth 8
        }
        return
    }
    if ($args -contains 'graphql' -and $args -ccontains "head=$revision" -and $args -ccontains 'pr=PR_fixture') {
        $query = @($args | Where-Object { $_ -clike 'query=*' })[0]
        if ($query -cnotmatch 'enablePullRequestAutoMerge\(' -or
            $query -cnotmatch 'expectedHeadOid: \$head' -or $query -cnotmatch 'mergeMethod: SQUASH') {
            throw 'Expected a native squash auto-merge request bound to the classified head.'
        }
        $api.Mutations++
        return
    }
    throw 'Unexpected gh call.'
}

$eventFile = New-TemporaryFile
$savedEvent = $env:GITHUB_EVENT_PATH
$savedRepo = $env:GITHUB_REPOSITORY
try {
    @{ pull_request = $fixturePr } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $eventFile
    $env:GITHUB_EVENT_PATH = $eventFile.FullName
    $env:GITHUB_REPOSITORY = 'fixture/repo'
    $enable = "$PSScriptRoot/Enable-DependabotAutoMerge.ps1"
    & $enable
    $fixturePr.head.sha = 'f' * 40
    & $enable
    $fixturePr.head.sha = $revision
    $fixturePr.commits = 2
    & $enable
    $fixturePr.commits = 1
    $fixturePr.head.repo.full_name = 'contributor/fork'
    & $enable
    $fixturePr.head.repo.full_name = 'fixture/repo'
    $api.DenyRules = $true
    try {
        & $enable
        throw 'Expected failure reading branch rules.'
    }
    catch {
        if ($_.Exception.Message -cne 'Fixture denied rules access.') {
            throw
        }
    }
    $api.DenyRules = $false
    $api.AutoMergeAllowed = $false
    try {
        & $enable
        throw 'Expected disabled auto-merge to block enrollment.'
    }
    catch {
        if ($_.Exception.Message -notlike 'Enable both auto-merge and squash*') {
            throw
        }
    }
    $api.AutoMergeAllowed = $true
    $api.Queue = @{ id = 'queue' }
    $rejected = $false
    try {
        & $enable
    }
    catch {
        $rejected = $_.Exception.Message -match 'queue'
    }
    if (!$rejected) {
        throw 'A classic merge queue must prevent squash auto-merge enrollment.'
    }
    if ($api.Mutations -ne 1) {
        throw 'Only the original eligible revision may request auto-merge.'
    }
}
finally {
    $env:GITHUB_EVENT_PATH = $savedEvent
    $env:GITHUB_REPOSITORY = $savedRepo
    Remove-Item -LiteralPath $eventFile
}
Write-Host 'Native auto-merge API fixture passed for eligible, stale, multi-commit, fork and access-denied PRs.'
