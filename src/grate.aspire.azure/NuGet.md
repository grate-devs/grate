# grate.aspire.azure

Source-only Azure Container Apps integration for `grate.aspire.hosting`.
`application.WithGrateMigrationInitContainer(migration, environment: "PRODUCTION")` preserves the local
completion wait and publishes that migration as an init container in the
application's ACA template. The SQL scripts are packaged in the migration image.

Requires Aspire 13.6.5 and a previously declared Azure Container Apps environment.
An application targeting multiple compute environments must select its ACA
environment explicitly before calling the helper.

The grate environment name is mandatory and scoped to that consumer's init
container. The shared local migration resource keeps its local environment.
Connection values must remain secret references without published defaults.

An init container runs for each replica startup, including restarts and scale-out.
It is not a once-per-deployment job or a distributed migration lock. Coordinate
database changes externally when replicas/deployments can migrate concurrently.
Everytime scripts may run again. A failed init prevents that replica's main
containers from starting; no graceful SQL rollback guarantee is added.

SQLite's local shared-file integration is not supported for ACA publishing.
Use an external server database and deferred runtime connection/secret references.
Additional init arguments must be literal strings; pass sensitive configuration
through environment references. This package has not been published.
