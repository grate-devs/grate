---
layout: default
title: Migration tables
permalink: /migration-tables/
nav_order: 7
---

# Migration tables

grate creates two sets of migration tables in the target database. `ScriptsRun`,
`ScriptsRunErrors`, and `Version` track **your SQL migrations**. `GrateScriptsRun`,
`GrateScriptsRunErrors`, and `GrateVersion` track **grate's own migrations**, which
create and update the tables used to record migration history.

Seeing all six tables is expected. The `Grate*` tables do not contain a second copy
of your application's migration history.

## What each table records

| Your migration history | grate's internal migration history | Purpose |
| --- | --- | --- |
| `ScriptsRun` | `GrateScriptsRun` | Records scripts applied, including their names, content hashes, script text, one-time flag, and associated `version_id`. grate uses this history to decide whether a script is new or has changed. |
| `ScriptsRunErrors` | `GrateScriptsRunErrors` | Records script failures, including the script name, version, error message, and the part of the script that failed. |
| `Version` | `GrateVersion` | Records migration versions, timestamps, and status. `Version` uses your configured `--version`; `GrateVersion` uses the version of the grate executable performing the internal migration. |

For example, if you run `up/001_create_customers.sql` with `--version=2026.10.1`,
its history belongs in `ScriptsRun`, linked through `version_id` to a `Version`
row for `2026.10.1`. A bundled script that creates or updates `ScriptsRun` belongs
in `GrateScriptsRun`, linked to `GrateVersion` instead. If your customer-table
script fails, look in `ScriptsRunErrors`; if an internal table migration fails,
look in `GrateScriptsRunErrors` and the migration log.

The history tables also have a few details worth knowing when inspecting a run:

- With `--baseline`, your scripts are recorded without being executed. A
  `ScriptsRun` entry therefore does not always mean that grate executed the SQL.
- `--donotstorescriptsruntext` omits the full text of your scripts from the history;
  it does not disable history tracking.
- A version row starts with status `In Progress` and is marked `Finished` after
  a successful migration. A failed or interrupted run can leave an `In Progress`
  row, so the presence of a version row alone does not prove success.
- A successful run that applies no scripts removes its new version row, except
  in baseline mode. In particular, `GrateVersion` is internal migration history,
  not an inventory of every grate executable version ever run against the database.

See [Script types](ScriptTypes/index.md) for how script history affects subsequent
runs, and [Configuration options](ConfigurationOptions/index.md) for the flags above.

## Why grate needs its own history

The migration tables can change as grate evolves. For example, grate added a
`status` column to the `Version` table. It uses bundled SQL migrations to make
these changes, and records which changes have already been applied in each
database.

Before running your migration folders, grate bootstraps its internal history
tables and applies the bundled migrations needed to create or upgrade the
migration tables. This also maintains the `Grate*` tables themselves. Your SQL
migrations then run using the separate application history.

The bundled scripts ship with grate, but their execution history belongs in the
target database: different databases may have been initialized or upgraded with
different grate versions.

## Where the tables live

All six tables use the same `--schema` setting, which defaults to `grate`.
This setting controls the location of migration history; it does not select the
schema for objects created by your SQL scripts.

| Database provider | Default naming examples |
| --- | --- |
| SQL Server | `grate.ScriptsRun`, `grate.GrateScriptsRun` |
| PostgreSQL | `"grate"."ScriptsRun"`, `"grate"."GrateScriptsRun"` |
| SQLite, MariaDB/MySQL, Oracle | `grate_ScriptsRun`, `grate_GrateScriptsRun` (the schema setting is used as a table-name prefix) |

To keep history in the `grate` schema while your scripts manage other application
schemas, keep `--schema=grate` and qualify your application objects in the scripts.
Running with different `--schema` values creates separate sets of history tables.
There is no separate schema setting for only the `Grate*` tables.

For an existing database, keep using its established history schema. Changing
`--schema` does not move the existing records and can make previously applied
scripts appear new.

## Can the internal tables be disabled or deleted?

There is no supported option to disable the `Grate*` history tables during normal
migrations. They are part of grate's migration infrastructure, including in
production databases. Leave both sets of tables in place: deleting or editing
their history can cause grate to attempt migrations that were already applied.

## What happens when migrating from RoundhousE?

When grate recognizes existing migration tables from RoundhousE or an older grate
version, it records their baseline creation scripts without recreating those
tables, then applies the required internal upgrades. The additional `Grate*`
tables track this work; your existing migration history stays in `ScriptsRun`,
`ScriptsRunErrors`, and `Version`.

Use the existing history schema (for example, `--schema=RoundhousE`). See
[Migrating from RoundhousE](MigratingFromRoundhousE.md) for the other migration steps.
