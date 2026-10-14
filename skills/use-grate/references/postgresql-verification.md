# PostgreSQL transaction verification

This local integration check characterizes failure and recovery for three ordinary `up` scripts with `--transaction false` and `--transaction true`. It verifies effective rollback against PostgreSQL, rather than treating acceptance of the option as evidence that a provider supports it.

## Environment and scope

- Date: 2026-09-05.
- Host: Darwin 25.6.0, arm64; Microsoft.NETCore.App 10.0.9.
- CLI: an existing `src/grate/bin/Release/net10.0/grate.dll` reporting `grate v2.2.0.0` in help and `grate v2.2.0 (build date 08/01/2026 16:33:46)` in logs.
- PostgreSQL: 17.11, `aarch64-unknown-linux-musl`, from `postgres:17-alpine`; image digest `sha256:18cfe3ef5e6815560c98237d6216d1e5119702fb0f3894c8785dd58b8bbe5d73`.
- Isolation: one new disposable Docker container, loopback-only dynamic host port, two fresh databases. The container was removed after verification. No existing database was used.

The existing binary was not rebuilt for this check, and its mapping to the current source commit has not been established. These results apply to this tested binary and environment; they do not establish that every supported provider or current source revision behaves identically. They do not cover autonomous folders, scripts that control their own transactions, or partial execution within a failed file.

SHA-256 identifiers of the tested assemblies:

| Assembly | SHA-256 |
| --- | --- |
| `grate.dll` | `055b3a877bdedc6ef2506a3041e2f3b1ad81985778b6b37cdb559c2fb0cb2166` |
| `grate.core.dll` | `435ab1a0168240f702b42565984da191b1f50877b21d2856e6a0a6cfaa665c79` |
| `grate.postgresql.dll` | `84a70289e51a45cdb3e350ee91e9ffcf8010349ef51e1c0b286b76d8f75c78d3` |

## Inputs and observed results

Each file contains one SQL statement. Each fresh database received `up/001_create_evidence.sql`:

```sql
CREATE TABLE public.grate821_evidence (id integer PRIMARY KEY);
```

Next, `up/002_seed_evidence.sql`:

```sql
INSERT INTO public.grate821_evidence (id) VALUES (1);
```

Finally, `up/003_fail.sql`, referencing a table that does not exist:

```sql
INSERT INTO public.grate821_missing (id) VALUES (2);
```

Assertions inspected the database after each CLI process exited, using a separate `psql` connection. Both initial invocations failed with exit code 1 and PostgreSQL error `42P01`.

| Observation after the third file failed | `--transaction false` | `--transaction true` |
| --- | --- | --- |
| Table created by the first file exists | Yes | No |
| Row inserted by the second file survives | Yes, row `1` | No table remains |
| First two files appear in `grate."ScriptsRun"` | Each exactly once | Both absent |
| Failed file appears in `grate."ScriptsRun"` | Absent | Absent |
| Failed file appears in `grate."ScriptsRunErrors"` | Exactly once | Exactly once |

Only in this disposable test database, `003_fail.sql` was then changed to the following statement. This correction is not guidance to edit a migration used by a shared deployment:

```sql
INSERT INTO public.grate821_evidence (id) VALUES (2);
```

The same migration command was rerun. Both modes exited 0 and produced exactly rows `1` and `2`, one success-history entry per file, and the retained original error-history entry. With transactions disabled, the log confirmed that `001_create_evidence.sql` and `002_seed_evidence.sql` were skipped. With transactions enabled, their effects had rolled back, so both could run again. A third invocation with unchanged files exited 0 in both modes and preserved the two rows.

## Reproduction

Set `GRATE_DLL` to the CLI to test and create a scratch directory. The tested binary, platform, and hashes above identify this run; another binary must be checked independently.

```sh
GRATE_DLL=/absolute/path/grate.dll
GRATE_VERIFY_ROOT=$(mktemp -d)
docker run --detach --rm \
  --name grate-821-pg-verification \
  --publish 127.0.0.1::5432 \
  --env POSTGRES_PASSWORD=grate821_local_only \
  --env POSTGRES_USER=grate821 \
  postgres:17-alpine
```

Wait for `docker exec grate-821-pg-verification pg_isready --username=grate821` to report readiness. Read the assigned port using `docker port grate-821-pg-verification 5432/tcp` and set `GRATE_VERIFY_PORT` to its numeric port. The verified run used port `62232`.

For each mode (`false`, then `true`), create the input files in a distinct directory. Each mode uses a fresh database inside the new container. The CLI creates its database and history tables.

```sh
MODE=false
mkdir -p "$GRATE_VERIFY_ROOT/transaction_${MODE}/sql/up"
cat > "$GRATE_VERIFY_ROOT/transaction_${MODE}/sql/up/001_create_evidence.sql" <<'SQL'
CREATE TABLE public.grate821_evidence (id integer PRIMARY KEY);
SQL
cat > "$GRATE_VERIFY_ROOT/transaction_${MODE}/sql/up/002_seed_evidence.sql" <<'SQL'
INSERT INTO public.grate821_evidence (id) VALUES (1);
SQL
cat > "$GRATE_VERIFY_ROOT/transaction_${MODE}/sql/up/003_fail.sql" <<'SQL'
INSERT INTO public.grate821_missing (id) VALUES (2);
SQL

dotnet "$GRATE_DLL" \
  --databasetype PostgreSQL \
  --connectionstring "Host=127.0.0.1;Port=${GRATE_VERIFY_PORT};Database=transaction_${MODE};Username=grate821;Password=grate821_local_only;Pooling=false" \
  --adminconnectionstring "Host=127.0.0.1;Port=${GRATE_VERIFY_PORT};Database=postgres;Username=grate821;Password=grate821_local_only;Pooling=false" \
  --files "$GRATE_VERIFY_ROOT/transaction_${MODE}/sql" \
  --output "$GRATE_VERIFY_ROOT/transaction_${MODE}/output" \
  --noninteractive --transaction "$MODE" --version 821-verification --verbosity Debug
```

Expect exit code 1 for the deliberate failure. Run the following queries with a separate connection and compare the results with the table above:

```sh
docker exec --interactive grate-821-pg-verification \
  psql --username=grate821 --dbname="transaction_${MODE}" \
  --tuples-only --no-align --set=ON_ERROR_STOP=1 <<'SQL'
SELECT to_regclass('public.grate821_evidence') IS NOT NULL;
SELECT script_name FROM grate."ScriptsRun" ORDER BY script_name;
SELECT script_name FROM grate."ScriptsRunErrors" ORDER BY script_name;
SELECT script_name, COUNT(*) FROM grate."ScriptsRun"
GROUP BY script_name ORDER BY script_name;
SQL
```

When the application table exists, also query `SELECT id FROM public.grate821_evidence ORDER BY id;` and assert the expected rows. In the disposable fixture, replace only `003_fail.sql` with the corrected statement shown above. Run the same CLI command again, expecting exit code 0, rows `1` and `2`, one success-history entry for each of the three files, and the original error-history entry. Run a third time with unchanged files and assert exit code 0 and unchanged rows. Repeat the full sequence with `MODE=true`.

Cleanup completed successfully after this verification:

```sh
docker rm --force grate-821-pg-verification
```
