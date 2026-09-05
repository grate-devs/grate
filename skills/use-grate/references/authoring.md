# Authoring migrations

## Lifecycles and order

Read the project's actual folder mapping before choosing a location. Folder names alone do not establish the type when configuration is customized.

| Type | Normal behavior | Authoring choice |
| --- | --- | --- |
| Once | A new tracked file executes; an unchanged successful file is skipped; changed content raises an error by default. | Ordered schema changes and one-time data changes. |
| AnyTime | New or changed files execute. | Repeatable definitions such as views/procedures, using provider-appropriate replace/alter semantics. |
| EveryTime | Executes on each migration invocation. | Deliberately repeatable work, such as permissions. |

The default `up` folder is Once; `functions`, `views`, `sprocs`, `triggers`, and `indexes` are AnyTime. `beforeMigration`, `permissions`, and `afterMigration` are EveryTime. The filename marker `EVERYTIME.` or `.EVERYTIME.` can also force repeat execution, even inside `up`; do not accidentally use it for one-time changes.

Configured folder order takes precedence over names in different folders. Within a folder grate orders scripts alphabetically, including relative subdirectory paths by default. The `--ignoredirectorynames` option changes sorting and tracked identity to filenames alone. Current sorting ignores case and uses the current culture; avoid names differentiated only by case or locale-sensitive characters.

Tracked names are relative to the configured migration folder, or just the basename with directory names ignored. History lookup does not namespace these names by folder type. Check uniqueness across the whole configured migration set, including subfolders and parallel branches.

## One operation per one-time file

The [runnable SQLite example](../assets/sqlite-example/up) separates table creation, indexes and seeds. For a new feature with a later constraint change, the intended shape is:

```text
up/
  20260905210000_issue821_01_create_widget.sql
  20260905210000_issue821_02_create_widget_name_index.sql
  20260905210000_issue821_03_add_widget_name_constraint.sql
  20260905210000_issue821_04_insert_initial_widget.sql
```

Use the consumer's existing convention when possible. Each index gets its own file; each separate `INSERT`, `UPDATE`, or `DELETE` gets its own file. Constraint alteration syntax and support vary by provider: the names above illustrate ordering, not portable SQL. A provider-required table rebuild may itself be one coordinated DDL operation; explain and test its atomicity instead of splitting an inseparable operation into an invalid sequence.

For SQL Server, this **single file still has only one successful history entry**:

```sql
CREATE TABLE dbo.Widget (Id int NOT NULL PRIMARY KEY, Name nvarchar(100));
GO
CREATE INDEX IX_Widget_Name ON dbo.Widget(Name);
GO
INSERT INTO dbo.Widget (Id, Name) VALUES (1, N'Initial');
```

`GO` controls batches, not grate's migration identity. Under ineffective transactions the table may survive an index or insert failure while the file has no successful history entry. Author those three operations in three ordered files. A `CREATE PROCEDURE` with multiple body statements remains one DDL operation; do not split its body into migrations.

## Parallel branches and applied history

Use a team-unique change identifier plus a zero-padded operation suffix, following local conventions. For example, independent changes can use `20260905210000_issue821_01_...` and `20260905210000_issue822_01_...`, even if their timestamps coincide. Timestamps alone do not guarantee uniqueness, and unique names alone do not ensure dependency order.

Before merge/apply, inspect both branches together. If B depends on A, make B sort after every required A operation in the appropriate folder. Resolve duplicate names or unsuitable order while the files are unpublished, and replay the combined set from empty and representative prior schemas. If either branch has deployed, preserve those names/content and design a forward migration against the actual deployed state. grate does not infer dependencies or replay all previously applied scripts when a newly added filename sorts earlier.

If asked to edit an applied seed from `Initial` to `Updated`, preserve the original insert and add a new `UPDATE` migration. A changed-script error is a signal to compare the original artifact and token configuration, not permission to change hashes. Neither warning mode is a routine repair: one reruns changed scripts; the other updates history without applying the changed SQL.

## Environments and tokens

Ordinary files run regardless of environment. A file containing `.ENV.` runs only when a selected environment matches a dot-delimited name component, case-insensitively; without a selected environment it is skipped. For example, `20260905210000_issue821_05_seed.ENV.TEST.sql` selects TEST and must remain separate from shared seed changes. Check the installed CLI's syntax for multiple environments; older documentation and versions differ.

Tokens use `{{TokenName}}` and are replaced before change detection and execution. Current grate accepts separate `--ut=Key=Value` arguments for user tokens. This is textual substitution, not parameter binding or automatic identifier/value quoting. Use only intended values and provider-correct SQL quoting. Changing a token value can make an unchanged file appear changed, including a Once file. Expanded SQL can appear in history and error output, so do not use secrets as SQL tokens casually.

## Upstream sources

Start with [script types](https://github.com/grate-devs/grate/tree/main/docs/ScriptTypes), [folder configuration](https://github.com/grate-devs/grate/blob/main/docs/ConfigurationOptions/FolderConfiguration.md), [environments](https://github.com/grate-devs/grate/blob/main/docs/EnvironmentScripts.md), and [tokens](https://github.com/grate-devs/grate/blob/main/docs/TokenReplacement.md). Select the tag/commit matching the consumer's version.

For version-sensitive details, inspect [FoldersConfiguration](https://github.com/grate-devs/grate/blob/main/src/grate.core/Configuration/FoldersConfiguration.cs), [FileSystem](https://github.com/grate-devs/grate/blob/main/src/grate.core/Migration/FileSystem.cs), [GrateMigrator](https://github.com/grate-devs/grate/blob/main/src/grate.core/Migration/GrateMigrator.cs), [DbMigrator](https://github.com/grate-devs/grate/blob/main/src/grate.core/Migration/DbMigrator.cs), and [GrateEnvironment](https://github.com/grate-devs/grate/blob/main/src/grate.core/Infrastructure/GrateEnvironment.cs). For example, current code configures `runAfterCreateDatabase` and `runFirstAfterUp` as AnyTime despite conflicting older documentation.
