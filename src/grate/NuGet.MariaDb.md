# grate-mariadb

Run SQL migrations against MariaDB with the MariaDB-only grate command-line tool.

```sh
dotnet tool install --global grate-mariadb
grate --connectionstring "<MariaDB connection string>" --files ./sql --silent
```

MariaDB is the default database. Explicit `--databasetype mariadb` is also supported.
Use the `grate` tool for a distribution containing all supported database providers.
Use the `grate.mariadb` library to run migrations from .NET code.

[grate documentation](https://grate-devs.github.io/grate/)
