# grate.aspire.mysql

Adds grate migrations to native Aspire MySQL database resources. Targets .NET 10
and Aspire 13.6.5. Add `using Grate.Aspire.Hosting;` and configure:

```csharp
var migration = database.AddGrateMigration().WithScriptsFolder("../db");
api.WaitForCompletion(migration);
```

Aspire provisions the database and checks its readiness. Grate uses its `mariadb`
provider for MySQL and leaves database creation disabled. Connection strings and
credentials remain deferred Aspire expressions. Native Aspire configuration and
grate image/environment overrides remain available.
