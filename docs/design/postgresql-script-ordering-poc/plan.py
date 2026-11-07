"""Build the same dependency plan using either PostgreSQL parser extractor."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent
PARSERS = ("libpg_query", "sqlparsercs")


def key(object_name):
    kind = "relation" if object_name["kind"] == "view" else object_name["kind"]
    return kind, object_name["schema"], object_name["name"]


def extract(parser, file):
    command = ([sys.executable, str(ROOT / "native.py")] if parser == "libpg_query" else
               ["dotnet", str(ROOT / "managed/bin/Release/net10.0/PostgreSqlManaged.dll")])
    result = subprocess.run([*command, str(file)], capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise ValueError(f"{file.name}: {result.stderr.strip()}")
    return json.loads(result.stdout)


def declarations(sql):
    declared = None
    for line in sql.splitlines():
        text = line.strip()
        if text and not text.startswith("--"):
            break
        if not text.startswith("-- Dependencies:"):
            continue
        if declared is not None:
            raise ValueError("Only one leading Dependencies declaration is supported")
        value = text[len("-- Dependencies:"):].strip()
        declared = [part.strip() for part in value.split(",")] if value else []
    return declared


def build_plan(parser, root):
    if not root.is_dir():
        raise ValueError(f"SQL root does not exist: {root}")
    scripts = []
    definitions = {}
    for folder in ("functions", "views"):
        directory = root / folder
        if not directory.exists():
            continue
        if any(path.is_dir() for path in directory.iterdir()):
            raise ValueError(f"{folder}: subfolders are unsupported")
        for file in sorted(directory.glob("*.sql")):
            path = f"{folder}/{file.name}"
            if file.name.lower().startswith("everytime.") or any(
                    marker in file.name.lower() for marker in (".everytime.", ".env.")):
                raise ValueError(f"{path}: only ordinary AnyTime files are supported")
            sql = file.read_text(encoding="utf-8-sig")
            if "{{" in sql or "\0" in sql:
                raise ValueError(f"{path}: tokens and NUL bytes are unsupported")
            parsed = extract(parser, file)
            parsed["references"] = sorted(
                {key(reference): reference for reference in parsed["references"]}.values(), key=key)
            expected_kind = "function" if folder == "functions" else "view"
            if parsed["defines"]["kind"] != expected_kind:
                raise ValueError(f"{path}: expected {expected_kind} definition")
            identity = key(parsed["defines"])
            if identity in definitions:
                raise ValueError(f"Duplicate definition: {definitions[identity]}, {path}")
            definitions[identity] = path
            scripts.append({"path": path, **parsed, "declared": declarations(sql)})
    if not scripts:
        raise ValueError("No candidate .sql files")

    paths = {script["path"] for script in scripts}
    pending = []
    for script in scripts:
        inferred, outside = [], []
        for reference in script["references"]:
            prerequisite = definitions.get(key(reference))
            if prerequisite:
                inferred.append({"path": prerequisite, "source": "inferred", "reference": reference})
            else:
                outside.append(reference)
        dependencies = inferred
        if script["declared"] is not None:
            dependencies = []
            for prerequisite in dict.fromkeys(script["declared"]):
                if prerequisite not in paths:
                    raise ValueError(f"{script['path']}: missing declared dependency {prerequisite}")
                dependencies.append({"path": prerequisite, "source": "declared", "reference": None})
        pending.append({"path": script["path"], "defines": script["defines"],
                        "dependencies": dependencies, "outsideReferences": outside})

    ordered, emitted = [], set()
    while pending:
        ready = next((script for script in pending
                      if all(edge["path"] in emitted for edge in script["dependencies"])), None)
        if ready is None:
            raise ValueError("Dependency cycle among remaining files: "
                             + ", ".join(script["path"] for script in pending))
        pending.remove(ready)
        emitted.add(ready["path"])
        ordered.append(ready)
    return {"scripts": ordered}


if __name__ == "__main__":
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--parser", choices=PARSERS, required=True)
    args.add_argument("sql_root", type=Path)
    options = args.parse_args()
    try:
        print(json.dumps(build_plan(options.parser, options.sql_root), indent=2))
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
