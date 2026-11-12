using Grate.Aspire.Hosting;

var builder = DistributedApplication.CreateBuilder(args);
var password = builder.AddParameter("password", secret: true);
var database = builder.AddMySql("mysql", password: password)
    .WithImageTag("8.4.13")
    .WithDataVolume("grate-aspire-example-mysql")
    .AddDatabase("appdb");
var migration = database.AddGrateMigration()
    .WithScriptsFolder("../db");

builder.AddProject<Projects.Api>("api")
    .WithHttpEndpoint(name: "http")
    .WithReference(database)
    .WithHttpHealthCheck("/health")
    .WaitForCompletion(migration);

await builder.Build().RunAsync();
