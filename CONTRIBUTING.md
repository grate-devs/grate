# Contributing

I'm very happy that you are reading this page! Grate needs all the contributors it can get!
I'll try to jot down a few notes on how to get started developing grate.

## Get .NET 10

Grate is built with .NET 8/9/10. You can get it [here](https://dotnet.microsoft.com/en-us/download) and start building right away.

The build requires SDK 10.0.403 or a later stable .NET 10 SDK, as selected by `global.json`.
CI installs `10.0.x` and Docker uses `10.0-alpine` / `alpine:3` so subsequent builds receive servicing updates.
Self-contained distributions use the selected SDK's latest runtime patch and reject versions below
8.0.33 / 9.0.22 / 10.0.14. These are security minimums, not exact runtime pins.
Pull fresh base images when rebuilding Docker (`docker buildx build --pull ...`), record the resulting
image digests, and verify the embedded runtime and native SQLite versions before releasing.
The Docker final stage supplies Alpine and ICU; the .NET runtime is embedded by `dotnet publish` in the build stage.
MSI and Debian recipes consume those published standalone binaries; framework-dependent tools and libraries use the consumer's runtime.

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
> dotnet test --framework net10.0
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
