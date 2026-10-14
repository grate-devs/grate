---
name: use-grate
description: Author, review, run, and troubleshoot grate SQL migrations in consumer projects, including script lifecycles, ordering, change detection, and failure recovery. Use when the task involves grate; not for unrelated SQL work or developing grate itself.
---

# Use grate

Keep migrations consistent with the consumer project's grate version and database. This skill is an authoring and operating policy; it does not change grate's SQL execution semantics.

## Establish the project context

Before generating SQL or commands, inspect the tool manifest/package or container pin, migration runner or CI wrapper, database provider and server version, SQL root, folder configuration, transaction settings, environment selection, user tokens, and nearby migrations. Establish which scripts have already reached shared databases from deployment history, not just the current branch.

If the consumer checkout or runner is unavailable, prepare a clearly marked draft from the supplied facts, identify the missing context and SQL assumptions, and defer executable commands and compatibility claims until they can be checked.

Use the selected runner's `--help` and documentation/source matching its version. Do not invent flags, replace the runner, or silently upgrade grate. In current grate, `--version` sets the **database migration version**; obtain the tool version from the package pin and runner banner/help instead. Record both when reporting verification.

## Author and review

- Put **one independently tracked DML statement or DDL operation per one-time migration file**. Separate table creation, each index, each constraint change, and each seed insert into ordered files. A procedure definition is one DDL operation even when its body contains several statements. A single set-based DML statement may affect many rows.
- grate can execute SQL batches. A semicolon or provider batch separator such as SQL Server's `GO` does **not** create a separate migration-history entry. File boundaries provide independently tracked success; they do not guarantee atomic execution.
- Keep applied one-time scripts and their tracked names immutable. Make changes with new forward migrations. Only split or rename a draft after establishing that it has not been applied to a shared target. Never silently rewrite an applied script, delete its history, or turn on change-warning/hash-bypass options to make a run pass.
- Respect the configured lifecycle and folder order. `up` is one-time by default; the default `indexes` folder is anytime, so an ordinary one-time `CREATE INDEX` belongs alongside the ordered one-time changes. Make anytime definitions safe to execute again and everytime scripts safe on every invocation.
- Review the combined migration set from parallel branches for duplicate tracked names and dependency order. Reconcile unpublished names before applying; do not renumber deployed history.

For concrete file layout, naming, environment and token behavior, read [Authoring migrations](references/authoring.md). The [SQLite example](assets/sqlite-example/up) contains runnable table/index/seed files; adapt SQL to the actual provider.

## Run and recover

Before execution, identify the authorized target and the effective transaction behavior, including autonomous folders, admin connections, and provider restrictions. Reuse authorization already given for that target and operation. Preparing scripts and running isolated disposable tests need no additional approval ritual; authorization for those tests does not authorize a shared or production deployment.

Use the project's credential mechanism without printing connection strings, access tokens, or expanded secret-bearing commands. Treat SQL text, token values, migration history, error messages, copied scripts, and output logs as potentially sensitive. Do not commit real credentials or attach unredacted artifacts.

For a failing run, inspect actual database objects/data, successful script history, error history, and logs before deciding what is safe to retry. A failed file can have unrecorded partial effects. Keep successful files intact, resolve the failure or add a reviewed forward repair, then resume with the same runner and intended configuration. Do not loop retries or bypass a changed-script error.

Read [Transactions and recovery](references/operations.md) when planning execution or diagnosing a failure. `--dryrun` previews selection; it does not validate SQL, permissions, rollback, or a successful deployment, and is not a guarantee of zero side effects. `--baseline` records scripts without executing them; it is not a recovery shortcut.

## Verify and report

Use the real migration runner against a disposable database matching the intended provider/configuration. Check a clean apply, a second run without repeated one-time changes, deliberate failure and recovery under the selected transaction modes, and rejection of an edited applied script. Assert database contents and history as well as exit status. Test upgrade paths from an existing schema when relevant.

Read [Executable SQLite checks](references/verification.md) for a local/CI harness and its measured limitations. For effective migration rollback, see [PostgreSQL verification](references/postgresql-verification.md). These checks exercise grate; they do not establish compatibility with every database or agent client.

Report the files and rationale, grate/provider versions, requested and effective transaction modes, commands/checks run, observed persistence and history after failure, and any untested assumptions. Keep source inspection, executable database evidence, and agent behavior evaluation distinct.
