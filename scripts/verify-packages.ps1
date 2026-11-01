param(
    [Parameter(Mandatory)][ValidateSet('Packages', 'Standalone')][string]$Kind,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$RuntimeIdentifier,
    [switch]$RunSmokeTest
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$frameworks = @(((dotnet msbuild src/grate/grate.csproj -nologo -getProperty:TargetFrameworks).Trim() -split ';') | Where-Object { $_ })
if ($frameworks.Count -eq 0) { throw 'No target frameworks found.' }
$targetFramework = $frameworks[-1]
$expectedRuntime = (dotnet msbuild src/grate/grate.csproj -nologo "-p:TargetFramework=$targetFramework" -getProperty:RuntimeFrameworkVersion).Trim()
if ($expectedRuntime -and $expectedRuntime -notlike "$($targetFramework.Substring(3)).*") {
    throw "Runtime version '$expectedRuntime' does not match $targetFramework."
}

function Test-Migration([string]$Executable, [string]$Directory) {
    New-Item -ItemType Directory -Force "$Directory/sql/up" | Out-Null
    'CREATE TABLE package_smoke (id INTEGER PRIMARY KEY); INSERT INTO package_smoke VALUES (1); CREATE TEMP TABLE package_check (value INTEGER CHECK(value = 1)); INSERT INTO package_check SELECT CASE WHEN COUNT(*) = 1 AND MIN(id) = 1 THEN 1 ELSE 0 END FROM package_smoke;' |
        Set-Content "$Directory/sql/up/001_create.sql"
    & $Executable --help
    # The second invocation must skip the already-run CREATE TABLE and INSERT.
    # Re-execution would fail with a duplicate table/primary key.
    foreach ($attempt in 1..2) {
        & $Executable --databasetype sqlite --connectionstring "Data Source=$Directory/smoke.db" --files "$Directory/sql" --output "$Directory/output" --silent
    }
    if (!(Test-Path "$Directory/smoke.db") -or (Get-Item "$Directory/smoke.db").Length -eq 0) {
        throw 'The packaged CLI did not create a SQLite database.'
    }
    # grate archives scripts it actually ran. Combined with the SQL CHECK above,
    # this rejects missing scripts, incorrect rows and a repeated one-time migration.
    $ran = @(Get-ChildItem "$Directory/output" -Filter '001_create.sql' -File -Recurse |
        Where-Object { $_.FullName -match '[\\/]itemsRan[\\/]up[\\/]001_create\.sql$' })
    if ($ran.Count -ne 1) { throw "Expected one executed migration script, found $($ran.Count)." }
    & $Executable skills install --local --path "$Directory/skill"
    if (!(Test-Path "$Directory/skill/.agents/skills/use-grate/SKILL.md")) {
        throw 'The packaged CLI did not install its bundled skill.'
    }
}

if ($Kind -eq 'Standalone') {
    if (!$RuntimeIdentifier) { throw '-RuntimeIdentifier is required for Standalone verification.' }
    $published = "$OutputDirectory/published"
    dotnet publish src/grate/grate.csproj -c Release -f $targetFramework -r $RuntimeIdentifier --self-contained -p:SelfContained=true "-p:TargetFrameworks=$targetFramework" -o $published
    # These files are the inputs embedded by the single-file bundler. Inspecting
    # them proves the runtime version even when the final archive contains one file.
    $buildDirectory = "src/grate/bin/Release/$targetFramework/$RuntimeIdentifier"
    $runtimeConfig = Get-Content "$buildDirectory/grate.runtimeconfig.json" -Raw | ConvertFrom-Json
    $runtime = @($runtimeConfig.runtimeOptions.includedFrameworks | Where-Object name -eq 'Microsoft.NETCore.App')
    if ($runtime.Count -ne 1 -or $runtime[0].version -notlike "$($targetFramework.Substring(3)).*" -or
        ($expectedRuntime -and $runtime[0].version -ne $expectedRuntime)) {
        throw "Self-contained $RuntimeIdentifier does not include the expected $targetFramework runtime."
    }
    $bundledRuntime = $runtime[0].version
    $deps = Get-Content "$buildDirectory/grate.deps.json" -Raw | ConvertFrom-Json -AsHashtable
    if (!$deps.libraries.ContainsKey("runtimepack.Microsoft.NETCore.App.Runtime.$RuntimeIdentifier/$bundledRuntime")) {
        throw "Self-contained $RuntimeIdentifier does not reference the expected runtime pack."
    }
    Copy-Item "$buildDirectory/grate.runtimeconfig.json", "$buildDirectory/grate.deps.json" $OutputDirectory
    if ($RunSmokeTest) {
        $executable = Join-Path $published $(if ($RuntimeIdentifier.StartsWith('win-')) { 'grate.exe' } else { 'grate' })
        Test-Migration $executable "$OutputDirectory/smoke"
    }
    Write-Host "Verified $RuntimeIdentifier bundles $bundledRuntime; native execution: $RunSmokeTest"
    return
}

$packages = "$OutputDirectory/packages"
$version = '0.0.0-ci.packages.' + [Guid]::NewGuid().ToString('N')
$libraryNames = @('grate.core', 'grate.mariadb', 'grate.oracle', 'grate.postgresql', 'grate.sqlite', 'grate.sqlserver')
foreach ($name in $libraryNames) {
    dotnet pack "src/$name/$name.csproj" -c Release --include-symbols -p:PackageVersion=$version -o $packages
}
# Framework-dependent packaging retains per-TFM assets usable by older SDKs.
# SelfContained=true in SDK 11 collapses them into tools/any/any (#867).
dotnet pack src/grate/grate.csproj -c Release -p:PackAsTool=true -p:SelfContained=false -p:PackageVersion=$version -o $packages

Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($name in @($libraryNames) + @('grate')) {
    $zip = [IO.Compression.ZipFile]::OpenRead("$packages/$name.$version.nupkg")
    try {
        foreach ($framework in $frameworks) {
            $entry = if ($name -eq 'grate') { "tools/$framework/any/grate.dll" } else { "lib/$framework/$name.dll" }
            if (!$zip.GetEntry($entry)) { throw "$name is missing $entry." }
        }
    } finally { $zip.Dispose() }
    if ($name -ne 'grate' -and !(Test-Path "$packages/$name.$version.snupkg")) {
        throw "$name is missing its symbol package."
    }
}

# Restore a consumer of all six local packages outside repository props. Execute
# the SQLite library API to check packaged bootstrap resources and migration history.
$references = ($libraryNames | ForEach-Object { "<PackageReference Include='$_' Version='$version' />" }) -join "`n"
$consumerSource = @'
using System;
using System.IO;
using grate.Configuration;
using grate.DependencyInjection;
using grate.Migration;
using grate.sqlite.DependencyInjection;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.DependencyInjection;

var root = Path.GetFullPath(args[0]);
var scripts = Path.Combine(root, "sql");
Directory.CreateDirectory(Path.Combine(scripts, "up"));
File.WriteAllText(Path.Combine(scripts, "up", "001_create.sql"),
    "CREATE TABLE package_consumer (id INTEGER PRIMARY KEY); INSERT INTO package_consumer VALUES (1);");
var connectionString = new SqliteConnectionStringBuilder
    { DataSource = Path.Combine(root, "consumer.db"), Pooling = false }.ToString();
for (var attempt = 0; attempt < 2; attempt++)
{
    var services = new ServiceCollection();
    services.AddLogging();
    services.AddGrate(GrateConfiguration.Default with { NonInteractive = true },
        builder => builder.WithConnectionString(connectionString)
        .WithSqlFilesDirectory(scripts).WithOutputFolder(Path.Combine(root, "output"))
        .WithVersion("1.0.0")).UseSqlite();
    await using var provider = services.BuildServiceProvider();
    await provider.GetRequiredService<IGrateMigrator>().Migrate();
}
using var connection = new SqliteConnection(connectionString);
connection.Open();
Check("SELECT COUNT(*) FROM package_consumer WHERE id = 1", 1);
Check("SELECT COUNT(*) FROM package_consumer", 1);
Check("SELECT COUNT(*) FROM grate_ScriptsRun", 1);
Check("SELECT COUNT(*) FROM grate_ScriptsRun WHERE script_name = '001_create.sql' AND text_hash <> '' AND one_time_script = 1", 1);
Check("SELECT COUNT(*) FROM grate_ScriptsRunErrors", 0);
Console.WriteLine("Packed SQLite library created schema, data and history exactly once.");

void Check(string sql, long expected)
{
    using var command = connection.CreateCommand();
    command.CommandText = sql;
    var actual = Convert.ToInt64(command.ExecuteScalar());
    if (actual != expected) throw new InvalidOperationException($"{sql}: expected {expected}, got {actual}.");
}
'@
foreach ($framework in $frameworks) {
    $consumer = "$OutputDirectory/consumer/$framework"
    New-Item -ItemType Directory -Force $consumer | Out-Null
    "<Project Sdk='Microsoft.NET.Sdk'><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>$framework</TargetFramework></PropertyGroup><ItemGroup>$references</ItemGroup></Project>" |
        Set-Content "$consumer/consumer.csproj"
    $consumerSource | Set-Content "$consumer/Program.cs"
    dotnet build "$consumer/consumer.csproj" -c Release --source $packages --source https://api.nuget.org/v3/index.json
    dotnet "$consumer/bin/Release/$framework/consumer.dll" "$consumer/smoke"
}

# Install and run each tool target with only its matching runtime available.
foreach ($framework in $frameworks) {
    $tool = "$OutputDirectory/tool/$framework"
    dotnet tool install grate --tool-path $tool --version $version --framework $framework --add-source $packages
    $runtimePrefix = "Microsoft.NETCore.App $($framework.Substring(3))."
    $runtimeLine = @(dotnet --list-runtimes | Where-Object { $_.StartsWith($runtimePrefix) } | Select-Object -Last 1)
    if ($runtimeLine.Count -ne 1) { throw "Cannot locate an installed runtime for $framework." }
    $runtimeVersion = $runtimeLine[0].Split(' ')[1]
    $runtimeDirectory = $runtimeLine[0].Substring($runtimeLine[0].IndexOf('[') + 1).TrimEnd(']')
    $sourceRoot = Split-Path (Split-Path $runtimeDirectory)
    $dotnetExecutable = Join-Path $sourceRoot $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
    $isolatedRoot = "$OutputDirectory/runtime/$framework"
    New-Item -ItemType Directory -Force "$isolatedRoot/host/fxr", "$isolatedRoot/shared/Microsoft.NETCore.App" | Out-Null
    Copy-Item $dotnetExecutable $isolatedRoot
    Copy-Item "$sourceRoot/host/fxr/*" "$isolatedRoot/host/fxr" -Recurse
    Copy-Item "$runtimeDirectory/$runtimeVersion" "$isolatedRoot/shared/Microsoft.NETCore.App" -Recurse
    $archVariable = 'DOTNET_ROOT_' + [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToUpperInvariant()
    $oldRoot = $env:DOTNET_ROOT
    $oldArchRoot = [Environment]::GetEnvironmentVariable($archVariable)
    $oldRollForward = $env:DOTNET_ROLL_FORWARD
    try {
        $env:DOTNET_ROOT = $isolatedRoot
        [Environment]::SetEnvironmentVariable($archVariable, $isolatedRoot)
        $env:DOTNET_ROLL_FORWARD = 'LatestPatch'
        $privateDotnet = Join-Path $isolatedRoot $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
        $runtimes = @(& $privateDotnet --list-runtimes)
        if ($runtimes.Count -ne 1 -or $runtimes[0] -notlike "Microsoft.NETCore.App $runtimeVersion *") {
            throw "The tool test root does not contain only runtime $runtimeVersion."
        }
        $runtimes | Add-Content "$OutputDirectory/tool-runtimes.txt"
        $shim = Join-Path $tool $(if ($IsWindows) { 'grate.exe' } else { 'grate' })
        Test-Migration $shim "$OutputDirectory/tool-smoke/$framework"
    } finally {
        $env:DOTNET_ROOT = $oldRoot
        [Environment]::SetEnvironmentVariable($archVariable, $oldArchRoot)
        $env:DOTNET_ROLL_FORWARD = $oldRollForward
    }
    Write-Host "Verified $framework library consumer and installed tool with only $runtimeVersion."
}
