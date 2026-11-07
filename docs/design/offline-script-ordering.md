# Offline script ordering for SQL Server

Draft proposal for [#631](https://github.com/grate-devs/grate/issues/631), following the earlier discussion about [declared dependencies](https://github.com/grate-devs/grate/discussions/242).

Today grate processes the entire `functions` folder before `views`. A view that reads from a function and a second function that reads from that view need the folders to interleave. Sorting files within each folder cannot express that order. The SQL definitions already contain the references needed for this example. [User example in #630](https://github.com/grate-devs/grate/discussions/630) · [Default folder order](../../src/grate.core/Configuration/FoldersConfiguration.cs)

## Plan in CI, apply during deployment

1. **Plan offline.** A command such as `grate plan` reads the SQL files and folder configuration from a checkout. It requires only local inputs, including the SQL dialect and any settings needed to interpret the files. It can run with network access disabled and without database credentials or a SQL Server instance.
2. **Publish the plan with the scripts.** The generated artifact records the ordered relative paths, the references that determined their order, and references outside the planned group. Identical inputs produce identical output. Include a fingerprint of the candidate paths, file contents and relevant configuration so deployment can reject a stale plan.
3. **Apply the plan.** When a plan is supplied, grate validates it against the deployment inputs before starting the migration. The plan orders the candidate scripts. The existing migration history still determines which scripts are eligible to run, using their existing names and hashes. The migration runner applies the existing connection and transaction policies.

The current `--dryrun` can query migration history to preview what would run against a particular database. The offline plan answers which order the source definitions require. [Current history lookup](../../src/grate.core/Migration/AnsiSqlDatabase.cs)

## First slice

Opt in one group of adjacent `AnyTime` folders after `up`, initially `functions` and `views`. The folders in the group must use the same connection and transaction settings. Use the configured folder sequence for `up`, hooks and all folders outside the group. The first slice covers one `CREATE OR ALTER VIEW` or T-SQL `CREATE OR ALTER FUNCTION` per file, with schema-qualified references between local objects. Use ordinary `AnyTime` files for the prototype and report unsupported input explicitly.

The SQL Server provider identifies object definitions and references. It returns provider-neutral data to the planner, which maps objects to files and sorts the dependency graph. Use the group's existing order to break ties deterministically. Keep SQL parsing and object matching inside the provider. Start with exact schema and object names and report ambiguous matches. Evaluate [ScriptDOM](https://github.com/microsoft/SqlScriptDOM) against representative scripts and try the [DacFx object model](https://learn.microsoft.com/en-us/dotnet/api/microsoft.sqlserver.dac.model.tsqlobject.getreferenced?view=sql-dacfx-162) if resolving names requires more than the syntax tree.

For example, the plan would emit this order using the files as written.

1. `functions/dbo.fnOrderTotals.sql` defines `dbo.fnOrderTotals`.
2. `views/dbo.vOrders.sql` reads from `dbo.fnOrderTotals()`.
3. `functions/dbo.fnReport.sql` reads from `dbo.vOrders`.

A cycle or duplicate definition should fail planning and name the files involved. Report references with no matching definition in the group separately, with the referring file and object name. A table such as `dbo.Orders` might come from `up` or a pre-existing schema. Its presence remains a deployment assumption. Report unsupported constructs that prevent analysis, such as tokens in object names when their values are unavailable during planning.

The plan describes dependencies in the proposed definitions. The starting schema can impose additional constraints. For example, an existing schema-bound view can block an `ALTER TABLE` even when the proposed view and function definitions have a valid order. Such changes may need an explicit migration step. [SQL Server rules for schema-bound views](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-view-transact-sql?view=sql-server-ver17#schemabinding)

## Optional dependency declarations

For cases where the inferred dependencies need correcting, a script can declare which files must precede it. The syntax below follows the comment style in the original prototype. Use paths relative to the configured SQL scripts directory. [Prototype documentation](https://github.com/RachelAmbler/eGrate/blob/main/docs/ConfigurationOptions/DependencyHandling.md)

```sql
-- Dependencies: views/dbo.vOrders.sql
```

A declaration supplies the complete list of prerequisites for that script. The planner uses those paths in place of the script's inferred prerequisites. It still infers dependencies for files without a declaration, including dependencies from other scripts on the declaring script. The generated plan identifies each dependency as declared or inferred.

Every declared path must name a file in the planned group. A missing path or a cycle in the combined graph fails offline planning and identifies the files involved. Editing a declaration changes the script text, so the existing `AnyTime` change detection can schedule that script to run again.

## Runnable prototype

The [standalone experiment](offline-script-ordering-poc/README.md) reads the
three example definitions from local files and emits their ordered paths and
dependency reasons as JSON. It fixes the candidate group to the default
`functions` and `views` folders. ScriptDOM is a dependency of the experiment
alone.

The SQL Server check applies the emitted order in a disposable database. The
upgrade changes the view and the function that reads it, leaving the first
function intact. The check applies those two files in plan order and queries the
result. It also tries the conflicting folder order on an empty database and
tries applying the changed function before the changed view during upgrade.

The JSON is an observation of the candidate order. Plan validation at deployment,
grate's script eligibility and history, and integration with the existing folder
runner are separate work covered by the criteria below.

The [PostgreSQL experiment](postgresql-script-ordering-poc/README.md) compares
libpg_query and SqlParserCS against shared dependency scenarios and a disposable
PostgreSQL database. Its parser-specific adapters feed one shared planner.

## Verification before implementation is ready

- Run the planner with networking disabled and no SQL Server configuration. The three files above must produce the same order and explain both dependencies across the folder boundary.
- Check that a cycle and duplicate definitions give actionable errors, and that an object supplied outside the group is reported separately.
- Give a script a declaration that disagrees with the inferred prerequisites. Verify that the declared paths determine its prerequisites, undeclared scripts still use inference, and the plan identifies the source of each dependency. Check that a missing declared path or a cycle involving a declaration fails planning.
- Apply the plan to an empty disposable SQL Server database, then rerun with unchanged scripts. Verify the objects and migration history, including that unchanged `AnyTime` scripts are skipped.
- Upgrade a disposable database with two dependent definitions changed together. Verify the new definitions and the expected history entries. Reject a plan if a script was added, removed or changed after planning.
- Run the same fixture without opting in and verify grate still follows the configured folder order.

The prototype should establish which SQL Server constructs can be handled confidently before the command name, artifact format and supported syntax are finalized.
