using Grate.Aspire.Hosting;

var builder = DistributedApplication.CreateBuilder(args);
var password = builder.AddParameter("password", secret: true);
var database = builder.AddOracle("oracle", password)
    .WithImage("gvenzl/oracle-free", "23.26.3-faststart")
    .WithImageRegistry("docker.io")
    // This image uses ORACLE_PASSWORD; native Aspire defaults to Oracle's ORACLE_PWD.
    .WithEnvironment("ORACLE_PASSWORD", password)
    .WithDataVolume("grate-aspire-example-oracle")
    // AddDatabase selects an existing PDB/service; it does not create one.
    .AddDatabase("appdb", "FREEPDB1");
var migration = database.AddGrateMigration().WithScriptsFolder("../db");

builder.AddProject<Projects.Api>("api")
    .WithReference(database)
    .WithHttpEndpoint(name: "http")
    .WithHttpHealthCheck("/health")
    .WaitForCompletion(migration);

await builder.Build().RunAsync();
