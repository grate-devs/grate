using Grate.Aspire.Hosting;

var builder = DistributedApplication.CreateBuilder(args);
var dataDirectory = Path.GetFullPath("../data", builder.AppHostDirectory);
var database = builder.AddSqlite("appdb", dataDirectory, "demo.db");
var migration = database.AddGrateMigration()
    .WithScriptsFolder("../db");

builder.AddProject<Projects.Api>("api")
    .WithEnvironment("DatabaseProvider", "sqlite")
    .WithHttpEndpoint(name: "http")
    .WithReference(database)
    .WithHttpHealthCheck("/health")
    .WaitForCompletion(migration);

await builder.Build().RunAsync();
