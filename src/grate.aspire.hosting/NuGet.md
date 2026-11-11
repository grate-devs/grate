# grate Aspire hosting

Experimental PostgreSQL hosting integration for Aspire 13.6.5 and .NET 10.

```csharp
using Grate.Aspire.Hosting;

var database = builder.AddPostgres("postgres").AddDatabase("appdb");
var migrate = database.AddGrateMigration().WithScriptsFolder("db");
builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WaitForCompletion(migrate);
```

The default image is `gratedevs/grate:2.3.0`. The adapter starts a finite
container, waits for the database, sets PostgreSQL, `CREATE_DATABASE=false`
and environment `LOCAL`, and mounts scripts read-only at `/db`.

Override resource naming/readiness through `AddGrateMigration(name,
waitForDatabase)`, script source/target/read-only settings through
`WithScriptsFolder`, and image or environment through standard Aspire builder
methods. `APP_CONNSTRING` accepts a deferred connection expression; no connection
string parsing is used. An override image must provide `/bin/sh` and `/app/grate`.
The adapter builds the CLI invocation directly rather than using the image's
fixed `/db` launcher. Additional nonconflicting CLI arguments can be appended
with `WithArgs`.

`VERSION`, `TRANSACTION` and `GRATE_OUTPUT_PATH` override the CLI version,
transaction and output settings, defaulting to `1.0.0`, `false` and `/output`.
The migration resource name defaults to `<database-resource-name>-grate`.
The database owns persistence and creation; API resources explicitly opt into
waiting for migration completion. PostgreSQL is the only typed provider in this
initial package. Local orchestration is not a production rollout mechanism.
