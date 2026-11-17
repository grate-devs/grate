using Aspire.Hosting;
using Grate.Aspire.Example.Kubernetes;

var builder = DistributedApplication.CreateBuilder(args);
KubernetesExampleModel.Configure(builder);
await builder.Build().RunAsync();
