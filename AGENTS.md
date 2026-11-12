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
- `README.md`: the GitHub entry point. `docs/`: user documentation and the
  GitHub Pages site; `docs/agents/`: repository development guidance.
- `examples/`: consumer workflows. `installers/` and `scripts/release/`:
  distribution packaging and release automation.

Read [provider guidance](docs/agents/providers.md) for SQL, history, splitters,
or transaction changes, and [verification guidance](docs/agents/verification.md)
for code changes and reviews. Use the [test and artifact map](docs/agents/testing.md)
to choose suites, database providers, binaries, and platforms. Read callers and
nearby tests before editing.

Keep Docker-backed provider tests out of `Basic_tests`. Windows CI runs those
provider namespaces without Docker.

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
  net8.0/net9.0/net10.0/net11.0 with nullable analysis and warnings as errors.
  Treat those files as the source of truth for SDK, test runner, and framework
  selection; a single-framework local run does not establish compatibility with
  all targets. See `CONTRIBUTING.md` for setup and the stable-SDK fallback.
- Use central package versions and existing dependencies. Match neighboring
  file-scoped namespaces, records/classes, naming, and async conventions; public
  methods here often have no `Async` suffix. Avoid style-only API changes.
- Use braces for C# `if` and `else` bodies, including single statements.
- When SQL grammar requires an interpolated identifier or literal, quote it
  using the provider's rules and explain why a parameter cannot be used.
- Keep failure and absence distinct. Do not mask errors with empty results,
  weaken assertions, or silence new warnings with broad suppressions. Explain
  narrowly necessary suppressions beside the code.
- Await I/O, preserve exceptions/cancellation, and keep ownership and disposal
  visible. Do not introduce blocking waits, unobserved tasks, or concurrent use
  of a migration's connection. Public signature changes need compatibility care.
- Keep credentials and access tokens out of logs and shared test evidence.

## Keep public documentation useful

- Lead the README with what grate does, supported databases, a small working
  example, and links to the next tasks. Keep RoundhousE compatibility in the
  migration guide rather than presenting feature catch-up as grate's purpose.
- Keep the README and `docs/index.md` consistent. Link to detailed configuration,
  installation, and release guidance instead of duplicating option tables or
  runtime/package-manager version lists that can drift.
- Check documented CLI options and defaults against the parser and configuration,
  and SQL examples against the named provider. Distinguish released features
  from changes available only in the checkout.
- For documentation-only changes, check relative links and affected examples.
  Exercise changed runnable examples against a disposable local database when
  practical; a full provider test matrix is not needed for prose edits. Report
  which executable/version was used and any checks that were not run.

## Write repository scripts in PowerShell

Use PowerShell 7 (`.ps1`, run with `pwsh`) for new repository automation and
script changes. Do not introduce Python scripts or a Python runtime dependency.
Use native PowerShell parameters, stop on errors, and propagate failures from
external commands. Update workflow callers, documentation, and relevant tests
when converting or renaming scripts. Keep SQL migration files in SQL.

The only shell-script exceptions are the small runtime launchers
`installers/docker/entrypoint.sh`, `examples/docker/my-entrypoint.sh`, and
`examples/k8s/multitenancy/script/migrate.sh`. Their container images do not
include PowerShell. Keep these launchers in POSIX shell unless changing that
runtime dependency is explicitly requested. Use PowerShell for host-side
development, CI and test orchestration, including Docker container tests.

### Keep PowerShell readable

- Use four spaces for indentation and spaces around assignments and operators.
  Separate functions and related setup, execution and assertion sections with
  blank lines. Keep closely related statements together.
- Write one statement per line. Expand `if`/`else`, loops, `try`/`catch`/`finally`,
  and nonempty returned objects into multiline blocks. Put function parameters
  in a multiline `param(...)` block and object properties on separate lines.
- Use descriptive names and full cmdlet and parameter names, without aliases or
  abbreviated parameters. Prefer straightforward control flow over clever
  pipelines or deeply nested inline expressions. Extract helpers for coherent
  responsibilities, not to satisfy arbitrary size limits.
- Wrap long argument lists as arrays; use splatting for long command calls.
  Prefer natural line breaks over backtick continuations. Build structured data
  as PowerShell objects or hashtables, then serialize with `ConvertTo-Json`.
- Prefer `Get-Content`, `Set-Content` and `Add-Content` with `-LiteralPath` for
  ordinary text files. Specify encoding and newline behavior when they matter.
  Keep .NET APIs where byte fidelity, atomic writes, streaming or bounded process
  control require them; explain the constraint beside the code.
- Keep formatting/refactoring behavior-preserving: retain array shapes, case
  sensitivity, output streams, exit codes, timeouts and cleanup. Run affected
  checks; formatting alone does not prove the behavior stayed the same.

References: Microsoft's [PowerShell style guidance](https://learn.microsoft.com/powershell/scripting/community/contributing/powershell-style-guide#coding-style-rules),
[consistent indentation rule](https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/rules/useconsistentindentation),
and [guidance on aliases in scripts](https://learn.microsoft.com/powershell/scripting/learn/shell/using-aliases#dont-use-aliases-in-scripts).

## Keep verification output out of git

Keep point-in-time logs, test reports, API observations, migration plans and other
execution evidence in CI artifacts or linked PR/release records, not in git.
Commit reusable tests, configuration templates and instructions; report actual
check outcomes and their limits in the review or release record.

Finish with the changed behavior, exact checks and outcomes, and remaining
provider/runtime gaps. A review reports actionable defects and evidence limits;
it does not silently implement fixes or claim release approval.
