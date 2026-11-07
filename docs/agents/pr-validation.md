# PR validation and proposed main protection

`CI` starts for every PR to main, including documentation-only and fork PRs.
Every category runs the full existing build, test and packaging matrix. There
is no documentation classifier or permitted skip.

`PR validation` uses `always()` and requires all six dependencies to succeed:
`validation-policy`, `build-code`, `test`, `packages`, `standalone` and `docker`.
It also queries every page of the current run's Jobs API and requires all 27
expected jobs and their 47 mandatory producer steps to complete successfully.
Missing, duplicate, failed, cancelled, unexpectedly skipped, timed-out, neutral,
unknown and pending required results fail validation. Existing names remain.
`Create test report` is diagnostic; successful HTML never overrides failed tests.

For partial reruns, the newest attempt per job is used. Earlier successes from
the same immutable run can be reused. API failure or missing context fails closed.
Workflow cancellation may cancel the aggregate; a cancelled required check blocks
merging. CodeQL and dependency-security checks remain separate controls.

## Permissions and maintenance

The aggregate uses `contents: read` and `actions: read`, the ordinary
`pull_request` event and ephemeral `github.token`. It needs no repository secrets,
write permissions, `pull_request_target` or privileged `workflow_run` consumer.
Checkout does not persist credentials. GitHub may require fork-run approval;
never run unknown PR code in a privileged context to avoid that rule.

Run with PowerShell 7:

```powershell
./scripts/ci/Test-PRValidation.ps1
./scripts/ci/Test-InvokePRValidation.ps1
```

Update the independent inventory, tests and workflow together when intentionally
changing required matrices or steps. Keep run evidence and test PR links in the
implementation PR, not in git.

## Proposed main ruleset

[The ruleset JSON](../../.github/main-ruleset.proposed.json) is a **disabled
proposal**, not applied repository settings. It proposes:

- PRs with one approval, stale approval dismissal and resolved review threads.
- Required `PR validation`, `Analyze Code Security`, `Dependency Review` and
  `NuGet dependency audit` from GitHub Actions (app ID 15368), on up-to-date PRs.
- Native CodeQL protection rejecting high/critical security alerts, no additional
  non-security threshold. Green analysis alone does not enforce alert severity.
  Dependency Review and NuGet audit also use high/critical.
- No main deletion or force pushes; merge, squash and rebase remain available.
- Administrator bypass through a PR only for emergencies, with reasons and
  follow-up recorded in that PR. No actor receives direct-push bypass.

Administrators `erikbra` and `wokket` can provide independent reviews;
`hoangthanh28` also has write access. Recheck permissions before activation.
Eligibility does not establish willingness to own an area. No CODEOWNERS
requirement is proposed until maintainers agree. Discuss both administrators
for `.github/` and `scripts/ci/`, then test any agreed ownership requirement.
CodeRabbit stays advisory. Merge queue requires a future `merge_group` trigger
and separate verification.

## Activation sequence

1. Review the implementation PR and actual code, documentation and fork PR runs.
   Record base/head/run/attempt, permissions and outcomes. Label fixture producers,
   permission simulations and test-base runs; these do not prove main protection.
2. Exercise failure, cancellation, missing members and unexpected skips. Green
   reporting alongside red tests must give red PR validation. Local policy tests
   complement hosted verification; they do not replace it.
3. Maintainers merge the reviewed configuration. This task does not authorize
   merging. Refresh main and repeat categories only demonstrated on a test base.
   Verify the separate security checks and accepted CodeQL baseline/threshold.
4. Obtain the user's review of results and final ruleset before applying active
   enforcement. Required PR validation waits until configuration is on main and
   all three contribution categories are verified.
5. Inspect effective rules; verify fresh passing PRs are allowed while failing,
   missing and stale checks block merging. Keep an audited emergency PR path.

See GitHub's [required-check troubleshooting](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks)
and [`jobs.<job_id>.needs`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds).
