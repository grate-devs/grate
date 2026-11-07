#!/usr/bin/env python3
"""Build, exercise and compare the Linux x64 CLI distributions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import sqlite3
import subprocess
import sys
import zipfile
from xml.sax.saxutils import quoteattr

ROOT = Path(__file__).resolve().parents[3]
PROJECT = ROOT / "src/grate/grate.csproj"
VERSION = "0.0.1"
PROVIDERS = {"grate.sqlite", "grate.sqlserver", "grate.postgresql",
             "grate.mariadb", "grate.oracle"}
OTHER_CLIENTS = {"Microsoft.Data.SqlClient", "Microsoft.Data.SqlClient.Extensions.Azure",
                 "Npgsql", "MySqlConnector", "Oracle.ManagedDataAccess.Core"}


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


def check_dependencies(deps, sqlite_only):
    libraries = {entry.split("/")[0] for entry in deps["libraries"]}
    expected = {"grate.sqlite"} if sqlite_only else PROVIDERS
    require(libraries & PROVIDERS == expected, f"Unexpected providers: {libraries & PROVIDERS}")
    require("Microsoft.Data.Sqlite" in libraries, "SQLite managed client missing")
    require(any(name.startswith("SQLitePCLRaw") for name in libraries),
            "SQLite native dependency graph missing")
    if sqlite_only:
        require(not libraries & OTHER_CLIENTS, f"Unused clients present: {libraries & OTHER_CLIENTS}")


def check_installed_package(tool, nupkg):
    installed, = (tool / ".store").rglob(nupkg.name)
    require(hashlib.sha256(nupkg.read_bytes()).digest()
            == hashlib.sha256(installed.read_bytes()).digest(),
            "Installed tool differs from the locally built package")


def smoke(executable, directory, sqlite_only):
    directory.mkdir()
    scripts = directory / "sql/up"
    scripts.mkdir(parents=True)
    (scripts / "001_widgets.sql").write_text(
        "CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT NOT NULL);\n"
        "INSERT INTO widgets VALUES (1, 'SQLite PoC');\n")
    database = directory / "migration.db"
    arguments = [executable, "--connectionstring", f"Data Source={database}",
                 "--files", directory / "sql", "--output", directory / "output", "--silent"]
    help_text = run([executable, "--help"], directory / "help.log")
    require("SQLite" in help_text, "Help does not mention SQLite")
    if sqlite_only:
        require("SQLite" in help_text.split("--databasetype", 1)[1],
                "Database option help does not mention SQLite")
        rejected_database = directory / "rejected.db"
        rejected = run([executable, "--databasetype", "sqlserver", "--connectionstring",
                        f"Data Source={rejected_database}", "--silent"],
                       directory / "unsupported.log", expected_success=False)
        require("SQLite" in rejected, "Unsupported-provider message does not identify SQLite")
        require(not rejected_database.exists(), "Rejected invocation created a database")
    else:
        arguments += ["--databasetype", "sqlite"]
    run(arguments, directory / "first.log")
    with sqlite3.connect(database) as connection:
        first_history = connection.execute(
            "SELECT script_name, text_hash FROM grate_ScriptsRun ORDER BY id").fetchall()
    run(arguments + (["--databasetype", "sqlite"] if sqlite_only else []),
        directory / "rerun.log")
    with sqlite3.connect(database) as connection:
        require(connection.execute("SELECT id, name FROM widgets").fetchall()
                == [(1, "SQLite PoC")], "Incorrect migration data")
        history = connection.execute(
            "SELECT script_name, text_hash FROM grate_ScriptsRun ORDER BY id").fetchall()
        require(history == first_history and
                sum(row[0] == "001_widgets.sql" for row in history) == 1,
                "One-time script history changed on rerun")
        require(connection.execute("SELECT COUNT(*) FROM grate_ScriptsRunErrors").fetchone()[0] == 0,
                "Migration errors were recorded")
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
    output.mkdir(parents=True)
    sdk = subprocess.check_output(["dotnet", "--version"], cwd=ROOT, text=True).strip()
    require(sdk == json.loads((ROOT / "global.json").read_text())["sdk"]["version"],
            "Use the SDK pinned by global.json")
    measurements = {}
    for distribution, package in [("All", "grate"), ("SQLite", "grate-sqlite")]:
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
        check_dependencies(json.loads(deps_path.read_text()), distribution == "SQLite")
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
        smoke(executable, work / "standalone-smoke", distribution == "SQLite")
        feed = work / "feed"
        run(["dotnet", "pack", PROJECT, *common, "-p:PackAsTool=true",
             "-p:SelfContained=false", f"-p:PackageVersion={VERSION}",
             f"-p:ArtifactsPath={work / 'tool-build'}", "-o", feed], work / "pack.log")
        nupkg, = feed.glob("*.nupkg")
        with zipfile.ZipFile(nupkg) as archive:
            for framework in ("net8.0", "net9.0", "net10.0", "net11.0"):
                deps = json.loads(archive.read(f"tools/{framework}/any/grate.deps.json"))
                check_dependencies(deps, distribution == "SQLite")
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
        smoke(tool / package, work / "tool-smoke", distribution == "SQLite")
        measurements[distribution] = {
            "standalone_binary_bytes": (publish / "grate").stat().st_size,
            "standalone_zip_bytes": archive_path.stat().st_size,
            "tool_nupkg_bytes": nupkg.stat().st_size,
        }
    baseline = measurements["All"]
    reduced = measurements["SQLite"]
    savings = {metric: {"bytes": baseline[metric] - reduced[metric],
                        "percent": round(100 * (baseline[metric] - reduced[metric])
                                         / baseline[metric], 2)} for metric in baseline}
    report = {"sdk": sdk, "platform": platform.platform(), "rid": "linux-x64",
              "version": VERSION, "tool_frameworks": ["net8.0", "net9.0", "net10.0", "net11.0"],
              "tool_execution_framework": "net11.0", "measurements": measurements,
              "savings": savings}
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
