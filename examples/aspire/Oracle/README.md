# Oracle Aspire example

This checkout example uses the unpublished `grate.aspire.oracle` adapter with Aspire 13.6.5 and .NET 10.
Start Docker and configure the AppHost secret `Parameters:password` through your
normal secret store, then run:

```powershell
dotnet user-secrets set --project examples/aspire/Oracle/AppHost 'Parameters:password' '<your-local-password>'
dotnet run --project examples/aspire/Oracle/AppHost --framework net10.0 --configuration Release
```

The native Oracle resource selects the existing `FREEPDB1` service with SYSTEM
credentials. `AddDatabase` does not create a PDB or application user. The
`gvenzl/oracle-free:23.26.3-faststart` image creates the database; grate defaults
to `CREATE_DATABASE=false` and creates the example table and its history tables
inside that PDB. This local demonstration uses administrator credentials;
provision a separate application user and its required grants for a real app.
The image supports Linux AMD64 and ARM64. Allow sufficient Docker memory and run
only one database smoke suite at a time on a constrained machine.

The dashboard uses local HTTP development settings in `launchSettings.json`.
The API starts only after the migration exits successfully. Its root endpoint
reads the migrated seed row. A named `grate-aspire-example-oracle` volume keeps
the database across restarts. Remove that volume deliberately to reset the demo.

The isolated smoke runner creates unique containers and temporary script folders,
checks table/data and one-time history, restarts on retained storage, checks a SQL
failure blocks the API and records an error, and checks invalid credentials block
the API without disclosing credentials in migration logs. It removes its own
containers and volumes after each scenario, including failures:

```powershell
dotnet run --project examples/aspire/Oracle/Smoke --framework net10.0 --configuration Release -- all
```

Select `success`, `retained`, `sql-failure`, or `credentials-failure` instead of
`all` for a focused check. The app graph has a bounded ten-minute timeout per
scenario. It uses the released `gratedevs/grate:2.3.0` migration image.

Image initialization semantics and ARM support are documented by the
[image maintainer](https://github.com/gvenzl/oci-oracle-free); Oracle resource
service selection is in the [Aspire 13.6.5 source](https://github.com/microsoft/aspire/blob/v13.6.5/src/Aspire.Hosting.Oracle/OracleDatabaseBuilderExtensions.cs).
