# Verify grate on disposable SQLite databases

Run the bundled harness with Python 3 and a trusted, already available grate CLI.
It uses only Python's standard library, invokes the real CLI without a shell,
and inspects real SQLite data and migration history. It never installs or updates
grate and has no option for supplying an existing database or connection string.

From the repository root:

```sh
python3 skills/use-grate/scripts/verify_sqlite.py -- grate
```

For an existing framework-dependent build, use an absolute DLL path. The harness
runs commands from its temporary directory, so relative command paths will not
resolve against the repository:

```sh
python3 skills/use-grate/scripts/verify_sqlite.py \
  --expected-version 2.2.0.0 \
  --report /tmp/grate-verification.md \
  -- dotnet /absolute/path/to/grate.dll
```

`--expected-version` is optional and compares the exact version in `grate --help`.
Choose the version approved for the project; `2.2.0.0` above records the tested
binary, not an instruction to upgrade. grate's `--version` option labels the
database migration and is not a command for inspecting the CLI version.

Each CLI invocation has a 60-second timeout, configurable with `--timeout` before
`--`. The script exits zero only if all checks pass. It prints the temporary
artifact directory and Markdown report path; databases, copied SQL, CLI output,
and grate output remain there for inspection. Remove that printed directory when
finished. Use the report's exact command lines and logs to investigate failures.

## What is checked

The example has three distinct one-time scripts, all in `up`, in this order:

1. `001_create_widgets.sql` creates the table.
2. `002_create_widgets_code_index.sql` creates its unique index.
3. `003_seed_widget.sql` inserts the seed row.

The harness checks the actual table, index, row values, successful script names,
stored hashes, and one-time flags. A repeat run must preserve application data
and `grate_ScriptsRun` exactly. This does not assert that version or log records
never change between invocations.

It then edits an applied seed script. grate must return exit 1, preserve its
successful history/hash and data, and record the changed-script error in
`grate_ScriptsRunErrors`. The harness restores the original bytes and adds a new
forward migration. That migration must apply once and preserve existing history.

Two fresh databases exercise deliberate SQL failure and recovery, one with
`--transaction=false` and one with `--transaction=true`:

The multi-batch failing file below is an intentional counterexample to the
authoring rule, created only inside the disposable test. It demonstrates why
new one-time changes should use separate files; it is not a migration template.

| Observation | Expected result for the tested SQLite provider |
| --- | --- |
| A complete file precedes the failure | Its inserted row and successful history persist. |
| The next file has three `GO`-separated batches; batch two fails | The first batch's row persists, the third batch and later file do not run. |
| Successful history for that failed file | Absent: history is recorded after the whole file completes. |
| Error history | Names the file and contains the failed batch. |
| Retry with the SQL unchanged | Starts the file at batch one and fails on its duplicate primary key. |
| Repair after inspecting the partial state | Handles the already inserted row, completes remaining work, preserves prior history/errors, and has no repeated effects on the next run. |

The repaired file has no successful history entry in the disposable fixture.
Editing it is a fixture-specific recovery demonstration, not permission to edit
a migration that has completed successfully in another environment. For an
applied one-time script, use the restore-and-forward-change procedure above.

grate's SQLite provider currently reports no DDL transaction support.
`--transaction=true --silent` emits a warning and continues without
grate-managed migration transactions. The harness checks that warning and the
persisted partial state; it does **not** claim SQLite rollback was verified.
The `GO` demonstration also establishes that a batch separator does not make
each batch independently resumable or a file atomic.

## Recorded verification

On 2026-09-05, all 11 reported checks passed against an existing local grate
binary identifying itself as **2.2.0.0**, with .NET runtime **10.0.9**, Python
**3.14.6**, on macOS **26.6.2 arm64**. Python used SQLite **3.53.4** for independent
inspection; this is not a claim about the CLI provider's native SQLite version.

The tested `grate.dll` SHA-256 was:

```text
055b3a877bdedc6ef2506a3041e2f3b1ad81985778b6b37cdb559c2fb0cb2166
```

The command was `python3 skills/use-grate/scripts/verify_sqlite.py
--expected-version 2.2.0.0 -- dotnet` followed by the absolute path to the existing
`src/grate/bin/Release/net10.0/grate.dll`. No installation or build was performed;
the binary's relationship to the checked-out source was not independently proven.

As a negative check, the index migration was replaced with `SELECT 1;` in an
isolated copy of the fixture. The CLI exited successfully, but the harness exited
1 with `The separate index migration did not create its index`. This confirms
that a successful process exit cannot substitute for the database assertions.

These results cover this supplied CLI and disposable SQLite only. They do not
prove transaction, batch parsing, or recovery behavior for SQL Server,
PostgreSQL, MariaDB, or Oracle. Repeat the relevant failure-and-recovery checks
on the project's provider and configuration before relying on its behavior.

## Skill behavior evaluation

An independent agent exercise on 2026-09-05 used a synthetic SQL Server request
with an already-deployed seed and a filename reserved by a parallel branch.
The resulting draft preserved the deployed seed and produced seven separate
one-time files: a forward data update, table creation, two indexes, a constraint,
and two seed inserts. One anytime procedure file kept its SELECT and UPDATE
together. The new names were unique and sorted after the supplied reservation.
The agent identified unknown runner/server settings, marked schema assumptions,
and deferred execution rather than inventing a command. Static inspection
confirmed those artifacts; SQL Server execution and agent-client installation
were not tested. This is evidence for that authoring scenario, not a claim of
compatibility with every agent or SQL Server version.
