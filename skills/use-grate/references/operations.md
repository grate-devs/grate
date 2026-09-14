# Transactions and recovery

## Determine what the selected runner will do

Record the grate package/binary version, database provider/server version, effective command/wrapper settings, folder connection/transaction overrides, and any explicit SQL transaction control. Use the installed runner's help to construct commands. `--transaction` is false by default in the source inspected here; passing it is not proof that the requested transaction takes effect.

The following describes source inspected at commit `6226b28d22f962ab8ca264575b124a04ea7fadf7`. Recheck the corresponding implementation when using a different release.

| Provider implementation | grate advertises DDL transaction support | Implication |
| --- | --- | --- |
| SQL Server | Yes | Default-participating migration scripts can share the migration transaction. Verify the actual SQL and connection configuration. |
| PostgreSQL | Yes | Default-participating migration scripts can share the migration transaction. Some database operations cannot run inside it. |
| SQLite | No | grate warns and disables the requested transaction. This is grate provider behavior, not a claim that SQLite itself cannot transact DDL. |
| MariaDB / Oracle | No | grate warns and disables the requested transaction. Do not promise migration-wide rollback. |

Do not infer tested provider compatibility from this source table. Measured evidence is in the [SQLite](verification.md) and [PostgreSQL](postgresql-verification.md) verification references.

## Success, commit and failure

grate executes the provider's statements/batches for a file, then writes that file's successful history entry. There is no success entry per semicolon or `GO` separator.

With an effective migration transaction, participating SQL and successful script-history entries commit together after the migration completes. On a participating failure they roll back. Work from earlier successful migration invocations remains. Database creation, bootstrapping, version metadata and autonomous work have separate lifetimes: “transactional migration” does not mean the entire invocation has no persistent effects on failure.

Without an effective migration transaction, SQL follows the provider's own commit rules, including implicit commits and explicit transactions in scripts. Earlier successful files and their history can remain after failure. Earlier operations **within the failing file** may also remain, without a successful record for that file. One operation per file narrows this recovery problem but does not make SQL and subsequent history insertion universally atomic.

On script failure, grate attempts to roll back the active transaction, closes the connection, and records the error through a connection outside the failed transaction. Inspect the configured `ScriptsRun`, `ScriptsRunErrors`, and `Version` tables using the provider's identifier quoting (SQLite defaults to `grate_ScriptsRun`, `grate_ScriptsRunErrors`, and `grate_Version`). Metadata or error-recording failures are possible; logs alone are not a complete state inventory. A version row is not proof that every script succeeded.

`TransactionHandling:Autonomous` excludes a folder from the surrounding migration transaction; it does not promise one atomic transaction per file. Defaults include autonomous `beforeMigration`, `alterDatabase`, `permissions`, and `afterMigration`; `alterDatabase` also uses the admin connection. After a script failure, remaining files in that folder stop and later default-participating folders are skipped, while later autonomous folders may still execute. Inspect their effects too, and do not assume cleanup completed merely because a folder is configured.

## Recovery procedure

1. Stop automatic retries. Identify the exact target, runner/configuration, failed filename and provider error. Preserve and redact relevant output.
2. Compare actual objects and rows with successful history and the failing SQL. Establish which earlier operations committed, which history entries survived, and whether the failed file has partial effects. Check other shared targets before calling a file unpublished.
3. Preserve applied scripts and their tracked names. For accidental edits, restore the deployed artifact (and investigate changed token values), then express the desired change in a new forward migration. Do not remove history or pass warning/bypass flags.
4. For a file that has never succeeded anywhere shared, a correction can be appropriate after accounting for partial effects. In a disposable database, recreating it is straightforward. In a shared database, repair only the verified residual state using the project's authorized recovery procedure. If repairing with a new file, account for ordering: a later file will not run past an earlier failure. Do not blindly rerun a partially applied batch or rename it to evade detection.
5. Replay the proposed recovery on a disposable reproduction with the same provider/settings. Resume the authorized target with the intended runner and verify data, schema, successful history and error status. Stop again on an unexpected failure.

## Preview and credentials

`--dryrun` skips normal migration SQL and success-history writes while showing selection. It does not prove SQL validity, server permissions, transaction compatibility, or deployment success. Current source has paths outside those guards: database create/drop/restore setup and changed-one-time-script error recording can still have effects; output folders and copied scripts are also produced. Use a disposable target for previews, and do not combine preview with drop/restore. A database read-only credential can enforce a boundary, but some preview/error paths may then fail.

Use the project's secret injection and logging controls. Do not echo expanded connection strings or enable shell tracing around them. SQL text is stored by default, and even suppressing successful script text does not guarantee secrets disappear from error statements, logs or copied source files. Inspect before publishing CI artifacts.

## Source map

- [GrateMigrator](https://github.com/grate-devs/grate/blob/main/src/grate.core/Migration/GrateMigrator.cs): setup, transaction support check, migration/version scope and folder processing.
- [DbMigrator](https://github.com/grate-devs/grate/blob/main/src/grate.core/Migration/DbMigrator.cs): statement execution, successful history, token/hash checks and failure recording.
- [AnsiSqlDatabase](https://github.com/grate-devs/grate/blob/main/src/grate.core/Migration/AnsiSqlDatabase.cs): connections, transaction handling and tracking queries.
- Provider implementations: [SQLite](https://github.com/grate-devs/grate/blob/main/src/grate.sqlite/Migration/SqLiteDatabase.cs), [PostgreSQL](https://github.com/grate-devs/grate/blob/main/src/grate.postgresql/Migration/PostgreSqlDatabase.cs), [SQL Server](https://github.com/grate-devs/grate/blob/main/src/grate.sqlserver/Migration/SqlServerDatabase.cs), [MariaDB](https://github.com/grate-devs/grate/blob/main/src/grate.mariadb/Migration/MariaDbDatabase.cs), [Oracle](https://github.com/grate-devs/grate/blob/main/src/grate.oracle/Migration/OracleDatabase.cs).
