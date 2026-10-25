# Consumer workflows

Use this reference for runner setup, response files, and adoption from RoundhousE. For an ordinary migration change, keep the existing runner and start with [authoring](authoring.md).

## Select and reuse the runner

Inspect the project pin before copying installation commands from the published [Getting Grate](https://grate-devs.github.io/grate/getting-grate/) page. Its examples include older package names and runtime requirements; match the selected release's help and release artifacts instead of inferring today's requirements from those examples.

| Existing installation | What to preserve/check |
| --- | --- |
| Local .NET tool | The tool manifest's package/version and invocation through `dotnet tool run grate` or the project's existing wrapper. Do not substitute a globally installed version. |
| Global tool or OS package | The installed package/version and executable resolution in the actual shell/CI environment. |
| Self-contained binary | Matching OS, architecture, and libc. It needs no installed .NET runtime; OS dependencies such as ICU can still apply. |
| Container | Image version/digest, entrypoint/wrapper, mounted SQL and output paths, credentials, and the database address reachable from inside the container. |

For Alpine, choose the release's `linux-musl` architecture or the project's pinned container; a glibc Linux binary is not interchangeable. See [Alpine support](https://grate-devs.github.io/grate/alpine-linux-support/) and inspect the selected release rather than replacing a pin with `latest`.

Once the runner is known, obtain its `--help`. Set the actual provider explicitly (`--databasetype` in current grate), because the CLI defaults to SQL Server. Confirm its SQL root and working directory: the default SQL root is the current directory, and a successful invocation against the wrong or empty root does not verify the intended migration. Set a migration `--version` from the project's release convention; it is a history label, not a filter that selects scripts up to that version.

Use [Getting Started](https://grate-devs.github.io/grate/getting-started/) for the workflow overview. Empty lifecycle folders are unnecessary. Choose actual configured folder types/order from [authoring](authoring.md), since some published default-folder labels conflict with current implementation.

## Inspect response files before execution

[Response files](https://grate-devs.github.io/grate/response-files/) pass CLI arguments via `@path/to/settings.rsp`. Inspect them together with wrapper-supplied arguments: they can select credentials, environment, SQL root, transactions, and destructive flags such as `--drop`. A response file is not inherently a harmless settings file; do not reuse the documentation's drop/create example for a normal deployment.

Check quoting in the actual shell (PowerShell may require quoting the `@...` argument) and resolve file paths using the runner's working directory. Do not assume relative paths are anchored at the response file. Keep real credentials out of committed `.rsp` files and redact their expanded contents from reports.

## Adopt grate from RoundhousE

Read [Migrating from RoundhousE](https://grate-devs.github.io/grate/migrating-from-roundhouse/) and verify each difference against the pinned grate release. Its missing-feature list is historical, not a complete statement of current capability.

Before the first shared migration:

1. Reproduce the existing database and migration history in a disposable target. Preserve script names/content, token values, and the actual tracking schema/table configuration. The default grate schema differs from RoundhousE; pointing at an empty new history schema can make deployed scripts look unapplied. Use the confirmed existing schema (often `--schema=RoundhousE`) rather than treating the target as a fresh database.
2. Translate the runner explicitly: grate options are case-sensitive, Windows `/option` syntax is not supported, and a connection string replaces the old server/database arguments. Current grate uses `--verbosity`, and each user token gets its own `--ut=Key=Value`. Recheck token availability and quoting. For MySQL procedures that need user variables, inspect whether the connection string requires `Allow User Variables`.
3. Review destructive behavior separately. `--drop` continues into create/migrate; it is not a drop-only mode. Do not use `--baseline` or hash-warning flags to conceal a mismatch with deployed history.
4. Check selected scripts and history on the disposable copy, run the real migration, then assert an unchanged rerun and expected schema/data. Validate failure/recovery for the provider if relying on transaction behavior. A preview alone cannot establish compatibility.

Report unresolved RoundhousE features or history differences before applying to a shared target. Keep applied migration artifacts intact while investigating.
