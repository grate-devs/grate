---
title: "Migrating from RoundhousE"
permalink: /migrating-from-roundhouse/
nav_order: 3
---

# Migrating to grate from RoundhousE

[RoundhousE](https://github.com/chucknorris/roundhouse) is an amazing tool, and grate is trying to be backwards compatible with RH to make upgrading easy.

# Changes compared to RoundhousE

There's a number of general changes in grate as a result of moving to the latest .Net bits that will apply to all users.

grate is built using the new [`System.CommandLine`](https://github.com/dotnet/command-line-api) API's, so:
- Command line arguments are now **case-sensitive** on all operating systems (including windows)
- Support for `/argument` on windows has been removed, and you'll have to use `-a` or `--argument` instead.  See `grate --help` for the full set of allowed options.
- We have gained support for [Response (`.rsp`) files](ConfigurationOptions/ResponseFiles.md)

- By default grate stores version information in the `grate` database schema.  To continue using your existing version information pass `--schema=RoundhousE`
- grate adds `GrateScriptsRun`, `GrateScriptsRunErrors`, and `GrateVersion` to track upgrades to the migration tables themselves. Your existing migration history remains in `ScriptsRun`, `ScriptsRunErrors`, and `Version`. See [Migration tables](MigrationTables.md) for details.
- grate has a single mandatory `-cs`/`--connstring` argument for simplicity.  RH's `--database`, `--server` etc arguments are no longer allowed.

- Not all previously supported tokens are available yet.  For more information see the [Token Replacement docs](TokenReplacement.md).
- UserTokens has a change which **affects back-compatibility**   
  - In keeping with the `System.CommandLine` standards the `--ut` option is now passed multiple times for multiple tokens, rather than parsing a single ';' delimited string as in RH.
  - This means that you **MUST** update your scripts passing multiple tokens in a single param to use multiple `--ut` parameters instead. 

- The `DropCreate` 'mode' has been merged with the `--drop` option. RH used a single-run workflow for `Normal` and `RestoreRun` modes, but needed two executions for the `DropCreate` mode.  grate uses the `--drop` option like RH but **it continues with the creation and migration afterwards**! If you have a scenario for dropping a database but _not_ then running a migration, please open an issue!

- The `--verbose` flag has been changed to a `--verbosity` flag, accepting the values of `<Critical|Debug|Error|Information|None|Trace|Warning>` (see [the MS docs](https://docs.microsoft.com/dotnet/api/Microsoft.Extensions.Logging.LogLevel) for details)

- The `Allow User Variables` connection string option for MySQL connections (used in SPROCs) is no longer set by default.


## RH Features that aren't yet in grate

Rebuilding a decade old product from scratch takes time, and features have to be prioritised. The list of items below shows the current set of outstanding RH features that haven't been built yet.  If there's something on this list you can't live without, raise an issue to help us out.  If people take ownership of a feature and contribute PR's then we'll all get there faster 👍

Expect this list to shrink over time.

- `--defaultencoding`
- MSBuild Task.
- Multiple Environments per run. Scripts can target multiple environments (`blah.env.test.uat.sql`), but each migration can only target a single environment.  If this is a limiting factor for  you please raise an issue to discuss.
- Recovery Modes (`--simple`, `--recoverymode` etc).  A `runAfterCreateDatabase` script using `alter {{DatabaseName}} ...` may work for you in the meantime.
- Restore Options (`--restorefrompath`, `--restoreoptions`, `--restoretimeout` etc)
- Version info sourced from a file.  `--version=<VALUE>` support is available on the command line
