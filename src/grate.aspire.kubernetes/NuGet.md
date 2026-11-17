# grate Aspire Kubernetes integration

Prototype in this checkout; not a released package.

```csharp
using Grate.Aspire.Hosting;
using Grate.Aspire.Kubernetes;

var kubernetes = builder.AddKubernetesEnvironment("kubernetes");
#pragma warning disable ASPIRECOMPUTE003 // Pinned Aspire registry APIs are experimental.
var registry = builder.AddContainerRegistry("registry", "registry.example.com", "my-team");
kubernetes.WithContainerRegistry(registry);
#pragma warning restore ASPIRECOMPUTE003
var database = builder.AddConnectionString("appdb");
var migration = database.AddGrateMigration(GrateDatabaseProvider.PostgreSql)
    .WithScriptsFolder("sql");

builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
```

The helper adds a local completion wait. During native Aspire Kubernetes publishing
it packages the scripts in a separate migration image and adds a regular init
container to this application's Deployment or StatefulSet. It preserves native
registry selection and image build/push steps; configure cluster pull credentials
through the normal pod `ImagePullSecrets` customization when needed.

The connection string must be a deferred secret reference without a published
default. Migration variables are isolated from the main container in separate
ConfigMap/Secret resources. `environment` is explicit for each consumer; the shared
local migration's environment is unchanged. Arguments must be literal strings;
use environment references for credentials.

Kubernetes reruns init containers when a pod starts. This does not provide a global
database lock or once-per-deployment execution. Review your migration concurrency
policy before increasing replicas. SQLite's shared host file is unsupported.
Select the compute environment before adding this binding and keep it unchanged.
The generated image build context lives for the current Aspire process; use the
native publish/deploy flow, rather than exporting a manifest for a later build.
