#!/usr/bin/env python3
"""Publish the verified Docker build archive to its canonical release tags."""

import argparse
import hashlib
import os
from pathlib import Path
import re

from copy_docker_release import (
    CopyError, SOURCE, existing_digest, run_skopeo, selected_tags, verify_source,
)
from migrate_docker_tags import Registry, timestamp, write_json


def validate_archive(expected_digest, archive):
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", expected_digest):
        raise CopyError("EXPECTED_DIGEST must be a SHA256 image digest.")
    if not archive.is_file():
        raise CopyError("Docker build archive is missing.")
    raw = run_skopeo(["inspect", "--raw", f"oci-archive:{archive}"], "archive inspection")
    if "sha256:" + hashlib.sha256(raw).hexdigest() != expected_digest:
        raise CopyError("Docker build archive differs from the build digest.")
    return expected_digest


def verify_archive(expected_digest, archive, report_path):
    result = {"artifact": "docker_oci_archive", "status": "in_progress", "started_at": timestamp()}
    write_json(report_path, result)
    try:
        result["digest"] = validate_archive(expected_digest, archive)
        result.update(status="verified", completed_at=timestamp())
        write_json(report_path, result)
        return result
    except Exception:
        result.update(status="failed", completed_at=timestamp())
        write_json(report_path, result)
        raise


def preflight_archive(tags_value, expected_digest, archive, result, report_path):
    tags = selected_tags(tags_value)
    # Registry's public pull preflight must never pick up the credentials
    # reserved for the separate compatibility publishing step.
    if os.getenv("DOCKER_HUB_USER") or os.getenv("DOCKER_HUB_TOKEN"):
        raise CopyError("Canonical publication cannot use compatibility Docker credentials.")
    result["expected_digest"] = validate_archive(expected_digest, archive)
    result["tags"] = {tag: {"status": "pending"} for tag in tags}
    write_json(report_path, result)
    destination = Registry(SOURCE)
    # Check every immutable version before any write; latest is mutable.
    for tag in tags:
        previous = existing_digest(destination, tag)
        result["tags"][tag]["already_present"] = previous == expected_digest
        if tag != "latest" and previous not in (None, expected_digest):
            raise CopyError("Canonical version already has a conflicting digest.")
    write_json(report_path, result)
    return tags


def preflight_release(tags_value, expected_digest, archive, report_path):
    result = {"destination": SOURCE, "mode": "preflight", "status": "in_progress",
              "started_at": timestamp(), "tags": {}}
    write_json(report_path, result)
    try:
        preflight_archive(tags_value, expected_digest, archive, result, report_path)
        for entry in result["tags"].values():
            entry["status"] = "preflight_verified"
        result.update(status="verified", completed_at=timestamp())
        write_json(report_path, result)
        return result
    except Exception:
        result.update(status="failed", completed_at=timestamp())
        write_json(report_path, result)
        raise


def publish_archive(tags_value, expected_digest, archive, authfile, report_path):
    result = {"destination": SOURCE, "status": "in_progress",
              "started_at": timestamp(), "tags": {}}
    write_json(report_path, result)
    try:
        if not authfile.is_file():
            raise CopyError("Canonical Docker authentication file is missing.")
        tags = preflight_archive(tags_value, expected_digest, archive, result, report_path)

        # selected_tags puts latest last, after version readback succeeds.
        for tag in tags:
            entry = result["tags"][tag]
            if not entry["already_present"]:
                entry["status"] = "copy_started"
                write_json(report_path, result)
                run_skopeo([
                    "copy", "--all", "--preserve-digests", "--retry-times", "2",
                    "--dest-authfile", str(authfile), f"oci-archive:{archive}",
                    f"docker://docker.io/{SOURCE}:{tag}",
                ], "canonical copy")
                entry["status"] = "copied"
                write_json(report_path, result)
            verify_source(authfile, ":" + tag, expected_digest)
            entry.update(status="verified", digest=expected_digest, verified_at=timestamp())
            write_json(report_path, result)
        # Resolve tags afresh to catch concurrent movement during publication.
        for tag in tags:
            verify_source(authfile, ":" + tag, expected_digest)
        result.update(status="verified", completed_at=timestamp())
        write_json(report_path, result)
        return result
    except Exception:
        result.update(status="failed", completed_at=timestamp())
        # Persist only the journal, never registry/tool response bodies or auth.
        write_json(report_path, result)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--authfile", type=Path)
    parser.add_argument("--report", required=True, type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--verify-only", action="store_true", help="Validate the local archive without registry access.")
    modes.add_argument("--preflight-only", action="store_true", help="Validate the archive and public release conflicts without publishing.")
    args = parser.parse_args()
    if not (args.verify_only or args.preflight_only) and args.authfile is None:
        parser.error("--authfile is required for publication")
    try:
        if args.verify_only:
            verify_archive(os.getenv("EXPECTED_DIGEST", ""), args.archive, args.report)
        elif args.preflight_only:
            preflight_release(os.getenv("DOCKER_TAGS", ""), os.getenv("EXPECTED_DIGEST", ""),
                              args.archive, args.report)
        else:
            publish_archive(os.getenv("DOCKER_TAGS", ""), os.getenv("EXPECTED_DIGEST", ""),
                            args.archive, args.authfile, args.report)
    except CopyError as error:
        raise SystemExit(str(error)) from None
    except Exception:
        raise SystemExit("Canonical publication failed; inspect the redacted report.") from None


if __name__ == "__main__":
    main()
