# grate-sqlite

Run SQL migrations against SQLite with the SQLite-only grate command-line tool.

```sh
dotnet tool install --global grate-sqlite
grate-sqlite --connectionstring "Data Source=example.db" --files ./sql --silent
```

SQLite is the default database. Explicit `--databasetype sqlite` is also supported.
Use the `grate` tool for a distribution containing all supported database providers.
Use the `grate.sqlite` library to run migrations from .NET code.

[grate documentation](https://grate-devs.github.io/grate/)
