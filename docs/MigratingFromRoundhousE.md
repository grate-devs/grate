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


## Reusing existing script history

Use the existing history schema (for example, `--schema=RoundhousE`) and preserve
any custom history table names. Selecting a different schema does not move the
old history and can make previously applied scripts appear new.

### Legacy hashes and line endings

Older RoundhousE versions hashed script text with its original line endings.
Later versions normalized line endings to LF when recording new hashes, while
still accepting older hashes during comparison. Upgrading RoundhousE did not
necessarily replace the hashes of scripts that were skipped as unchanged.

grate accepts these legacy hashes, including CRLF and CR hashes, when deciding
whether an existing script has changed. Changing a checkout between LF, CRLF,
and CR line endings alone does not require rerunning an already applied script.
An unchanged one-time or anytime script is skipped; everytime scripts still run
according to their normal rules. Existing history is not rewritten, and new
history records continue to use grate's LF-normalized hash format.

Unchanged files with mixed line endings are also recognized from their original
text. If a legacy file used mixed endings, preserve that mixture: its original
layout cannot in general be reconstructed from the stored hash after conversion
to a single line-ending style.

This compatibility applies to grate versions containing the fix for
[#841](https://github.com/grate-devs/grate/issues/841). Earlier grate versions
compared only the normalized hash, so an unchanged script with an older
RoundhousE hash could fail as a changed one-time script or rerun as an anytime
script.

Line-ending compatibility does not ignore other text changes. Both tools hash
the SQL after token replacement, so preserve token values and replacement
settings. Also check file encoding: grate reads UTF-8 by default and recognizes
supported byte-order marks, but does not support RoundhousE's `--defaultencoding`.
Files without a BOM that relied on another encoding must decode to the same text
in grate; convert them to UTF-8 while preserving that text if necessary.

Investigate remaining hash differences instead of using `--baseline`,
`--warnononetimescriptchanges`, or `--warnandignoreononetimescriptchanges` merely
to make the migration succeed. These options can hide actual changes or rerun
one-time scripts.

### Scripts in subdirectories

RoundhousE records only the filename in `ScriptsRun.script_name`. By default,
grate records the relative path within each migration folder. For example:

| File | RoundhousE history name | Default grate history name |
| --- | --- | --- |
| `up/001.sql` | `001.sql` | `001.sql` |
| `up/2020/001.sql` | `001.sql` | `2020/001.sql` |

For the second example, grate will not find the filename-only history entry and
can execute the script again as a new migration, even if its hash is unchanged.
Using `--schema=RoundhousE` alone does not resolve this difference.

Use `--ignoredirectorynames` to retain filename-only identity when taking over
such history. This option still searches subdirectories, but also sorts scripts
by filename alone. RoundhousE's default traversal processes files in a directory
before descending into child directories, so check the order of pending scripts
and their dependencies before switching. Keep filenames unique across migration
folders and subdirectories, since filename-only history cannot distinguish
duplicates. Preserve the selected identity convention on subsequent runs.

Verify the transition on a disposable copy of the database with the intended
scripts, token values, encoding, folder configuration, and grate version before
using it against the original database.

## RH Features that aren't yet in grate

Rebuilding a decade old product from scratch takes time, and features have to be prioritised. The list of items below shows the current set of outstanding RH features that haven't been built yet.  If there's something on this list you can't live without, raise an issue to help us out.  If people take ownership of a feature and contribute PR's then we'll all get there faster 👍

Expect this list to shrink over time.

- `--defaultencoding`
- MSBuild Task.
- Multiple Environments per run. Scripts can target multiple environments (`blah.env.test.uat.sql`), but each migration can only target a single environment.  If this is a limiting factor for  you please raise an issue to discuss.
- Recovery Modes (`--simple`, `--recoverymode` etc).  A `runAfterCreateDatabase` script using `alter {{DatabaseName}} ...` may work for you in the meantime.
- Restore Options (`--restorefrompath`, `--restoreoptions`, `--restoretimeout` etc)
- Version info sourced from a file.  `--version=<VALUE>` support is available on the command line
