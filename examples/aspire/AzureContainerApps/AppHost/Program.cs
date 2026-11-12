using Aspire.Hosting;
using Grate.Aspire.Example.AzureContainerApps;

var builder = DistributedApplication.CreateBuilder(args);
AcaExampleModel.Configure(builder);
await builder.Build().RunAsync();
