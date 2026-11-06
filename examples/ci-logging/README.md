# Check migration logs in a CI runner

Run this from a GitHub Actions shell step, an Azure Pipelines Bash task, a TeamCity
Command Line step, or a Jenkins freestyle shell build step. Use a grate executable
built from this checkout for the agent's OS and architecture.

```sh
bash examples/ci-logging/smoke.sh /path/to/grate
```

The script runs two SQLite migrations in a temporary directory. The first reports
a warning about unsupported DDL transactions and must exit 0. The second fails
on `02-failure.sql` and must exit 1. The script checks both exit codes, leaving
grate's stdout connected to the runner so it can interpret the output.

Look for one warning about DDL transactions and one error naming
`02-failure.sql` and `missing_table`. GitHub Actions should show annotations,
Azure Pipelines should show issues, and TeamCity should show the two severities
in its build log. The Jenkins console should show `[WARNING]` and `[ERROR]`
without any plugins. The CI step can still be marked failed by a policy that
acts on the error message independently of the script's exit code.

See [Migration logs in CI](../../docs/ConfigurationOptions/index.md#migration-logs-in-ci)
for format overrides and a Docker example.
