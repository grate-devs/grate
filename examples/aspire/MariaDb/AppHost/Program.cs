using Grate.Aspire.Hosting;

var builder = DistributedApplication.CreateBuilder(args);
var password = builder.AddParameter("password", secret: true);
// MariaDB's official image accepts the native integration's MYSQL_ROOT_PASSWORD.
// Keep the native MySQL resource for database provisioning and health checks.
var database = builder.AddMySql("mariadb", password: password)
    .WithImage("mariadb", "12.3.3")
    .WithDataVolume("grate-aspire-example-mariadb")
    .AddDatabase("appdb");
var migration = database.AddGrateMigration()
    .WithScriptsFolder("../db");

builder.AddProject<Projects.Api>("api")
    .WithHttpEndpoint(name: "http")
    .WithReference(database)
    .WithHttpHealthCheck("/health")
    .WaitForCompletion(migration);

await builder.Build().RunAsync();
