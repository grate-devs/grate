# Contributing

I'm very happy that you are reading this page! Grate needs all the contributors it can get!
I'll try to jot down a few notes on how to get started developing grate.

## Get .NET 10

Grate is built with .NET 8/9/10. You can get it [here](https://dotnet.microsoft.com/en-us/download) and start building right away.

## Get (buy, borrow, rent, or whatever) a computer with an operating system on it

.NET 8+ runs on Windows, macOS or Linux. You choose what you like to use for development.

## Get Docker

Grate uses docker extensively for testing against different databases, so you need to get it from e.g. 
[The docker website](https://www.docker.com/products/docker-desktop), or you can probably use a package manager on your platform to 
install it.

## Clone the grate repo

```
git clone https://github.com/grate-devs/grate.git
```

## Run the tests, to make sure you are properly up and running

```
> cd grate
> dotnet test --solution unittests/CoreTests.slnf --framework net10.0 --max-parallel-test-modules 1
```

This runs the same seven core/database test projects as CI. Run one module at a
time on a development machine: database containers share Docker Desktop's memory,
and running several SQL Server or Oracle instances together can exhaust it.
Each CI database job has a separate runner. Omit `--framework net10.0` to test all
three supported frameworks, provided their runtimes are installed.

Running `dotnet test` from the repository root includes 17 test projects across
three frameworks, including command-line and Docker integration tests. MTP can run
as many modules concurrently as there are logical processors. The existing
`unittests/UnitTests.slnf` also includes these integration projects.

Local Docker integration tests automatically build `grate-local:tests` from your
checkout immediately before the first migration that needs the application
container. Building projects, listing tests, or filtering out these tests does
not run `docker build`. The selected Docker projects and target frameworks share
one image build per normal .NET build; Docker reuses cached layers when inputs
are unchanged. No image is pushed:

```sh
dotnet test --framework net10.0 --max-parallel-test-modules 1
```

CI and an explicit image other than `grate-local:tests` do not trigger this
build. Set `GrateBuildLocalDockerImage=false` to disable it explicitly.

The Docker test projects copy `unittests/Docker/testconfig.local.json` beside their
executables as MTP configuration. It sets
`GrateTestConfig__DefaultApplicationDockerImage=grate-local:tests`. An explicit
`GrateTestConfig__ApplicationDockerImage` takes precedence, so callers can still
select another image without editing the profile. Local runs need neither
variable on the command line.

Builds with `CI=true` or `ContinuousIntegrationBuild=true` select the separate
`testconfig.ci.json`, which does not set a local image. `GrateTestEnvironment`
can explicitly select `local` or `ci` during a build. `--no-build` uses whichever
configuration was copied by the preceding build.

The application-image setting applies only to Docker integration tests.
`GrateTestConfig__DockerImage` independently selects the database image. The CI
integration workflow currently disables the Docker tests because it does not
build and pass a matching application image to them.

For a focused Docker check, add, for example,
`--project unittests/Docker/Docker.Sqlite`.

`--no-build`, `--test-modules`, and direct test-executable runs reuse the last
build plan. If it has already built the image, they do not rebuild it. Run without
`--no-build` after changing application sources to prepare a fresh build plan.
When automatic image building is disabled, prepare it explicitly:

```sh
docker build -f installers/docker/Dockerfile -t grate-local:tests .
```

## Build a self-contained executable (if you want)

Grate is set up to build in the whole .NET framework in the executable when built in release mode, so the executable is a bit bigger than you 
might expect. But it's totally independent of .NET being installed on the runtime environment at all, and not of the versions actually installed either.
You can build a self-contained executable just using `dotnet publish` (example from my mac below)

```
> cd src/grate
> dotnet publish -r osx-x64 --self-contained true --framework net10.0 -c Release -o /tmp/grate
```

Find the fully independent executable, and the noticable size:
```
> ls -lh /tmp/grate 
total 59808
-rwxr-xr-x  1 erik  staff    29M Sep 14 23:22 grate
```

Verify that the executable is working:
```
> /tmp/grate/grate 
Option '--connectionstring' is required.

Description:
  The new grate - sql for the 20s

Usage:
  grate [options]

Options:
  --database <database>                                                    OBSOLETE: Please specify the connection string instead
  -c, -cs, --connectionstring, --connstring <connectionstring> (REQUIRED)  You now provide an entire connection string. ServerName and Database are obsolete.
  -f, --files, --sqlfilesdirectory <sqlfilesdirectory>                     The directory where your SQL scripts are [default: .]
  -o, --output, --outputPath <outputPath>                                  This is where everything related to the migration is stored. This includes any 
                                                                           backups, all items that ran, permission dumps, logs, etc. [default: 
                                                                           /Users/erik/.local/share/grate]
  -s, --instance, --server, --servername <servername>                      OBSOLETE: Please specify the connection string instead.
  -a, -acs, -csa, --adminconnectionstring, --adminconnstring               The connection string for connecting to master, if you want to create the database.
  <adminconnectionstring>
  --accesstoken <accesstoken>                                              Access token to be used for logging in to SQL Server / Azure SQL Database.
  -ct, --commandtimeout <commandtimeout>                                   This is the timeout when commands are run. This is not for admin commands or 
                                                                           restore. [default: 60]
  -cta, --admincommandtimeout <admincommandtimeout>                        This is the timeout when administration commands are run (except for restore, which 
                                                                           has its own). [default: 300]
  --databasetype, --dbt, --dt <mariadb|oracle|postgresql|sqlserver>        Tells grate what type of database it is running on. [default: sqlserver]
  --schemaversion <schemaversion>                                          Specify the version directly.
  -t, --transaction, --trx <transaction>                                   Run the migration in a transaction
  --env, --environment <environment>                                       Run for only a certain environment (can be specified multiple times to run for more 
                                                                           environments)
  --sc, --schema, --schemaname <schemaname>                                The schema to use for the migration tables [default: grate]
  -ni, --noninteractive, --silent                                          Silent - tells grate not to ask for any input when it runs.
  -v, --verbose                                                            Verbose output
  --version                                                                Show version information
  -?, -h, --help                                                           Show help and usage information
```

## Open your favourite editor or IDE, and start hacking

I really like [Jetbrains Rider](https://www.jetbrains.com/rider/), but it does cost money. Free alternatives are e.g. [Visual Studio Code](https://code.visualstudio.com/download)
(free, and cross platform), or [Visual Studio Community Edition](https://visualstudio.microsoft.com/downloads/). Use what you love, and start hacking :)
