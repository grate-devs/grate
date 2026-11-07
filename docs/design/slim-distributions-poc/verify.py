#!/usr/bin/env python3
"""Build and compare Linux x64 All, SQLite, SQL Server and MariaDB distributions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import uuid
import zipfile
from xml.etree import ElementTree
from xml.sax.saxutils import quoteattr

ROOT = Path(__file__).resolve().parents[3]
PROJECT = ROOT / "src/grate/grate.csproj"
CHECK_PROJECT = Path(__file__).with_name("VerifyDatabase.csproj")
VERSION = "0.0.1"
FRAMEWORKS = ("net8.0", "net9.0", "net10.0", "net11.0")
PROVIDERS = {"grate.sqlite", "grate.sqlserver", "grate.postgresql",
             "grate.mariadb", "grate.oracle"}
CLIENTS = {
    "SQLite": {"Microsoft.Data.Sqlite"},
    "SQLServer": {"Microsoft.Data.SqlClient", "Microsoft.Data.SqlClient.Extensions.Azure"},
    "MariaDB": {"MySqlConnector"},
    "PostgreSQL": {"Npgsql"},
    "Oracle": {"Oracle.ManagedDataAccess.Core"},
}
PACKAGES = {"All": "grate", "SQLite": "grate-sqlite",
            "SQLServer": "grate-sqlserver", "MariaDB": "grate-mariadb"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(arguments, log, expected_success=True, env=None):
    with log.open("w") as stream:
        result = subprocess.run([str(arg) for arg in arguments], cwd=ROOT,
                                stdout=stream, stderr=subprocess.STDOUT, env=env)
    output = log.read_text()
    require((result.returncode == 0) == expected_success,
            f"Unexpected exit code {result.returncode}. See {log}\n{output[-4000:]}")
    return output


def check_dependencies(deps, distribution):
    libraries = {entry.split("/")[0] for entry in deps["libraries"]}
    expected = PROVIDERS if distribution == "All" else {f"grate.{distribution.lower()}"}
    require(libraries & PROVIDERS == expected, f"Unexpected providers: {libraries & PROVIDERS}")
    selected_clients = set().union(*CLIENTS.values()) if distribution == "All" else CLIENTS[distribution]
    require(selected_clients <= libraries, f"Missing clients: {selected_clients - libraries}")
    omitted_clients = set().union(*CLIENTS.values()) - selected_clients
    require(not libraries & omitted_clients, f"Unused clients present: {libraries & omitted_clients}")
    if distribution in ("All", "SQLite"):
        require(any(name.startswith("SQLitePCLRaw") for name in libraries),
                "SQLite native dependency graph missing")


def check_installed_package(tool, nupkg):
    installed, = (tool / ".store").rglob(nupkg.name)
    require(hashlib.sha256(nupkg.read_bytes()).digest()
            == hashlib.sha256(installed.read_bytes()).digest(),
            "Installed tool differs from the locally built package")


def database_state(checker, provider, connection, log):
    output = run(["dotnet", checker, provider], log,
                 env={**os.environ, "GRATE_POC_CHECK_CONNECTION": connection})
    return json.loads(output)


def check_migration_states(first, second):
    require(first == second, "Database state changed on one-time script rerun")
    require(second["data"] == [["1", "Slim PoC"]], "Incorrect migration data")
    history = [row for row in second["history"] if row[0] == "001_widgets.sql"]
    require(len(history) == 1 and history[0][1], "Missing or duplicated one-time script history")
    require(second["errors"] == [["0"]], "Migration errors were recorded")


def smoke(executable, directory, provider, slim, checker, database_prefix):
    directory.mkdir(parents=True)
    scripts = directory / "sql/up"
    scripts.mkdir(parents=True)
    (scripts / "001_widgets.sql").write_text(
        "CREATE TABLE widgets (id INTEGER PRIMARY KEY, name VARCHAR(50) NOT NULL);\n"
        "INSERT INTO widgets VALUES (1, 'Slim PoC');\n")
    if provider == "SQLite":
        connection = f"Data Source={directory / 'migration.db'}"
    else:
        template = os.environ[f"GRATE_POC_{provider.upper()}"]
        database = f"{database_prefix}_{directory.parent.name}_{directory.name}"
        connection = template.replace("{database}", database.replace("-", "_"))
    arguments = [executable, "--connectionstring", connection, "--files", directory / "sql",
                 "--output", directory / "output", "--silent"]
    help_text = run([executable, "--help"], directory / "help.log")
    require(provider in help_text, f"Help does not mention {provider}")
    if slim:
        rejected_provider = "SQLite" if provider == "SQLServer" else "SQLServer"
        rejected_database = directory / "rejected.db"
        rejected = run([executable, "--databasetype", rejected_provider, "--connectionstring",
                        f"Data Source={rejected_database}", "--silent"],
                       directory / "unsupported.log", expected_success=False)
        require(provider in rejected, "Unsupported-provider message omits this build's provider")
        require(not rejected_database.exists(), "Rejected invocation created a database")
    else:
        arguments += ["--databasetype", provider]
    run(arguments, directory / "first.log")
    first = database_state(checker, provider, connection, directory / "state-first.json")
    run(arguments + (["--databasetype", provider] if slim else []), directory / "rerun.log")
    second = database_state(checker, provider, connection, directory / "state-rerun.json")
    check_migration_states(first, second)
    run([executable, "skills", "install", "--local", "--path", directory / "skills"],
        directory / "skills.log")
    require((directory / "skills/.agents/skills/use-grate/SKILL.md").is_file(),
            "Bundled skill missing")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    require(sys.platform == "linux" and platform.machine() == "x86_64",
            "Run this PoC on Linux x64, including an amd64 Docker container")
    require(not output.exists(), "Use a fresh output directory for each comparison")
    for provider in ("SQLSERVER", "MARIADB"):
        require("{database}" in os.environ.get(f"GRATE_POC_{provider}", ""),
                f"GRATE_POC_{provider} needs a disposable-server connection with {{database}}")
    output.mkdir(parents=True)
    sdk = subprocess.check_output(["dotnet", "--version"], cwd=ROOT, text=True).strip()
    require(sdk == json.loads((ROOT / "global.json").read_text())["sdk"]["version"],
            "Use the SDK pinned by global.json")
    run(["dotnet", "build", CHECK_PROJECT, "-c", "Release",
         f"-p:ArtifactsPath={output / 'check-build'}"], output / "build-checker.log")
    checker, = (output / "check-build/bin/VerifyDatabase").glob("*/VerifyDatabase.dll")
    database_prefix = "poc_" + uuid.uuid4().hex[:10]
    measurements = {}
    for distribution, package in PACKAGES.items():
        print(f"Building and checking {distribution}", flush=True)
        work = output / distribution.lower()
        work.mkdir()
        common = ["-c", "Release", f"-p:Version={VERSION}",
                  f"-p:GrateDistribution={distribution}"]
        publish = work / "published"
        build = work / "standalone-build"
        run(["dotnet", "publish", PROJECT, *common, "-f", "net11.0", "-r", "linux-x64",
             "--self-contained", "-p:TargetFrameworks=net11.0",
             f"-p:ArtifactsPath={build}", "-o", publish], work / "publish.log")
        deps_path, = build.glob("bin/grate/**/grate.deps.json")
        check_dependencies(json.loads(deps_path.read_text()), distribution)
        archive_path = work / f"{package}-linux-x64-self-contained-{VERSION}.zip"
        with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for file in sorted(publish.iterdir()):
                require(file.is_file(), f"Unexpected publish directory: {file}")
                archive.write(file, file.name)
        extracted = work / "extracted"
        with zipfile.ZipFile(archive_path) as archive:
            archive.extractall(extracted)
        executable = extracted / "grate"
        executable.chmod(0o755)
        providers = ("SQLite", "SQLServer", "MariaDB") if distribution == "All" else (distribution,)
        for provider in providers:
            smoke(executable, work / f"{distribution.lower()}-standalone" / provider,
                  provider, distribution != "All", checker, database_prefix)
        feed = work / "feed"
        run(["dotnet", "pack", PROJECT, *common, "-p:PackAsTool=true",
             "-p:SelfContained=false", f"-p:PackageVersion={VERSION}",
             f"-p:ArtifactsPath={work / 'tool-build'}", "-o", feed], work / "pack.log")
        nupkg, = feed.glob("*.nupkg")
        with zipfile.ZipFile(nupkg) as archive:
            for framework in FRAMEWORKS:
                deps = json.loads(archive.read(f"tools/{framework}/any/grate.deps.json"))
                check_dependencies(deps, distribution)
                settings = ElementTree.fromstring(
                    archive.read(f"tools/{framework}/any/DotnetToolSettings.xml"))
                commands = settings.findall("./Commands/Command")
                require(len(commands) == 1 and commands[0].get("Name") == "grate",
                        f"Unexpected installed command for {framework}")
        config = work / "NuGet.Config"
        config.write_text('<configuration><packageSources><clear/>'
                          f'<add key="local" value={quoteattr(str(feed))}/>'
                          '</packageSources></configuration>')
        tool = work / "tool"
        run(["dotnet", "tool", "install", package, "--version", VERSION,
             "--framework", "net11.0", "--tool-path", tool, "--configfile", config],
            work / "install.log",
            env={**os.environ, "NUGET_PACKAGES": str(work / "tool-cache")})
        check_installed_package(tool, nupkg)
        for provider in providers:
            smoke(tool / "grate", work / f"{distribution.lower()}-tool" / provider,
                  provider, distribution != "All", checker, database_prefix)
        measurements[distribution] = {
            "standalone_binary_bytes": (publish / "grate").stat().st_size,
            "standalone_zip_bytes": archive_path.stat().st_size,
            "tool_nupkg_bytes": nupkg.stat().st_size,
        }
        print(f"{distribution} passed", flush=True)
    baseline = measurements["All"]
    savings = {
        distribution: {
            metric: {"bytes": baseline[metric] - reduced[metric],
                     "percent": round(100 * (baseline[metric] - reduced[metric]) / baseline[metric], 2)}
            for metric in baseline}
        for distribution, reduced in measurements.items() if distribution != "All"}
    report = {"sdk": sdk, "platform": platform.platform(), "rid": "linux-x64",
              "version": VERSION, "tool_frameworks": FRAMEWORKS,
              "tool_execution_framework": "net11.0", "measurements": measurements,
              "savings": savings}
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
