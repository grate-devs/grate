# MySQL Aspire example

This checkout example uses the unpublished `grate.aspire.mysql` adapter with
Aspire 13.6.5 and .NET 10. Start Docker and set the local AppHost password:

```powershell
dotnet user-secrets set --project examples/aspire/MySql/AppHost 'Parameters:password' '<your-local-password>'
dotnet run --project examples/aspire/MySql/AppHost --framework net10.0 --configuration Release
```

The example pins `mysql:8.4.13` in the MySQL 8.4 LTS line, independently of
Aspire's default MySQL image. Native Aspire creates `appdb` after the server is
ready and checks the database connection. Grate leaves `CREATE_DATABASE=false`,
uses its `mariadb` provider for MySQL, and creates the example table and migration
history. Both providers share MySqlConnector; the MySQL sample uses MySQL SQL.
The native resource supplies root credentials for this local demonstration.

The API starts after a successful migration and reads the seed row at `/`.
The named `grate-aspire-example-mysql` volume retains data between restarts.
Remove that volume deliberately to reset the example. Docker supports the
image on Linux AMD64 and ARM64; run one database suite at a time when memory is
limited. The migration uses the released `gratedevs/grate:2.3.0` image.

Run the isolated checks with:

```powershell
dotnet run --project examples/aspire/MySql/Smoke --framework net10.0 --configuration Release -- all
```

Select `success`, `retained`, `sql-failure`, or `credentials-failure` for a focused
check. Each scenario has a four-minute bound and owns unique containers, a volume,
and temporary SQL scripts. Checks cover native database provisioning, table/data,
API reads, error history, and one-time migration identity/hash across retained
storage. Invalid SQL and credentials must block API startup. Migration logs are
checked for credential disclosure. The runner removes its resources after each
scenario, including failures.

Database creation and health checks follow the
[Aspire 13.6.5 implementation](https://github.com/dotnet/aspire/blob/v13.6.5/src/Aspire.Hosting.MySql/MySqlBuilderExtensions.cs).
The selected patch is listed in the
[MySQL 8.4 release notes](https://dev.mysql.com/doc/relnotes/mysql/8.4/en/).
