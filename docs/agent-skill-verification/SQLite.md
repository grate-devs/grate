# Historical SQLite and skill verification

This records checks made while developing the skill. The former standalone
verifier and its wrappers have been removed from the distributed skill. Its
behavioral checks now run as xUnit tests in
`unittests/Sqlite/AgentSkill/AgentSkillSqliteTests.cs`, using the CLI built from
the checkout and the skill's example SQL files copied to test output.

Both `.github/workflows/ci.yml` and `.github/workflows/build.yml` include these
tests in their existing `Sqlite` matrix entry. To run the focused checks locally:

```sh
dotnet test --project unittests/Sqlite --filter-class Sqlite.AgentSkill.AgentSkillSqliteTests
```

Use the repository's normal test prerequisites. The shared SQLite suite startup
currently checks Docker availability even though these cases use temporary local
SQLite databases and launch no database container.

The four test cases retain the original 11 behavioral checkpoints. CI uses the
normal test runner and its captured CLI output; there is no separate verifier
package or optional SDK detection for skill consumers. The historical results
below describe earlier binaries, not a pass claim for the current checkout.

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

## Recorded C# verification

On 2026-10-25, all 11 checks passed through **both wrappers**, using .NET SDK
**10.0.401**, runtime **10.0.12**, PowerShell **7.6.6**, and an existing grate CLI
identifying itself as **2.2.0.0**, on macOS arm64. Inspection used
Microsoft.Data.Sqlite **10.0.10** and SQLitePCLRaw.bundle_e_sqlite3 **3.0.3**.

The tested `grate.dll` SHA-256 was:

```text
055b3a877bdedc6ef2506a3041e2f3b1ad81985778b6b37cdb559c2fb0cb2166
```

Each wrapper received `--expected-version 2.2.0.0 -- dotnet` followed by the
absolute path to the existing `src/grate/bin/Release/net10.0/grate.dll`. The
verifier was built, but grate was not rebuilt; the binary's relationship to the
checked-out source was not independently proven.

As a negative check, the index migration was replaced with `SELECT 1;` in an
isolated copy of the complete skill, outside the repository and in a path with
spaces. The CLI exited successfully, but the verifier exited 1 with
`The separate index migration did not create its index.` This also exercised
asset discovery independently of the repository and working directory.

Both wrappers were tested with simulated missing `dotnet`, a runtime-only
installation, and an SDK reporting version 9. Each printed `SKIP` and exited 77.
A fake SDK/runner also verified preservation of arguments containing spaces and
shell punctuation, and propagation of its nonzero exit code. These wrapper
checks do not establish execution on Windows: PowerShell was tested on macOS.

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
