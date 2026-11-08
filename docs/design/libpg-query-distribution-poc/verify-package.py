"""Verify native assets through fresh .NET package consumers and published apps."""

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent
PACKAGE = "Grate.Poc.LibPgQuery.Native.18.1.0-poc.1.nupkg"
RIDS = ("win-x64", "win-x86", "win-arm64", "osx-x64", "osx-arm64",
        "linux-x64", "linux-arm64", "linux-musl-x64", "linux-musl-arm64")
NOTICES = ("libpg_query-LICENSE", "PostgreSQL-COPYRIGHT", "upb-LICENSE",
           "utf8_range-LICENSE", "xxhash-LICENSE")


def native_name(rid):
    if rid.startswith("win-"):
        return "pg_query.dll"
    return "libpg_query.dylib" if rid.startswith("osx-") else "libpg_query.so"


def digest(content):
    return hashlib.sha256(content).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def inspect_package(feed, rid, complete):
    with zipfile.ZipFile(feed / PACKAGE) as package:
        names = set(package.namelist())
        for notice in NOTICES:
            require(bool(package.read("licenses/" + notice)), f"Empty notice {notice}")
        if complete:
            expected = {f"runtimes/{item}/native/{native_name(item)}" for item in RIDS}
            actual = {name for name in names if name.startswith("runtimes/") and "/native/" in name}
            require(actual == expected, f"Unexpected universal package native assets: {actual}")
        asset = f"runtimes/{rid}/native/{native_name(rid)}"
        content = package.read(asset)
        require(bool(content), f"Empty native asset {asset}")
        return digest(content)


def verify_notices(directory):
    for notice in NOTICES:
        copies = list(directory.rglob(notice))
        require(bool(copies) and all(path.is_file() and path.stat().st_size > 0 for path in copies),
                f"Missing redistributed native notice {notice} under {directory}")


def verify(feed, rid, framework, complete):
    expected_hash = inspect_package(feed, rid, complete)
    with tempfile.TemporaryDirectory(prefix="grate-native-consumer-") as directory:
        temporary = Path(directory)
        environment = dict(os.environ, NUGET_PACKAGES=str(temporary / "packages"))
        consumer = temporary / "consumer"
        shutil.copytree(ROOT / "managed/Smoke", consumer, ignore=shutil.ignore_patterns("bin", "obj"))
        project = consumer / "LibPgQuery.Smoke.csproj"

        def run(command):
            result = subprocess.run(command, cwd=temporary, env=environment,
                                    capture_output=True, text=True, timeout=600)
            if result.returncode:
                raise RuntimeError(" ".join(map(str, command)) + "\n" + result.stdout + result.stderr)
            return result.stdout

        for single_file in (False, True):
            mode = "single-file" if single_file else "framework-dependent"
            output = temporary / mode
            properties = [f"-p:TargetFrameworks={framework}", f"-p:SelfContained={str(single_file).lower()}",
                          f"-p:PublishSingleFile={str(single_file).lower()}",
                          f"-p:DirectoryBuildPropsPath={ROOT.parents[2] / 'Directory.Build.props'}"]
            if not single_file:
                properties.append("-p:PublishTrimmed=false")
            run(["dotnet", "restore", str(project), "-r", rid, *properties,
                 "--source", str(feed), "--source", "https://api.nuget.org/v3/index.json", "--nologo"])
            run(["dotnet", "publish", str(project), "--no-restore", "-c", "Release", "-f", framework,
                 "-r", rid, *properties, "-o", str(output), "--nologo"])
            filename = native_name(rid)
            adjacent = output / filename
            if single_file:
                require(not adjacent.exists(), f"Native asset remained beside single-file app: {adjacent}")
                extraction = temporary / "extraction"
                environment["DOTNET_BUNDLE_EXTRACT_BASE_DIR"] = str(extraction)
            else:
                require(adjacent.is_file(), f"Missing RID-selected adjacent native asset: {adjacent}")
                require(digest(adjacent.read_bytes()) == expected_hash, "Published native bytes differ from package")
            executable = output / ("LibPgQuery.Smoke.exe" if rid.startswith("win-") else "LibPgQuery.Smoke")
            result = run([str(executable)])
            architecture = "Arm64" if rid.endswith("arm64") else "X86" if rid.endswith("x86") else "X64"
            require(result.startswith("PASS ") and f" {architecture}:" in result,
                    f"Unexpected process result for {rid}: {result}")
            if single_file:
                extracted = list(extraction.rglob(filename))
                require(len(extracted) == 1, f"Expected one extracted native asset, found {extracted}")
                require(digest(extracted[0].read_bytes()) == expected_hash,
                        "Extracted native bytes differ from RID-selected package asset")
                verify_notices(extraction)
            else:
                verify_notices(output)
            print(f"{rid} {framework} {mode}: {result.strip()}")
    print(f"Verified package notices and native SHA256 {expected_hash}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed", type=Path, required=True)
    parser.add_argument("--rid", choices=RIDS, required=True)
    parser.add_argument("--framework", choices=("net10.0", "net11.0"), default="net10.0")
    parser.add_argument("--complete", action="store_true", help="Require exactly all nine supported RID assets")
    args = parser.parse_args()
    verify(args.feed.resolve(), args.rid, args.framework, args.complete)
