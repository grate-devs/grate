# Code and dependency security checks

`CI` keeps the existing Windows `Analyze Code Security` job and its CodeQL
analysis identity (`.github/workflows/ci.yml:analyze`). The explicit language list
covers C#, C++ and GitHub Actions; Python sources were migrated to PowerShell on
main. The explicit `grate.slnx` build and native MSI compilation remain between
initialization and analysis. Do not replace this with a second overlapping
CodeQL workflow or limit extraction to C#.

Every main PR and main push is analyzed. A weekly Monday 05:23 UTC run refreshes
the main baseline as queries evolve. Main pushes and scheduled runs execute only
security analysis; PR and manual analysis waits for preflight, Build and both
isolated test lanes to succeed before the expensive jobs. Schedules use the
default branch and take effect after merge.

## Dependency policy

The `Dependency security` workflow has no PR path filters and needs only
`contents: read`, including for fork PRs. It adds two complementary checks:

| Check | Scope and failure policy |
| --- | --- |
| `Dependency Review` | New dependency changes in main PRs, as exposed by GitHub's dependency graph. Fail on high or critical known advisories in runtime, development and unknown scopes. |
| `NuGet dependency audit` | Restore the entire `grate.slnx` with the pinned SDK and every declared target framework. Evaluate central and conditional versions and audit direct and transitive packages. High/critical advisories and feed failures fail; low/moderate advisories remain visible warnings. Runs on PRs, main pushes and weekly Monday 05:43 UTC. |

The NuGet check uses the shared root `NuGet.Config` and its explicit vulnerability
feed, and fails on NU1900/NU1905 as well as NU1903/NU1904. It does not suppress
advisories. Existing build/pack
jobs retain their own, possibly stricter, warning policy. Run the same check from
the checkout with the SDK in `global.json` installed:

```powershell
./scripts/release/Install-TestDependencies.ps1
./scripts/security/Test-DependencySecurityPolicy.ps1
./scripts/security/Test-NuGetDependencies.ps1
```

Daily Dependabot version updates already cover NuGet and Actions. Its NuGet
updater can propose central-version changes; that does not establish that the
dependency graph contains resolved CPM versions or transitive packages.
Do not interpret zero open Dependabot alerts or a green Dependency Review with
zero changes as proof of complete NuGet coverage. The resolved NuGet audit closes
that gap for projects in `grate.slnx`, including test/build dependencies.

Examples outside the solution, Terraform providers, SDK/runtime
servicing, operating-system/container packages and native library payloads require
their own inventory checks. GitHub Actions advisory detection also has limitations
for SHA-pinned actions; keep Dependabot version updates and deliberate pin review.
The existing `actions/setup-dotnet >=5` update exclusion relates to the public-feed
redirect issue #830; it is not an advisory waiver. Reassess it against the upstream
fix before changing the pin. See also [packaging guidance](Packaging.md).

## Merge enforcement handoff

A successful `Analyze Code Security` job means extraction/analysis/upload worked.
It does **not** establish a high/critical finding threshold. The main ruleset owner
should add the native `code_scanning` rule with these parameters after validating
the main baseline and PR analyses:

```json
{
  "type": "code_scanning",
  "parameters": {
    "code_scanning_tools": [
      {
        "tool": "CodeQL",
        "security_alerts_threshold": "high_or_higher",
        "alerts_threshold": "none"
      }
    ]
  }
}
```

Require the GitHub Actions checks `Analyze Code Security`, `Dependency Review`
and `NuGet dependency audit` only once they have produced verified results.
CodeQL merge protection rejects new high/critical security alerts; pre-existing
findings remain a separate triage queue. General correctness warnings do not
block under this proposed code-scanning rule. This PR does not enable rulesets
or change repository-wide CodeQL thresholds.

Validate both a clean PR and an intentionally failing disposable dependency
fixture before enabling requirements. Verify missing/failed analyses block under
the actual ruleset; a green workflow cannot prove this external setting. Record
check links, graph coverage and triage observations in the PR, not as dated logs
in git. Refresh the main baseline after merge and reassess old alerts against it.

No advisory exceptions are configured. Any future exception must identify the
exact GHSA/package/version/project or CodeQL alert, applicability evidence,
maintainer owner, compensating control, review date and expiry/removal condition
in a linked issue/PR. Use a narrowly reviewed advisory exclusion if needed;
never disable an ecosystem, all transitive auditing or the gate. Emergency
ruleset bypasses belong to the shared main policy and must be attributable and
explained in the PR.

References: [Dependency Review options](https://github.com/actions/dependency-review-action),
[NuGet Audit](https://learn.microsoft.com/en-us/nuget/concepts/auditing-packages),
[supported dependency graph inputs](https://docs.github.com/en/code-security/reference/supply-chain-security/dependency-graph-supported-package-ecosystems),
[CodeQL merge protection](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/set-merge-protection).
