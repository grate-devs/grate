# Offline script ordering prototype

This experiment for [#631](https://github.com/grate-devs/grate/issues/631) uses
Microsoft ScriptDOM to read local T-SQL definitions and write one JSON plan to
stdout. It lives outside the grate solution and packages.

## Build and run

Use the stable .NET 10 SDK. Run the build from outside the checkout so the
repository's pinned SDK does not control SDK selection. From the repository root:

```sh
poc="$PWD/docs/design/offline-script-ordering-poc"
(cd /tmp && dotnet build "$poc/OfflineScriptOrdering.csproj" -c Release)
planner="$poc/bin/Release/net10.0/OfflineScriptOrdering.dll"
dotnet "$planner" "$poc/fixtures/base"
python3 "$poc/verify-offline.py" "$planner"
```

Package restore may require internet access. The built DLL reads the SQL root
and needs neither a server nor database configuration. To demonstrate this with
a cached Linux .NET 10 SDK image:

```sh
docker run --rm --pull never --network none \
  --mount "type=bind,src=$poc,dst=/poc,readonly" \
  --entrypoint dotnet mcr.microsoft.com/dotnet/sdk:10.0 \
  /poc/bin/Release/net10.0/OfflineScriptOrdering.dll /poc/fixtures/base
```

## Supported inputs

- Immediate lowercase `.sql` files in the default `functions` and `views`
  folders. A file is UTF-8 and contains one `CREATE OR ALTER` definition of
  the corresponding kind. Functions in the group are inline table-valued.
- The supported `FROM` sources are schema-qualified named relations and
  table-valued function calls. The parser also detects two-part scalar calls.
  The subset excludes joins, CTE references and derived
  tables, token placeholders, and environment and EveryTime scripts.
- SQL identifiers match by exact, case-sensitive name. The planner uses
  ordinal filename order within each folder and prefers `functions` over
  `views` when multiple files can run. The plan uses paths relative to the SQL
  root. The production migrator has its own sorting and history identities.
- A leading `-- Dependencies:` line may list exact candidate paths separated
  by commas. It replaces that file's inferred prerequisites in the group.
  An empty declaration removes them all. Other files still infer dependencies
  normally. Outside references are reported separately as deployment assumptions.
- Duplicate definitions, missing declared paths, cycles, parse errors and
  detected unsupported inputs exit with a diagnostic and no JSON. The scope
  assumes the documented SQL subset. ScriptDOM provides syntax, while SQL Server
  resolves column names, collations and existing objects.

## SQL Server check

Use Python 3.8 or newer and a local `mcr.microsoft.com/mssql/server:2022-latest`
Docker image with `mssql-tools18`. The script starts an isolated Developer
Edition container with no published ports or volumes and removes it afterward.
It uses `sqlcmd` to apply the fresh plan, then applies the two changed files in
the upgrade plan. It checks the result of `dbo.fnReport()` and demonstrates why
the wrong orders fail. This exercise covers SQL binding. Grate's history,
transactions, and deployment-time plan validation are separate concerns.

```sh
python3 "$poc/verify-sql-server.py" "$planner"
```
