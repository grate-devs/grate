# All inputs come from the trusted pull_request_target event and runner.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
$repository = $env:GITHUB_REPOSITORY
$number = $event.pull_request.number
$head = $event.pull_request.head.sha
$pr = gh api "repos/$repository/pulls/$number" | ConvertFrom-Json
if ($pr.state -cne 'open' -or $pr.draft -or $pr.base.ref -cne 'main' -or
    $pr.head.repo.full_name -cne $repository -or $pr.user.login -cne 'dependabot[bot]' -or
    $pr.commits -ne 1 -or $pr.head.sha -cne $head -or $pr.auto_merge) {
    Write-Host 'The pull request changed or already has an auto-merge request.'
    return
}

# Recheck after runner/environment wait time and immediately before enrollment.
& "$PSScriptRoot/Assert-DependabotAutoMergeRules.ps1" -Repository $repository

$mutation = @'
mutation($pr: ID!, $head: GitObjectID!) {
  enablePullRequestAutoMerge(input: {pullRequestId: $pr, expectedHeadOid: $head, mergeMethod: SQUASH}) {
    pullRequest { url }
  }
}
'@
gh api graphql -f "query=$mutation" -f "pr=$($pr.node_id)" -f "head=$head" --jq '.data.enablePullRequestAutoMerge.pullRequest.url'
