#!/usr/bin/env python3
"""Characterize a supplied grate CLI against fresh, disposable SQLite databases.

No installation, shell invocation, network service, or existing database is used.
Pass a trusted, already available CLI command as individual arguments after --.
The temporary databases, command logs, and Markdown report are kept for review.
"""

import argparse
from datetime import datetime, timezone
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile


EXAMPLE = Path(__file__).resolve().parents[1] / "assets" / "sqlite-example"
INITIAL_SCRIPTS = [
    "001_create_widgets.sql",
    "002_create_widgets_code_index.sql",
    "003_seed_widget.sql",
]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def rows(database, sql):
    # Read-only inspection must never create a missing database by accident.
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
        return connection.execute(sql).fetchall()


def history(database):
    return rows(database, "SELECT script_name, text_hash, one_time_script "
                "FROM grate_ScriptsRun ORDER BY id")


def assert_history(database, names):
    recorded = history(database)
    require([entry[0] for entry in recorded] == names,
            f"Unexpected successful script history: {recorded!r}")
    require(all(entry[1] and entry[2] == 1 for entry in recorded),
            "Every example migration must have a hash and be recorded as one-time")
    return recorded


def widgets(database):
    return rows(database, "SELECT id, code, name FROM widgets ORDER BY id")


class Verification:
    def __init__(self, command, root, timeout):
        self.command = command
        self.root = root
        self.timeout = timeout
        self.version = "not established"
        self.commands = []
        self.checks = []

    def execute(self, label, arguments, expected_code=0):
        command = self.command + arguments
        log = self.root / f"{len(self.commands):02d}-{label}.log"
        result = subprocess.run(command, cwd=self.root, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding="utf-8", errors="replace",
                                timeout=self.timeout, check=False)
        log.write_text(result.stdout, encoding="utf-8")
        self.commands.append((label, result.returncode, log, command))
        require(result.returncode == expected_code,
                f"{label}: expected exit {expected_code}, got {result.returncode}; see {log}")
        return result.stdout

    def migrate(self, label, scripts, database, transaction=False, expected_code=0):
        return self.execute(label, [
            "--databasetype=SQLite",
            f"--connectionstring=Data Source={database};Pooling=False",
            f"--sqlfilesdirectory={scripts}",
            f"--outputPath={self.root / 'output' / label}",
            "--schemaname=grate",
            "--silent",
            f"--transaction={str(transaction).lower()}",
            f"--version=verification-{label}",
        ], expected_code)

    def passed(self, description):
        self.checks.append(description)
        print(f"PASS: {description}", flush=True)

    def fixture(self, name):
        directory = self.root / name
        scripts = directory / "sql"
        shutil.copytree(EXAMPLE, scripts)
        return scripts, directory / "example.sqlite"

    def preflight(self, expected_version):
        output = self.execute("help", ["--help"])
        match = re.search(r"grate v([^\s]+)", output, re.IGNORECASE)
        require(match is not None, "--help did not identify a grate CLI version")
        self.version = match.group(1)
        require("SQLite" in output and "--databasetype" in output,
                "The supplied CLI does not advertise the SQLite provider")
        if expected_version:
            require(self.version == expected_version,
                    f"Expected grate {expected_version}, found {self.version}")
        self.passed(f"CLI identifies grate {self.version} and advertises SQLite")

    def clean_apply_and_forward_change(self):
        scripts, database = self.fixture("clean")
        self.migrate("clean-apply", scripts, database)
        require(database.read_bytes()[:16] == b"SQLite format 3\x00",
                "The CLI did not create a SQLite database")
        initial_data = [(1, "W-001", "Starter widget")]
        require(widgets(database) == initial_data, "Clean apply produced incorrect seed data")
        require(rows(database, "SELECT name FROM sqlite_master WHERE type='index' "
                     "AND name='ux_widgets_code'") == [("ux_widgets_code",)],
                "The separate index migration did not create its index")
        require(any(index[1] == "ux_widgets_code" and index[2] == 1
                    for index in rows(database, "PRAGMA index_list('widgets')")),
                "The widgets code index must enforce uniqueness")
        initial_history = assert_history(database, INITIAL_SCRIPTS)
        self.passed("Clean apply creates the table, index, seed row, and three ordered history entries")

        self.migrate("clean-repeat", scripts, database)
        require(widgets(database) == initial_data and history(database) == initial_history,
                "A second migration repeated or altered an applied one-time script")
        self.passed("A second run preserves application data and successful script history")

        seed = scripts / "up" / INITIAL_SCRIPTS[-1]
        original = seed.read_bytes()
        seed.write_bytes(original.replace(b"Starter widget", b"Changed old script"))
        self.migrate("changed-one-time-refused", scripts, database, expected_code=1)
        require(widgets(database) == initial_data and history(database) == initial_history,
                "Refusing an edited one-time script must preserve its data and successful history")
        errors = rows(database, "SELECT script_name, error_message FROM grate_ScriptsRunErrors")
        require(len(errors) == 1 and errors[0][0] == INITIAL_SCRIPTS[-1]
                and "changed" in errors[0][1].lower(),
                f"Missing changed-script error history: {errors!r}")
        self.passed("Changing an applied one-time script fails with recorded error and unchanged data/hash")

        seed.write_bytes(original)
        forward = "004_rename_widget.sql"
        (scripts / "up" / forward).write_text(
            "UPDATE widgets SET name = 'Updated widget' WHERE id = 1;\n", encoding="utf-8")
        self.migrate("forward-recovery", scripts, database)
        require(widgets(database) == [(1, "W-001", "Updated widget")],
                "The forward migration did not apply the intended change")
        recovered_history = assert_history(database, INITIAL_SCRIPTS + [forward])
        require(recovered_history[:3] == initial_history, "Existing history was rewritten")
        self.migrate("forward-repeat", scripts, database)
        require(history(database) == recovered_history
                and widgets(database) == [(1, "W-001", "Updated widget")],
                "The forward migration must also run only once")
        self.passed("Restoring the original file and adding a forward migration recovers without rewriting history")

    def failure_and_recovery(self, transaction):
        mode = str(transaction).lower()
        scripts, database = self.fixture(f"failure-transaction-{mode}")
        self.migrate(f"failure-{mode}-setup", scripts, database, transaction)
        initial_history = assert_history(database, INITIAL_SCRIPTS)
        completed = "004_completed_before_failure.sql"
        failing = "005_fails_after_first_batch.sql"
        following = "006_after_failure.sql"
        (scripts / "up" / completed).write_text(
            "INSERT INTO widgets VALUES (2, 'W-002', 'Completed file');\n", encoding="utf-8")
        failed_file = scripts / "up" / failing
        failed_file.write_text(
            "INSERT INTO widgets VALUES (3, 'W-003', 'First batch');\n"
            "GO\n"
            "INSERT INTO missing_verification_table VALUES (1);\n"
            "GO\n"
            "INSERT INTO widgets VALUES (4, 'W-004', 'Last batch');\n", encoding="utf-8")
        (scripts / "up" / following).write_text(
            "INSERT INTO widgets VALUES (5, 'W-005', 'Following file');\n", encoding="utf-8")
        output = self.migrate(f"failure-{mode}-injected", scripts, database,
                              transaction, expected_code=1)
        if transaction:
            require("doesn't support DDL transactions" in output,
                    "SQLite transaction request was not accompanied by the expected downgrade warning")
        partial_data = [(1, "W-001", "Starter widget"), (2, "W-002", "Completed file"),
                        (3, "W-003", "First batch")]
        require(widgets(database) == partial_data,
                f"Unexpected SQLite partial state with --transaction={mode}: {widgets(database)!r}")
        partial_history = assert_history(database, INITIAL_SCRIPTS + [completed])
        require(partial_history[:3] == initial_history, "Setup history changed after failure")
        errors = rows(database, "SELECT script_name, erroneous_part_of_script, error_message "
                      "FROM grate_ScriptsRunErrors ORDER BY id")
        require(len(errors) == 1 and errors[0][0] == failing
                and "missing_verification_table" in errors[0][1]
                and "First batch" not in errors[0][1] and "Last batch" not in errors[0][1]
                and "no such table" in errors[0][2].lower(),
                f"Expected exactly the failed GO-delimited batch in error history: {errors!r}")
        self.passed(f"--transaction={mode}: completed file and first batch persist; later work stops; "
                    "only the completed file enters successful history")

        self.migrate(f"failure-{mode}-unsafe-repeat", scripts, database,
                     transaction, expected_code=1)
        require(widgets(database) == partial_data and history(database) == partial_history,
                "Retrying the failed file unexpectedly changed persisted state")
        errors = rows(database, "SELECT script_name, erroneous_part_of_script, error_message "
                      "FROM grate_ScriptsRunErrors ORDER BY id")
        require(len(errors) == 2 and errors[1][0] == failing
                and "First batch" in errors[1][1] and "UNIQUE" in errors[1][2].upper(),
                "Retry must restart the unrecorded file at its first batch and encounter duplicate data")
        self.passed(f"--transaction={mode}: retry starts the failed file again, not its last failed batch")

        # This file has NO successful history entry. Inspecting its partial effects above
        # establishes why this specific repair is safe in the disposable fixture.
        failed_file.write_text(
            "INSERT INTO widgets VALUES (3, 'W-003', 'First batch') ON CONFLICT(id) DO NOTHING;\n"
            "GO\n"
            "UPDATE widgets SET name = 'Recovered third widget' WHERE id = 3;\n"
            "GO\n"
            "INSERT INTO widgets VALUES (4, 'W-004', 'Last batch');\n", encoding="utf-8")
        self.migrate(f"failure-{mode}-recovery", scripts, database, transaction)
        final_data = [(1, "W-001", "Starter widget"), (2, "W-002", "Completed file"),
                      (3, "W-003", "Recovered third widget"), (4, "W-004", "Last batch"),
                      (5, "W-005", "Following file")]
        require(widgets(database) == final_data, "Recovery did not produce all five expected rows")
        final_history = assert_history(database, INITIAL_SCRIPTS + [completed, failing, following])
        require(final_history[:4] == partial_history, "Recovery rewrote successful history")
        self.migrate(f"failure-{mode}-recovered-repeat", scripts, database, transaction)
        require(widgets(database) == final_data and history(database) == final_history,
                "Recovered scripts ran more than once")
        require(rows(database, "SELECT COUNT(*) FROM grate_ScriptsRunErrors") == [(2,)],
                "Recovery must retain both prior failure records without adding another")
        self.passed(f"--transaction={mode}: inspected repair resumes the unrecorded file, "
                    "preserves prior history/errors, and leaves the next run unchanged")

    def report(self, path, failure):
        lines = ["# Disposable SQLite verification", "",
                 f"- UTC: {datetime.now(timezone.utc).isoformat()}",
                 f"- Result: {'FAIL' if failure else 'PASS'}",
                 f"- CLI version from `--help`: {self.version}",
                 "- Provider: SQLite (explicit CLI option; actual database and history inspected)",
                 f"- Python SQLite inspection library: {sqlite3.sqlite_version}",
                 f"- Artifacts: {self.root}", "",
                 "## Passed checks", ""]
        lines += [f"- {description}" for description in self.checks]
        if failure:
            lines += ["", "## Failure", "", str(failure)]
        lines += ["", "## Commands", ""]
        for label, code, log, command in self.commands:
            lines += [f"### {label} (exit {code})", "", "```text", shlex.join(command),
                      "```", "", f"Log: {log}", ""]
        lines += ["## Scope", "",
                  "This checks the supplied binary and disposable SQLite databases only. It does not "
                  "establish binary/source provenance or validate other providers. SQLite transaction "
                  "requests are expected to warn and continue without grate-managed DDL transactions. "
                  "Both modes therefore retain partial effects. Run provider-specific failure and "
                  "recovery checks before relying on rollback elsewhere.", ""]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-version", help="Require the exact version shown in grate --help")
    parser.add_argument("--report", type=Path, help="Markdown report destination (default: temporary artifacts)")
    parser.add_argument("--timeout", type=int, default=60, help="Timeout in seconds per CLI invocation")
    parser.add_argument("command", nargs=argparse.REMAINDER,
                        help="Trusted installed CLI command after --; use absolute paths for DLLs/executables")
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.command[:1] != ["--"]:
        parser.error("Supply the CLI command after --, for example: -- dotnet /absolute/path/grate.dll")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    root = Path(tempfile.mkdtemp(prefix="grate-skill-sqlite-")).resolve()
    verification = Verification(command, root, args.timeout)
    report = args.report.resolve() if args.report else root / "verification.md"
    print(f"Disposable artifacts: {root}", flush=True)
    failure = None
    try:
        verification.preflight(args.expected_version)
        verification.clean_apply_and_forward_change()
        verification.failure_and_recovery(False)
        verification.failure_and_recovery(True)
    except (AssertionError, OSError, sqlite3.Error, subprocess.SubprocessError) as error:
        failure = error
        print(f"FAIL: {error}", file=sys.stderr)
    verification.report(report, failure)
    print(f"Report: {report}")
    return 1 if failure else 0


if __name__ == "__main__":
    sys.exit(main())
