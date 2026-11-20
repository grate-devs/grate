# PostgreSQL parser comparison

This standalone experiment compares dependency extraction using libpg_query and
SqlParserCS. Both adapters read the same SQL files. A shared Python planner maps
their normalized definitions and references to files, applies declared
prerequisites and performs a deterministic topological sort.

The project lives outside the grate solution and packages. The native adapter
calls libpg_query directly through Python's standard-library `ctypes` interface.
The managed adapter uses the published SqlParserCS package. Each extractor runs
in a separate process with a timeout.

## Prepare the parsers

Use Python 3.10 or newer, a C compiler, make, Git and the stable .NET 10 SDK.
From the repository root, choose a new external directory for native sources.
The tag and commit below pin the exact C ABI and JSON tree format.

```sh
poc="$PWD/docs/design/postgresql-script-ordering-poc"
native="/tmp/grate-libpg-query-18.1.0"
git clone --depth 1 --branch 18.1.0 https://github.com/pganalyze/libpg_query.git "$native"
test "$(git -C "$native" rev-parse HEAD)" = c1546e7e97edc93fe8474d7a59881e91fbf48cfc
make -C "$native" -j4 build_shared
(cd /tmp && dotnet build "$poc/managed/PostgreSqlManaged.csproj" -c Release)
```

Set `LIBPG_QUERY_LIBRARY` to `libpg_query.dylib` on macOS or `libpg_query.so` on Linux.

```sh
export LIBPG_QUERY_LIBRARY="$native/libpg_query.dylib"
python3 "$poc/plan.py" --parser libpg_query "$poc/fixtures/base"
python3 "$poc/plan.py" --parser sqlparsercs "$poc/fixtures/base"
python3 "$poc/compare.py"
```

Acquisition and compilation may use the network. The built extractors and planner
use local files only. On macOS the complete comparison can run with networking denied.

```sh
sandbox-exec -p '(version 1) (allow default) (deny network*)' python3 "$poc/compare.py"
```

## Scenarios and interpretation

The checks assert complete ordered paths, edges, declaration sources, outside
references, deterministic output and absence of partial plans on error. They
also compare complete JSON plans for common successful cases.

| Scenario | libpg_query 18.1.0 adapter | SqlParserCS 0.6.5 adapter |
| --- | --- | --- |
| Scalar function → view → function and two-definition upgrade | Plan | Plan |
| View dependencies, joins, derived queries, nonrecursive CTE scopes | Plan | Plan with explicit traversal |
| DISTINCT ON expressions | Plan | Plan with explicit traversal |
| Quoted names and unquoted ASCII name folding | Plan | Plan |
| SQL function bodies supplied as strings | Parse the body again | Parse the body again |
| SQL-standard RETURN | Plan | Plan |
| SQL-standard BEGIN ATOMIC | Plan | Grammar rejection |
| RETURNS TABLE with built-in output-column types | Plan | Adapter rejection |
| Duplicate definitions, cycles and missing declared files | Error | Error |

The table-return declaration parses in SqlParserCS, but its output columns are
represented as opaque custom-type modifiers. This adapter rejects that form
because it cannot validate output-column types safely from that representation.
That result differs from its parser rejecting BEGIN ATOMIC syntax.

SqlParserCS 0.6.5's default visitor skips dependencies in some FROM forms and
does not invoke its query visitor hooks. Its Select visitor omits DISTINCT ON
expressions. The managed adapter explicitly visits these parts, and the shared
regressions exercise the workarounds. Parsing success alone therefore does not
establish complete dependency extraction.

## Contract boundaries

- Candidates are immediate lowercase `.sql` files under `functions` and `views`,
  with one schema-qualified CREATE OR REPLACE definition per file. Environment,
  EveryTime and tokenized scripts are excluded.
- Candidate functions have no input parameters. Function calls have no arguments.
  Overload resolution and custom/array type dependencies are outside this slice.
- References use two-part names. Unknown references are deployment assumptions.
  Search-path binding, column/type checking and semantic validity require the
  database. The managed adapter additionally excludes recursive CTEs and
  unquoted non-ASCII identifiers.
- A leading `-- Dependencies:` comment replaces a file's inferred prerequisites
  with exact comma-separated candidate paths. Other files retain inference.
- The graph distinguishes function names from relation names. Files keep their
  paths and contents. Ties use ordinal paths within the fixed folder sequence.
  Dependencies on operators, collations and extension installation require
  separate analysis.
- Plan consumption by grate, stale-plan validation, migration history and
  production transaction policies require a later integration step.

## Real PostgreSQL check

The verification uses a local PostgreSQL 17.6 image and creates separate databases
for each parser's plan. It starts the container with networking disabled, uses
its internal loopback interface, and removes the container and owned data volume.

```sh
docker pull postgres:17.6-alpine
python3 "$poc/verify-postgresql.py"
```

It enables `check_function_bodies`, checks report values on fresh setup and
upgrade, and checks that reversing the dependent files fails for the expected
missing view or column. It applies the two changed definitions from each upgrade
plan. This checks SQL binding with explicitly selected changed files.

## Parser adoption questions

libpg_query requires native builds and distribution for the supported host
platforms, plus an adapter tied to its PostgreSQL tree version. SqlParserCS is
managed, but its published visitor needs the workarounds exercised here.
Evaluate the published package separately from its newer source tree and resolve
the reported tokenizer liveness issue before running it inside a production
CLI process. [libpg_query](https://github.com/pganalyze/libpg_query),
[SqlParserCS package](https://www.nuget.org/packages/SqlParserCS/0.6.5),
[tokenizer issue](https://github.com/TylerBrinks/SqlParser-cs/issues/89)
