"""Apply both offline plans to disposable PostgreSQL databases."""

from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import time

from plan import PARSERS, ROOT, build_plan

FIRST = "functions/public.fn_order_totals.sql"
VIEW = "views/public.v_orders.sql"
REPORT = "functions/public.fn_report.sql"
IMAGE = "postgres:17.6-alpine"


def verify():
    base = ROOT / "fixtures/base"
    with tempfile.TemporaryDirectory() as directory:
        upgrade = Path(directory) / "upgrade"
        shutil.copytree(base, upgrade)
        shutil.copytree(ROOT / "fixtures/upgrade", upgrade, dirs_exist_ok=True)
        plans = {parser: (build_plan(parser, base), build_plan(parser, upgrade)) for parser in PARSERS}
        for initial, changed in plans.values():
            assert [s["path"] for s in initial["scripts"]] == [FIRST, VIEW, REPORT]
            assert [s["path"] for s in changed["scripts"]] == [FIRST, VIEW, REPORT]
        verify_sql(base, upgrade, plans)


def verify_sql(base, upgrade, plans):
    container = "grate-pg-order-" + secrets.token_hex(5)

    def sql(database, statement, check=True):
        result = subprocess.run(
            ["docker", "exec", "-i", container, "psql", "-h", "127.0.0.1", "-U", "postgres", "-d", database,
             "-X", "-qAt", "-v", "ON_ERROR_STOP=1"],
            input="\\set VERBOSITY verbose\nSET check_function_bodies = on;\n" + statement,
            text=True, capture_output=True, timeout=20)
        if check and result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result

    def apply(database, root, path, check=True):
        return sql(database, (root / path).read_text(), check)

    def expect_report(database, value):
        result = sql(database, "SELECT public.fn_report();")
        assert result.stdout.strip() == str(value), result.stdout

    def expect_error(result, code, name):
        assert result.returncode != 0 and code in result.stderr and name in result.stderr, result.stderr

    subprocess.run(
        ["docker", "run", "--detach", "--pull", "never", "--network", "none", "--name", container,
         "-e", "POSTGRES_HOST_AUTH_METHOD=trust", IMAGE],
        capture_output=True, text=True, check=True, timeout=60)
    try:
        deadline = time.monotonic() + 60
        # The image's temporary initialization server accepts only Unix-socket connections.
        # Wait for the final server on loopback before running the database checks.
        while sql("postgres", "SELECT 1;", check=False).returncode:
            if time.monotonic() >= deadline:
                raise RuntimeError("Disposable PostgreSQL did not become ready")
            time.sleep(0.5)
        print("PostgreSQL " + sql("postgres", "SHOW server_version;").stdout.strip())
        sql("postgres", "CREATE DATABASE default_order;")
        apply("default_order", base, FIRST)
        expect_error(apply("default_order", base, REPORT, False), "42P01", "v_orders")
        print("Default folder order fails with 42P01 for v_orders.")
        for parser, (initial, changed) in plans.items():
            database = "planned_" + parser
            sql("postgres", f"CREATE DATABASE {database};")
            for script in initial["scripts"]:
                apply(database, base, script["path"])
            expect_report(database, 100)
            expect_error(apply(database, upgrade, REPORT, False), "42703", "net_total")
            expect_report(database, 100)
            paths = [s["path"] for s in changed["scripts"]
                     if (base / s["path"]).read_bytes() != (upgrade / s["path"]).read_bytes()]
            assert paths == [VIEW, REPORT], paths
            for path in paths:
                apply(database, upgrade, path)
            expect_report(database, 85)
            print(f"{parser}: fresh report=100, wrong upgrade fails 42703, planned upgrade=85.")
    finally:
        subprocess.run(["docker", "rm", "-fv", container], capture_output=True, check=True, timeout=20)


if __name__ == "__main__":
    verify()
