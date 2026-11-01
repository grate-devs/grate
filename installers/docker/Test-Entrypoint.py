#!/usr/bin/env python3
"""Verify a candidate image through its default entrypoint, without publishing it.

Requires Docker and Python's standard library on the host; the image needs no
test tools. CI supplies the image it just built and retains the output directory.
"""

import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import uuid


class EntrypointVerification:
    def __init__(self, image, output_directory):
        self.image = image
        self.output = output_directory.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.completed = []
        self.summary = {"requested_image": image, "entrypoint": "image default"}

    def docker(self, name, arguments, timeout=60):
        log_path = self.output / (name + ".log")
        with log_path.open("w") as log:
            try:
                result = subprocess.run(
                    ["docker", *arguments], stdout=log, stderr=subprocess.STDOUT,
                    text=True, timeout=timeout, check=False,
                )
            except subprocess.TimeoutExpired as error:
                raise AssertionError(f"{name} exceeded {timeout}s; see {log_path}") from error
        return result.returncode, log_path.read_text(errors="replace")

    def run(self, name, state, arguments=(), connection=True):
        # Pin the inspected local image ID so a tag cannot change between cases.
        # These commands deliberately do not set --entrypoint.
        container_name = "grate-entrypoint-" + uuid.uuid4().hex
        command = [
            "run", "--rm", "--name", container_name, "--network", "none",
            "--mount", f"type=bind,source={state / 'sql'},target=/db,readonly",
            "--mount", f"type=bind,source={state / 'data'},target=/data",
            "--tmpfs", "/output:rw,size=16m",
            "--env", "DATABASE_TYPE=sqlite",
            "--env", "VERSION=entrypoint-v1",
        ]
        if connection:
            command += ["--env", "APP_CONNSTRING=Data Source=/data/database with spaces.db"]
        try:
            return self.docker(name, [*command, self.image, *arguments])
        finally:
            # Normally --rm already removed it. This also handles a timed-out
            # docker client, which does not itself stop its running container.
            subprocess.run(
                ["docker", "rm", "--force", container_name],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=15, check=False,
            )

    def require(self, condition, message):
        if not condition:
            raise AssertionError(message)

    def inspect_image(self):
        code, output = self.docker("image-inspect", ["image", "inspect", self.image])
        self.require(code == 0, "Candidate image must already exist locally; see image-inspect.log")
        metadata = json.loads(output)[0]
        self.image = metadata["Id"]
        self.summary.update({
            "image_id": self.image,
            "image_os": metadata["Os"],
            "image_architecture": metadata["Architecture"],
            "configured_entrypoint": metadata["Config"].get("Entrypoint"),
        })
        # Keep only relevant identity metadata, not the image's environment.
        (self.output / "image-inspect.log").write_text(json.dumps(self.summary, indent=2) + "\n")

    def query(self, database, sql):
        from urllib.parse import quote
        with sqlite3.connect("file:" + quote(str(database)) + "?mode=ro", uri=True) as connection:
            return connection.execute(sql).fetchall()

    def verify(self):
        self.inspect_image()
        with tempfile.TemporaryDirectory(prefix="grate-entrypoint-") as temporary:
            state = Path(temporary)
            scripts = state / "sql" / "up"
            scripts.mkdir(parents=True)
            (state / "data").mkdir()
            database = state / "data" / "database with spaces.db"
            (scripts / "001_create.sql").write_text(
                "CREATE TABLE entrypoint_probe (id INTEGER PRIMARY KEY, value TEXT NOT NULL);\n"
                "INSERT INTO entrypoint_probe VALUES (42, 'entrypoint payload');\n"
            )

            code, output = self.run("dryrun-new", state, ["--dryrun"])
            self.require(code == 0, "New-database preview failed; see dryrun-new.log")
            self.require("DryRun" in output and "001_create.sql" in output,
                         "Forwarded --dryrun must preview the migration; see dryrun-new.log")
            self.require(not database.exists(), "Forwarded --dryrun created a database")
            self.completed.append("dryrun-new")

            for name in ["migrate", "rerun"]:
                code, _ = self.run(name, state)
                self.require(code == 0, f"{name} failed; see {name}.log")
                self.require(database.is_file(), f"{name} did not create the configured database")
                self.require(
                    self.query(database, "PRAGMA table_info(entrypoint_probe)") ==
                    [(0, "id", "INTEGER", 0, None, 1), (1, "value", "TEXT", 1, None, 0)],
                    f"{name} did not preserve the expected application schema",
                )
                self.require(
                    self.query(database, "SELECT id,value FROM entrypoint_probe ORDER BY id") ==
                    [(42, "entrypoint payload")], f"{name} did not preserve the exact application data",
                )
                self.require(
                    self.query(database, "SELECT script_name,one_time_script FROM grate_ScriptsRun ORDER BY id") ==
                    [("001_create.sql", 1)], f"{name} did not record exactly one one-time execution",
                )
                self.require(
                    self.query(database, "SELECT version,status FROM grate_Version ORDER BY id") ==
                    [("entrypoint-v1", "Finished")], f"{name} ignored VERSION or changed completed version history",
                )
                self.require(self.query(database, "SELECT COUNT(*) FROM grate_ScriptsRunErrors") == [(0,)],
                             f"{name} recorded unexpected migration errors")
                self.completed.append(name)

            # An unapplied script makes the second preview distinguishable from
            # an ordinary no-op invocation. Compare the entire database file too.
            preview_script = scripts / "002_preview.sql"
            preview_script.write_text("CREATE TABLE preview_only (id INTEGER);\n")
            before = hashlib.sha256(database.read_bytes()).digest()
            code, output = self.run("dryrun-existing", state, ["--dryrun"])
            self.require(code == 0, "Existing-database preview failed; see dryrun-existing.log")
            self.require("DryRun" in output and "002_preview.sql" in output,
                         "Existing-database preview did not report the pending script")
            self.require(hashlib.sha256(database.read_bytes()).digest() == before,
                         "Existing-database preview modified schema, data or migration history")
            preview_script.unlink()
            self.completed.append("dryrun-existing")

            code, output = self.run("missing-connection", state, connection=False)
            self.require(code != 0 and "APP_CONNSTRING" in output,
                         "Missing APP_CONNSTRING must fail with a useful diagnostic; see missing-connection.log")
            self.require(hashlib.sha256(database.read_bytes()).digest() == before,
                         "Missing connection configuration changed the database")
            self.completed.append("missing-connection")

            (scripts / "003_failure.sql").write_text("INSERT INTO missing_entrypoint_table VALUES (1);\n")
            code, output = self.run("failing-sql", state)
            self.require(code != 0 and "missing_entrypoint_table" in output and "003_failure.sql" in output,
                         "Invalid SQL must return nonzero and identify the cause; see failing-sql.log")
            self.require(self.query(database, "SELECT id,value FROM entrypoint_probe") == [(42, "entrypoint payload")],
                         "The failing migration changed existing application data")
            self.require(self.query(database, "SELECT script_name FROM grate_ScriptsRun ORDER BY id") == [("001_create.sql",)],
                         "The failing SQL was recorded as successful")
            self.require(self.query(database, "SELECT script_name FROM grate_ScriptsRunErrors ORDER BY id") == [("003_failure.sql",)],
                         "The failing SQL did not record its error history")
            self.completed.append("failing-sql")

    def execute(self):
        try:
            self.verify()
        except Exception as error:
            self.summary.update({"result": "failed", "completed": self.completed, "error": str(error)})
            raise
        else:
            self.summary.update({"result": "passed", "completed": self.completed})
        finally:
            (self.output / "summary.json").write_text(json.dumps(self.summary, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, help="Already-built local candidate image")
    parser.add_argument("--output-directory", required=True, type=Path, help="Retained logs and summary directory")
    options = parser.parse_args()
    verifier = EntrypointVerification(options.image, options.output_directory)
    verifier.execute()
    print("PASS: default Docker entrypoint, environment, migration/rerun, dry runs and failures")
