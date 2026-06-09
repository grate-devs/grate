# grate

grate is a SQL scripts migration runner, using plain, old SQL for migrations. No meta-language, no code, no config,
no EF migrations. It gives you full flexibility, and full control of your migrations, and lets you use
all the fancy features of you particular database system. You are not constrained to any lowest common
feature set of all supported databases.

# grate.core
[![NuGet](https://img.shields.io/nuget/v/grate.core.svg)](https://www.nuget.org/packages/grate.core/)

This is the core package, which does nothing by itself. You need to add a database specific package to use it.
See below for the list of supported databases.


# grate (dotnet tool)
[![NuGet](https://img.shields.io/nuget/v/grate.svg)](https://www.nuget.org/packages/grate/)

grate is also available as a dotnet tool, which can be installed with the following command:

```shell
dotnet tool install -g grate
```


## Minimal example
The only required argument to pass to grate is a **connection string** to tell it where to find your database. 
It will deploy to that database, looking for sql scripts in the current directory.

```csharp
[Fact]
public async Task Run_migration_agains_target_db()
{
    var serviceCollection = new ServiceCollection();
    serviceCollection.AddLogging();
    serviceCollection.AddGrate(builder =>
    {
        builder
            .WithSqlFilesDirectory("/db")
            .WithConnectionString("mariadb/mysql connection string here")
    })
    .UseMariaDb(); // Important!, you need to specify the database type to use.
    var serviceProvider = serviceCollection.BuildServiceProvider();
    var grateMigrator = serviceProvider.GetRequiredService<IGrateMigrator>();
    await grateMigrator.Migrate();
}
```

for more configuration options, see the [documentation](https://grate-devs.github.io/grate/configuration-options/).


## grate supports the following DMBS's

| Database  | NuGet package |
|--|--|
| Microsoft SQL server (sqlserver) | [![NuGet](https://img.shields.io/nuget/v/grate.sqlserver.svg)](https://www.nuget.org/packages/grate.sqlserver/) |
| PostgreSQL (postgresql) | [![NuGet](https://img.shields.io/nuget/v/grate.postgresql.svg)](https://www.nuget.org/packages/grate.postgresql/) |
| MariaDB/MySQL (mariadb) | [![NuGet](https://img.shields.io/nuget/v/grate.mariadb.svg)](https://www.nuget.org/packages/grate.mariadb/) |
| Sqlite (sqlite) | [![NuGet](https://img.shields.io/nuget/v/grate.sqlite.svg)](https://www.nuget.org/packages/grate.sqlite/) |
| Oracle (oracle) | [![NuGet](https://img.shields.io/nuget/v/grate.oracle.svg)](https://www.nuget.org/packages/grate.oracle/) |

Full documentation can be found at [https://grate-devs.github.io/grate/](https://grate-devs.github.io/grate/).


