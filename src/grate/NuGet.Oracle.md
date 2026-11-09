# grate-oracle

Run SQL migrations against Oracle with the Oracle-only grate command-line tool.

```sh
dotnet tool install --global grate-oracle
grate --connectionstring "<Oracle connection string>" --files ./sql --silent
```

Oracle is the default database. Explicit `--databasetype oracle` is also supported.
Use the `grate` tool for a distribution containing all supported database providers.
Use the `grate.oracle` library to run migrations from .NET code.

[grate documentation](https://grate-devs.github.io/grate/)
