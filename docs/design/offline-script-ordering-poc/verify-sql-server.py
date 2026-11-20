"""Apply the prototype order to disposable SQL Server databases."""

import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent
SQL_IMAGE = "mcr.microsoft.com/mssql/server:2022-latest"
FUNCTION = "functions/dbo.fnOrderTotals.sql"
VIEW = "views/dbo.vOrders.sql"
REPORT = "functions/dbo.fnReport.sql"


def planned_paths(planner, root):
    output = subprocess.check_output(["dotnet", str(planner), str(root)], text=True)
    paths = [script["path"] for script in json.loads(output)["scripts"]]
    if paths != [FUNCTION, VIEW, REPORT]:
        raise RuntimeError(f"Unexpected plan for {root.name}: {paths}")
    return paths


def expect_sql_error(result, number, identifier):
    output = result.stdout + result.stderr
    if result.returncode == 0 or f"Msg {number}," not in output or identifier not in output:
        raise RuntimeError(f"Expected SQL error {number} for {identifier}, got:\n{output}")


def verify(planner):
    base = ROOT / "fixtures" / "base"
    with tempfile.TemporaryDirectory() as directory:
        upgrade = Path(directory) / "upgrade"
        shutil.copytree(base, upgrade)
        shutil.copytree(ROOT / "fixtures" / "upgrade", upgrade, dirs_exist_ok=True)
        base_order = planned_paths(planner, base)
        upgrade_order = planned_paths(planner, upgrade)
        # Model the changed definitions for this check. Grate owns eligibility and history.
        changed_paths = [
            path for path in upgrade_order
            if (base / path).read_bytes() != (upgrade / path).read_bytes()
        ]
        if changed_paths != [VIEW, REPORT]:
            raise RuntimeError(f"Unexpected upgrade inputs: {changed_paths}")
        verify_sql(base, upgrade, base_order, changed_paths)


def verify_sql(base, upgrade, base_order, changed_paths):
    container = "grate-631-" + secrets.token_hex(5)
    password = "Grate631!" + secrets.token_hex(16)
    environment = dict(os.environ, MSSQL_SA_PASSWORD=password, SQLCMDPASSWORD=password)

    def sql(database, statement, *, check=True):
        return subprocess.run(
            ["docker", "exec", "-i", "-e", "SQLCMDPASSWORD", container,
             "/opt/mssql-tools18/bin/sqlcmd", "-S", "127.0.0.1", "-U", "sa",
             "-d", database, "-C", "-b", "-l", "3", "-t", "10", "-r1"],
            input=statement + "\nGO\n", text=True, capture_output=True, check=check,
            env=environment, timeout=20,
        )

    def apply(database, root, path, *, check=True):
        return sql(database, (root / path).read_text(encoding="utf-8"), check=check)

    def expect_report(database, value):
        sql(database, f"""
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM dbo.fnReport() WHERE ReportTotal = {value})
   OR (SELECT COUNT(*) FROM dbo.fnReport()) <> 1
    THROW 50000, 'Unexpected report result', 1;
""")

    subprocess.run(
        ["docker", "run", "--detach", "--pull", "never", "--network", "none",
         "--platform", "linux/amd64", "--name", container, "-e", "ACCEPT_EULA=Y",
         "-e", "MSSQL_PID=Developer", "-e", "MSSQL_SA_PASSWORD", SQL_IMAGE],
        env=environment, check=True, capture_output=True, text=True, timeout=60,
    )
    try:
        deadline = time.monotonic() + 120
        while True:
            readiness = sql("master", "SELECT 1;", check=False)
            if readiness.returncode == 0:
                break
            if time.monotonic() >= deadline:
                logs = subprocess.run(["docker", "logs", container], capture_output=True,
                                      text=True, timeout=20)
                raise RuntimeError(
                    f"SQL Server did not start:\n{readiness.stderr}{logs.stdout}{logs.stderr}"
                )
            time.sleep(1)

        version = sql("master", """
SET NOCOUNT ON;
SELECT CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')) AS ProductVersion;
""").stdout.strip().splitlines()[-1].strip()
        print(f"SQL Server {version}")

        sql("master", "CREATE DATABASE DefaultOrder;")
        apply("DefaultOrder", base, FUNCTION)
        expect_sql_error(apply("DefaultOrder", base, REPORT, check=False), 208, "vOrders")
        print("Default folder order fails on an empty database with SQL error 208 (vOrders).")

        sql("master", "CREATE DATABASE PlannedOrder;")
        for path in base_order:
            apply("PlannedOrder", base, path)
        expect_report("PlannedOrder", 100)
        print("Offline order succeeds on an empty database. ReportTotal = 100.")

        expect_sql_error(apply("PlannedOrder", upgrade, REPORT, check=False), 207, "NetTotal")
        expect_report("PlannedOrder", 100)
        print("Applying the upgraded function first fails with SQL error 207 (NetTotal).")

        for path in changed_paths:
            apply("PlannedOrder", upgrade, path)
        expect_report("PlannedOrder", 85)
        print("Offline order succeeds for the two changed definitions. ReportTotal = 85.")
    finally:
        subprocess.run(["docker", "rm", "-f", container], check=True, capture_output=True,
                       text=True, timeout=20)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("planner", type=Path, help="Path to the built planner DLL")
    try:
        verify(parser.parse_args().planner.resolve())
    except subprocess.CalledProcessError as error:
        # Print server/client diagnostics without including the environment.
        raise SystemExit((error.stdout or "") + (error.stderr or "")) from error
