# CodeRabbit automatic advisory review

The root [.coderabbit.yaml](../../.coderabbit.yaml) controls this pilot. Review
criteria remain in [AGENTS.md](../../AGENTS.md), [providers](providers.md),
[verification](verification.md), and [testing](testing.md). Edit those sources
when a rule changes; do not maintain another grate-specific prompt here or in
the CodeRabbit UI. The YAML explicitly maps the documents under `docs/agents`
to all files, because their default directory scope would miss product code.

The YAML records the repository UI choices: Chill, automatic reviews and
incremental reviews on pushes, drafts excluded, automatic approvals disabled,
and summaries in the walkthrough with review details enabled. It keeps the
author's PR description intact. The general docstring coverage check and
docstring/unit-test generation are disabled. Keep future UI and YAML changes
aligned; the committed YAML takes precedence over repository UI settings.

## Connect the repository

An organization owner installs the
[CodeRabbit GitHub App](https://github.com/apps/coderabbitai/installations/new),
chooses **grate-devs**, then **Only select repositories → grate**, and completes
**Install & Authorize**. If prompted for CodeRabbit account authorization, use
[Login with GitHub](https://app.coderabbit.ai/login), select `grate-devs`, and
confirm that `grate` is connected. See the official
[GitHub integration guide](https://docs.coderabbit.ai/platforms/github-com).

Use the public repository's OSS access. CodeRabbit's
[plan documentation](https://docs.coderabbit.ai/management/plans) distinguishes
OSS access (Team features without a paid subscription) from the ordinary Free
plan (PR summaries). Confirm OSS entitlement in the dashboard; a trial review
alone does not establish ongoing OSS access. Do not add payment details, purchase
seats, or enable paid usage/agent products for this pilot. When limited, wait
for quota refill rather than purchasing reviews.

The App requests write permissions for several features; this is not a
read-only installation. This pilot disables automatic approvals, finishing-touch
code generation/fixes, and metadata automation. Use review/configuration commands
only. Do not invoke coding-agent tasks or merge/approve/resolve commands.
Repository owners retain control of branch rules. Keep CodeRabbit advisory and
do not make its check or approval a merge requirement during the pilot.

## Run and inspect a review

1. Use this configuration PR as the installation smoke check. A collaborator's
   same-repository PR uses its feature branch's YAML. Fork reviews use trusted
   target-branch settings; see [configuration via YAML](https://docs.coderabbit.ai/getting-started/yaml-configuration)
   and [guideline access rules](https://docs.coderabbit.ai/knowledge-base/code-guidelines).
   Merge the configuration before testing unrelated PRs, or explicitly prepare
   the same configuration/guidelines on a collaborator-owned pilot branch.
2. Comment `@coderabbitai configuration` to inspect the resolved settings and
   sources. Comment `@coderabbitai full review` to request one complete review.
   Review commands can explicitly review a draft; ordinary automatic draft
   reviews are disabled. A same-repository draft configuration PR can instead use
   the isolated `@coderabbitai review --preview-config` command (post it alone).
   Ready PRs targeting the default branch receive an automatic review, and pushes
   receive incremental reviews. Automatic review pauses after five reviewed
   commits. Use `@coderabbitai review` for a manual review or `@coderabbitai resume`
   to resume automatic reviews. No opt-in keyword is needed. Request a full review
   when warranted; avoid duplicating an active review.
   See the [command reference](https://docs.coderabbit.ai/reference/review-commands).
3. Inspect the summary's **Additional context used → Code guidelines**. Require
   the four configured files above to be listed; inspect skipped-source and
   parse warnings. Review details are enabled to expose other context and
   suppressed comments. Configuration validity proves parsing, not that every
   instruction reached the review prompt. If a source is missing, correct the
   scope/loading issue and rerun before evaluating the review quality.
4. Save the reviewed head SHA, resolved configuration, guideline list, review
   link, and skipped files/checks in the PR discussion. Distinguish configured,
   reported-as-loaded, and actually demonstrated behavior. Put run evidence in
   PR records, not in this document or committed log files.

## Evaluate a small pilot

Use three real, bounded PRs: one migration-policy/history or hash change, one
provider/transaction or existing-database compatibility change, and one test or
public API change. The configuration smoke check does not count as a product
review. Prefer current patches with independently known expectations and
verification; do not seed defects into mergeable code.

For each review, a maintainer records a small table in the PR discussion:

| Field | Evidence |
| --- | --- |
| Source and instructions | Head SHA, configuration source, loaded guidelines, review link |
| Confirmed defect | Comment link, trigger/consequence, reproducer or independent code evidence |
| False positive | Comment link and evidence explaining why the claimed defect is absent |
| Other advice | Duplicates, optional preferences, and unresolved hypotheses, counted separately |
| Known missed defect | Independently established defect in the reviewed diff, if any |
| Cost of review | Review latency and maintainer triage minutes |

After three completed product reviews, compare confirmed defects, false positives,
duplicate/style comments, known misses, and triage time. Report precision as
confirmed / (confirmed + false positives), or **not measurable** when that
denominator is zero. Do not infer recall from an unknown number of defects.
Keep or tune the review profile and instructions based on whether maintainers
judge the actionable findings worth the triage time. A silent review
is not acceptance or release approval. High-risk changes still need the separate
critical review and verification described in [verification](verification.md).

## Maintain the configuration

Validate changes against the current
[published schema](https://coderabbit.ai/integrations/schema.v2.json) or official
[YAML validator](https://docs.coderabbit.ai/configuration/yaml-validator), and
inspect `@coderabbitai configuration` on a real run. The
[configuration reference](https://docs.coderabbit.ai/reference/configuration)
defines the options; do not copy stale examples (for example, the legacy
`request_changes_workflow` alias instead of `reviews.auto_approvals.enabled`).
Schema validation and an actual App review are separate checks.
