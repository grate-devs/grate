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
$expectedRuntime = (dotnet msbuild src/grate/grate.csproj -nologo -p:TargetFramework=net11.0 -getProperty:RuntimeFrameworkVersion).Trim()
if ($expectedRuntime -notlike '11.0.*') { throw "Expected an explicit .NET 11 runtime version, got '$expectedRuntime'." }
$frameworks = @('net8.0', 'net9.0', 'net10.0', 'net11.0')

function Test-Migration([string]$Executable, [string]$Directory) {
    New-Item -ItemType Directory -Force "$Directory/sql/up" | Out-Null
    'CREATE TABLE package_smoke (id INTEGER PRIMARY KEY); INSERT INTO package_smoke VALUES (1);' |
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
    $python = Get-Command python3, python -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$python) { throw 'Python with sqlite3 is required to verify migration effects.' }
    & $python.Source -c 'import sqlite3, sys; db = sqlite3.connect(sys.argv[1]); rows = db.execute("SELECT id FROM package_smoke ORDER BY id").fetchall(); assert rows == [(1,)], rows' "$Directory/smoke.db"
    & $Executable skills install --local --path "$Directory/skill"
    if (!(Test-Path "$Directory/skill/.agents/skills/use-grate/SKILL.md")) {
        throw 'The packaged CLI did not install its bundled skill.'
    }
}

if ($Kind -eq 'Standalone') {
    if (!$RuntimeIdentifier) { throw '-RuntimeIdentifier is required for Standalone verification.' }
    $published = "$OutputDirectory/published"
    dotnet publish src/grate/grate.csproj -c Release -f net11.0 -r $RuntimeIdentifier --self-contained -p:SelfContained=true -p:TargetFrameworks=net11.0 -o $published
    # These files are the inputs embedded by the single-file bundler. Inspecting
    # them proves the runtime version even when the final archive contains one file.
    $buildDirectory = "src/grate/bin/Release/net11.0/$RuntimeIdentifier"
    $runtimeConfig = Get-Content "$buildDirectory/grate.runtimeconfig.json" -Raw | ConvertFrom-Json
    $runtime = @($runtimeConfig.runtimeOptions.includedFrameworks | Where-Object name -eq 'Microsoft.NETCore.App')
    if ($runtime.Count -ne 1 -or $runtime[0].version -ne $expectedRuntime) {
        throw "Self-contained $RuntimeIdentifier does not include runtime $expectedRuntime."
    }
    $deps = Get-Content "$buildDirectory/grate.deps.json" -Raw | ConvertFrom-Json -AsHashtable
    if (!$deps.libraries.ContainsKey("runtimepack.Microsoft.NETCore.App.Runtime.$RuntimeIdentifier/$expectedRuntime")) {
        throw "Self-contained $RuntimeIdentifier does not reference the expected runtime pack."
    }
    Copy-Item "$buildDirectory/grate.runtimeconfig.json", "$buildDirectory/grate.deps.json" $OutputDirectory
    if ($RunSmokeTest) {
        $executable = Join-Path $published $(if ($RuntimeIdentifier.StartsWith('win-')) { 'grate.exe' } else { 'grate' })
        Test-Migration $executable "$OutputDirectory/smoke"
    }
    Write-Host "Verified $RuntimeIdentifier bundles $expectedRuntime; native execution: $RunSmokeTest"
    return
}

$packages = "$OutputDirectory/packages"
$version = '0.0.0-ci.dotnet11.' + [Guid]::NewGuid().ToString('N')
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

# Restore and compile a consumer of all six local packages, outside repository
# props, so this exercises NuGet asset selection for net11.0.
$consumer = "$OutputDirectory/consumer"
New-Item -ItemType Directory -Force $consumer | Out-Null
$references = ($libraryNames | ForEach-Object { "<PackageReference Include='$_' Version='$version' />" }) -join "`n"
"<Project Sdk='Microsoft.NET.Sdk'><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net11.0</TargetFramework></PropertyGroup><ItemGroup>$references</ItemGroup></Project>" |
    Set-Content "$consumer/consumer.csproj"
'global::System.Console.WriteLine(typeof(grate.Configuration.GrateConfiguration).Assembly.FullName);' | Set-Content "$consumer/Program.cs"
dotnet build "$consumer/consumer.csproj" -c Release --source $packages --source https://api.nuget.org/v3/index.json

$tool = "$OutputDirectory/tool"
dotnet tool install grate --tool-path $tool --version $version --add-source $packages

# Tool shims must succeed without any .NET 8/9/10 runtime being available.
# Copy only the selected 11 runtime and host into a private root, leaving runner
# installations untouched. The SDK used for install is not required for execution.
$runtimeLine = @(dotnet --list-runtimes | Where-Object { $_.StartsWith("Microsoft.NETCore.App $expectedRuntime [") })
if ($runtimeLine.Count -ne 1) { throw "Cannot locate installed runtime $expectedRuntime." }
$runtimeDirectory = $runtimeLine[0].Substring($runtimeLine[0].IndexOf('[') + 1).TrimEnd(']')
$sourceRoot = Split-Path (Split-Path $runtimeDirectory)
$dotnetExecutable = Join-Path $sourceRoot $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
$isolatedRoot = "$OutputDirectory/dotnet11-only"
New-Item -ItemType Directory -Force "$isolatedRoot/host/fxr", "$isolatedRoot/shared/Microsoft.NETCore.App" | Out-Null
Copy-Item $dotnetExecutable $isolatedRoot
Copy-Item "$sourceRoot/host/fxr/$expectedRuntime" "$isolatedRoot/host/fxr" -Recurse
Copy-Item "$sourceRoot/shared/Microsoft.NETCore.App/$expectedRuntime" "$isolatedRoot/shared/Microsoft.NETCore.App" -Recurse
$archVariable = 'DOTNET_ROOT_' + [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToUpperInvariant()
$oldRoot = $env:DOTNET_ROOT
$oldArchRoot = [Environment]::GetEnvironmentVariable($archVariable)
$oldRollForward = $env:DOTNET_ROLL_FORWARD
try {
    $env:DOTNET_ROOT = $isolatedRoot
    [Environment]::SetEnvironmentVariable($archVariable, $isolatedRoot)
    $env:DOTNET_ROLL_FORWARD = 'Disable'
    $privateDotnet = Join-Path $isolatedRoot $(if ($IsWindows) { 'dotnet.exe' } else { 'dotnet' })
    $runtimes = @(& $privateDotnet --list-runtimes)
    if ($runtimes.Count -ne 1 -or $runtimes[0] -notlike "Microsoft.NETCore.App $expectedRuntime *") {
        throw "The tool test root does not contain only runtime $expectedRuntime."
    }
    $runtimes | Set-Content "$OutputDirectory/tool-runtimes.txt"
    $shim = Join-Path $tool $(if ($IsWindows) { 'grate.exe' } else { 'grate' })
    Test-Migration $shim "$OutputDirectory/tool-smoke"
} finally {
    $env:DOTNET_ROOT = $oldRoot
    [Environment]::SetEnvironmentVariable($archVariable, $oldArchRoot)
    $env:DOTNET_ROLL_FORWARD = $oldRollForward
}
Write-Host 'Verified all four framework assets, six library consumers and the installed tool on .NET 11 only.'
