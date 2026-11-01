#!/usr/bin/env python3
"""Resolve release versions and publishing intent without changing remote state."""

import json
import os
from pathlib import Path
import re
import subprocess


_NUMBER = r"(?:0|[1-9][0-9]*)"
_IDENTIFIER = rf"(?:{_NUMBER}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
_VERSION = re.compile(rf"{_NUMBER}\.{_NUMBER}\.{_NUMBER}(?:-{_IDENTIFIER}(?:\.{_IDENTIFIER})*)?")


class ContextError(Exception):
    pass


def read_release(tag, repository):
    """Read published-release metadata; never create or update a release."""
    try:
        result = subprocess.run([
            "gh", "release", "view", tag, "--repo", repository,
            "--json", "isDraft,isPrerelease",
        ], capture_output=True, text=True, timeout=45)
        if result.returncode:
            raise ContextError("The requested GitHub release could not be read.")
        return json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        # gh output and exceptions may contain tokens or response bodies.
        raise ContextError("The requested GitHub release could not be read.") from None


def boolean(value, name, default=None):
    if value == "true":
        return True
    if value == "false":
        return False
    if value == "" and default is not None:
        return default
    raise ContextError(f"{name} must be true or false.")


def resolve_context(env, release_reader=read_release):
    """Return the workflow's output values. This function writes no files."""
    event = env.get("EVENT_NAME", "")
    release_tag = ""
    publish = False
    declared_prerelease = None
    if event == "release":
        if env.get("RELEASE_ACTION", "") != "published" \
                or boolean(env.get("RELEASE_DRAFT", ""), "RELEASE_DRAFT"):
            raise ContextError("Only a published non-draft release event can enable publishing.")
        release_tag = env.get("RELEASE_TAG", "")
        if not release_tag:
            raise ContextError("A published release event requires RELEASE_TAG.")
        publish = True
        declared_prerelease = boolean(env.get("RELEASE_PRERELEASE", ""), "RELEASE_PRERELEASE")
    elif event == "workflow_dispatch":
        publish = boolean(env.get("MANUAL_PUBLISH", ""), "MANUAL_PUBLISH", default=False)
        release_tag = env.get("MANUAL_TAG", "")
        if publish and not release_tag:
            raise ContextError("MANUAL_TAG is required when publishing is enabled.")

    version = release_tag or env.get("GITVERSION_SEMVER", "")
    if not _VERSION.fullmatch(version):
        raise ContextError("Version must be SemVer without a v prefix, build metadata, or numeric leading zeroes.")
    prerelease = "-" in version

    if publish and event == "workflow_dispatch":
        repository = env.get("GITHUB_REPOSITORY", "")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", repository):
            raise ContextError("GITHUB_REPOSITORY is required for release validation.")
        try:
            metadata = release_reader(release_tag, repository)
        except Exception:
            raise ContextError("The requested GitHub release could not be read.") from None
        if not isinstance(metadata, dict) or type(metadata.get("isDraft")) is not bool \
                or type(metadata.get("isPrerelease")) is not bool:
            raise ContextError("GitHub release metadata must include boolean draft and prerelease settings.")
        if metadata["isDraft"]:
            raise ContextError("Publishing requires an existing published GitHub release; drafts are not allowed.")
        declared_prerelease = metadata["isPrerelease"]

    if publish and declared_prerelease != prerelease:
        raise ContextError("Tag prerelease suffix and GitHub release prerelease setting disagree.")
    checkout_ref = release_tag or env.get("GITHUB_SHA", "")
    if not release_tag and not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", checkout_ref):
        raise ContextError("GITHUB_SHA must identify the commit being built.")
    return {
        "checkout_ref": checkout_ref,
        "core_version": version.partition("-")[0],
        "version": version,
        "publish": str(publish).lower(),
        "prerelease": str(prerelease).lower(),
        "release_tag": release_tag,
    }


def main():
    try:
        output_path = os.getenv("GITHUB_OUTPUT", "")
        if not output_path:
            raise ContextError("GITHUB_OUTPUT is required.")
        context = resolve_context(os.environ)
        with Path(output_path).open("a", encoding="utf-8") as output:
            output.writelines(f"{key}={value}\n" for key, value in context.items())
        summary_path = os.getenv("GITHUB_STEP_SUMMARY", "")
        if summary_path:
            with Path(summary_path).open("a", encoding="utf-8") as summary:
                summary.write("## Release context\n\n")
                for label, key in (("Version", "version"), ("Checkout ref", "checkout_ref"),
                                   ("Publish", "publish"), ("Prerelease", "prerelease")):
                    summary.write(f"- {label}: `{context[key]}`\n")
    except ContextError as error:
        raise SystemExit(str(error)) from None
    except Exception:
        raise SystemExit("Release context resolution failed; no credential details logged.") from None


if __name__ == "__main__":
    main()
