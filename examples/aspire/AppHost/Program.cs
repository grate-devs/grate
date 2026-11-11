using Grate.Aspire.Hosting;

var builder = DistributedApplication.CreateBuilder(args);
var password = builder.AddParameter("password", secret: true);
var database = builder.AddPostgres("postgres", password: password)
    .WithImageTag("16")
    .WithDataVolume("grate-aspire-example-postgres")
    .AddDatabase("appdb");

var migrate = database.AddGrateMigration()
    .WithScriptsFolder("../db");

builder.AddProject<Projects.Api>("api")
    .WithHttpEndpoint(name: "http")
    .WithReference(database)
    .WithHttpHealthCheck("/health")
    .WaitForCompletion(migrate);

await builder.Build().RunAsync();
