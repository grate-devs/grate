# grate-sqlserver

Run SQL migrations against SQL Server with the SQL Server-only grate command-line tool.

```sh
dotnet tool install --global grate-sqlserver
grate --connectionstring "<SQL Server connection string>" --files ./sql --silent
```

SQL Server is the default database. Explicit `--databasetype sqlserver` is also supported.
Use the `grate` tool for a distribution containing all supported database providers.
Use the `grate.sqlserver` library to run migrations from .NET code.

[grate documentation](https://grate-devs.github.io/grate/)
