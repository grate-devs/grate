# Providers, SQL, and migration history

`GrateMigrator` owns migration sequencing and ambient transaction scope;
`DbMigrator` applies script policies; `AnsiSqlDatabase` owns shared database work.
Provider projects supply dialect and connection behavior. Trace all affected
layers before moving SQL or connection work between them.

- Preserve default/admin connection choice, `TransactionHandling.Default` versus
  `Autonomous`, and each provider's DDL transaction capability. Autonomous folders
  use suppressed ambient scopes and a separate active connection intentionally.
  Do not replace this design with a generic transaction pattern as cleanup.
- For transaction changes, establish which script effects and history rows must
  commit, roll back, or remain after failure. Grate structure/version setup,
  error recording, and deferred run-table writes have different lifetimes.
  Inspect disposal and failure paths as well as the happy path.
- Keep borrowed and owned connections distinct. Ensure a temporary active
  connection restores the default connection even on failure; cleanup must not
  create an unused lazy connection. Do not retry uncertain script execution
  without a demonstrated reason it is safe to repeat.
- Parameterize metadata values through Dapper/ADO.NET. Identifiers need the
  provider's syntax and deliberate escaping; parameters cannot quote identifiers.
  Migration script text is executable user input by design: preserve it rather
  than attempting to parameterize or globally rewrite its literals.
- Respect `Parameterize`, provider boolean/date/identity representations,
  schema support, and default/admin command timeouts. A shared SQL change must
  be checked against affected providers, including case-sensitive identifiers.
- Splitters are dialect-specific. Cover delimiters inside literals, quoted
  identifiers, comments, and multiline constructs relevant to the dialect.
  Assert the complete ordered batches; a batch count alone can hide lost SQL.
- Embedded `Bootstrapping/Sql/Baseline` and `GrateStructure` scripts serve both
  fresh installs and upgrades. For structure changes, prove both paths and
  preserve already-applied history; do not rewrite historical upgrade scripts
  casually. Check resource inclusion in the provider project.
- Put a common behavior test in `TestCommon/Generic` when it truly applies across
  providers, then inspect inheriting projects and overrides. Keep provider-only
  behavior in that provider's tests. SQLite or a mock cannot establish another
  provider's dialect, timeout, DDL, or transaction behavior.

Use synthetic, isolated databases and the existing test fixtures. Inspect test
configuration before execution: `GrateTestConfig` can select external database
connections instead of containers. Never infer permission to use live databases
or provision cloud infrastructure from a request for local code changes.
