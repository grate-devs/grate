---
title: Authoring migrations
---

{% raw %}

# Authoring migrations

## Lifecycles and order

Read the project's actual folder mapping before choosing a location. Folder names alone do not establish the type when configuration is customized.

| Type | Normal behavior | Authoring choice |
| --- | --- | --- |
| Once | A new tracked file executes; an unchanged successful file is skipped; changed content raises an error by default. | Ordered schema changes and one-time data changes. |
| AnyTime | New or changed files execute. | Repeatable definitions such as views/procedures, using provider-appropriate replace/alter semantics. |
| EveryTime | Executes on each migration invocation. | Deliberately repeatable work, such as permissions. |

The default `up` folder is Once; `functions`, `views`, `sprocs`, `triggers`, and `indexes` are AnyTime. `beforeMigration`, `permissions`, and `afterMigration` are EveryTime. The filename marker `EVERYTIME.` or `.EVERYTIME.` can also force repeat execution, even inside `up`; do not accidentally use it for one-time changes. For repeatable object definitions, prefer the provider's replace/alter pattern that preserves required permissions and dependencies over an unconditional drop/create.

`runAfterCreateDatabase` is only processed when grate created the database during that invocation; adding a file there will not initialize an existing database. The source inspected here configures both that folder and `runFirstAfterUp` as AnyTime, despite conflicting published documentation. Check the selected release before relying on either lifecycle. Unused default folders need not exist on disk.

Configured folder order takes precedence over names in different folders. Within a folder grate orders scripts alphabetically, including relative subdirectory paths by default. The `--ignoredirectorynames` option changes sorting and tracked identity to filenames alone. Current sorting ignores case and uses the current culture; avoid names differentiated only by case or locale-sensitive characters.

Tracked names are relative to the configured migration folder, or just the basename with directory names ignored. History lookup does not namespace these names by folder type. Check uniqueness across the whole configured migration set, including subfolders and parallel branches.

## Custom folder configuration

Read [folder configuration](https://grate-devs.github.io/grate/folder-configuration/) and inspect the actual `--folders` value or configuration file before adding a folder:

- If every key is a known default key, grate overlays the supplied settings on the defaults. For example, `--folders 'up=ddl;views=projections'` renames two paths while retaining the other default folders and their order.
- If any key is custom, the supplied list replaces the default set and defines its order. A typo or a newly added custom key can therefore omit existing migration folders. Set the intended `Path`, `Type`, `ConnectionType`, and `TransactionHandling` deliberately; a new custom folder otherwise defaults to Once, the default connection, and participation in the surrounding transaction.

Quote semicolon-separated arguments for the shell, or reuse the project's folder configuration file. Do not change folder mapping, directory-name handling, or script identity merely to make a new file run; check the resulting selection against deployed history first.

## One operation per one-time file

The [runnable SQLite example](../assets/sqlite-example/up/index.md) separates table creation, indexes and seeds. For a new feature with a later constraint change, the intended shape is:

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

`GO` controls batches, not grate's migration identity. Under ineffective transactions the table may survive an index or insert failure while the file has no successful history entry. Author those three operations in three ordered files. A `CREATE PROCEDURE` with multiple body statements remains one DDL operation; do not split its body into migrations. Batch parsing is provider- and version-specific: do not add SQL Server `GO`, Oracle `/`, or client-specific delimiters to another provider's scripts without checking its grate splitter and executing a representative definition.

## Parallel branches and applied history

Use a team-unique change identifier plus a zero-padded operation suffix, following local conventions. For example, independent changes can use `20260905210000_issue821_01_...` and `20260905210000_issue822_01_...`, even if their timestamps coincide. Timestamps alone do not guarantee uniqueness, and unique names alone do not ensure dependency order.

Before merge/apply, inspect both branches together. If B depends on A, make B sort after every required A operation in the appropriate folder. Resolve duplicate names or unsuitable order while the files are unpublished, and replay the combined set from empty and representative prior schemas. If either branch has deployed, preserve those names/content and design a forward migration against the actual deployed state. grate does not infer dependencies or replay all previously applied scripts when a newly added filename sorts earlier.

If asked to edit an applied seed from `Initial` to `Updated`, preserve the original insert and add a new `UPDATE` migration. A changed-script error is a signal to compare the original artifact and token configuration, not permission to change hashes. Neither warning mode is a routine repair: one reruns changed scripts; the other updates history without applying the changed SQL.

## Environments and tokens

See [environment scripts](https://grate-devs.github.io/grate/environment-scripts/) for environment selection. Ordinary files run regardless of environment. A file containing `.ENV.` runs only when a selected environment matches a dot-delimited name component, case-insensitively; without a selected environment it is skipped. For example, `20260905210000_issue821_05_seed.ENV.TEST.sql` selects TEST and must remain separate from shared seed changes. Check the installed CLI's syntax for multiple environments; older documentation and versions differ.

One file can target several environments, for example `seed.ENV.TEST.UAT.sql`. Current source also accepts multiple selected environments via comma/semicolon-separated values; the published environment page still describes a single selection. Verify the pinned runner rather than treating that older restriction as current behavior. Keep environment names distinct from other dot-delimited filename components, because matching is not limited to the text after `ENV`.

See [token replacement](https://grate-devs.github.io/grate/token-replacement/) for supported tokens and user-token syntax. Tokens use `{{TokenName}}` and are replaced before change detection and execution. Current grate accepts separate `--ut=Key=Value` arguments for user tokens. This is textual substitution, not parameter binding or automatic identifier/value quoting. Use only intended values and provider-correct SQL quoting. Changing a token value can make an unchanged file appear changed, including a Once file. Expanded SQL can appear in history and error output, so do not use secrets as SQL tokens casually.

Token names are case-insensitive, but only the selected version's built-in tokens and supplied user tokens are available. An unrecognized `{{TokenName}}` remains in the SQL instead of causing an early configuration error. Check intended expansion in the disposable fixture; an unresolved token inside a quoted SQL value can otherwise be stored as literal data. Do not introduce tokens where ordinary provider SQL would suffice.

## Upstream sources

Start with [script types](https://grate-devs.github.io/grate/script-types/), [folder configuration](https://grate-devs.github.io/grate/folder-configuration/), [environments](https://grate-devs.github.io/grate/environment-scripts/), and [tokens](https://grate-devs.github.io/grate/token-replacement/). Select the tag/commit matching the consumer's version.

For version-sensitive details, inspect [FoldersConfiguration](https://github.com/grate-devs/grate/blob/main/src/grate.core/Configuration/FoldersConfiguration.cs), [FileSystem](https://github.com/grate-devs/grate/blob/main/src/grate.core/Migration/FileSystem.cs), [GrateMigrator](https://github.com/grate-devs/grate/blob/main/src/grate.core/Migration/GrateMigrator.cs), [DbMigrator](https://github.com/grate-devs/grate/blob/main/src/grate.core/Migration/DbMigrator.cs), and [GrateEnvironment](https://github.com/grate-devs/grate/blob/main/src/grate.core/Infrastructure/GrateEnvironment.cs). For example, current code configures `runAfterCreateDatabase` and `runFirstAfterUp` as AnyTime despite conflicting older documentation.

{% endraw %}
