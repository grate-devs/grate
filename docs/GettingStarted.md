---
title: "Getting Started"
permalink: /getting-started/
nav_order: 2
---

# Getting Started

## Overview

grate is an automated database deployment (change management) system that allows you to use plain old `.sql` scripts but gain much more.  We don't believe in writing database migrations in C#, but don't care how you get your scripts on disk.  Write them at dev time alongside the code for your new feature, or generate larger diff's using other tooling (SSDT/RedGate/etc), whatever works for you and your team!  Include schema objects, data, server configuration, whatever you need!

**Low Maintenance Migrations**: It seeks to solve both maintenance concerns and ease of deployment. We follow some of the same idioms as other database management systems (SQL scripts), but we are different in that we think about future maintenance concerns. We want to apply certain scripts whenever there's changes (like functions, views, stored procedures, and permissions), so we don’t have to throw everything into our one-time only `update` change scripts.

**What Version Is YOUR Database On?**: We subscribe to the idea of versioning your database how you want. At this point it's very rare to find someone that doesn't think you should version your code, and few would argue against versioning your code in a way that can lead back to a specific point in source control history. However, most people don’t really think of doing the same thing with your database. We say version it using the same version as your code base by passing it a version number at runtime.  We love versioning our applications based on source control revisions, and how sweet it is when you can pinpoint the exact state of your database _and_ the exact code in your application all to a given point in space and time in your repo!

**Use your whole DBMS**: You're running a full DBMS, why not use all it's features!  Table-Valued Parameters for efficient processing? Data compression for space savings?  Fancy-pants filtered indexes?  Replication? Fine-grained permission management?  If you've ever had to fight with code-based database scaffolding then you'll appreciate the value of plain old sql scripts.

By the way, we currently support Sql Server (including Azure and localdb), SqLite, Postgres, MariaDb and Oracle!!

## How it works

grate is based on a simple premise: you create a directory structure on disk with well-known folder names, and then add `.sql` files.  grate processes these folders in a fixed order, and runs the scripts inside in alphabetical order.  That's it!

But don't be fooled, there's power in this simplicity due to a couple of key factors:
- Different folders are treated differently depending on the scripts they contain, eg Sproc's are re-run whenver the definition has changed from that in the target database, while `up` scripts are run once only... See the `Script Types` section below.
- grate allows you to specify an Environment for each run, and [Environment Specific](EnvironmentScripts.md) scripts will only be run if appropriate.  This allows for the loading of test-data into non-prod environments while keeping production clean, or catering for systems where environments markedly diverge (maybe you have different versions of Sql or something?).

grate records your migration history in `ScriptsRun`, `ScriptsRunErrors`, and
`Version`. It also maintains three `Grate*` tables to track changes to the migration
tables themselves. See [Migration tables](MigrationTables.md) for what each table
contains and where they are stored.

## Examples

There are samples included in source control in the [`/examples/`](https://github.com/grate-devs/grate/tree/main/examples) directory, have a look and a play in there for some more info.

## Script Types

Scripts in grate are considered to be one of three types:

**One-time scripts**
These are scripts that are run **exactly once** per database, and never again.  More info [here](ScriptTypes/OneTimeScripts.md).

**Anytime Scripts**
These scripts are run **any time they're changed**.  More info [here](ScriptTypes/AnytimeScripts.md).

**Everytime Scripts**
These scripts are run (you guessed it) **every time** grate executes :)  More info [here](ScriptTypes/EverytimeScripts.md)

## Directory run order

By default, grate processes the files in a standard set of directories in a fixed order for deterministic processing.  
As of grate 1.4, the folder structure is [fully customisable](ConfigurationOptions/FolderConfiguration.md). However,
if you don't have any special requirements (e.g. an existing set of SQL scripts in an existing, set folder structure),
we would recommend you going with the defaults.

The default folders are run in the following order:

### -1. dropDatabase (Anytime scripts)
If you have the need for a custom `DROP DATABASE` script (used with the `--drop` command-line flag)

### 0. createDatabase (Anytime scripts)
If you have the need for a custom `CREATE DATABASE` script, put it here, and it will be used instead of the default.

### 1. beforeMigration (Everytime scripts)
If you have particular tasks you want to perform prior to any database migrations (custom logging? database backups? disable replication?) you can do it here.

### 2. alterDatabase (Anytime scripts)
If you have scripts that need to alter the database config itself (rather than the _contents_ of the database) this is the place to do it.  For example setting recovery modes, enabling query stores, etc etc

### 3. runAfterCreateDatabase (Anytime scripts).
This directory is only processed if the database was created from scratch by grate.  Maybe you need to add user accounts or similar?

### 4. runBeforeUp (Anytime scripts)

### 5. up (One-time scripts).  
This is where the bulk of your 'migration' scripts end up, eg adding tables, removing columns, adding reference data etc

Note that there's no `down`!  If you've dropped a column in your `up` scripts, how do you possibly script an undo for that operation?  grate has support for running the migration inside a transaction, and will rollback on script failure.

### 6. runFirstAfterUp (One-time scripts)
Scripts run prior to other anytime folders are found here. This folder exists to allow you to put sql files in when you need to run out of order, say a stored procecure prior to a function. It is not a normal occurrence to have many files in here or any for that matter.

### 7. functions (Anytime scripts)
If you have any functions that need to run prior to others, make sure they are alphabetically first before the dependent scripts.

### 8. views (Anytime scripts)
If you have views any that need to run prior to others, make sure they are alphabetically first before the dependent scripts.

### 9. sprocs (Anytime scripts)
Stored procedures are found in a `sprocs` folder. If you have any that need to run prior to others, make sure they are alphabetically first before the dependent scripts.

### 10. triggers (Anytime scripts)

### 11. indexes (Anytime scripts)

### 12. runAfterOtherAnyTimeScripts (Anytime scripts)
This folder exists to allow you to run scripts after you have set up your anytime scripts. It's pretty open what you put in here, but remember that it is still an anytime folder.

### 13. permissions (Everytime scripts)
If you have any that need to run prior to others, make sure they are alphabetically first before the dependent scripts.
Permissions may contain auto-wiring of permissions, so they are run every time regardless of changes in the files.

### 14. afterMigration (Everytime scripts)
If you have particular tasks you want to perform prior to any database migrations (custom logging? database backups?) you can do it here.

### Notes
- You are not required to have every one of these folders...i.e. if you don't use triggers there's no need to have an empty `triggers` directory.
