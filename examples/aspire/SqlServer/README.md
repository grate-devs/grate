# SQL Server migrations in Aspire

This source-only prototype uses Aspire 13.6.5, SQL Server's
`mcr.microsoft.com/mssql/server:2022-latest` image and `gratedevs/grate:2.3.0`.
The hosting package is unpublished.

```csharp
var database = builder.AddSqlServer("sqlserver", password: password)
    .WithImageTag("2022-latest")
    .WithContainerRuntimeArgs("--platform", "linux/amd64")
    .AddDatabase("appdb");
var migration = database.AddGrateMigration()
    .WithScriptsFolder("../db");
```

Aspire creates the target database. The migration infers the SQL Server provider,
uses the deferred connection expression, defaults database creation to false and
waits for database readiness. The API references that database and waits for
successful migration completion.

## Run

Install the .NET 10 SDK and PowerShell 7 and start Docker. SQL Server's Linux
image requires amd64; arm64 hosts require container emulation. An unsupported
host or failed startup is not a passing verification or a reason to substitute
another database engine.

From this directory, set a password meeting SQL Server's password policy:

```powershell
dotnet user-secrets set --project AppHost/AppHost.csproj 'Parameters:password' '<your-local-password>'
dotnet run --project AppHost/AppHost.csproj --framework net10.0 --configuration Release
```

Find the API HTTP endpoint in the local Aspire dashboard and request `/`; it
should return `Hello from grate`. The named volume
`grate-aspire-example-sqlserver` retains data between runs. Keep the same
password. After stopping the AppHost and waiting for its containers to be
removed, discard the example database with:

```powershell
docker volume rm grate-aspire-example-sqlserver
```

From any directory, run the bounded checks:

```powershell
pwsh -NoProfile -File /absolute/path/to/examples/aspire/Smoke.ps1 -Provider sqlserver
```

They verify actual fresh schema/data/history and API response; retained-volume
restart; SQL errors with history and blocked API startup; and invalid
credentials with blocked API startup. The migration output is checked for
credential disclosure. Paths contain spaces. Each scenario removes its own
containers, temporary SQL and volume. Startup/migration failures time out rather
than silently skipping the test.

See the [shared guide](../README.md) for override and local-only support scope.
