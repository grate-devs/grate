---
title: "Home"
nav_order: 1
---

# grate

SQL scripts migration runner

**Database migrations in plain SQL.**

## What is grate?

grate is a SQL scripts migration runner, using plain, old SQL for migrations. No meta-language, no code, no config,
no EF migrations. It gives you full flexibility, and full control of your migrations, and lets you use
all the fancy features of you particular database system. You are not constrained to any lowest common
feature set of all supported databases.

Use it from the command line, in CI/CD, in a container, or through its .NET
libraries. Start with [getting started](GettingStarted.md) or choose an
[installation option](GettingGrate.md).

## Supported databases

SQL Server (including Azure SQL), PostgreSQL, MariaDB/MySQL, SQLite, and Oracle.
grate runs on Windows, Linux, and macOS.

## How scripts run

Different kinds of SQL changes need different execution policies:

- [One-time scripts](ScriptTypes/OneTimeScripts.md), such as schema changes in
  `up`, run once per database. Changing an applied script fails the migration
  by default.
- [Anytime scripts](ScriptTypes/AnytimeScripts.md), such as views and stored
  procedures, run when new or changed. Write them so they can run again.
- [Everytime scripts](ScriptTypes/EverytimeScripts.md), such as permissions and
  migration hooks, run on every migration.

Folders run in a defined order, with scripts sorted alphabetically within them.
Use the defaults or [configure your own folder layout](ConfigurationOptions/FolderConfiguration.md).
The [migration tables](MigrationTables.md) record script names, hashes, and versions.

## Prerequisites

Standalone executables bundle the .NET runtime; .NET tools and libraries use an
installed runtime. See [installation and runtime requirements](GettingGrate.md)
for your distribution and platform.

## Why the name grate?

grate is short for migrate. And it's also pronounced the same way as _great_, so, there you go. 

## Documentation

* [Getting started](GettingStarted.md)
* [Getting grate](GettingGrate.md)
* [Migrating from RoundhousE](MigratingFromRoundhousE.md)
* [Configuration Options](ConfigurationOptions/index.md)
* [Migration tables](MigrationTables.md)
* [Environment scripts](EnvironmentScripts.md)
* [Token replacement](TokenReplacement.md)
* [Response files](ConfigurationOptions/ResponseFiles.md)
* [Agent skill](AgentSkill.md)

## Coming from RoundhousE?

grate grew out of experience maintaining RoundhousE and carries forward its
SQL-first workflow. See [migrating from RoundhousE](MigratingFromRoundhousE.md)
for compatibility details and the changes to make when moving an existing project.

## Contributing

Maintainers can follow the [release process](ReleaseProcess.md) to prepare,
publish, verify, and recover a release.

Head over to the [github page]({{ site.github.repository_url }}), and please see [CONTRIBUTING.md]({{ site.github.repository_url }}/blob/main/CONTRIBUTING.md)
