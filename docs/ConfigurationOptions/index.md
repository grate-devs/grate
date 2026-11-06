---
layout: default
title: Configuration options
permalink: /configuration-options/
nav_order: 5
has_children: true
---

# Grate Configuration Options

For the purpose and location of `ScriptsRun`, `Version`, and the internal
`Grate*` tables, see [Migration tables](../MigrationTables.md).

## Barebone
The only required argument to pass to grate is a connection string to tell it where to find your database. It will deploy to that database, looking for sql scripts in the current directory.

```
grate --connectionstring="Server=(localdb)\MSSQLLocalDB;Integrated Security=true;Database=grate_test"
```

## Full Configuration


| Option | Default | Purpose |
| ------ | ------- | ------- |
| -c<br>-cs<br>--connectionstring<br>--connstring &lt;connectionstring&gt; | - | **REQUIRED** You now provide an entire connection string. ServerName and Database are obsolete. |
| -a<br>-acs<br>-csa<br>--adminconnectionstring<br>--adminconnstring &lt;adminconnectionstring&gt; | The value provided via --connectionstring, with the target database replaced with a database that can be assumed to be present. For example, "master" for SQL Server. | Used when creating a new database, rather than migrating an existing one. |
| -f<br>--files<br>--sqlfilesdirectory &lt;sqlfilesdirectory&gt; | . (current directory) | The directory where your SQL scripts are located |
| --folders | Default folders as described in [Getting started](../GettingStarted.md) | Folder configuration, see [Folder configuration](FolderConfiguration.md) for details. | 
| -o<br>--output<br>--outputPath &lt;outputPath&gt; | %LOCALAPPDATA%/grate | This is where everything related to the migration is stored. This includes any backups, all items that ran, permission dumps, logs, etc. |
| --accesstoken &lt;token&gt; | - | Specify an access token to use when connecting to SQL Server. |
| -ct<br>--commandtimeout &lt;commandtimeout&gt; | 60 | This is the timeout in seconds when commands are run. This is not for admin commands or restore. |
| -cta<br>--admincommandtimeout &lt;admincommandtimeout&gt; | 300 | This is the timeout in seconds when administration commands are run (except for restore, which has its own) |
| --databasetype<br>--dbt<br>--dt <mariadb \| oracle \| postgresql \| sqlite \| sqlserver> | sqlserver | Tells grate what type of database it is running on. |
| -t<br>--transaction<br>--trx <transaction> | false | Run the migration in a transaction |
| --sc<br>--schema<br>--schemaname &lt;schemaname&gt; | grate | The schema to use for the migration tables.  If you're upgrading from RoundhousE you'll probably want this! |
| --drop | false | **Drop** - This instructs grate to remove the target database. Unlike RoundhousE grate will continue to run the migration scripts after the drop. |
| --env<br>--environment <environment> | _(empty)_ | Environment Name - This allows grate to be environment aware and only run scripts that are in a particular environment based on the name of the script.  'something.ENV.LOCAL.sql' would only be run if --env=LOCAL was set. |
| -w<br>--warnononetimescriptchanges | false | **WarnOnOneTimeScriptChanges** - Instructs grate to execute changed one time scripts(DDL / DML in Upfolder) that have previously been run against the database instead of failing. A warning is logged for each one time script that is rerun. |
| --warnandignoreononetimescriptchanges | false | **WarnAndIgnoreOnOneTimeScriptChanges** - Warns about changed one-time scripts and records their new hashes without executing them. See [One-Time Scripts](../ScriptTypes/OneTimeScripts.md#changed-one-time-scripts) for the history and subsequent-run behavior. |
| --disabletokenreplacement<br>--disabletokens | false | **Tokens** - This instructs grate to not perform token replacement ({% raw %}{{DatabaseName}}{% endraw %}). |
| --usertokens<br>--ut &lt;usertokens&gt; | - | **User Tokens** - Allows grate to perform token replacement on custom tokens ({% raw %}{{my_token}}{% endraw %}). Set as a key=value pair, eg '--ut=my_token=myvalue'. Can be specified multiple times.  ℹ️ NB that while RoundhousE passed multiple tokens as a single parameter, grate **requires** you to pass each user token separately |
| --donotstorescriptsruntext | false | **DoNotStoreScriptsRunText** - This instructs grate to not store the full script text in the database. |
| --forceanytimescripts<br>--runallanytimescripts | false | **RunAllAnyTimeScripts** - This instructs grate to run any time scripts every time it is run even if they haven't changed. Defaults to false. |
| --baseline | - | **Baseline** - This instructs grate to mark the scripts as run, but not to actually run anything against the database. Use this option if you already have scripts that have been run through other means (and BEFORE you start the new ones). | 
| --dryrun | false | **DryRun** - This instructs grate to log what would have run, but not to actually run anything against the database.  Use this option if you are trying to figure out what grate is going to do. |
| --restore | - | **Restore** - This instructs grate where to find the database backup file (.bak) to restore from. If this option is not specified, no restore will be done. |
| -ni<br>--noninteractive<br>--silent | false | **Silent** - tells grate not to ask for any input when it runs. |
| -r<br>--repo<br>--repositorypath <repositorypath> | - | **Repository Path** - RepositoryPath - The repository. A string that can be anything. Used to track versioning along with the version. Defaults to `null`. |
| --version <version> | 1.0.0.0 | **Database Version** - specify the version of the current migration directly on the command line. |
| --isuptodate<br>--uptodatecheck | - | Outputs whether the database is up to date or not (whether any non-everytime scripts would be run) |
| -v<br>--verbosity &lt;Critical\|<br>Debug\|<br>Error\|<br>Information\|<br>None\|<br>Trace\|Warning&gt; | Information | **Verbosity level** (as defined here: https://docs.microsoft.com/dotnet/api/Microsoft.Extensions.Logging.LogLevel) |
| --log-format &lt;auto\|console\|ci\|github\|azure-devops\|teamcity&gt; | auto | Selects how the CLI writes migration logs. See [Migration logs in CI](#migration-logs-in-ci). |
| --createdatabase<br>--create | true | **Create** - Instructs grate to create the target database if it does not exist. Set to false to emulate the `--donotcreatedatabase` flag in roundhouse. |
| -?<br>-h<br>--help | - |  Show help and usage information | 


## Messages from SQL Server scripts

Use `--verbosity=Debug` (or `Trace`) to see SQL Server `PRINT` output and
other informational messages from migration scripts. Grate logs them at
`Debug` with the script name. The default `Information` level keeps these
messages hidden. SQL errors still fail the migration.

## Migration logs in CI

`--log-format=auto` selects a format once when the CLI starts a migration.
Set `--log-format` explicitly to override detection. `azure` and `devops` are aliases for `azure-devops`.

| Runner | Signal in `auto` | Format |
| --- | --- | --- |
| [GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/variables#default-environment-variables) | `GITHUB_ACTIONS=true` | `github`: warning and error annotations |
| [Azure Pipelines](https://learn.microsoft.com/en-us/azure/devops/pipelines/build/variables?view=azure-devops) | `TF_BUILD=True` | `azure-devops`: warning and error issues via `task.logissue` |
| [TeamCity](https://www.jetbrains.com/help/teamcity/predefined-build-parameters.html) | Nonempty `TEAMCITY_VERSION` | `teamcity`: build log messages with `WARNING` or `ERROR` status |
| [Jenkins](https://www.jenkins.io/doc/book/pipeline/jenkinsfile/#using-environment-variables) | Nonempty `JENKINS_URL` or a `BUILD_TAG` starting with `jenkins-` | `ci`: plain text in the standard build console |
| Other CI, or more than one runner matches | `CI=true` without a runner match, or multiple runner matches | `ci`: plain text |
| Local or unrecognized environment | No active signal | `console`: interactive colors when available and warnings and errors on stderr |

Boolean signals match `true` regardless of case. Unset, empty and false values
do not activate them. All CI formats write migration logs to stdout without
colors. Plain output includes severity labels such as `[INFO]` and `[WARNING]`;
native formats use the runner's own markup for warnings, errors and critical
errors. Use `--log-format=console` to keep the original stdout/stderr split in a
CI job. The `--isuptodate` result line stays `Up to date: True` or
`Up to date: False` on stdout in every format.

A warning does not change grate's exit code. A failed migration exits nonzero.
A runner may also act on native errors independently of the process exit code,
for example when TeamCity's [fail-on-error-message setting](https://www.jetbrains.com/help/teamcity/build-failure-conditions.html#Fail+Build+on+Error+Message)
is enabled. Use `--log-format=ci` if the job needs plain logs and relies on the
process exit code.

Docker does not forward runner variables by default. For example, in a GitHub
Actions job, forward `GITHUB_ACTIONS` to let a grate image with this option
detect the runner:

```sh
mkdir -p output
docker run --rm --env GITHUB_ACTIONS --env DATABASE_TYPE=sqlite \
  --env 'APP_CONNSTRING=Data Source=/output/example.db' \
  --mount "type=bind,src=$PWD/migrations,dst=/db,readonly" \
  --mount "type=bind,src=$PWD/output,dst=/output" \
  gratedevs/grate
```

For other runners, forward the corresponding variable from the table. You can
also pass a flag after the image name, for example
`gratedevs/grate --log-format=azure-devops`, without forwarding any runner variables.
