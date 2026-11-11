#!/usr/bin/env pwsh
# Compile and execute an isolated consumer of the locally packed prototype.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repository = Split-Path $PSScriptRoot -Parent
$project = Join-Path $repository 'src/grate.aspire.hosting/grate.aspire.hosting.csproj'
$workspace = Join-Path ([IO.Path]::GetTempPath()) "grate-aspire-package-$([Guid]::NewGuid().ToString('N'))"
$feed = Join-Path $workspace 'feed'
$consumer = Join-Path $workspace 'consumer'
$packageVersion = '0.0.0-local.956'

New-Item -ItemType Directory -Path $feed, $consumer | Out-Null
try {
    # For the documented SDK 10 fallback, invoke this script from outside the
    # checkout. This adapter targets net10 only; no grate core project is built.
    dotnet pack $project -c Release --output $feed "-p:PackageVersion=$packageVersion"
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
  </ItemGroup>
</Project>
"@
    Set-Content -LiteralPath (Join-Path $consumer 'Consumer.csproj') -Value $projectContent
    $program = @'
using Aspire.Hosting;
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
if (migration.Resource.Name != "appdb-grate" ||
    sqlServerMigration.Resource.Name != "sqldb-grate" ||
    sqliteMigration.Resource.Name != "filedb-grate" ||
    builder.Resources.OfType<GrateMigrationResource>().Count() != 3)
{
    throw new InvalidOperationException("The packaged API did not register one migration per provider.");
}
Console.WriteLine("PASS: isolated NuGet consumer compiled and registered all three migration providers.");
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
