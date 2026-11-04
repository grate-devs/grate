#!/usr/bin/env python3
"""Select Docker release tags without publishing anything.

Versions use SemVer without build metadata: Docker tags cannot contain '+',
and discarding metadata could overwrite a different release's version tag.
"""

import argparse
from pathlib import Path
import re


REPOSITORIES = ("gratedevs/grate", "erikbra/grate")
_NUMBER = r"(?:0|[1-9][0-9]*)"
_IDENTIFIER = rf"(?:{_NUMBER}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
_VERSION = re.compile(rf"v?({_NUMBER}\.{_NUMBER}\.{_NUMBER}(?:-{_IDENTIFIER}(?:\.{_IDENTIFIER})*)?)")


def normalize_version(value: str) -> str:
    match = _VERSION.fullmatch(value)
    if match is None:
        raise ValueError("Version must be SemVer without build metadata (optional 'v' prefix).")
    version = match.group(1)
    if len(version) > 128:
        raise ValueError("Version exceeds Docker's 128-character tag limit.")
    return version


def image_tags(value: str, prerelease: bool = False) -> list[str]:
    version = normalize_version(value)
    tags = [version] if prerelease or "-" in version else [version, "latest"]
    return [f"{repository}:{tag}" for repository in REPOSITORIES for tag in tags]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="release version, optionally prefixed with v")
    parser.add_argument("--prerelease", action="store_true", help="suppress latest even for a stable version")
    parser.add_argument("--github-output", type=Path, help="append outputs for a GitHub Actions step")
    args = parser.parse_args()
    try:
        version = normalize_version(args.version)
    except ValueError as error:
        parser.error(str(error))
    prerelease = args.prerelease or "-" in version
    tags = "\n".join(image_tags(version, prerelease))
    if args.github_output is not None:
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write(f"version={version}\nis-prerelease={str(prerelease).lower()}\n")
            output.write(f"tags<<GRATE_DOCKER_TAGS\n{tags}\nGRATE_DOCKER_TAGS\n")
            for name, repository in (("canonical-tags", REPOSITORIES[0]),
                                     ("compatibility-tags", REPOSITORIES[1])):
                selected = "\n".join(tag for tag in tags.splitlines() if tag.startswith(repository + ":"))
                output.write(f"{name}<<GRATE_DOCKER_TAGS\n{selected}\nGRATE_DOCKER_TAGS\n")
    print(tags)


if __name__ == "__main__":
    main()
