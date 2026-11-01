# Working on grate

This repository develops the migration tool and its .NET libraries. The skill in
`docs/skills/use-grate/` teaches consumers to run grate; it is not the development
contract for this repository. Start with `CONTRIBUTING.md` and the relevant code.
Repository skill-installation code, tests, and bundled SQL fixtures remain normal
product scope; their names do not make them external development instructions.

## Locate the change

- `src/grate`: CLI commands, parsing, console output, and skill installation.
- `src/grate.core`: configuration, folder policies, migration orchestration,
  history, tokens, hashes, and shared database behavior.
- `src/grate.{sqlserver,postgresql,mariadb,oracle,sqlite}`: provider connections,
  SQL syntax, statement splitting, exceptions, and embedded bootstrap SQL.
- `unittests/Basic_tests`: isolated rules and CLI/configuration checks.
  `unittests/TestCommon`: shared fixtures and inherited provider contracts.
  Provider projects exercise actual databases. CommandLine and Docker projects
  exercise distribution boundaries; their artifacts and environments matter.

Read [provider guidance](docs/agents/providers.md) for SQL, history, splitters,
or transaction changes, and [verification guidance](docs/agents/verification.md)
for code changes and reviews. Use the [test and artifact map](docs/agents/testing.md)
to choose suites, database providers, binaries, and platforms. Read callers and
nearby tests before editing.

## Implement and challenge separately

For nontrivial implementation, use separate implementation and critical-review
subagents when the tool and task instructions permit delegation. Start with one
implementer and one reviewer; add specialists only for distinct risks. Small,
straightforward edits can use a separate self-review pass. If subagents are
unavailable or prohibited, report that limitation and perform the review yourself.

- Give implementers bounded scope, acceptance criteria, owned paths, and relevant
  checks. Isolate concurrent edits in separate worktrees or nonoverlapping files.
- Give a different agent the original requirements, final diff, surrounding code,
  and raw check results. Ask it to challenge behavior, compatibility, test
  sensitivity, and artifact/provider coverage. Review is read-only; do not ask
  for a predetermined verdict or a fixed number of findings.
- Have the implementer address substantiated findings, then have the reviewer
  recheck material fixes. Bound review rounds and disclose unresolved findings.
  The coordinating agent inspects the integrated diff and relevant check results;
  agreement between agents is not verification or release approval.

## Preserve the contract

- Identify the observable behavior being changed: selected scripts, order,
  history rows, outputs, failures, or public configuration/API behavior.
  Preserve the other behavior and explain intentional compatibility changes.
- Hashes and script names are persisted migration identity. Changing their
  normalization, encoding, comparison, or algorithm can rerun scripts or reject
  existing migrations. Require compatibility examples before changing them.
- Keep one-time, anytime, everytime, environment, dry-run, and baseline policies
  distinct. A successful command or mocked database call alone does not prove
  that SQL ran, was skipped, or rolled back as intended.
- Make the smallest coherent change. Avoid unrelated formatting, renames,
  dependency upgrades, abstractions, and provider rewrites. Extract helpers when
  they clarify a real policy or resource boundary, not to satisfy a line count.
- Add automated tests for new functionality and focused regression coverage for
  bug fixes. Cover observable outcomes, relevant boundaries, and failures at the
  appropriate test layer; explain any unverified behavior or missing environment.

## Match the .NET project

- Inspect `global.json`, `Directory.Build.props`, `Directory.Packages.props`,
  `.editorconfig`, and the changed project's `.csproj`. The repository targets
  net8.0/net9.0/net10.0 with nullable analysis and warnings as errors; a net10-only
  local run does not establish compatibility with all targets.
- Use central package versions and existing dependencies. Match neighboring
  file-scoped namespaces, records/classes, naming, and async conventions; public
  methods here often have no `Async` suffix. Avoid style-only API changes.
- Keep failure and absence distinct. Do not mask errors with empty results,
  weaken assertions, or silence new warnings with broad suppressions. Explain
  narrowly necessary suppressions beside the code.
- Await I/O, preserve exceptions/cancellation, and keep ownership and disposal
  visible. Do not introduce blocking waits, unobserved tasks, or concurrent use
  of a migration's connection. Public signature changes need compatibility care.
- Keep credentials and access tokens out of logs and shared test evidence.

Finish with the changed behavior, exact checks and outcomes, and remaining
provider/runtime gaps. A review reports actionable defects and evidence limits;
it does not silently implement fixes or claim release approval.
