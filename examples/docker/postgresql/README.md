# PostgreSQL Docker Compose example

Run these commands from this directory with Docker Compose. The password is
supplied at runtime and is for this local example.

```sh
export POSTGRES_PASSWORD=grate-example
docker compose run --rm migrate
```

Compose starts PostgreSQL and waits for it to accept connections. The
`migrate` service sets `DATABASE_TYPE=postgresql` and passes a complete
[Npgsql connection string](https://www.npgsql.org/doc/connection-string-parameters.html)
as `APP_CONNSTRING`. In that string, `Host=db` is the Compose service name,
`Username=postgres` is the PostgreSQL role, and `Database=grate_example` is
the database that grate creates and migrates using the scripts in `db/up`.

Check that the migration inserted a row. The query should print `Hello from grate`.

```sh
docker compose exec -T db psql -U postgres -d grate_example -Atc 'SELECT message FROM public.migration_demo;'
```

## Optional admin connection

By default, grate uses the target connection settings with `Database=postgres`
for database creation. To specify a maintenance database or credentials
explicitly, pass a full admin connection string after the service name.
The image entrypoint forwards it to grate. Use this form in place of the
migration command above and set `Database` to an existing maintenance database
that the admin role can connect to.

```sh
docker compose run --rm migrate \
  --adminconnectionstring="Host=db;Port=5432;Database=postgres;Username=postgres;Password=$POSTGRES_PASSWORD"
```

## Cleanup

Remove the local containers and their PostgreSQL data volume.

```sh
docker compose down --volumes
```
