# grate-postgresql

Run SQL migrations against PostgreSQL with the PostgreSQL-only grate command-line tool.

```sh
dotnet tool install --global grate-postgresql
grate --connectionstring "<PostgreSQL connection string>" --files ./sql --silent
```

PostgreSQL is the default database. Explicit `--databasetype postgresql` is also supported.
Use the `grate` tool for a distribution containing all supported database providers.
Use the `grate.postgresql` library to run migrations from .NET code.

[grate documentation](https://grate-devs.github.io/grate/)
