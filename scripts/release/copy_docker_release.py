#!/usr/bin/env python3
"""Copy one canonical Docker release to its compatibility name without rebuilding."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.error

from migrate_docker_tags import Registry, timestamp, write_json


SOURCE = "gratedevs/grate"
DESTINATION = "erikbra/grate"


class CopyError(Exception):
    pass


def selected_tags(value):
    names = {SOURCE: set(), DESTINATION: set()}
    for line in value.splitlines():
        repository, separator, tag = line.partition(":")
        if repository not in names or not separator or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
            raise CopyError("Unexpected release image reference.")
        if tag in names[repository]:
            raise CopyError("Duplicate release image reference.")
        names[repository].add(tag)
    if not names[SOURCE] or names[SOURCE] != names[DESTINATION]:
        raise CopyError("Canonical and compatibility release tags must match exactly.")
    versions = names[SOURCE] - {"latest"}
    if len(versions) != 1:
        raise CopyError("Exactly one version tag is required.")
    version = next(iter(versions))
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", version):
        raise CopyError("A release version tag is required.")
    if "-" in version and "latest" in names[SOURCE]:
        raise CopyError("Prereleases cannot update latest.")
    return sorted(names[SOURCE], key=lambda tag: (tag == "latest", tag))


def run_skopeo(arguments, operation):
    try:
        result = subprocess.run(["skopeo", *arguments], capture_output=True, timeout=1200)
    except (OSError, subprocess.SubprocessError):
        raise CopyError(f"Skopeo {operation} could not complete.") from None
    if result.returncode:
        # Skopeo errors and registry response bodies may include credentials.
        raise CopyError(f"Skopeo {operation} failed.")
    return result.stdout


def verify_source(source_authfile, reference, expected_digest):
    raw = run_skopeo([
        "inspect", "--raw", "--authfile", str(source_authfile),
        f"docker://docker.io/{SOURCE}{reference}",
    ], "source inspection")
    if "sha256:" + hashlib.sha256(raw).hexdigest() != expected_digest:
        raise CopyError("Canonical release reference differs from the build digest.")


def existing_digest(destination, tag):
    try:
        return destination.resolve_digest(tag)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            error.close()
            return None
        raise


def copy_release(tags_value, expected_digest, source_authfile, report_path, user, secret):
    result = {"source": SOURCE, "destination": DESTINATION, "status": "in_progress",
              "started_at": timestamp(), "tags": {}}
    write_json(report_path, result)
    try:
        tags = selected_tags(tags_value)
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", expected_digest):
            raise CopyError("EXPECTED_DIGEST must be a SHA256 image digest.")
        if not user or not secret:
            raise CopyError("Compatibility publishing requires both Docker credential variables.")
        if not source_authfile.is_file():
            raise CopyError("Canonical Docker authentication file is missing.")
        result["expected_digest"] = expected_digest
        destination = Registry(DESTINATION)
        verify_source(source_authfile, "@" + expected_digest, expected_digest)
        # Validate every selected canonical tag and immutable destination version
        # before the first compatibility write. latest is intentionally mutable.
        for tag in tags:
            verify_source(source_authfile, ":" + tag, expected_digest)
            previous = existing_digest(destination, tag)
            if tag != "latest" and previous not in (None, expected_digest):
                raise CopyError("Compatibility version already has a conflicting digest.")
            result["tags"][tag] = {"status": "pending", "already_present": previous == expected_digest}
        write_json(report_path, result)
        with tempfile.TemporaryDirectory(prefix="grate-compatibility-auth-") as directory:
            authfile = Path(directory) / "auth.json"
            descriptor = os.open(authfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                auth = base64.b64encode(f"{user}:{secret}".encode()).decode()
                json.dump({"auths": {"docker.io": {"auth": auth}}}, output)
            # latest is last, after version graph/blob verification succeeds.
            for tag in tags:
                entry = result["tags"][tag]
                if not entry["already_present"]:
                    entry["status"] = "copy_started"
                    write_json(report_path, result)
                    run_skopeo([
                        "copy", "--all", "--preserve-digests", "--retry-times", "2",
                        "--src-authfile", str(source_authfile), "--dest-authfile", str(authfile),
                        f"docker://docker.io/{SOURCE}@{expected_digest}",
                        f"docker://docker.io/{DESTINATION}:{tag}",
                    ], "compatibility copy")
                    entry["status"] = "copied"
                    write_json(report_path, result)
                actual = destination.describe(tag, check_blobs=True)
                if actual["digest"] != expected_digest:
                    raise CopyError("Compatibility manifest differs from the build digest.")
                entry.update(status="verified", verified_at=timestamp(), **actual)
                write_json(report_path, result)
        # Resolve mutable tags afresh to detect concurrent publication.
        for tag in tags:
            verify_source(source_authfile, ":" + tag, expected_digest)
            if destination.resolve_digest(tag) != expected_digest:
                raise CopyError("Compatibility release reference changed during copying.")
        result.update(status="verified", completed_at=timestamp())
        write_json(report_path, result)
        return result
    except Exception:
        result.update(status="failed", completed_at=timestamp())
        # Neither subprocess response text nor credential-bearing exceptions are
        # persisted. Per-tag states identify any partially completed writes.
        write_json(report_path, result)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-authfile", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    try:
        copy_release(os.getenv("DOCKER_TAGS", ""), os.getenv("EXPECTED_DIGEST", ""),
                     args.source_authfile, args.report,
                     os.getenv("DOCKER_HUB_USER", ""), os.getenv("DOCKER_HUB_TOKEN", ""))
    except CopyError as error:
        raise SystemExit(str(error)) from None
    except Exception:
        raise SystemExit("Compatibility publication failed; inspect the redacted report.") from None


if __name__ == "__main__":
    main()
