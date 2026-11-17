using Aspire.Hosting;
using Grate.Aspire.Example.AzureAppService;

var builder = DistributedApplication.CreateBuilder(args);
AppServiceExampleModel.Configure(builder);
await builder.Build().RunAsync();
