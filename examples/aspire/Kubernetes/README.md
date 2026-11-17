# PostgreSQL migrations in a Kubernetes init container

This source-checkout example uses `grate.aspire.kubernetes` with the native
Aspire 13.6.5 Kubernetes publisher (`13.6.5-preview.1.26559.7`). It is not a
published package installation guide. The database already exists; this example
does not provision PostgreSQL or connect to a cluster during offline checks.

```csharp
using Grate.Aspire.Hosting;
using Grate.Aspire.Kubernetes;

var database = builder.AddConnectionString("appdb");
var migration = database.AddGrateMigration(
        GrateDatabaseProvider.PostgreSql, waitForDatabase: false)
    .WithScriptsFolder("../db");

builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
```

Locally, the application waits for the migration container to finish. Publishing
packages the SQL into a derived grate 2.3.0 image and places its finite launcher
in the application's native Kubernetes `initContainers`. No standalone migration
Deployment or Service is generated. The native image build/push precedes the
actual Helm deployment step. `PRODUCTION` selects grate's environment scripts;
it is separate from the native Aspire CLI's deployment environment selection.

The shared model also selects the registry explicitly and adds ordinary
application configuration, health checks, pod settings and an image pull secret.
These settings must survive init-container customization. In a real cluster,
provide the referenced `grate-example` service account and `registry-pull` image
pull secret, or customize the example to use existing names.

## Build and verify without a cluster

Use the repository's SDK, a .NET 10 runtime, PowerShell 7, the verified native
Aspire 13.6.5 CLI/bundle and Helm 4.2 or newer. The versioned
[`Install-AspireCli.ps1`](../../../scripts/Install-AspireCli.ps1) bootstrapper
returns `CliPath` and `BundlePath`; expose them as the `AspireCliPath` and
`AspireCliBundlePath` build environment variables. The optional
[`Install-KubernetesTestTools.ps1`](../../../scripts/Install-KubernetesTestTools.ps1)
bootstrapper installs the pinned Helm/kind test tools into a caller-owned folder.

From the repository root:

```powershell
./scripts/Verify-AspireKubernetesPublication.ps1 -HelmPath /path/to/helm
```

The script builds the publication-check executable and runs native `publish`
without deploying, pushing an image, reading a kubeconfig or contacting a
cluster. It captures the final native pipeline graph, runs `helm lint` and
`helm template`, and checks the rendered YAML structurally. Checks cover the
finite init command/arguments, explicit environment, secret references, native
built-image mapping, preserved application configuration/pull secrets and
absence of staging variables in the primary environment. A dummy connection
containing quotes, a backslash and a newline must survive both Secret resources
unchanged. Passing temporary output is removed; failures retain local diagnostics.

To retain artifacts for an owned disposable-cluster test, run the built
`PublicationChecks.dll` directly from a directory outside the checkout:

```powershell
$env:GRATE_KUBE_CHECK_OUTPUT = '/path/to/new-output-directory'
$env:GRATE_HELM_PATH = '/path/to/helm'
dotnet /absolute/path/to/examples/aspire/Kubernetes/PublicationChecks/bin/Release/net10.0/PublicationChecks.dll
```

The output includes the native chart, rendered YAML/JSON, `pipeline-check.json`
and a nonsecret `runtime-contract.json` containing the actual Helm value paths
and resource names. Setting `GRATE_KUBE_BUILD_IMAGE` to a caller-owned local tag
also builds the packaged migration image while the AppHost is alive. This
opt-in requires Docker and leaves image cleanup to the caller. The default
artifact check does not require Docker. The AppHost owns the temporary build
context; an exported chart is not a portable source context for a later image
build. Use the native build pipeline, or build the image before that host exits.

## Verify startup in a disposable cluster

With Docker, kubectl and the pinned Helm/kind clients available:

```powershell
./scripts/Verify-AspireKubernetesRuntime.ps1 -HelmPath /path/to/helm -KindPath /path/to/kind
```

This builds the actual API and migration images, creates a uniquely named kind
cluster and installs the generated Helm chart. It verifies that the init migration
finishes before the API serves seeded data, a replacement Pod preserves one-time
history/data, and invalid SQL records an error while the main container remains
unstarted. The database password includes separators, quotes and a backslash.
Every kubectl/Helm operation uses an owned kubeconfig and explicit context; the
caller's current context is untouched. Cleanup removes the owned cluster and
image tags, and a cleanup failure fails verification while retaining diagnostics.

## Deploy to an existing cluster

Supply a valid `ConnectionStrings:appdb` secret reachable from both the init
container and API. Set `Registry:Endpoint` and `Registry:Repository` for a real
registry; the example's `registry.example/grate` default is deliberately unusable
for deployment. Build/push credentials and the cluster's pull secret are separate
requirements. Keep native deploy-time values files containing credentials out
of version control. An intended cluster/context must be selected by the operator
before a real native `aspire deploy`; the offline verifier never selects one.

After configuring the database connection, registry, credentials and Pod resources,
generate a chart for inspection or run the native deployment pipeline:

```powershell
aspire publish --apphost examples/aspire/Kubernetes/AppHost/AppHost.csproj --output-path /absolute/path/to/artifacts
aspire deploy --apphost examples/aspire/Kubernetes/AppHost/AppHost.csproj
```

`aspire deploy` builds/pushes images and applies the chart to the selected cluster.
These commands are separate from the offline verifier and disposable-cluster test.

An init container runs for each new pod, including replica creation and restarts
that recreate the pod. Successful init completion gates that pod's application
startup; SQL failure keeps the main container from starting. This is not one
global migration per rollout. Multiple pods, applications or deployments using
one database need external serialization or another deliberate migration owner.
grate's history does not supply a cross-pod migration lock, and interruption does
not guarantee rollback of already committed SQL. SQLite shared-file deployment
is explicitly unsupported by this Kubernetes adapter.
