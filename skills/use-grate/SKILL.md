---
name: use-grate
description: Author, review, run, and troubleshoot grate SQL migrations in consumer projects, including script lifecycles, ordering, change detection, and recovery. Use for projects using or adopting grate, including migration from RoundhousE; not for unrelated SQL work or developing grate itself.
---

# Use grate

Use the consumer project's runner, grate version, and database dialect. This skill defines an authoring and operating policy; it does not change grate's SQL execution semantics.

## Start with the requested task

Read the relevant reference when it helps the task; do not load every reference by default. Resolve bundled paths relative to this `SKILL.md`, wherever the skill is installed.

| Task | Reference |
| --- | --- |
| Set up a runner, inspect `.rsp` files, or migrate from RoundhousE | [Consumer workflows](references/consumer-workflows.md) |
| Add or review migrations, select folders, order parallel changes, or use environments/tokens | [Authoring migrations](references/authoring.md) |
| Plan execution, understand transactions, or recover a failure | [Transactions and recovery](references/operations.md) |
| Run the optional SQLite behavior checks | [Executable SQLite checks](references/verification.md) |
| Check evidence for effective PostgreSQL rollback | [PostgreSQL verification](references/postgresql-verification.md) |

## Establish the project context

Find the tool manifest/package or container pin and the actual runner/CI wrapper, including response files and its working directory. Inspect the provider/server version, SQL root, configured folders, transaction settings, environments, tokens, and nearby migrations. Establish deployed script names/content from deployment history, not just the current branch.

Use the selected runner's `--help` and documentation/source matching its version. Do not invent flags, replace the runner, or silently upgrade grate. Specify the intended database provider explicitly when constructing a command; the CLI defaults to SQL Server. `--version` labels the **database migration**, not the CLI release; report both versions separately.

If context is missing, prepare a clearly marked draft with the missing facts and SQL assumptions. Defer executable commands and compatibility claims until the runner and target configuration can be checked.

## Author and review

- Put **one independently tracked DML statement or DDL operation per one-time migration file**. Separate table creation, each index, each constraint change, and each seed insert into ordered files. A procedure definition remains one DDL operation even with several body statements. A single set-based DML statement may affect many rows.
- grate can execute SQL batches. Semicolons and provider batch separators such as SQL Server's `GO` do **not** create separate migration-history entries. File boundaries provide independently tracked success, not guaranteed atomicity.
- Keep applied one-time scripts and their tracked names immutable. Add forward migrations. Only split or rename drafts after establishing they have not reached any shared target. Never silently rewrite applied SQL, delete history, or enable change-warning/hash-bypass options to make a run pass.
- Respect configured lifecycles and folder order. `up` is one-time by default; `indexes` is anytime, so ordinary one-time `CREATE INDEX` operations belong with ordered one-time changes. Anytime definitions must tolerate re-execution; everytime scripts must be safe on every invocation.
- Check the combined migration set across parallel branches for duplicate tracked names and dependency order. Reconcile unpublished names before applying; do not renumber deployed history.

The [SQLite table/index/seed example](assets/sqlite-example/up) demonstrates separate operations. Adapt its SQL to the actual provider; do not treat it as a portable schema template. grate has no automatic `down` migration: plan forward repairs and any required data restoration explicitly.

## Run and recover

Identify the authorized target and effective transaction behavior, including autonomous folders, admin connections, and provider restrictions. Reuse authorization already given for that target/operation. Preparing SQL and running isolated disposable tests need no additional approval ritual; they do not authorize a shared or production deployment.

Use the project's credential mechanism without printing connection strings, tokens, or expanded secret-bearing commands. SQL text, response files, history, copied scripts, and output/error logs can expose sensitive values; inspect and redact artifacts before sharing.

For a failure, inspect actual schema/data, successful history, error history, and logs before retrying. A failed file can have unrecorded partial effects. Preserve successful files, resolve the failure or design a forward repair, and resume with the intended runner/configuration. Do not loop retries or bypass changed-script errors.

`--dryrun` previews selection, not SQL validity, permissions, rollback, or deployment success; it does not guarantee zero effects. `--baseline` records scripts without executing them and is not a recovery shortcut. Consult the recovery reference before relying on either.

## Verify and report

Test a migration change with the real runner on a disposable database matching the intended provider/configuration: exercise clean apply or a representative upgrade path, assert schema/data and history, then verify an unchanged rerun. When making transaction/recovery claims or adopting a runner, also test deliberate failure, inspected recovery, and rejection of an edited applied one-time script. A successful CLI exit alone is insufficient.

The optional SQLite verifier uses shell/PowerShell wrappers and requires .NET SDK 10 or newer. Exit **77** means verification was skipped, not passed. Continue the rest of the task and report the gap without automatically installing an SDK. SQLite checks do not establish rollback or compatibility for other providers; distinguish them from the PostgreSQL evidence and actual project-provider tests.

Report changed files and rationale, grate/provider versions, requested/effective transaction modes, checks actually run, observed persistence/history after failure, and untested assumptions. Keep source inspection, executable evidence, and agent behavior evaluation distinct.
