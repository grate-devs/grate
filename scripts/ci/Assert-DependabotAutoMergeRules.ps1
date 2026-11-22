param(
    [Parameter(ParameterSetName = 'Rules')]
    [object[]] $Rules,

    [Parameter(Mandatory, ParameterSetName = 'Repository')]
    [string] $Repository
)

if ($PSCmdlet.ParameterSetName -ceq 'Repository') {
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $true
    $owner, $name = $Repository.Split('/')
    $query = @'
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    autoMergeAllowed
    squashMergeAllowed
    mergeQueue(branch: "main") { id }
  }
}
'@
    $config = gh api graphql -f "query=$query" -f "owner=$owner" -f "name=$name" --jq '.data.repository' | ConvertFrom-Json
    if (!$config.autoMergeAllowed -or !$config.squashMergeAllowed) {
        throw 'Enable both auto-merge and squash in the repository settings before enrolling updates.'
    }

    if ($config.mergeQueue) {
        throw 'The main merge queue chooses the merge method. Squash auto-merge is disabled.'
    }

    # This public endpoint includes only active, applicable rulesets.
    $Rules = @(gh api --paginate "repos/$Repository/rules/branches/main?per_page=100" --jq '.[] | @json' |
        ForEach-Object { ConvertFrom-Json -InputObject $_ })
}

if ($Rules.type -ccontains 'merge_queue') {
    throw 'A merge queue chooses the merge method. Squash auto-merge is disabled.'
}
if ($Rules.type -cnotcontains 'pull_request') {
    throw 'main needs an active pull request rule.'
}

$checks = foreach ($rule in $Rules) {
    if ($rule.type -ceq 'required_status_checks' -and
        $rule.parameters.strict_required_status_checks_policy -is [bool] -and
        $rule.parameters.strict_required_status_checks_policy) {
        foreach ($check in $rule.parameters.required_status_checks) {
            if ($check.integration_id -eq 15368) {
                $check.context
            }
        }
    }
}

$required = @(
    'PR validation'
    'CI result'
    'Security analysis / Analyze Code Security'
    'Dependency Review'
    'NuGet dependency audit'
    'Dependabot auto-merge revision'
)
foreach ($name in $required) {
    if ($name -cnotin $checks) {
        throw "main needs a strict required status check from GitHub Actions for '$name'."
    }
}

$scanners = ($Rules | Where-Object type -CEQ 'code_scanning').parameters.code_scanning_tools
foreach ($scanner in $scanners) {
    if ($scanner.tool -ceq 'CodeQL' -and
        $scanner.security_alerts_threshold -cin @('high_or_higher', 'medium_or_higher', 'all')) {
        return
    }
}
throw 'main needs a CodeQL rule blocking security alerts of high severity or higher.'
