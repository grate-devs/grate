# PR validation and proposed main protection

`CI` starts for every PR to main, including documentation-only and fork PRs.
Every category runs the full existing build, test and packaging matrix. There
is no documentation classifier or permitted skip.

Each PR build workflow starts with the shared `.github/actions/preflight` action.
It checks CI scheduling, the aggregate policy, container-monitor contracts,
release/Docker/Debian automation and the generated documentation before compiling
grate. Run its script checks locally with `pwsh -File scripts/ci/Invoke-Preflight.ps1`.

In `CI`, the existing `PR validation policy` job runs this preflight. Build and
Basic_tests wait for it; database, CodeQL and packaging jobs then wait for Build
and Basic_tests. Release artifacts and integration tests perform preflight before
version resolution, installation checks wait for their documentation/preflight
job, and WinGet preparation waits before compiling native MSI actions. Each
workflow evaluates its own first job using the same action. Failed, cancelled or
skipped preflight prevents its build jobs from starting. The final `PR validation`
and `CI result` checks still run to report incomplete CI.

`PR validation` uses `always()` and requires all seven dependencies to succeed:
`validation-policy`, `build-code`, `test`, `cli-distributions`, `packages`,
`standalone` and `docker`. It also queries every page of the current run's Jobs
API and requires all 94 expected jobs and their applicable mandatory producer
steps to complete successfully. This includes every All/slim CLI and tool lane,
native standalone target, MSI lifecycle and Alpine target.
Missing, duplicate, failed, cancelled, unexpectedly skipped, timed-out, neutral,
unknown and pending required results fail validation. Reusable workflow jobs are
matched by their exact caller/leaf check names.
`Create test report` runs as a separate diagnostic job after the test producers,
including on test failure. `PR validation` and `CI result` can finish while that
job is queued or running. The report still has its own status and HTML artifact.

For partial reruns, the newest attempt per job is used. Earlier successes from
the same immutable run can be reused. API failure or missing context fails closed.
Workflow cancellation may cancel the aggregate; a cancelled required check blocks
merging. CodeQL and dependency-security checks remain separate controls.

This aggregate covers the required producers in `ci.yml`. The separate
heavyweight `Integration tests` workflow runs All and slim CommandLine suites
against its database-version matrix and propagates native test failures. Its
legacy Docker lane remains disabled and advisory. Path-specific
skill, installer and release-contract workflows retain their separate checks;
they are not silently promoted into required workflows by this proposal.

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

- PRs with no required approvals, stale approval dismissal and resolved review
  threads.
- Required `PR validation`, `CI result`, `Security analysis / Analyze Code Security`,
  `Dependency Review`, `NuGet dependency audit` and `Dependabot auto-merge revision`
  from GitHub Actions (app ID 15368), on up-to-date PRs.
- Native CodeQL protection rejecting high/critical security alerts, no additional
  non-security threshold. Green analysis alone does not enforce alert severity.
  Dependency Review and NuGet audit also use high/critical.
- No main deletion or force pushes; PRs merge using squash.
- Administrator bypass through a PR only for emergencies, with reasons and
  follow-up recorded in that PR. No actor receives direct-push bypass.

Maintainers with write access can provide voluntary reviews. Confirm current
repository permissions and agree ownership before introducing a CODEOWNERS
requirement for `.github/` or `scripts/ci/`, then test any agreed requirement.
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

## Dependabot auto-merge

Dependabot checks GitHub Actions and NuGet daily. The auto-merge workflow can
request a squash merge of a single verified Dependabot commit from this repository
to `main`. Every dependency in the commit must be a patch or minor update.
A group containing a major or an unclassified dependency goes to manual review.
The workflow neither reviews PRs nor grants a ruleset exception.

### Configure main before enabling auto-merge

1. Follow the activation sequence above. Configure an **active** PR ruleset on
   `main`, keep required reviews and conversation resolution as agreed by
   maintainers, and allow squash. Keep GitHub Actions and the optional merge App
   off all applicable bypass lists. These rules affect every PR to `main`.
2. Require up-to-date branches and select **GitHub Actions** (app ID `15368`)
   as the expected source for each check below. Keep the native CodeQL rule
   blocking high and critical security alerts. The disabled proposal includes
   these checks for a maintainer to review before activation.

   | Required check | What it protects |
   | --- | --- |
   | `PR validation` | Build, database tests and distribution matrix, including missing or cancelled producers |
   | `CI result` | Final result across the CI phases, including isolated tests and security analysis |
   | `Security analysis / Analyze Code Security` | Execution of the CodeQL analysis |
   | `Dependency Review` | Vulnerability review of the PR's dependency changes |
   | `NuGet dependency audit` | Audit of resolved direct and transitive packages |
   | `Dependabot auto-merge revision` | Reclassification on a changed Dependabot PR that already has an auto-merge request |

3. Inspect the effective server-side rules with
   `gh api --paginate repos/grate-devs/grate/rules/branches/main`. The workflow
   uses this metadata-readable endpoint so its token needs no administration
   permission. Classic protection alone, evaluation-mode rules and an active
   merge queue leave this workflow ineligible. A queue controls its own merge
   method and would need CI support for `merge_group`.
4. Enable **Allow squash merging** and **Allow auto-merge** in the repository's
   pull request settings. The workflow requests native auto-merge for the
   specific head SHA. GitHub waits for required checks, reviews and any other
   merge requirements. With a strict ruleset a busy base can require a Dependabot
   rebase and fresh CI.

The write job runs trusted code from the base revision. Keep the normal Actions
workflow permissions read-only. The job requests its own short-lived token
permissions. Leave automatic PR approval disabled. If GitHub restricts the
token or refuses the request, the PR stays available for manual review.

For GitHub Actions updates that modify workflow files, GitHub can require
`Workflows: write` on the merging identity. See the
[GitHub CLI example of this rejection](https://github.com/cli/cli/issues/11493).
To support these updates, install a dedicated GitHub App on this repository
with Contents, Pull requests and Workflows write permissions. Create the
`dependabot-auto-merge` environment, restrict deployment branches to the
selected branch `main`, and store `DEPENDABOT_AUTOMERGE_APP_PRIVATE_KEY` **only**
as an environment secret. Set the repository variable
`DEPENDABOT_AUTOMERGE_APP_CLIENT_ID` last. The trusted GitHub Actions update
job then mints a short-lived installation token for this repository. NuGet
continues to use the built-in token. Keep the App off ruleset bypass lists.
[GitHub's environment branch rules](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments#deployment-branches-and-tags)

### Verify the rollout

- On a fresh bot patch or minor update, confirm the merge box shows squash
  auto-merge waiting for the required jobs and any outstanding review. Check
  that missing or failing CI blocks merging even when dependency review passes.
- On a bot major, an unclassified group, a fork and a human-authored PR,
  confirm the workflow leaves auto-merge off. A configuration change alone
  does not enroll open PRs. A subsequent eligible PR event reruns the policy.
- If a previously enrolled PR changes, check the revision job on the new head.
  An ineligible head with an outstanding request must be blocked. Disable
  auto-merge on that PR to continue with manual review. Protect edits to CI
  and its policy scripts through the repository's review process.
- Verify the first authorized squash in GitHub, including the resulting
  `push` workflows on `main`. The identity that performs the merge matters for
  follow-on Actions events. To suspend the rollout, disable the workflow,
  inspect open PRs and turn off their outstanding auto-merge requests before
  relaxing branch protections.

Run the policy and API fixtures with
`pwsh -NoProfile -File scripts/ci/Test-DependabotAutoMerge.ps1`.
