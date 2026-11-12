#!/usr/bin/env pwsh
# Compile and execute an isolated consumer of the locally packed prototype.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repository = Split-Path $PSScriptRoot -Parent
$packages = @('hosting', 'azure', 'oracle', 'mysql', 'kubernetes')
$workspace = Join-Path ([IO.Path]::GetTempPath()) "grate-aspire-package-$([Guid]::NewGuid().ToString('N'))"
$feed = Join-Path $workspace 'feed'
$consumer = Join-Path $workspace 'consumer'
$packageVersion = '0.0.0-local.956'

New-Item -ItemType Directory -Path $feed, $consumer | Out-Null
try {
    # For the documented SDK 10 fallback, invoke this script from outside the
    # checkout. This adapter targets net10 only; no grate core project is built.
    foreach ($package in $packages) {
        $project = Join-Path $repository "src/grate.aspire.$package/grate.aspire.$package.csproj"
        dotnet pack $project -c Release --output $feed "-p:PackageVersion=$packageVersion"
    }
    $projectContent = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <NuGetAudit>true</NuGetAudit>
    <NuGetAuditMode>all</NuGetAuditMode>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="grate.aspire.hosting" Version="$packageVersion" />
    <PackageReference Include="grate.aspire.azure" Version="$packageVersion" />
    <PackageReference Include="grate.aspire.oracle" Version="$packageVersion" />
    <PackageReference Include="grate.aspire.mysql" Version="$packageVersion" />
    <PackageReference Include="grate.aspire.kubernetes" Version="$packageVersion" />
  </ItemGroup>
</Project>
"@
    Set-Content -LiteralPath (Join-Path $consumer 'Consumer.csproj') -Value $projectContent
    $program = @'
using Aspire.Hosting;
using Aspire.Hosting.ApplicationModel;
using Grate.Aspire.Azure;
using Grate.Aspire.Hosting;

var builder = DistributedApplication.CreateBuilder(new DistributedApplicationOptions
{
    ProjectDirectory = AppContext.BaseDirectory,
    DisableDashboard = true
});
var database = builder.AddPostgres("postgres").AddDatabase("appdb");
var migration = database.AddGrateMigration().WithScriptsFolder(AppContext.BaseDirectory);
var sqlServer = builder.AddSqlServer("sqlserver").AddDatabase("sqldb");
var sqlServerMigration = sqlServer.AddGrateMigration().WithScriptsFolder(AppContext.BaseDirectory);
var sqlite = builder.AddSqlite("filedb",
    databasePath: Path.Combine(AppContext.BaseDirectory, "sqlite-data"), databaseFileName: "app.db");
var sqliteMigration = sqlite.AddGrateMigration().WithScriptsFolder(AppContext.BaseDirectory);
var oracle = builder.AddOracle("oracle").AddDatabase("oracledb", "FREEPDB1");
var oracleMigration = oracle.AddGrateMigration().WithScriptsFolder(AppContext.BaseDirectory);
var mysql = builder.AddMySql("mysql").AddDatabase("mysqldb");
var mysqlMigration = mysql.AddGrateMigration().WithScriptsFolder(AppContext.BaseDirectory);
var mariadb = builder.AddMySql("mariadb").WithImage("mariadb", "12.3.3").AddDatabase("mariadbdb");
var mariadbMigration = mariadb.AddGrateMigration().WithScriptsFolder(AppContext.BaseDirectory);
var consumer = builder.AddContainer("consumer", "nginx", "stable")
    .WithGrateMigrationInitContainer(migration, environment: "PRODUCTION");
// Use the target class explicitly when both deployment adapters are referenced.
var kubernetesConsumer = Grate.Aspire.Kubernetes.GrateKubernetesExtensions.WithGrateMigrationInitContainer(
    builder.AddContainer("kubernetes-consumer", "nginx", "stable"), mysqlMigration, environment: "PRODUCTION");
if (migration.Resource.Name != "appdb-grate" ||
    sqlServerMigration.Resource.Name != "sqldb-grate" ||
    sqliteMigration.Resource.Name != "filedb-grate" ||
    oracleMigration.Resource.Name != "oracledb-grate" ||
    mysqlMigration.Resource.Name != "mysqldb-grate" ||
    mariadbMigration.Resource.Name != "mariadbdb-grate" ||
    builder.Resources.OfType<GrateMigrationResource>().Count() != 6 ||
    !consumer.Resource.Annotations.OfType<WaitAnnotation>().Any(wait =>
        wait.Resource == migration.Resource && wait.WaitType == WaitType.WaitForCompletion && wait.ExitCode == 0) ||
    !kubernetesConsumer.Resource.Annotations.OfType<WaitAnnotation>().Any(wait =>
        wait.Resource == mysqlMigration.Resource && wait.WaitType == WaitType.WaitForCompletion && wait.ExitCode == 0))
{
    throw new InvalidOperationException("The packaged API did not register one migration per provider.");
}
Console.WriteLine("PASS: isolated NuGet consumer registered all six databases and both deployment APIs from five packages.");
'@
    Set-Content -LiteralPath (Join-Path $consumer 'Program.cs') -Value $program
    Push-Location $consumer
    try {
        # Explicit sources and a private package cache prevent a developer feed
        # or an older local prototype from satisfying this package reference.
        dotnet restore Consumer.csproj --packages (Join-Path $workspace 'packages') --source $feed --source https://api.nuget.org/v3/index.json
        dotnet run --project Consumer.csproj -c Release --no-restore
    }
    finally {
        Pop-Location
    }
}
finally {
    Remove-Item -LiteralPath $workspace -Recurse -Force
}
