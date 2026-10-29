# grate

grate is a SQL scripts migration runner, using plain, old SQL for migrations. No meta-language, no code, no config,
no EF migrations. It gives you full flexibility, and full control of your migrations, and lets you use
all the fancy features of you particular database system. You are not constrained to any lowest common
feature set of all supported databases.

## Supported runtimes

This tool includes .NET 8, 9, 10 and 11 assets. The .NET 11 build supports RC3
(runtime `11.0.0-rc.3.26522.148`) with Microsoft's go-live license. Install a
matching supported runtime and use an SDK to install the tool. RC3 support ends
November 10, 2026; move to the final .NET 11 runtime when available.

## Minimal example
The only required argument to pass to grate is a **connection string** to tell it where to find your database. 
It will deploy to that database, looking for sql scripts in the current directory.

```
grate --connectionstring="Server=(localdb)\MSSQLLocalDB;Integrated Security=true;Database=grate_test"
```

for more configuration options, see the [documentation](https://grate-devs.github.io/grate/configuration-options/).



## grate supports the following DMBS's

* Microsoft SQL server
* PostgreSQL
* MariaDB/MySQL
* Sqlite
* Oracle

Full documentation can be found at [https://grate-devs.github.io/grate/](https://grate-devs.github.io/grate/).



## Coding-agent skill

After installing this tool, run `grate skills install --global` to install its
bundled `use-grate` skill for Codex and Claude Code. For a project-local tool,
run `dotnet tool run grate -- skills install --local` from the repository.
See the [agent skill guide](https://grate-devs.github.io/grate/agent-skill/) for
locations and updating existing copies. Installation does not contact a database.
