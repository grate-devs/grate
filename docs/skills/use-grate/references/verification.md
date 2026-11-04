---
title: Verify the project's migrations
---

# Verify the project's migrations

Use the consumer project's pinned grate runner and a disposable database matching
its provider, server version, folder mapping, tokens, environments and transaction
settings. Reuse its existing verification tooling. The skill adds no test runner
or SDK requirement of its own.

## Check the intended change

1. Reproduce a representative existing schema and migration history when testing
   an upgrade. Also check a clean apply when new-database creation is supported.
2. Run the actual project migrations and assert the expected schema, index and
   constraint definitions, affected rows, and successful history. Check forbidden
   effects too: a successful exit alone does not establish correctness.
3. Run again unchanged. One-time changes must preserve data and successful
   history; account separately for intentional anytime/everytime effects and
   version/log records that may change.
4. When verifying change detection or adopting a runner, edit an applied one-time
   file only in the disposable fixture. Confirm rejection and inspect the
   unchanged data/hash/history. Restore the original bytes and check that a new
   forward migration applies the intended change once.
5. When relying on transaction or recovery behavior, inject a controlled failure
   after earlier work. Inspect actual persisted objects/rows, successful history
   and error history before retrying. Reproduce and test the proposed repair;
   assert an unchanged rerun after recovery.

Follow [transactions and recovery](operations.md) for partial effects, autonomous
folders and preview limits. A failed file can have unrecorded committed work;
changing a successfully applied file or retrying blindly is not a recovery plan.

## Keep the evidence within its scope

The bundled [SQLite SQL example](../assets/sqlite-example/up/index.md) demonstrates one
operation per one-time file. Adapt it to the actual provider; checking that
example cannot validate a project's own migrations. grate's SQLite provider
disables requested migration transactions, so SQLite partial-persistence checks
cannot establish rollback behavior for SQL Server or PostgreSQL.

Report the runner/provider versions, configuration, commands/checks run, observed
schema/data/history, requested and effective transaction behavior, and remaining
assumptions. If the appropriate disposable environment is unavailable, leave a
verification plan and state what was not tested. Do not install a different grate
version or additional runtime automatically to manufacture a pass.
