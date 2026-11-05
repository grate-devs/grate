---
title: Folder configuration
permalink: /folder-configuration/
parent: Configuration options
---

# Folder configuration

The folder configuration in grate is now (since grate v 1.4) entirely configurable. That means you can 
specify the folder structure of choice, and make grate work with your existing structure, rather than
having to change the folder structure to suite how grate works. There is, however, a [default configuration](#default-folder-configuration),
which might be a good starting point if you have no special requirements.

## Folder types

grate works with three different folder types:


| Folder/script type | Name | Explanation | More info |
| ------ |----|  ------- |------- |
| One-time scripts | Once | These are scripts that are run **exactly once** per database, and never again. | [One time scripts](../ScriptTypes/OneTimeScripts.md#one-time-scripts) |
| Anytime Scripts | AnyTime | These scripts are run **any time they're changed** | [Anytime scripts](../ScriptTypes/AnytimeScripts.md#anytime-scripts) |
| Everytime Scripts | EveryTime | These scripts are run (you guessed it) **every time** grate executes :) |  [Everytime scripts](../ScriptTypes/EverytimeScripts.md#everytime-scripts) |

## Specifying a custom folder configuration

If you want to specify a custom folder configuration, you have two options:

1. Start with the [default grate folder configuration](#default-folder-configuration), and make adjustments
1. Specify a fully customised set of folders to use

**Note:** you can either:
1) specify the parameters directly on the command line, or 
2) _supply a filename_, and grate will read the folder config from that file.

Before starting a migration, the CLI checks the effective directory paths configured through `--folders`,
whether supplied inline or read from a configuration file. Relative paths are resolved against `--files`
(`--sqlfilesdirectory`). A fully custom configuration also requires folders whose paths are inferred
from their keys, such as `folder1=Once`. When using the default configuration, folders with no explicit
path override can be absent, including when only their migration type is changed. The CLI reports an
invalid folder on standard error and exits with code 1 before connecting to the database.

### Making adjustments to default folder configuration

If you want to change the name of one or more of the default folder names, you specify a semicolon-separated
list of the folders you want to use a different name for to the `--folders` argument.

#### Example

This would use the [default folder configuration](#default-folder-configuration), except that it would look in the
`ddl` folder for **up** scripts, in the `projections` folder for **views**, and in the `preparefordeploy` folder for **beforemigration** scripts.

```
--folders 'up=ddl;views=projections;beforemigration=preparefordeploy'
```

**NOTE:** Be sure to use quotes when specifying multiple folders in the argument, as many shells treat `;` as
a the "end this command" character, so everything after the `;` will not be part of the command line.

or 

```
--folders /where/ever/myfolderconfig.txt
```

and, put the following content in `/where/ever/myfolderconfig.txt` (either semicolon or newline separated)

```
up=ddl
views=projections
beforemigration=preparefordeploy
```

### Specifying a custom list of folders

If you want to specify an entirely different folder structure, this is no problem. Just supply a list of the folders
to the `--folders` argument, and grate will run them in the specified order, with the specified configuration for 
each folder.

The list of folder should consist of some keys that are not among the default folders. Then none of the default folders will be configured, just the ones you supply. If all the keys are some of the default ones, e.g. only `up`, `views` and `sprocs`, grate will assume that you want the default configuration, with the adjustments you have specified.

Example:

```
--folders folder1=path:a/sub/folder/here,type:Once,connectionType:Admin;folder2=type:EveryTime;folder3=type:AnyTime
```

The properties you can set per folder, are:

| Property | Description | Allowed values | Default |
| ------ | ------- | ------- | ------- |
| Name   | the key/name you wish to give to the folder | (doesn't matter if path is specified) | _(none)_ |
| Path   | the relative path of the folder, relative to the --sqlfilesdirectory parameter. | Any relative path | the **Name** specified above.
| Type   | the type of the migration | Once, EveryTime, AnyTime | Once |
| ConnectionType | whether to run on the default connection, or on the admin | Default, Admin | Default |
| TransactionHandling | whether to be part of the transaction (if running the migration in a transaction), or run the script in an autonomous transaction, so that it is always run, even on a rollback | Default, Autonomous | Default |

There are also short forms, if you only wish to supply the folder name or the migration type.

Example:

```
--folders folder1=my/first/scripts;folder2=the/last/ones;folder3=something/i/forgot
```

or

```
--folders folder1=Once;folder2=EveryTime;folder3=AnyTime
```

the last one will expect the folders to be named `folder1`, `folder2`, and `folder3`, 
in the supplied **sqlfilesdirectory**. 

**The interpretation logic is:** If you specify a migration type, 
we interpret it as if you only specify a migration type, if you specify something that is not a migration type, 
grate interprets it as a folder name.


## Default folder configuration

Out of the box, grate has a suggested folder structure. If you start from zero, this might be a good starting point. 
Even if you choose to go with the default folder configuration, you can (as of grate 1.4) configure the names of the default
folders, should you wish so.

Simply specify the folders you want to override in the `--folders` parameter. The ones you don't mention, will remain configured
as default. 

An example, if you want to use a folder `tables` to keep you `up` scripts in, use the following argument to grate:

```bash
$ grate --folders up=tables
```



grate processes the files in a standard set of directories in a fixed order for deterministic processing.  Folders are run in the following order:

| Folder | Script type | Explanation |
| ------ | ------- |------- |
| <nobr> (-1. dropDatabase)</nobr> | Anytime scripts | If you have the need for a custom `DROP DATABASE` script (used with the `--drop` command-line flag) |
| <nobr> (0. createDatabase)</nobr> | Anytime scripts | If you have the need for a custom `CREATE DATABASE` script, put it here, and it will be used instead of the default. |
| <nobr> 1. beforeMigration</nobr> | Everytime scripts | If you have particular tasks you want to perform prior to any database migrations (custom logging? database backups? disable replication?) you can do it here. |
| <nobr>2. alterDatabase</nobr> | Anytime scripts | If you have scripts that need to alter the database config itself (rather than the _contents_ of the database) this is the place to do it.  For example setting recovery modes, enabling query stores, etc etc |
| <nobr>3. runAfterCreateDatabase</nobr> | Anytime scripts | This directory is only processed if the database was created from scratch by grate.  Maybe you need to add user accounts or similar?
| <nobr>4. runBeforeUp</nobr> | Anytime scripts | 
| <nobr>5. up</nobr> | One-time scripts | This is where the bulk of your 'migration' scripts end up, eg adding tables, removing columns, adding reference data etc. <br><br> Note that there's no `down`!  If you've dropped a column in your `up` scripts, how do you possibly script an undo for that operation?  grate has support for running the migration inside a transaction, and will rollback on script failure.
| <nobr>6. runFirstAfterUp</nobr> | One-time scripts | Scripts run prior to other anytime folders are found here. This folder exists to allow you to put sql files in when you need to run out of order, say a stored procedure prior to a function. It is not a normal occurrence to have many files in here or any for that matter. |
| <nobr>7. functions</nobr> | Anytime scripts | If you have any functions that need to run prior to others, make sure they are alphabetically first before the dependent scripts. |
| <nobr>8. views</nobr> | Anytime scripts | If you have views any that need to run prior to others, make sure they are alphabetically first before the dependent scripts. |
| <nobr>9. sprocs</nobr> | Anytime scripts | Stored procedures are found in a `sprocs` folder. If you have any that need to run prior to others, make sure they are alphabetically first before the dependent scripts. |
| <nobr>10. triggers</nobr> | Anytime scripts | |
| <nobr>11. indexes</nobr> | Anytime scripts | |
| <nobr>12. runAfterOtherAnyTimeScripts</nobr> | Anytime scripts | This folder exists to allow you to run scripts after you have set up your anytime scripts. It's pretty open what you put in here, but remember that it is still an anytime folder. |
| <nobr>13. permissions</nobr> | Everytime scripts | If you have any that need to run prior to others, make sure they are alphabetically first before the dependent scripts. <br><br> Permissions may contain auto-wiring of permissions, so they are run every time regardless of changes in the files.
| <nobr>14. afterMigration</nobr> | Everytime scripts | If you have particular tasks you want to perform prior to any database migrations (custom logging? database backups?) you can do it here. |

### Notes

- You are not required to have every one of these folders. That is, if you don't use triggers there's no 
need to have an empty `triggers` folder.
