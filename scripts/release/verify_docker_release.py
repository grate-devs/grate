#!/usr/bin/env python3
"""Read back all release tags and compare their manifest bodies to one build digest."""

import argparse
import json
import os
from pathlib import Path
import re

from migrate_docker_tags import Registry


def verify(tags, expected_digest, registry_factory=Registry):
    if expected_digest is not None and not re.fullmatch(r"sha256:[a-f0-9]{64}", expected_digest):
        raise ValueError("A valid build digest is required")
    if not tags or any(not re.fullmatch(
            r"(?:gratedevs|erikbra)/grate:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag)
            for tag in tags):
        raise ValueError("Expected explicit canonical/compatibility Docker Hub tags")

    registries = {}
    results = []
    for tag in tags:
        repository, reference = tag.split(":", 1)
        try:
            if repository not in registries:
                registries[repository] = registry_factory(repository)
            # Registry.manifest hashes the actual body and validates the header.
            digest, _ = registries[repository].manifest(reference)
            results.append({"tag": tag, "digest": digest,
                            "status": ("observed_without_build_digest" if expected_digest is None else
                                       "verified" if digest == expected_digest else "digest_mismatch")})
        except Exception:
            # Do not expose authenticated request/response details in evidence.
            results.append({"tag": tag, "status": "unavailable_or_invalid_manifest"})
    return {"expected_digest": expected_digest,
            "status": "verified" if all(r["status"] == "verified" for r in results) else "failed",
            "tags": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = verify(os.environ.get("DOCKER_TAGS", "").splitlines(),
                    os.environ.get("EXPECTED_DIGEST") or None)
    report["build_push_outcome"] = os.environ.get("BUILD_OUTCOME", "unknown")
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write("## Docker publication verification\n\n")
            output.write(f"Built digest: `{report['expected_digest']}`\n\n")
            for result in report["tags"]:
                output.write(f"- `{result['tag']}`: {result['status']}\n")
            if report["status"] != "verified":
                output.write("\nPublication is incomplete or inconsistent. Inspect both repositories; "
                             "do not rebuild or blindly retry a partially published version.\n")
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "verified" else 1


if __name__ == "__main__":
    raise SystemExit(main())
