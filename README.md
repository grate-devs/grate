# grate

SQL scripts migration runner

**Database migrations in plain SQL.**

Keep your database changes alongside your application code. grate runs your SQL
scripts in a predictable order and records what has been applied, so you can
deploy the same changes from your laptop, your tests, or your CI/CD pipeline.
Use your database's SQL dialect and features without a migration DSL or an ORM.

Supports **SQL Server (including Azure SQL), PostgreSQL, MariaDB/MySQL, SQLite,
and Oracle**, on Windows, Linux, and macOS.

[Documentation](https://grate-devs.github.io/grate/) ·
[Installation](docs/GettingGrate.md) ·
[Releases](https://github.com/grate-devs/grate/releases/latest) ·
[Examples](examples) ·
[Contributing](CONTRIBUTING.md)

[![CI](https://github.com/grate-devs/grate/actions/workflows/ci.yml/badge.svg)](https://github.com/grate-devs/grate/actions/workflows/ci.yml)
[![Build](https://github.com/grate-devs/grate/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/grate-devs/grate/actions/workflows/build.yml)
[![Integration tests](https://github.com/grate-devs/grate/actions/workflows/integration-tests.yml/badge.svg)](https://github.com/grate-devs/grate/actions/workflows/integration-tests.yml)

## SQL files, with a place for each kind of change

Schema changes and stored procedure definitions have different maintenance needs.
grate lets you keep both in source control without turning every edit into a new
one-time migration.

| Script type | Default folders include | When it runs |
| --- | --- | --- |
| [One-time](docs/ScriptTypes/OneTimeScripts.md) | `up` | Once per database. Changing an applied script fails the migration by default. |
| [Anytime](docs/ScriptTypes/AnytimeScripts.md) | `functions`, `views`, `sprocs`, `indexes` | When the script is new or has changed. Write these scripts so they can run again. |
| [Everytime](docs/ScriptTypes/EverytimeScripts.md) | `beforeMigration`, `permissions`, `afterMigration` | On every migration, whether the script has changed or not. |

Folders run in a defined order, with scripts sorted alphabetically within them.
Create only the folders you need, or [customize the layout and execution policies](docs/ConfigurationOptions/FolderConfiguration.md)
to fit an existing project. grate stores [migration history](docs/MigrationTables.md)
in the target database, including script names, hashes, and versions.

## Try it with SQLite

This example uses a local database file, so you don't need a database server.

Install the [.NET tool](https://www.nuget.org/packages/grate/) with the .NET SDK
and a matching runtime installed:

```sh
dotnet tool install --global grate
```

Prefer a standalone executable or Docker? See [installation options and runtime requirements](docs/GettingGrate.md).

Create a directory named `db/up` and save this as `db/up/001_create_greetings.sql`:

```sql
CREATE TABLE greetings (
    id INTEGER PRIMARY KEY,
    message TEXT NOT NULL
);
```

Run from the directory containing `db`:

```sh
grate --databasetype sqlite --connectionstring "Data Source=hello-grate.db" --files ./db --silent
```

grate creates `hello-grate.db`, runs the script, and records it in its migration
history. Run the same command again: the unchanged one-time script is skipped.
For the next schema change, add `002_...sql` to `db/up` and run grate again.

For another database, select its `--databasetype` and supply its connection string.
See [getting started](docs/GettingStarted.md) for the full folder order and workflow.

## Fit grate into your workflow

Use the CLI locally and in CI/CD, run it in a container, or embed the
[.NET libraries](src/grate.core/NuGet.md) in your application or test setup.

| What you want to do | Where to start |
| --- | --- |
| Configure connections, transactions, previews, or baselining | [Configuration options](docs/ConfigurationOptions/index.md) |
| Select scripts by environment or supply deployment values | [Environment scripts](docs/EnvironmentScripts.md) and [token replacement](docs/TokenReplacement.md) |
| Run migrations in a pipeline | [GitHub Actions](.github/workflows/grate-workflow.yml), [Azure Pipelines](examples/AzureDevops/azure-pipelines.yml), and [CI logging](examples/ci-logging/README.md) |
| Run migrations in containers or Kubernetes | [Docker](examples/docker/readme.md), [init containers](examples/k8s/initcontainer/README.md), and [multi-tenant deployments](examples/k8s/multitenancy/README.md) |
| Prepare a database for automated tests | [Test integration example](examples/test-integration/sample-test-integration/readme.md) |
| Try the unpublished PostgreSQL Aspire integration | [Aspire prototype](docs/Aspire.md) |
| Work with a coding agent | [Bundled use-grate skill](docs/AgentSkill.md) |

## Coming from RoundhousE?

grate grew out of experience maintaining RoundhousE and carries forward its
SQL-first workflow. See [migrating from RoundhousE](docs/MigratingFromRoundhousE.md)
for compatibility details and the changes to make when moving an existing project.

## Contributing

Source builds use the stable .NET 11 SDK selected by `global.json`. Self-contained
builds and Docker images use .NET 11 GA, including Linux/musl binaries. See the
[SDK and bundled runtime guidance](docs/Packaging.md#moving-to-net-11-ga).

Bug reports, documentation improvements, and code contributions are welcome.
Start with [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and tests,
or [open an issue](https://github.com/grate-devs/grate/issues) to report a problem
or discuss an idea. Coding agents should also follow [AGENTS.md](AGENTS.md).

We welcome AI-assisted contributions. You are responsible for understanding,
reviewing, and verifying the changes you submit, with the same quality standards
as code you wrote yourself. Include good automated test coverage for new behavior
and regression tests for bug fixes, and describe the checks you ran and any gaps.

grate is short for *migrate*, pronounced like *great*, and [MIT licensed](LICENSE).
