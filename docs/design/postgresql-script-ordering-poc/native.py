"""Extract a bounded PostgreSQL definition through the libpg_query C API."""

import ctypes
import json
import os
from pathlib import Path
import sys


class PgError(ctypes.Structure):
    _fields_ = [
        ("message", ctypes.c_char_p), ("function", ctypes.c_char_p),
        ("filename", ctypes.c_char_p), ("line", ctypes.c_int),
        ("cursor", ctypes.c_int), ("context", ctypes.c_char_p),
    ]


class PgResult(ctypes.Structure):
    _fields_ = [
        ("tree", ctypes.c_char_p), ("stderr", ctypes.c_char_p),
        ("error", ctypes.POINTER(PgError)),
    ]


def parse(sql):
    library = os.environ.get("LIBPG_QUERY_LIBRARY")
    if not library:
        raise ValueError("Set LIBPG_QUERY_LIBRARY to the pinned libpg_query shared library")
    if "\0" in sql:
        raise ValueError("NUL bytes are unsupported")
    native = ctypes.CDLL(library)
    native.pg_query_parse.argtypes = [ctypes.c_char_p]
    native.pg_query_parse.restype = PgResult
    native.pg_query_free_parse_result.argtypes = [PgResult]
    native.pg_query_free_parse_result.restype = None
    result = native.pg_query_parse(sql.encode("utf-8"))
    try:
        if result.error:
            raise ValueError(result.error.contents.message.decode("utf-8"))
        return json.loads(result.tree)["stmts"]
    finally:
        native.pg_query_free_parse_result(result)


def name(parts, kind):
    if len(parts) != 2:
        raise ValueError("Require two-part schema-qualified names")
    return {"schema": parts[0], "name": parts[1], "kind": kind}


def strings(items):
    return [item["String"]["sval"] for item in items]


def validate_type(type_name):
    parts = strings(type_name.get("names", []))
    builtins = {"bool", "boolean", "int2", "int4", "int8", "integer", "text", "varchar",
                "numeric", "float4", "float8", "date", "timestamp", "timestamptz"}
    if type_name.get("arrayBounds") or not (
            len(parts) == 2 and parts[0] == "pg_catalog"
            or len(parts) == 1 and parts[0] in builtins):
        raise ValueError("Custom and array types are outside this prototype")


def extract(sql):
    statements = parse(sql)
    if len(statements) != 1:
        raise ValueError("Require one CREATE OR REPLACE definition")
    statement = statements[0]["stmt"]
    if "ViewStmt" in statement:
        view = statement["ViewStmt"]
        if not view.get("replace"):
            raise ValueError("Require CREATE OR REPLACE VIEW")
        relation = view["view"]
        if relation.get("relpersistence") != "p":
            raise ValueError("Temporary views are outside this prototype")
        if relation.get("catalogname"):
            raise ValueError("Cross-database definition names are unsupported")
        definition = name([relation.get("schemaname", ""), relation["relname"]], "view")
        if not definition["schema"]:
            raise ValueError("Require schema-qualified definition")
        body = view["query"]
    elif "CreateFunctionStmt" in statement:
        function = statement["CreateFunctionStmt"]
        if not function.get("replace") or function.get("is_procedure"):
            raise ValueError("Require CREATE OR REPLACE FUNCTION")
        for parameter in function.get("parameters", []):
            if parameter["FunctionParameter"]["mode"] != "FUNC_PARAM_TABLE":
                raise ValueError("Function input parameters and overloads are unsupported")
            validate_type(parameter["FunctionParameter"]["argType"])
        validate_type(function.get("returnType", {}))
        definition = name(strings(function["funcname"]), "function")
        options = {item["DefElem"]["defname"]: item["DefElem"].get("arg")
                   for item in function.get("options", [])}
        if options.get("language", {}).get("String", {}).get("sval") != "sql":
            raise ValueError("Only LANGUAGE sql is supported; procedural and dynamic SQL are unsupported")
        body = function.get("sql_body")
        if body is None:
            bodies = strings(options.get("as", {}).get("List", {}).get("items", []))
            if len(bodies) != 1:
                raise ValueError("Require one SQL function body")
            parsed_body = parse(bodies[0])
            if len(parsed_body) != 1 or "SelectStmt" not in parsed_body[0]["stmt"]:
                raise ValueError("Require one SELECT in a string SQL body")
            body = parsed_body[0]["stmt"]
    else:
        raise ValueError("Require one CREATE OR REPLACE VIEW or FUNCTION")

    references = []

    def walk(node, ctes=frozenset()):
        if isinstance(node, list):
            for child in node:
                walk(child, ctes)
        elif isinstance(node, dict):
            if "TypeName" in node:
                validate_type(node["TypeName"])
            if "typeName" in node:
                validate_type(node["typeName"])
            if "SelectStmt" in node:
                select = node["SelectStmt"]
                with_clause = select.get("withClause", {})
                local_ctes = set(ctes)
                entries = [entry["CommonTableExpr"] for entry in with_clause.get("ctes", [])]
                if with_clause.get("recursive"):
                    local_ctes.update(entry["ctename"] for entry in entries)
                for entry in entries:
                    walk(entry["ctequery"], frozenset(local_ctes))
                    local_ctes.add(entry["ctename"])
                walk({key: value for key, value in select.items() if key != "withClause"},
                     frozenset(local_ctes))
            elif "RangeVar" in node:
                relation = node["RangeVar"]
                if relation.get("catalogname"):
                    raise ValueError("Cross-database names are unsupported")
                schema = relation.get("schemaname")
                if not schema and relation["relname"] in ctes:
                    return
                if not schema:
                    raise ValueError("Require schema-qualified relation references")
                references.append(name([schema, relation["relname"]], "relation"))
            elif "FuncCall" in node:
                call = node["FuncCall"]
                if call.get("args"):
                    raise ValueError("Function calls with arguments are unsupported")
                references.append(name(strings(call["funcname"]), "function"))
                walk({key: value for key, value in call.items() if key != "funcname"}, ctes)
            else:
                if any(key.endswith("Stmt") and key != "ReturnStmt" for key in node):
                    raise ValueError("Only SELECT or RETURN SQL bodies are supported")
                for child in node.values():
                    walk(child, ctes)

    walk(body)
    references = sorted({(ref["schema"], ref["name"], ref["kind"]) for ref in references})
    return {"defines": definition,
            "references": [name([schema, object_name], kind)
                           for schema, object_name, kind in references]}


if __name__ == "__main__":
    try:
        print(json.dumps(extract(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))))
    except (ValueError, OSError, IndexError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
