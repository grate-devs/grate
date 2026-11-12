using Grate.Aspire.Hosting;

var builder = DistributedApplication.CreateBuilder(args);
var password = builder.AddParameter("password", secret: true);
var database = builder.AddSqlServer("sqlserver", password: password)
    .WithImageTag("2022-latest")
    .WithContainerRuntimeArgs("--platform", "linux/amd64")
    .WithDataVolume("grate-aspire-example-sqlserver")
    .AddDatabase("appdb");
var migration = database.AddGrateMigration()
    .WithScriptsFolder("../db");

builder.AddProject<Projects.Api>("api")
    .WithEnvironment("DatabaseProvider", "sqlserver")
    .WithHttpEndpoint(name: "http")
    .WithReference(database)
    .WithHttpHealthCheck("/health")
    .WaitForCompletion(migration);

await builder.Build().RunAsync();
