# grate.aspire.oracle

Add this optional package to an Aspire AppHost to migrate a native Oracle database resource:

```csharp
using Grate.Aspire.Hosting;

var database = builder.AddOracle("oracle").AddDatabase("appdb", "FREEPDB1");
var migration = database.AddGrateMigration().WithScriptsFolder("../db");
builder.AddProject<Projects.Api>("api").WithReference(database).WaitForCompletion(migration);
```

The `AddDatabase` service must already exist. Aspire's Oracle resource selects its
service using SYSTEM credentials; it does not create a PDB or application user.
The Oracle container owns initial database creation, and grate defaults to
`CREATE_DATABASE=false`. Supply initialization scripts or provision a dedicated
application schema and use the base package's explicit-provider overload with its
connection string for deployments requiring different credentials.

Connections remain deferred Aspire expressions. Standard `WithEnvironment`,
`WithImage`, `WithArgs` and readiness configuration remain available. Readiness
waits for the database's parent server by default; set `waitForDatabase: false`
only when you arrange readiness yourself.
