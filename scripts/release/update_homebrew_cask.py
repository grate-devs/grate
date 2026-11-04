#!/usr/bin/env python3

"""Generate the grate Homebrew cask for a stable GitHub release."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


STABLE_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--arm64-sha256", required=True)
    parser.add_argument("--x64-sha256", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def validate(version: str, arm64_sha256: str, x64_sha256: str) -> None:
    if not STABLE_VERSION.fullmatch(version):
        raise ValueError(f"Homebrew only publishes stable SemVer versions, got: {version}")

    for architecture, checksum in (
        ("arm64", arm64_sha256),
        ("x64", x64_sha256),
    ):
        if not SHA256.fullmatch(checksum):
            raise ValueError(f"Invalid {architecture} SHA-256: {checksum}")


def render(version: str, arm64_sha256: str, x64_sha256: str) -> str:
    return f'''cask "grate" do
  arch arm: "arm64", intel: "x64"

  version "{version}"
  sha256 arm:   "{arm64_sha256}",
         intel: "{x64_sha256}"

  url "https://github.com/grate-devs/grate/releases/download/#{{version}}/grate-osx-#{{arch}}-self-contained-#{{version}}.zip"
  name "grate"
  desc "SQL scripts migration runner"
  homepage "https://grate-devs.github.io/grate/"

  binary "grate"
end
'''


def main() -> None:
    args = parse_args()
    arm64_sha256 = args.arm64_sha256.lower()
    x64_sha256 = args.x64_sha256.lower()
    validate(args.version, arm64_sha256, x64_sha256)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        render(args.version, arm64_sha256, x64_sha256),
        encoding="utf-8",
        newline="\n",
    )


if __name__ == "__main__":
    main()
