---
title: "One-Time Scripts"
permalink: script-types/one-time/
parent: Script types
---
## One Time Scripts

By default, these scripts run once per database. They typically contain statements such as `create table`, which may fail if run a second time. If a previously run script changes, grate fails the migration unless one of the options below is set.

## Folders
Scripts in the following folders are `one time` scripts by default.

* runAfterCreateDatabase
* up

## What goes in the Up Folder?

1. DDL (schema changes - database structure)  
1. DML (inserts/updates/deletes)  
  
## How does the order work?
  
grate always runs files in order alphabetically.
  
## How should I name my scripts?
  
One should prepend your order specific scripts with either a number moving upwards padded with three zeros (i.e. `0001_somescript.sql` followed by `0002_nextscript.sql`) or a nice long date time in YYYYMMddHHmmss format (i.e. `20121026091400_somescript.sql` followed by `20121026091401_nextscript.sql`), but you are not limited to those options. Some people do a separation by numbers as in `####.##.##.####` or something else. Find what works for you (and your team) and use it.   
  
## Changed one-time scripts

By default, grate fails the migration if a previously run one-time script has changed. Prefer adding a new migration script instead of changing an applied one.

Two options allow a changed script to be accepted with a warning:

- `--warnononetimescriptchanges` (`-w`) executes the changed script again and records its new hash after it succeeds. The script must be safe to run again.
- `--warnandignoreononetimescriptchanges` records the new hash without executing the changed SQL. Use this only when the database is already in the intended state; accepting the hash does not apply the change.

If both options are set, the execute option takes precedence. See [Configuration options](../ConfigurationOptions/index.md) for the defaults.

## Script history and hashes

For a successful execution, grate adds a row to `ScriptsRun` containing the script name and hash. Accepting a changed one-time script with `--warnandignoreononetimescriptchanges` also adds a row, even though it does not execute the SQL. Earlier rows remain as history.

On a later migration, grate compares the script with the hash in the row with the highest `id` for that script name. For example, if version A was run and version B was subsequently accepted with either option, a later unchanged B is skipped; it is compared with B's hash, not A's. Token replacement occurs before hashing, so changes to token values can also change the comparison.

[Anytime scripts](AnytimeScripts.md) run again when changed, while [Everytime scripts](EverytimeScripts.md) run on every migration. Both record a new history row when they run successfully.
