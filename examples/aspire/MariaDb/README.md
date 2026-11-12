# MariaDB Aspire example

This checkout example uses the unpublished `grate.aspire.mysql` adapter with
Aspire 13.6.5 and .NET 10. MariaDB uses the native MySQL database resource and
grate's `mariadb` provider. The official MariaDB image accepts the native
resource's `MYSQL_ROOT_PASSWORD` variable. Aspire provisions `appdb` after the
server becomes ready; grate leaves database creation disabled.

From the repository root with Docker running:

```powershell
dotnet user-secrets set --project examples/aspire/MariaDb/AppHost 'Parameters:password' '<your-local-password>'
dotnet run --project examples/aspire/MariaDb/AppHost --framework net10.0 --configuration Release
```

The example pins `mariadb:12.3.3` and `gratedevs/grate:2.3.0`. It uses root
credentials for a disposable local demonstration. The API starts after a
successful migration and reads the seed row at `/`. The named
`grate-aspire-example-mariadb` volume retains the database; reuse the same
password when restarting, or remove the volume deliberately to reset it.

Run the isolated checks from any directory:

```powershell
pwsh -NoProfile -File /absolute/path/to/examples/aspire/Smoke.ps1 -Provider mariadb
```

The checks verify the actual MariaDB server version, native database
provisioning, table/data and API response, retained migration identity/hash,
and blocked API startup for SQL errors and incorrect credentials. SQL failures
must also produce an error-history row. Every scenario uses its own bounded
execution, scripts, containers and volume, checks logs for its generated
credentials, and removes its resources on success or failure. Run one database
suite at a time on memory-constrained Docker hosts.

For SDK selection, see the repository's
[stable .NET 10 fallback](../../../CONTRIBUTING.md#working-with-the-stable-net-10-sdk).
The [official image entrypoint](https://github.com/MariaDB/mariadb-docker/blob/master/docker-entrypoint.sh)
implements the `MYSQL_*` compatibility aliases. Native database provisioning
and readiness follow the
[pinned Aspire implementation](https://github.com/dotnet/aspire/blob/v13.6.5/src/Aspire.Hosting.MySql/MySqlBuilderExtensions.cs).
